defmodule Parley do
  @moduledoc """
  A WebSocket client built on `gen_statem` and Mint.

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

  ## Name registration

  The `:name` option supports the same values as `GenServer`:

    * an atom — registered locally with `{:local, atom}`
    * `{:global, term}` — registered with `:global`
    * `{:via, module, term}` — registered with a custom registry

  ## Callbacks

  All callbacks are optional and have default implementations that return
  `{:ok, state}`. Override only the ones you need.

    * `c:handle_connect/1` — called when the WebSocket handshake completes
    * `c:handle_frame/2` — called when a frame is received from the server
    * `c:handle_disconnect/2` — called when the connection is lost or closed
  """

  @type state :: term()
  @type frame :: {:text, String.t()} | {:binary, binary()} | {:ping, binary()} | {:pong, binary()}

  @doc "Called when the WebSocket handshake completes."
  @callback handle_connect(state) :: {:ok, state}

  @doc "Called when a frame is received from the server."
  @callback handle_frame(frame, state) :: {:ok, state}

  @doc "Called when the connection is lost or closed."
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

      def child_spec({init_arg, opts}) do
        %{
          id: __MODULE__,
          start: {__MODULE__, :start_link, [init_arg, opts]}
        }
      end

      defoverridable child_spec: 1

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

  ## Return values

  See `:gen_statem.start_link/3` for return values.
  """
  def start_link(module, init_arg, opts \\ []) when is_atom(module) and is_list(opts) do
    {url, opts} = Keyword.pop!(opts, :url)
    do_start(:start_link, module, {url, init_arg}, opts)
  end

  @doc """
  Starts a `Parley` process without a link (outside of a supervision tree).

  See `start_link/3` for more information.
  """
  def start(module, init_arg, opts \\ []) when is_atom(module) and is_list(opts) do
    {url, opts} = Keyword.pop!(opts, :url)
    do_start(:start, module, {url, init_arg}, opts)
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

  def send_frame(server, frame) do
    :gen_statem.call(server, {:send, frame})
  end

  def disconnect(server) do
    :gen_statem.call(server, :disconnect)
  end
end
