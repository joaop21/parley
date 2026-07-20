defmodule Parley.Connection do
  @moduledoc false

  require Logger

  @behaviour :gen_statem

  @default_connect_timeout 10_000
  @default_reconnect_opts [base_delay: 1_000, max_delay: 30_000, max_retries: :infinity]

  defstruct [
    :conn,
    :websocket,
    :request_ref,
    :uri,
    :module,
    :user_state,
    :reconnect_timer,
    # Monotonic time at which the open connect span started. Non-nil means a
    # [:parley, :connect, :start] has fired without its matching :stop yet, so
    # it doubles as the open-span flag. Nulled the moment the span is closed.
    :connect_started_at,
    connect_timeout: @default_connect_timeout,
    headers: [],
    transport_opts: [],
    protocols: [:http1],
    status: nil,
    resp_headers: [],
    disconnect_reason: :closed,
    reconnect: false,
    reconnect_attempt: 0
  ]

  ## gen_statem callbacks

  @impl true
  def callback_mode, do: [:state_functions, :state_enter]

  @impl true
  def init({module, {url, user_state, opts}}) do
    # Trap exits so that on shutdown gen_statem terminates cleanly (running
    # terminate/3) instead of being killed by the signal. gen_statem consumes
    # the *parent's* EXIT in its own loop; the intercept clauses in each state
    # handle only *non-parent* EXITs (a linked worker, the transport port),
    # preserving the untrapped behaviour for those.
    Process.flag(:trap_exit, true)

    case module.init(user_state) do
      {:ok, user_state} ->
        uri = URI.parse(url)
        connect_timeout = Keyword.get(opts, :connect_timeout, @default_connect_timeout)
        headers = Keyword.get(opts, :headers, [])
        transport_opts = Keyword.get(opts, :transport_opts, [])
        protocols = Keyword.get(opts, :protocols, [:http1])
        reconnect = parse_reconnect(Keyword.get(opts, :reconnect, false))

        data = %__MODULE__{
          uri: uri,
          module: module,
          user_state: user_state,
          connect_timeout: connect_timeout,
          headers: headers,
          transport_opts: transport_opts,
          protocols: protocols,
          reconnect: reconnect
        }

        {:ok, :disconnected, data, [{:next_event, :internal, :connect}]}

      {:stop, reason} ->
        {:stop, reason}
    end
  end

  ## :disconnected state

  def disconnected(:enter, :disconnected, _data) do
    :keep_state_and_data
  end

  def disconnected(:enter, _old_state, data) do
    # Safety net: any path that reached :disconnected with the span still open
    # (a {:stop, ...} from a state-enter clause, an unhandled transition) closes
    # it as :aborted here. Explicit close sites null the flag first, so this
    # no-ops for them.
    data = stop_connect_span(data, :aborted, data.disconnect_reason)

    if data.conn, do: Mint.HTTP.close(data.conn)

    data = %{
      data
      | conn: nil,
        websocket: nil,
        request_ref: nil,
        status: nil,
        resp_headers: []
    }

    case data.module.handle_disconnect(data.disconnect_reason, data.user_state) do
      {:reconnect, user_state} ->
        maybe_reconnect(:reconnect, %{data | user_state: user_state, disconnect_reason: :closed})

      {:disconnect, user_state} ->
        {:keep_state, %{data | user_state: user_state, disconnect_reason: :closed}}

      {:ok, user_state} ->
        maybe_reconnect(:ok, %{data | user_state: user_state, disconnect_reason: :closed})
    end
  end

  # Opening the span and running do_connect are split across two internal
  # events on purpose: the :start-carrying data must be committed to gen_statem
  # *before* do_connect runs, so that a raise inside do_connect (e.g.
  # ws_to_http_scheme/1 on a bad scheme, or Mint.HTTP.connect/4 on bad
  # transport_opts) still leaves terminate/3 a non-nil connect_started_at to
  # emit the balancing :stop against.
  def disconnected(:internal, :connect, data) do
    {:keep_state, start_connect_span(data), [{:next_event, :internal, {:do_connect, :initial}}]}
  end

  # `origin` distinguishes the two do_connect callers so the error branch keeps
  # its original behaviour: only the *initial* connect with reconnection disabled
  # stops the process; a retry (which may be forced by handle_disconnect's
  # {:reconnect, ...} even when the `reconnect` option is false) always falls
  # through to :connect_failed.
  def disconnected(:internal, {:do_connect, origin}, data) do
    case do_connect(data) do
      {:ok, conn, request_ref} ->
        {:next_state, :connecting, %{data | conn: conn, request_ref: request_ref}}

      {:error, reason, data} ->
        data = stop_connect_span(data, :error, reason)

        if origin == :initial and data.reconnect == false do
          {:stop, {:error, reason}, data}
        else
          {:keep_state, %{data | disconnect_reason: {:error, reason}},
           [{:next_event, :internal, :connect_failed}]}
        end
    end
  end

  def disconnected(:internal, :connect_failed, data) do
    case data.module.handle_disconnect(data.disconnect_reason, data.user_state) do
      {:reconnect, user_state} ->
        maybe_reconnect(:reconnect, %{data | user_state: user_state, disconnect_reason: :closed})

      {:disconnect, user_state} ->
        {:keep_state, %{data | user_state: user_state, disconnect_reason: :closed}}

      {:ok, user_state} ->
        maybe_reconnect(:ok, %{data | user_state: user_state, disconnect_reason: :closed})
    end
  end

  def disconnected(:info, :reconnect, data) do
    # Stale message -- timer was cancelled
    if data.reconnect_timer == nil do
      :keep_state_and_data
    else
      # Open the span only once the stale-timer guard has passed, then hand off
      # to the shared :do_connect handler (see disconnected(:internal, :connect,
      # ...)) so the same commit-before-connect protection applies here.
      data = start_connect_span(%{data | reconnect_timer: nil})
      {:keep_state, data, [{:next_event, :internal, {:do_connect, :reconnect}}]}
    end
  end

  def disconnected(:info, {:EXIT, _from, reason}, data) do
    handle_linked_exit(reason, data)
  end

  # Leftover transport frames (e.g. a server close frame still in the mailbox
  # after we transitioned to :disconnected) must be consumed here, not leaked to
  # the client's handle_info/2 as raw wire bytes. Only :disconnected drops them:
  # in :connecting/:connected they belong to the live conn and are consumed by
  # Mint.WebSocket.stream/2, but here conn is nil so nothing else would.
  def disconnected(:info, {:tcp, _socket, _bytes}, _data), do: :keep_state_and_data
  def disconnected(:info, {:tcp_closed, _socket}, _data), do: :keep_state_and_data
  def disconnected(:info, {:tcp_error, _socket, _reason}, _data), do: :keep_state_and_data
  def disconnected(:info, {:ssl, _socket, _bytes}, _data), do: :keep_state_and_data
  def disconnected(:info, {:ssl_closed, _socket}, _data), do: :keep_state_and_data
  def disconnected(:info, {:ssl_error, _socket, _reason}, _data), do: :keep_state_and_data

  def disconnected(:info, message, data) do
    case data.module.handle_info(message, data.user_state) do
      {:ok, user_state} ->
        {:keep_state, %{data | user_state: user_state}}

      {:push, _frame, user_state} ->
        Logger.warning("Ignoring {:push, ...} from handle_info/2 while disconnected")
        {:keep_state, %{data | user_state: user_state}}

      {:disconnect, _reason, user_state} ->
        {:keep_state, %{data | user_state: user_state}}

      {:stop, reason, user_state} ->
        {:stop, reason, %{data | user_state: user_state}}
    end
  end

  def disconnected({:call, from}, {:send, _frame}, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :disconnected}}]}
  end

  def disconnected(:cast, {:send, _frame}, _data) do
    :keep_state_and_data
  end

  def disconnected({:call, from}, :disconnect, data) do
    data = cancel_reconnect_timer(data)
    {:keep_state, data, [{:reply, from, :ok}]}
  end

  ## :connecting state

  def connecting(:enter, :disconnected, data) do
    {:keep_state_and_data, [{:state_timeout, data.connect_timeout, :connect_timeout}]}
  end

  def connecting(:state_timeout, :connect_timeout, data) do
    data = stop_connect_span(data, :error, :connect_timeout)
    {:next_state, :disconnected, %{data | disconnect_reason: :connect_timeout}}
  end

  def connecting(:info, {:EXIT, _from, reason}, data) do
    handle_linked_exit(reason, data)
  end

  def connecting(:info, message, data) do
    case Mint.WebSocket.stream(data.conn, message) do
      {:ok, conn, responses} ->
        handle_upgrade_responses(%{data | conn: conn}, responses)

      {:error, conn, reason, _responses} ->
        data = stop_connect_span(%{data | conn: conn}, :error, {:error, reason})
        {:next_state, :disconnected, %{data | disconnect_reason: {:error, reason}}}

      :unknown ->
        case data.module.handle_info(message, data.user_state) do
          {:ok, user_state} ->
            {:keep_state, %{data | user_state: user_state}}

          {:push, _frame, user_state} ->
            Logger.warning("Ignoring {:push, ...} from handle_info/2 while connecting")
            {:keep_state, %{data | user_state: user_state}}

          {:disconnect, reason, user_state} ->
            data = %{data | user_state: user_state, disconnect_reason: reason}
            data = stop_connect_span(data, :aborted, reason)
            {:next_state, :disconnected, data}

          {:stop, reason, user_state} ->
            if data.conn, do: Mint.HTTP.close(data.conn)
            {:stop, reason, %{data | user_state: user_state, conn: nil}}
        end
    end
  end

  def connecting({:call, _from}, {:send, _frame}, _data) do
    {:keep_state_and_data, [:postpone]}
  end

  def connecting(:cast, {:send, _frame}, _data) do
    {:keep_state_and_data, [:postpone]}
  end

  def connecting({:call, from}, :disconnect, data) do
    data = stop_connect_span(data, :aborted, :closed)
    {:next_state, :disconnected, %{data | disconnect_reason: :closed}, [{:reply, from, :ok}]}
  end

  ## :connected state

  def connected(:enter, :connecting, data) do
    data = %{data | reconnect_attempt: 0, reconnect_timer: nil}

    case data.module.handle_connect(data.user_state) do
      {:ok, user_state} ->
        {:keep_state, %{data | user_state: user_state}}

      {:push, frame, user_state} ->
        data = %{data | user_state: user_state}

        case send_frame_internal(data, frame) do
          {:ok, data} ->
            {:keep_state, data}

          {:error, :encode, data, reason} ->
            Logger.warning("Failed to encode frame: #{inspect(reason)}")
            {:keep_state, data}

          {:error, :send, data, reason} ->
            {:keep_state, %{data | disconnect_reason: {:error, reason}},
             [{:next_event, :internal, :send_failed}]}
        end

      # Enter callbacks cannot perform state transitions or emit internal
      # events, so we schedule an immediate state timeout to transition
      # to :disconnected on the next step.
      {:disconnect, reason, user_state} ->
        data = %{data | user_state: user_state, disconnect_reason: reason}
        data = send_close(data)
        {:keep_state, data, [{:state_timeout, 0, :user_disconnect}]}

      {:stop, reason, user_state} ->
        if data.conn, do: Mint.HTTP.close(data.conn)
        {:stop, reason, %{data | user_state: user_state, conn: nil}}
    end
  end

  def connected(:state_timeout, :user_disconnect, data) do
    {:next_state, :disconnected, data}
  end

  def connected(:internal, :send_failed, data) do
    {:next_state, :disconnected, data}
  end

  def connected(:info, {:EXIT, _from, reason}, data) do
    handle_linked_exit(reason, data)
  end

  def connected(:info, message, data) do
    case Mint.WebSocket.stream(data.conn, message) do
      {:ok, conn, responses} ->
        handle_data_responses(%{data | conn: conn}, responses)

      {:error, conn, reason, _responses} ->
        {:next_state, :disconnected, %{data | conn: conn, disconnect_reason: {:error, reason}}}

      :unknown ->
        handle_info_result(data.module.handle_info(message, data.user_state), data)
    end
  end

  def connected({:call, from}, {:send, frame}, data) do
    case send_frame_internal(data, frame) do
      {:ok, data} ->
        {:keep_state, data, [{:reply, from, :ok}]}

      {:error, :encode, data, reason} ->
        {:keep_state, data, [{:reply, from, {:error, reason}}]}

      {:error, :send, data, reason} ->
        {:next_state, :disconnected, %{data | disconnect_reason: {:error, reason}},
         [{:reply, from, {:error, reason}}]}
    end
  end

  def connected(:cast, {:send, frame}, data) do
    case send_frame_internal(data, frame) do
      {:ok, data} ->
        {:keep_state, data}

      {:error, :encode, data, reason} ->
        Logger.warning("Failed to encode async frame: #{inspect(reason)}")
        {:keep_state, data}

      {:error, :send, data, reason} ->
        {:next_state, :disconnected, %{data | disconnect_reason: {:error, reason}}}
    end
  end

  def connected({:call, from}, :disconnect, data) do
    case Mint.WebSocket.encode(data.websocket, :close) do
      {:ok, websocket, encoded} ->
        case Mint.WebSocket.stream_request_body(data.conn, data.request_ref, encoded) do
          {:ok, conn} ->
            {:next_state, :disconnected,
             %{data | conn: conn, websocket: websocket, disconnect_reason: :closed},
             [{:reply, from, :ok}]}

          {:error, conn, _reason} ->
            {:next_state, :disconnected, %{data | conn: conn, disconnect_reason: :closed},
             [{:reply, from, :ok}]}
        end

      {:error, _websocket, _reason} ->
        {:next_state, :disconnected, %{data | disconnect_reason: :closed}, [{:reply, from, :ok}]}
    end
  end

  # Last-resort span close. Runs on every stop, including crashes and shutdowns
  # (a {:stop, ...} from a state-enter clause hands us the *new* state, so we
  # never match on state). Emits :aborted only when the span is still open; a
  # normal close already nulled the flag, making this a no-op.
  @impl true
  def terminate(reason, _state, %__MODULE__{} = data) do
    stop_connect_span(data, :aborted, reason)
    :ok
  end

  def terminate(_reason, _state, _data), do: :ok

  ## Private helpers

  # Opens the connect span: records the monotonic start time (also the open-span
  # flag) before emitting, so a slow handler can't inflate the measured
  # duration, and reads the attempt index straight off the data.
  defp start_connect_span(data) do
    data = %{data | connect_started_at: System.monotonic_time()}
    Parley.Telemetry.connect_start(data.module, data.uri, data.reconnect_attempt)
    data
  end

  # Closes the connect span, nulling the flag. Idempotent: a nil flag means the
  # span is already closed, so repeated closes (explicit site then safety net
  # then terminate/3) collapse to a single :stop.
  defp stop_connect_span(%__MODULE__{connect_started_at: nil} = data, _outcome, _reason), do: data

  defp stop_connect_span(%__MODULE__{connect_started_at: started_at} = data, outcome, reason) do
    duration = System.monotonic_time() - started_at

    Parley.Telemetry.connect_stop(
      data.module,
      data.uri,
      data.reconnect_attempt,
      duration,
      outcome,
      reason
    )

    %{data | connect_started_at: nil}
  end

  defp parse_reconnect(false), do: false
  defp parse_reconnect(true), do: @default_reconnect_opts

  defp parse_reconnect(opts) when is_list(opts) do
    Keyword.merge(@default_reconnect_opts, opts)
  end

  defp do_connect(data) do
    %{uri: uri} = data

    http_scheme = ws_to_http_scheme(uri.scheme)
    port = uri.port || default_port(uri.scheme)

    ws_scheme = ws_scheme(uri.scheme)
    path = (uri.path || "/") <> if(uri.query, do: "?#{uri.query}", else: "")

    connect_opts = [protocols: data.protocols, transport_opts: data.transport_opts]

    with {:ok, conn} <- Mint.HTTP.connect(http_scheme, uri.host, port, connect_opts),
         {:ok, conn, request_ref} <- Mint.WebSocket.upgrade(ws_scheme, conn, path, data.headers) do
      {:ok, conn, request_ref}
    else
      {:error, reason} ->
        {:error, reason, data}

      {:error, conn, reason} ->
        Mint.HTTP.close(conn)
        {:error, reason, data}
    end
  end

  defp maybe_reconnect(callback_return, data) do
    reconnect_opts = effective_reconnect_opts(callback_return, data.reconnect)

    if reconnect_opts do
      max_retries = Keyword.fetch!(reconnect_opts, :max_retries)

      if max_retries != :infinity and data.reconnect_attempt >= max_retries do
        Parley.Telemetry.reconnect_exhausted(data)
        {:stop, {:error, :max_retries_exceeded}, data}
      else
        base_delay = Keyword.fetch!(reconnect_opts, :base_delay)
        max_delay = Keyword.fetch!(reconnect_opts, :max_delay)
        # calculate_delay/3 gets the PRE-increment attempt so the first retry
        # is base_delay * 2^0.
        delay = calculate_delay(base_delay, max_delay, data.reconnect_attempt)

        timer = Process.send_after(self(), :reconnect, delay)

        # Increment BEFORE emitting so :scheduled reports the post-increment
        # attempt (1 for the first retry), aligning it with the connect that
        # follows. The :reconnect message sits in the mailbox until this
        # function returns, so the timer cannot race the emit.
        data = %{data | reconnect_timer: timer, reconnect_attempt: data.reconnect_attempt + 1}
        Parley.Telemetry.reconnect_scheduled(data, delay)

        {:keep_state, data}
      end
    else
      {:keep_state, data}
    end
  end

  defp effective_reconnect_opts(:reconnect, false), do: @default_reconnect_opts
  defp effective_reconnect_opts(:reconnect, opts) when is_list(opts), do: opts
  defp effective_reconnect_opts(:ok, false), do: nil
  defp effective_reconnect_opts(:ok, opts) when is_list(opts), do: opts

  defp calculate_delay(base_delay, max_delay, attempt) do
    delay = min(base_delay * Integer.pow(2, attempt), max_delay)
    half = max(div(delay, 2), 1)
    half + :rand.uniform(half)
  end

  defp cancel_reconnect_timer(%{reconnect_timer: nil} = data), do: data

  defp cancel_reconnect_timer(%{reconnect_timer: timer} = data) do
    Process.cancel_timer(timer)
    %{data | reconnect_timer: nil}
  end

  # Mint.HTTP.t() is opaque so Dialyzer can't prove Mint.WebSocket.new/4
  # can return {:ok, ...} through the opaque boundary.
  @dialyzer {:no_match, handle_upgrade_responses: 2}
  defp handle_upgrade_responses(data, responses) do
    data =
      Enum.reduce(responses, data, fn
        {:status, _ref, status}, data ->
          %{data | status: status}

        {:headers, _ref, headers}, data ->
          %{data | resp_headers: data.resp_headers ++ headers}

        {:done, _ref}, data ->
          data

        _other, data ->
          data
      end)

    if done?(responses) do
      # Emit the :stop inside each branch, not before the case: the {:ok, ...}
      # branch closes the span as :ok while it is still the :connecting state
      # (attempt not yet reset), and the {:error, ...} branch as :error.
      case Mint.WebSocket.new(data.conn, data.request_ref, data.status, data.resp_headers) do
        {:ok, conn, websocket} ->
          data = %{data | conn: conn, websocket: websocket, status: nil, resp_headers: []}
          data = stop_connect_span(data, :ok, nil)
          {:next_state, :connected, data}

        {:error, conn, reason} ->
          data = stop_connect_span(%{data | conn: conn}, :error, {:error, reason})
          {:next_state, :disconnected, %{data | disconnect_reason: {:error, reason}}}
      end
    else
      {:keep_state, data}
    end
  end

  defp handle_data_responses(data, responses) do
    Enum.reduce(responses, {:keep_state, data}, fn
      {:data, _ref, raw}, {:keep_state, data} ->
        decode_and_process(data, raw)

      _other, acc ->
        acc
    end)
    |> case do
      {:keep_state, data} -> {:keep_state, data}
      {:next_state, state, data} -> {:next_state, state, data}
      {:stop, reason, data} -> {:stop, reason, data}
    end
  end

  defp decode_and_process(data, raw) do
    case Mint.WebSocket.decode(data.websocket, raw) do
      {:ok, websocket, frames} ->
        data = %{data | websocket: websocket}

        case process_frames(data, frames) do
          {:ok, data} ->
            {:keep_state, data}

          {:close, code, reason, data} ->
            {:next_state, :disconnected,
             %{data | disconnect_reason: {:remote_close, code, reason}}}

          {:close_on_send_error, reason, data} ->
            {:next_state, :disconnected, %{data | disconnect_reason: {:error, reason}}}

          {:disconnect, reason, data} ->
            {:next_state, :disconnected, %{data | disconnect_reason: reason}}

          {:stop, reason, data} ->
            if data.conn, do: Mint.HTTP.close(data.conn)
            {:stop, reason, %{data | conn: nil}}
        end

      {:error, websocket, reason} ->
        {:next_state, :disconnected,
         %{data | websocket: websocket, disconnect_reason: {:error, reason}}}
    end
  end

  defp process_frames(data, frames) do
    Enum.reduce_while(frames, {:ok, data}, fn
      # Close frames are lifecycle, not data: they must not emit frame:received,
      # so they are handled here before the single emit site below.
      {:close, code, reason}, {:ok, data} ->
        data = send_close(data)
        {:halt, {:close, code, reason, data}}

      frame, {:ok, data} ->
        Parley.Telemetry.frame_received(frame, data.module, data.uri)
        dispatch_frame(frame, data)
    end)
  end

  defp dispatch_frame({:ping, payload}, data) do
    data = send_pong(data, payload)
    handle_frame_result(data.module.handle_ping(payload, data.user_state), data)
  end

  defp dispatch_frame(frame, data) do
    handle_frame_result(data.module.handle_frame(frame, data.user_state), data)
  end

  defp handle_frame_result({:ok, user_state}, data) do
    {:cont, {:ok, %{data | user_state: user_state}}}
  end

  defp handle_frame_result({:push, reply_frame, user_state}, data) do
    data = %{data | user_state: user_state}

    case send_frame_internal(data, reply_frame) do
      {:ok, data} ->
        {:cont, {:ok, data}}

      {:error, :encode, data, reason} ->
        Logger.warning("Failed to encode frame: #{inspect(reason)}")
        {:cont, {:ok, data}}

      {:error, :send, data, reason} ->
        {:halt, {:close_on_send_error, reason, data}}
    end
  end

  defp handle_frame_result({:disconnect, reason, user_state}, data) do
    data = send_close(data)
    {:halt, {:disconnect, reason, %{data | user_state: user_state}}}
  end

  defp handle_frame_result({:stop, reason, user_state}, data) do
    {:halt, {:stop, reason, %{data | user_state: user_state}}}
  end

  defp handle_info_result({:ok, user_state}, data) do
    {:keep_state, %{data | user_state: user_state}}
  end

  defp handle_info_result({:push, frame, user_state}, data) do
    data = %{data | user_state: user_state}

    case send_frame_internal(data, frame) do
      {:ok, data} ->
        {:keep_state, data}

      {:error, :encode, data, reason} ->
        Logger.warning("Failed to encode frame: #{inspect(reason)}")
        {:keep_state, data}

      {:error, :send, data, reason} ->
        {:keep_state, %{data | disconnect_reason: {:error, reason}},
         [{:next_event, :internal, :send_failed}]}
    end
  end

  defp handle_info_result({:disconnect, reason, user_state}, data) do
    data = %{data | user_state: user_state}
    data = send_close(data)
    {:next_state, :disconnected, %{data | disconnect_reason: reason}}
  end

  defp handle_info_result({:stop, reason, user_state}, data) do
    if data.conn, do: Mint.HTTP.close(data.conn)
    {:stop, reason, %{data | user_state: user_state, conn: nil}}
  end

  # We trap exits (see init/1), so we replicate OTP's default behaviour for a
  # linked process' EXIT: ignore a :normal exit, die with the reason on an
  # abnormal one. There is deliberately no is_pid guard — the transport socket is
  # a linked *port*, not a pid, so an abnormal port death must stop us exactly as
  # it did before we trapped exits (an unguarded port EXIT would otherwise fall
  # through to stream/handle_info and leave us alive in a broken state). Every
  # state's non-parent {:EXIT, _, _} clause delegates here.
  defp handle_linked_exit(:normal, _data), do: :keep_state_and_data
  defp handle_linked_exit(reason, data), do: {:stop, reason, data}

  defp send_frame_internal(data, frame) do
    case Mint.WebSocket.encode(data.websocket, frame) do
      {:ok, websocket, encoded} ->
        case Mint.WebSocket.stream_request_body(data.conn, data.request_ref, encoded) do
          {:ok, conn} ->
            Parley.Telemetry.frame_sent(frame, data.module, data.uri)
            {:ok, %{data | conn: conn, websocket: websocket}}

          {:error, conn, reason} ->
            {:error, :send, %{data | conn: conn, websocket: websocket}, reason}
        end

      {:error, websocket, reason} ->
        {:error, :encode, %{data | websocket: websocket}, reason}
    end
  end

  defp send_close(data), do: send_frame_best_effort(data, :close)

  defp send_pong(data, payload), do: send_frame_best_effort(data, {:pong, payload})

  defp send_frame_best_effort(data, frame) do
    case send_frame_internal(data, frame) do
      {:ok, data} -> data
      {:error, _, data, _reason} -> data
    end
  end

  defp done?(responses), do: Enum.any?(responses, &match?({:done, _}, &1))

  defp ws_to_http_scheme("ws"), do: :http
  defp ws_to_http_scheme("wss"), do: :https

  defp ws_scheme("ws"), do: :ws
  defp ws_scheme("wss"), do: :wss

  defp default_port("ws"), do: 80
  defp default_port("wss"), do: 443
end
