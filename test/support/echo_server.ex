defmodule Parley.Test.EchoServer do
  @moduledoc false

  defmodule WebSocket do
    @moduledoc false
    @behaviour WebSock

    @impl true
    def init(_opts), do: {:ok, %{}}

    @impl true
    def handle_in({"close", [opcode: :text]}, state) do
      {:stop, :normal, {1000, "normal closure"}, state}
    end

    def handle_in({"crash", [opcode: :text]}, _state) do
      Process.exit(self(), :kill)
    end

    def handle_in({"send_and_crash", [opcode: :text]}, state) do
      Process.send_after(self(), :crash, 10)
      {:reply, :ok, [{:text, "push_this"}], state}
    end

    def handle_in({message, [opcode: :text]}, state) do
      {:reply, :ok, [{:text, message}], state}
    end

    def handle_in({message, [opcode: :binary]}, state) do
      {:reply, :ok, [{:binary, message}], state}
    end

    @impl true
    def handle_info(:crash, _state), do: Process.exit(self(), :kill)
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

    get "/reject" do
      conn
      |> send_resp(403, "Forbidden")
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
