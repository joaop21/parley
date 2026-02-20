defmodule Parley.Test.EchoServer do
  @moduledoc false

  defmodule WebSocket do
    @moduledoc false
    @behaviour WebSock

    @impl true
    def init(_opts), do: {:ok, %{}}

    @impl true
    def handle_in({message, [opcode: :text]}, state) do
      {:reply, :ok, [{:text, message}], state}
    end

    def handle_in({message, [opcode: :binary]}, state) do
      {:reply, :ok, [{:binary, message}], state}
    end

    @impl true
    def handle_info(_message, state), do: {:ok, state}

    @impl true
    def terminate(_reason, _state), do: :ok
  end

  defmodule Router do
    @moduledoc false
    use Plug.Router

    plug(:match)
    plug(:dispatch)

    get "/ws" do
      conn
      |> WebSockAdapter.upgrade(WebSocket, %{}, [])
      |> halt()
    end
  end

  def start do
    {:ok, server_pid} =
      Bandit.start_link(
        plug: Router,
        port: 0,
        ip: :loopback,
        startup_log: false
      )

    Process.unlink(server_pid)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server_pid)
    {port, server_pid}
  end
end
