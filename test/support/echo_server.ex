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

    def handle_in({"send_ping", [opcode: :text]}, state) do
      {:push, {:ping, "ping"}, state}
    end

    def handle_in({"send_ping:" <> payload, [opcode: :text]}, state) do
      {:push, {:ping, payload}, state}
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

  defmodule AuthWebSocket do
    @moduledoc false
    @behaviour WebSock

    @impl true
    def init(_opts), do: {:ok, %{}}

    @impl true
    def handle_in({message, [opcode: :text]}, state) do
      {:reply, :ok, [{:text, message}], state}
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

    get "/ws/auth" do
      case Plug.Conn.get_req_header(conn, "authorization") do
        ["Bearer " <> _token] ->
          conn
          |> WebSockAdapter.upgrade(AuthWebSocket, %{}, [])
          |> halt()

        _ ->
          conn
          |> send_resp(401, "Unauthorized")
          |> halt()
      end
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

  @doc """
  Starts a raw TCP listener that accepts connections but never speaks HTTP.

  The kernel completes the TCP handshake into the listen backlog, so a client
  connects successfully but never receives a WebSocket upgrade response —
  driving `connect_timeout`. A Bandit/Plug route can't reproduce this: Bandit
  finishes the accept before the router runs. Mirrors `start/0`: binds port 0,
  returns `{port, pid}`, and unlinks the owner so the caller's exit doesn't take
  it down. Stop it with `Process.exit(pid, :kill)`.
  """
  def black_hole_listen do
    test = self()

    pid =
      spawn_link(fn ->
        {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
        {:ok, port} = :inet.port(listen)
        send(test, {self(), port})
        # Hold the listen socket (and this process) open forever without ever
        # accepting or responding.
        Process.sleep(:infinity)
      end)

    receive do
      {^pid, port} ->
        Process.unlink(pid)
        {port, pid}
    end
  end
end
