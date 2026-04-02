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

  def disconnected(:internal, :connect, data) do
    case do_connect(data) do
      {:ok, conn, request_ref} ->
        {:next_state, :connecting, %{data | conn: conn, request_ref: request_ref}}

      {:error, reason, data} ->
        if data.reconnect == false do
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
      data = %{data | reconnect_timer: nil}

      case do_connect(data) do
        {:ok, conn, request_ref} ->
          {:next_state, :connecting, %{data | conn: conn, request_ref: request_ref}}

        {:error, reason, data} ->
          {:keep_state, %{data | disconnect_reason: {:error, reason}},
           [{:next_event, :internal, :connect_failed}]}
      end
    end
  end

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

  def disconnected({:call, from}, :disconnect, data) do
    data = cancel_reconnect_timer(data)
    {:keep_state, data, [{:reply, from, :ok}]}
  end

  ## :connecting state

  def connecting(:enter, :disconnected, data) do
    {:keep_state_and_data, [{:state_timeout, data.connect_timeout, :connect_timeout}]}
  end

  def connecting(:state_timeout, :connect_timeout, data) do
    {:next_state, :disconnected, %{data | disconnect_reason: :connect_timeout}}
  end

  def connecting(:info, message, data) do
    case Mint.WebSocket.stream(data.conn, message) do
      {:ok, conn, responses} ->
        handle_upgrade_responses(%{data | conn: conn}, responses)

      {:error, conn, reason, _responses} ->
        {:next_state, :disconnected, %{data | conn: conn, disconnect_reason: {:error, reason}}}

      :unknown ->
        case data.module.handle_info(message, data.user_state) do
          {:ok, user_state} ->
            {:keep_state, %{data | user_state: user_state}}

          {:push, _frame, user_state} ->
            Logger.warning("Ignoring {:push, ...} from handle_info/2 while connecting")
            {:keep_state, %{data | user_state: user_state}}

          {:disconnect, reason, user_state} ->
            {:next_state, :disconnected,
             %{data | user_state: user_state, disconnect_reason: reason}}

          {:stop, reason, user_state} ->
            if data.conn, do: Mint.HTTP.close(data.conn)
            {:stop, reason, %{data | user_state: user_state, conn: nil}}
        end
    end
  end

  def connecting({:call, _from}, {:send, _frame}, _data) do
    {:keep_state_and_data, [:postpone]}
  end

  def connecting({:call, from}, :disconnect, data) do
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
    case Mint.WebSocket.encode(data.websocket, frame) do
      {:ok, websocket, encoded} ->
        case Mint.WebSocket.stream_request_body(data.conn, data.request_ref, encoded) do
          {:ok, conn} ->
            {:keep_state, %{data | conn: conn, websocket: websocket}, [{:reply, from, :ok}]}

          {:error, conn, reason} ->
            {:next_state, :disconnected, %{data | conn: conn}, [{:reply, from, {:error, reason}}]}
        end

      {:error, websocket, reason} ->
        {:keep_state, %{data | websocket: websocket}, [{:reply, from, {:error, reason}}]}
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

  ## Private helpers

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
        {:stop, {:error, :max_retries_exceeded}, data}
      else
        base_delay = Keyword.fetch!(reconnect_opts, :base_delay)
        max_delay = Keyword.fetch!(reconnect_opts, :max_delay)
        delay = calculate_delay(base_delay, max_delay, data.reconnect_attempt)

        timer = Process.send_after(self(), :reconnect, delay)

        {:keep_state,
         %{data | reconnect_timer: timer, reconnect_attempt: data.reconnect_attempt + 1}}
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
      case Mint.WebSocket.new(data.conn, data.request_ref, data.status, data.resp_headers) do
        {:ok, conn, websocket} ->
          {:next_state, :connected,
           %{data | conn: conn, websocket: websocket, status: nil, resp_headers: []}}

        {:error, conn, reason} ->
          {:next_state, :disconnected, %{data | conn: conn, disconnect_reason: {:error, reason}}}
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
      {:close, code, reason}, {:ok, data} ->
        data = send_close(data)
        {:halt, {:close, code, reason, data}}

      {:ping, payload}, {:ok, data} ->
        data = send_pong(data, payload)
        handle_frame_result(data.module.handle_ping(payload, data.user_state), data)

      frame, {:ok, data} ->
        handle_frame_result(data.module.handle_frame(frame, data.user_state), data)
    end)
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

  defp send_frame_internal(data, frame) do
    case Mint.WebSocket.encode(data.websocket, frame) do
      {:ok, websocket, encoded} ->
        case Mint.WebSocket.stream_request_body(data.conn, data.request_ref, encoded) do
          {:ok, conn} ->
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
