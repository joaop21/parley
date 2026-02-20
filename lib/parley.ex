defmodule Parley do
  @moduledoc """
  A WebSocket client built on `gen_statem` and Mint.

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

      {:ok, pid} = MyClient.start_link(url: "wss://example.com/ws")
      MyClient.send_frame(pid, {:text, "hello"})
      MyClient.disconnect(pid)
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

      def start_link(opts) do
        Parley.Connection.start_link(__MODULE__, opts)
      end

      def send_frame(pid, frame) do
        Parley.Connection.send_frame(pid, frame)
      end

      def disconnect(pid) do
        Parley.Connection.disconnect(pid)
      end
    end
  end
end
