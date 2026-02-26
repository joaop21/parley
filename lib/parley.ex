defmodule Parley do
  @moduledoc """
  A WebSocket client built on `gen_statem` and [Mint WebSocket](https://hexdocs.pm/mint_web_socket).

  `Parley` provides a callback-based API similar to `GenServer`. You define a
  module with `use Parley`, implement the callbacks you need, and interact with
  the connection through the functions in this module.

  ## Usage

      defmodule MyClient do
        use Parley

        @impl true
        def handle_connect(state) do
          IO.puts("Connected!")
          {:ok, state}
        end

        @impl true
        def handle_frame({:text, msg}, state) do
          IO.puts("Received: \#{msg}")
          {:ok, state}
        end

        @impl true
        def handle_disconnect(_reason, state) do
          IO.puts("Disconnected")
          {:ok, state}
        end
      end

  ### Starting with a pid

      {:ok, pid} = MyClient.start_link(%{}, url: "wss://example.com/ws")
      Parley.send_frame(pid, {:text, "hello"})
      Parley.disconnect(pid)

  ### Starting with a registered name

      {:ok, _pid} = MyClient.start_link(%{}, url: "wss://example.com/ws", name: MyClient)
      Parley.send_frame(MyClient, {:text, "hello"})
      Parley.disconnect(MyClient)

  ### Starting under a supervisor

      children = [
        {MyClient, {%{}, url: "wss://example.com/ws", name: MyClient}}
      ]

      Supervisor.start_link(children, strategy: :one_for_one)

  ## Options

    * `:url` (required) — the WebSocket URL to connect to (e.g. `"wss://example.com/ws"`)
    * `:name` — used for name registration, see the "Name registration" section below
    * `:connect_timeout` — timeout in milliseconds for the WebSocket upgrade
      handshake (default: `10_000`)

  ## Name registration

  The `:name` option supports the same values as `GenServer`:

    * an atom — registered locally with `{:local, atom}`
    * `{:global, term}` — registered with `:global`
    * `{:via, module, term}` — registered with a custom registry

  ## Connection lifecycle

  The connection is managed as a state machine with three states:

  ```mermaid
  stateDiagram-v2
      [*] --> disconnected: start_link/3

      disconnected --> connecting: TCP connect + WebSocket upgrade

      connecting --> connected: upgrade success
      connecting --> disconnected: error / timeout

      connected --> disconnected: error / close / disconnect/1

      state connected {
          [*] --> handle_connect
          handle_connect --> waiting
          waiting --> handle_frame: frame received
          handle_frame --> waiting
      }

      state disconnected {
          [*] --> handle_disconnect
      }
  ```

  - **`disconnected`** — initial state. On process start, immediately attempts to connect.
    Calls `c:handle_disconnect/2` when entering from another state.
  - **`connecting`** — TCP connection established, waiting for the WebSocket upgrade
    handshake to complete. Frames sent via `send_frame/2` during this state are
    automatically queued and delivered once connected.
  - **`connected`** — WebSocket upgrade complete. Calls `c:handle_connect/1` on entry,
    then `c:handle_frame/2` for each frame received from the server.

  ## Callbacks

  All callbacks are optional and have default implementations that return
  `{:ok, state}`. Override only the ones you need.

    * `c:handle_connect/1` — called when the WebSocket handshake completes
    * `c:handle_frame/2` — called when a frame is received from the server
    * `c:handle_disconnect/2` — called when the connection is lost or closed

  `c:handle_connect/1` and `c:handle_frame/2` also support `{:push, frame, state}`
  to send a frame from within the callback, and `{:stop, reason, state}` to stop
  the process. See the callback docs for details.
  """

  @typedoc "The user-managed state passed through all callbacks."
  @type state :: term()

  @typedoc "A WebSocket frame."
  @type frame :: {:text, String.t()} | {:binary, binary()} | {:ping, binary()} | {:pong, binary()}

  @doc """
  Called when the WebSocket handshake completes.

  ## Return values

    * `{:ok, state}` — update state, remain connected
    * `{:push, frame, state}` — send a frame immediately after connecting
      (useful for auth or subscribe messages)
    * `{:stop, reason, state}` — reject the connection, stop the process
  """
  @callback handle_connect(state) ::
              {:ok, state} | {:push, frame, state} | {:stop, reason :: term(), state}

  @doc """
  Called when a frame is received from the server.

  ## Return values

    * `{:ok, state}` — update state
    * `{:push, frame, state}` — send a frame back to the server
    * `{:stop, reason, state}` — close the connection and stop the process
  """
  @callback handle_frame(frame, state) ::
              {:ok, state} | {:push, frame, state} | {:stop, reason :: term(), state}

  @doc """
  Called when the connection is lost or closed.

  The `reason` indicates why the connection ended:

    * `:closed` — graceful disconnect via `disconnect/1`
    * `{:remote_close, code, reason}` — server-initiated close frame
    * `{:error, reason}` — stream or decode error
    * `:connect_timeout` — WebSocket upgrade handshake timed out

  ## Return values

    * `{:ok, state}` — acknowledge the disconnect
  """
  @callback handle_disconnect(reason :: term(), state) :: {:ok, state}

  defmacro __using__(_opts) do
    quote do
      @behaviour Parley

      @impl true
      def handle_connect(state), do: {:ok, state}

      @impl true
      def handle_frame(_frame, state), do: {:ok, state}

      @impl true
      def handle_disconnect(_reason, state), do: {:ok, state}

      defoverridable handle_connect: 1, handle_frame: 2, handle_disconnect: 2

      @doc """
      Returns a child specification for starting this module under a supervisor.

      Accepts a tuple `{init_arg, opts}` where `opts` are passed to `start_link/2`.
      """
      def child_spec({init_arg, opts}) do
        %{
          id: __MODULE__,
          start: {__MODULE__, :start_link, [init_arg, opts]}
        }
      end

      defoverridable child_spec: 1

      @doc """
      Starts this WebSocket client linked to the current process.

      Delegates to `Parley.start_link/3`. See `Parley.start_link/3` for options.
      """
      def start_link(init_arg, opts \\ []) do
        Parley.start_link(__MODULE__, init_arg, opts)
      end
    end
  end

  @doc """
  Starts a `Parley` process linked to the current process.

  This is often used to start the process as part of a supervision tree.

  `module` is the module that implements the `Parley` callbacks.
  `init_arg` is passed as the initial user state accessible in callbacks.

  ## Options

    * `:url` (required) — the WebSocket URL to connect to (e.g. `"wss://example.com/ws"`)
    * `:name` — used for name registration, see the "Name registration" section
      in the module documentation
    * `:connect_timeout` — timeout in milliseconds for the WebSocket upgrade
      handshake (default: `10_000`)

  ## Return values

  See `:gen_statem.start_link/3` for return values.
  """
  @spec start_link(module(), state(), keyword()) :: :gen_statem.start_ret()
  def start_link(module, init_arg, opts \\ []) when is_atom(module) and is_list(opts) do
    {url, opts} = Keyword.pop!(opts, :url)
    {connect_timeout, opts} = Keyword.pop(opts, :connect_timeout)
    connection_opts = if connect_timeout, do: [connect_timeout: connect_timeout], else: []
    do_start(:start_link, module, {url, init_arg, connection_opts}, opts)
  end

  @doc """
  Starts a `Parley` process without a link (outside of a supervision tree).

  Accepts the same arguments and options as `start_link/3`. Useful for
  interactive or scripted use where you don't want the calling process
  to be linked.
  """
  @spec start(module(), state(), keyword()) :: :gen_statem.start_ret()
  def start(module, init_arg, opts \\ []) when is_atom(module) and is_list(opts) do
    {url, opts} = Keyword.pop!(opts, :url)
    {connect_timeout, opts} = Keyword.pop(opts, :connect_timeout)
    connection_opts = if connect_timeout, do: [connect_timeout: connect_timeout], else: []
    do_start(:start, module, {url, init_arg, connection_opts}, opts)
  end

  defp do_start(link, module, init_arg, opts) do
    case Keyword.pop(opts, :name) do
      {nil, opts} ->
        apply(:gen_statem, link, [Parley.Connection, {module, init_arg}, opts])

      {atom, opts} when is_atom(atom) ->
        apply(:gen_statem, link, [{:local, atom}, Parley.Connection, {module, init_arg}, opts])

      {{:global, _term} = tuple, opts} ->
        apply(:gen_statem, link, [tuple, Parley.Connection, {module, init_arg}, opts])

      {{:via, via_module, _term} = tuple, opts} when is_atom(via_module) ->
        apply(:gen_statem, link, [tuple, Parley.Connection, {module, init_arg}, opts])

      {other, _opts} ->
        raise ArgumentError, """
        expected :name option to be one of the following:

          * nil
          * atom
          * {:global, term}
          * {:via, module, term}

        Got: #{inspect(other)}
        """
    end
  end

  @doc """
  Sends a WebSocket frame to the server.

  Returns `:ok` if the frame was sent successfully, or `{:error, reason}` if
  the send failed (e.g. the process is in the `:disconnected` state).

  ## Examples

      :ok = Parley.send_frame(pid, {:text, "hello"})
      :ok = Parley.send_frame(pid, {:binary, <<1, 2, 3>>})

  """
  @spec send_frame(:gen_statem.server_ref(), frame()) :: :ok | {:error, term()}
  def send_frame(server, frame) do
    :gen_statem.call(server, {:send, frame})
  end

  @doc """
  Gracefully disconnects from the WebSocket server.

  Sends a WebSocket close frame and transitions the process to the
  `:disconnected` state. The process remains alive after disconnecting.

  ## Examples

      :ok = Parley.disconnect(pid)

  """
  @spec disconnect(:gen_statem.server_ref()) :: :ok
  def disconnect(server) do
    :gen_statem.call(server, :disconnect)
  end
end
