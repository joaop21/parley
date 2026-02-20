defmodule Parley.Connection do
  @moduledoc false

  @behaviour :gen_statem

  defstruct [
    :conn,
    :websocket,
    :request_ref,
    :uri,
    :module,
    :user_state,
    status: nil,
    resp_headers: []
  ]

  ## Public API

  def start_link(module, opts) do
    {url, opts} = Keyword.pop!(opts, :url)
    {state, opts} = Keyword.pop(opts, :state, nil)
    {name, opts} = Keyword.pop(opts, :name)
    init_arg = {module, url, state}

    if name do
      :gen_statem.start_link(name, __MODULE__, init_arg, opts)
    else
      :gen_statem.start_link(__MODULE__, init_arg, opts)
    end
  end

  def send_frame(pid, frame) do
    :gen_statem.call(pid, {:send, frame})
  end

  def disconnect(pid) do
    :gen_statem.call(pid, :disconnect)
  end

  ## gen_statem callbacks

  @impl true
  def callback_mode, do: [:state_functions, :state_enter]

  @impl true
  def init({module, url, user_state}) do
    uri = URI.parse(url)

    data = %__MODULE__{
      uri: uri,
      module: module,
      user_state: user_state
    }

    {:ok, :disconnected, data, [{:next_event, :internal, :connect}]}
  end

  ## :disconnected state

  def disconnected(:enter, :disconnected, _data) do
    :keep_state_and_data
  end

  def disconnected(:enter, _old_state, data) do
    {:ok, user_state} = data.module.handle_disconnect(:closed, data.user_state)

    {:keep_state,
     %{
       data
       | user_state: user_state,
         conn: nil,
         websocket: nil,
         request_ref: nil,
         status: nil,
         resp_headers: []
     }}
  end

  def disconnected(:internal, :connect, data) do
    %{uri: uri} = data

    http_scheme = ws_to_http_scheme(uri.scheme)
    port = uri.port || default_port(uri.scheme)

    ws_scheme = ws_scheme(uri.scheme)
    path = (uri.path || "/") <> if(uri.query, do: "?#{uri.query}", else: "")

    with {:ok, conn} <- Mint.HTTP.connect(http_scheme, uri.host, port, protocols: [:http1]),
         {:ok, conn, request_ref} <- Mint.WebSocket.upgrade(ws_scheme, conn, path, []) do
      {:next_state, :connecting, %{data | conn: conn, request_ref: request_ref}}
    else
      # connect/3 fails
      {:error, reason} ->
        {:stop, {:error, reason}, data}

      # upgrade/4 fails
      {:error, conn, reason} ->
        Mint.HTTP.close(conn)
        {:stop, {:error, reason}, data}
    end
  end

  def disconnected({:call, from}, {:send, _frame}, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :disconnected}}]}
  end

  def disconnected({:call, from}, :disconnect, _data) do
    {:keep_state_and_data, [{:reply, from, :ok}]}
  end

  ## :connecting state

  def connecting(:enter, :disconnected, _data) do
    :keep_state_and_data
  end

  def connecting(:info, message, data) do
    case Mint.WebSocket.stream(data.conn, message) do
      {:ok, conn, responses} ->
        handle_upgrade_responses(%{data | conn: conn}, responses)

      {:error, conn, reason, _responses} ->
        Mint.HTTP.close(conn)

        {:next_state, :disconnected, %{data | conn: conn},
         [{:next_event, :internal, {:connect_error, reason}}]}

      :unknown ->
        :keep_state_and_data
    end
  end

  def connecting({:call, _from}, {:send, _frame}, _data) do
    {:keep_state_and_data, [:postpone]}
  end

  def connecting({:call, from}, :disconnect, data) do
    if data.conn, do: Mint.HTTP.close(data.conn)
    {:next_state, :disconnected, %{data | conn: nil}, [{:reply, from, :ok}]}
  end

  ## :connected state

  def connected(:enter, :connecting, data) do
    {:ok, user_state} = data.module.handle_connect(data.user_state)
    {:keep_state, %{data | user_state: user_state}}
  end

  def connected(:info, message, data) do
    case Mint.WebSocket.stream(data.conn, message) do
      {:ok, conn, responses} ->
        handle_data_responses(%{data | conn: conn}, responses)

      {:error, conn, reason, _responses} ->
        Mint.HTTP.close(conn)

        {:next_state, :disconnected, %{data | conn: conn},
         [{:next_event, :internal, {:connect_error, reason}}]}

      :unknown ->
        :keep_state_and_data
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
            Mint.HTTP.close(conn)

            {:next_state, :disconnected, %{data | conn: nil, websocket: websocket},
             [{:reply, from, :ok}]}

          {:error, conn, _reason} ->
            Mint.HTTP.close(conn)
            {:next_state, :disconnected, %{data | conn: nil}, [{:reply, from, :ok}]}
        end

      {:error, _websocket, _reason} ->
        if data.conn, do: Mint.HTTP.close(data.conn)
        {:next_state, :disconnected, %{data | conn: nil}, [{:reply, from, :ok}]}
    end
  end

  ## Private helpers

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
          Mint.HTTP.close(conn)
          {:stop, {:error, reason}, %{data | conn: conn}}
      end
    else
      {:keep_state, data}
    end
  end

  defp handle_data_responses(data, responses) do
    Enum.reduce(responses, {:keep_state, data}, fn
      {:data, _ref, raw}, {_action, data} ->
        case Mint.WebSocket.decode(data.websocket, raw) do
          {:ok, websocket, frames} ->
            data = %{data | websocket: websocket}
            data = process_frames(data, frames)
            {:keep_state, data}

          {:error, websocket, reason} ->
            Mint.HTTP.close(data.conn)

            {:next_state, :disconnected, %{data | websocket: websocket, conn: nil},
             [{:next_event, :internal, {:connect_error, reason}}]}
        end

      _other, acc ->
        acc
    end)
    |> case do
      {:keep_state, data} -> {:keep_state, data}
      {:next_state, state, data, actions} -> {:next_state, state, data, actions}
    end
  end

  defp process_frames(data, frames) do
    Enum.reduce(frames, data, fn
      {:close, _code, _reason}, data ->
        data

      {:ping, payload}, data ->
        send_pong(data, payload)

      frame, data ->
        {:ok, user_state} = data.module.handle_frame(frame, data.user_state)
        %{data | user_state: user_state}
    end)
  end

  defp send_pong(data, payload) do
    with {:ok, websocket, encoded} <- Mint.WebSocket.encode(data.websocket, {:pong, payload}),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(data.conn, data.request_ref, encoded) do
      %{data | conn: conn, websocket: websocket}
    else
      {:error, _, _} -> data
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
