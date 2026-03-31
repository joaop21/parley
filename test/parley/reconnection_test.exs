defmodule Parley.ReconnectionTest do
  use ExUnit.Case, async: true

  alias Parley.Test.EchoServer

  setup do
    {port, server_pid} = EchoServer.start()

    on_exit(fn ->
      if Process.alive?(server_pid), do: Supervisor.stop(server_pid, :normal, 1000)
    end)

    %{port: port, url: "ws://localhost:#{port}/ws", server_pid: server_pid}
  end

  describe "reconnection on server crash" do
    test "client reconnects after server dies", %{url: url, server_pid: server_pid} do
      defmodule ReconnectOnCrashClient do
        use Parley

        @impl true
        def handle_connect(%{test_pid: pid} = state) do
          send(pid, :connected)
          {:ok, state}
        end

        @impl true
        def handle_frame(frame, %{test_pid: pid} = state) do
          send(pid, {:frame, frame})
          {:ok, state}
        end

        @impl true
        def handle_disconnect(reason, %{test_pid: pid} = state) do
          send(pid, {:disconnected, reason})
          {:ok, state}
        end
      end

      {:ok, pid} =
        Parley.start_link(ReconnectOnCrashClient, %{test_pid: self()},
          url: url,
          reconnect: [base_delay: 50, max_delay: 200]
        )

      assert_receive :connected, 1000

      # Kill the server
      Supervisor.stop(server_pid, :normal, 1000)
      assert_receive {:disconnected, _reason}, 1000

      # Start a new server on the same port
      {:ok, new_server_pid} =
        Bandit.start_link(
          plug: EchoServer.Router,
          port: port_from_url(url),
          ip: :loopback,
          startup_log: false
        )

      Process.unlink(new_server_pid)

      # Client should reconnect automatically
      assert_receive :connected, 2000

      # Verify we can exchange frames
      :ok = Parley.send_frame(pid, {:text, "after reconnect"})
      assert_receive {:frame, {:text, "after reconnect"}}, 1000

      Parley.disconnect(pid)
      Supervisor.stop(new_server_pid, :normal, 1000)
    end
  end

  describe "backoff delay increases" do
    test "successive attempts use increasing delays" do
      defmodule BackoffDelayClient do
        use Parley

        @impl true
        def handle_disconnect(reason, %{test_pid: pid} = state) do
          send(pid, {:disconnected, reason, System.monotonic_time(:millisecond)})
          {:ok, state}
        end
      end

      Process.flag(:trap_exit, true)

      # Connect to an unreachable host with reconnect enabled
      {:ok, pid} =
        Parley.start_link(BackoffDelayClient, %{test_pid: self()},
          url: "ws://127.0.0.1:1/ws",
          reconnect: [base_delay: 50, max_delay: 400, max_retries: 4]
        )

      # Collect timestamps of disconnect callbacks (triggered by connect_failed)
      timestamps =
        for _i <- 1..4 do
          assert_receive {:disconnected, _reason, ts}, 5000
          ts
        end

      # Verify delays increase (with some tolerance for jitter)
      delays =
        timestamps
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.map(fn [a, b] -> b - a end)

      # Each delay should generally be >= the previous one
      assert length(delays) >= 2
      assert Enum.at(delays, -1) >= Enum.at(delays, 0)

      assert_receive {:EXIT, ^pid, {:error, :max_retries_exceeded}}, 5000
    end
  end

  describe "max retries exceeded" do
    test "process stops with :max_retries_exceeded" do
      defmodule MaxRetriesClient do
        use Parley

        @impl true
        def handle_disconnect(reason, %{test_pid: pid} = state) do
          send(pid, {:disconnected, reason})
          {:ok, state}
        end
      end

      Process.flag(:trap_exit, true)

      {:ok, pid} =
        Parley.start_link(MaxRetriesClient, %{test_pid: self()},
          url: "ws://127.0.0.1:1/ws",
          reconnect: [base_delay: 50, max_delay: 100, max_retries: 3]
        )

      # Should get 3 disconnect notifications then stop
      for _i <- 1..3 do
        assert_receive {:disconnected, _reason}, 2000
      end

      assert_receive {:EXIT, ^pid, {:error, :max_retries_exceeded}}, 2000
    end
  end

  describe "{:disconnect, state} suppresses reconnection" do
    test "overrides reconnect option", %{url: url, server_pid: server_pid} do
      defmodule DisconnectOverrideClient do
        use Parley

        @impl true
        def handle_connect(%{test_pid: pid} = state) do
          send(pid, :connected)
          {:ok, state}
        end

        @impl true
        def handle_disconnect(reason, %{test_pid: pid} = state) do
          send(pid, {:disconnected, reason})
          {:disconnect, state}
        end
      end

      {:ok, pid} =
        Parley.start_link(DisconnectOverrideClient, %{test_pid: self()},
          url: url,
          reconnect: [base_delay: 50, max_delay: 200]
        )

      assert_receive :connected, 1000

      # Kill the server
      Supervisor.stop(server_pid, :normal, 1000)
      assert_receive {:disconnected, _reason}, 1000

      # Should NOT reconnect
      refute_receive :connected, 500

      # Process should still be alive
      assert Process.alive?(pid)
      Parley.disconnect(pid)
    end
  end

  describe "{:reconnect, state} forces reconnection" do
    test "reconnects even without reconnect option", %{url: url, server_pid: server_pid} do
      defmodule ForceReconnectClient do
        use Parley

        @impl true
        def handle_connect(%{test_pid: pid} = state) do
          send(pid, :connected)
          {:ok, state}
        end

        @impl true
        def handle_frame(frame, %{test_pid: pid} = state) do
          send(pid, {:frame, frame})
          {:ok, state}
        end

        @impl true
        def handle_disconnect(reason, %{test_pid: pid} = state) do
          send(pid, {:disconnected, reason})
          {:reconnect, state}
        end
      end

      # No reconnect option set
      {:ok, pid} =
        Parley.start_link(ForceReconnectClient, %{test_pid: self()}, url: url)

      assert_receive :connected, 1000

      # Kill the server
      Supervisor.stop(server_pid, :normal, 1000)
      assert_receive {:disconnected, _reason}, 1000

      # Start a new server on the same port
      {:ok, new_server_pid} =
        Bandit.start_link(
          plug: EchoServer.Router,
          port: port_from_url(url),
          ip: :loopback,
          startup_log: false
        )

      Process.unlink(new_server_pid)

      # Should reconnect using default backoff
      assert_receive :connected, 5000

      :ok = Parley.send_frame(pid, {:text, "reconnected"})
      assert_receive {:frame, {:text, "reconnected"}}, 1000

      Parley.disconnect(pid)
      Supervisor.stop(new_server_pid, :normal, 1000)
    end
  end

  describe "{:ok, state} defers to option" do
    test "with reconnect option, default callback triggers reconnection", %{
      url: url,
      server_pid: server_pid
    } do
      defmodule DeferToOptionClient do
        use Parley

        @impl true
        def handle_connect(%{test_pid: pid} = state) do
          send(pid, :connected)
          {:ok, state}
        end

        @impl true
        def handle_disconnect(reason, %{test_pid: pid} = state) do
          send(pid, {:disconnected, reason})
          {:ok, state}
        end
      end

      {:ok, pid} =
        Parley.start_link(DeferToOptionClient, %{test_pid: self()},
          url: url,
          reconnect: [base_delay: 50, max_delay: 200]
        )

      assert_receive :connected, 1000

      Supervisor.stop(server_pid, :normal, 1000)
      assert_receive {:disconnected, _reason}, 1000

      # Start a new server on the same port
      {:ok, new_server_pid} =
        Bandit.start_link(
          plug: EchoServer.Router,
          port: port_from_url(url),
          ip: :loopback,
          startup_log: false
        )

      Process.unlink(new_server_pid)

      # {:ok, state} + reconnect option -> reconnects
      assert_receive :connected, 2000

      Parley.disconnect(pid)
      Supervisor.stop(new_server_pid, :normal, 1000)
    end

    test "without reconnect option, default callback stays disconnected", %{
      url: url,
      server_pid: server_pid
    } do
      defmodule NoReconnectOptionClient do
        use Parley

        @impl true
        def handle_connect(%{test_pid: pid} = state) do
          send(pid, :connected)
          {:ok, state}
        end

        @impl true
        def handle_disconnect(reason, %{test_pid: pid} = state) do
          send(pid, {:disconnected, reason})
          {:ok, state}
        end
      end

      # No reconnect option
      {:ok, pid} =
        Parley.start_link(NoReconnectOptionClient, %{test_pid: self()}, url: url)

      assert_receive :connected, 1000

      Supervisor.stop(server_pid, :normal, 1000)
      assert_receive {:disconnected, _reason}, 1000

      # Should NOT reconnect
      refute_receive :connected, 500

      assert Process.alive?(pid)
      Parley.disconnect(pid)
    end
  end

  describe "disconnect/1 cancels pending reconnect" do
    test "calling disconnect cancels the reconnect timer", %{url: url, server_pid: server_pid} do
      defmodule CancelTimerClient do
        use Parley

        @impl true
        def handle_connect(%{test_pid: pid} = state) do
          send(pid, :connected)
          {:ok, state}
        end

        @impl true
        def handle_disconnect(reason, %{test_pid: pid} = state) do
          send(pid, {:disconnected, reason})
          {:ok, state}
        end
      end

      {:ok, pid} =
        Parley.start_link(CancelTimerClient, %{test_pid: self()},
          url: url,
          reconnect: [base_delay: 2000, max_delay: 5000]
        )

      assert_receive :connected, 1000

      # Kill the server — triggers reconnect timer with long delay
      Supervisor.stop(server_pid, :normal, 1000)
      assert_receive {:disconnected, _reason}, 1000

      # Immediately cancel via disconnect
      :ok = Parley.disconnect(pid)

      # Should NOT attempt reconnect
      refute_receive :connected, 500

      assert Process.alive?(pid)
    end
  end

  describe "initial connection failure retries" do
    test "retries with reconnect option then succeeds" do
      defmodule InitialRetryClient do
        use Parley

        @impl true
        def handle_connect(%{test_pid: pid} = state) do
          send(pid, :connected)
          {:ok, state}
        end

        @impl true
        def handle_frame(frame, %{test_pid: pid} = state) do
          send(pid, {:frame, frame})
          {:ok, state}
        end

        @impl true
        def handle_disconnect(reason, %{test_pid: pid} = state) do
          send(pid, {:disconnected, reason})
          {:ok, state}
        end
      end

      # Find a free port and don't start a server on it yet
      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, free_port} = :inet.port(listen)
      :gen_tcp.close(listen)

      {:ok, _pid} =
        Parley.start_link(InitialRetryClient, %{test_pid: self()},
          url: "ws://127.0.0.1:#{free_port}/ws",
          reconnect: [base_delay: 50, max_delay: 200]
        )

      # The initial connection fails
      assert_receive {:disconnected, _reason}, 1000

      # Start a server on that port so the retry succeeds
      {:ok, new_server_pid} =
        Bandit.start_link(
          plug: EchoServer.Router,
          port: free_port,
          ip: {127, 0, 0, 1},
          startup_log: false
        )

      Process.unlink(new_server_pid)

      # Should eventually reconnect
      assert_receive :connected, 5000

      Parley.disconnect(self() |> Process.info(:links) |> elem(1) |> List.last())
      Supervisor.stop(new_server_pid, :normal, 1000)
    end
  end

  describe "attempt counter resets on success" do
    test "backoff starts fresh after successful reconnect", %{url: url, server_pid: server_pid} do
      defmodule AttemptResetClient do
        use Parley

        @impl true
        def handle_connect(%{test_pid: pid} = state) do
          send(pid, :connected)
          {:ok, state}
        end

        @impl true
        def handle_disconnect(reason, %{test_pid: pid} = state) do
          send(pid, {:disconnected, reason, System.monotonic_time(:millisecond)})
          {:ok, state}
        end
      end

      {:ok, pid} =
        Parley.start_link(AttemptResetClient, %{test_pid: self()},
          url: url,
          reconnect: [base_delay: 50, max_delay: 200]
        )

      assert_receive :connected, 1000

      # First disconnect cycle
      Supervisor.stop(server_pid, :normal, 1000)
      assert_receive {:disconnected, _reason, _ts}, 1000

      # Start new server for reconnect
      {:ok, server_pid2} =
        Bandit.start_link(
          plug: EchoServer.Router,
          port: port_from_url(url),
          ip: :loopback,
          startup_log: false
        )

      Process.unlink(server_pid2)
      assert_receive :connected, 2000

      # Second disconnect cycle
      Supervisor.stop(server_pid2, :normal, 1000)
      assert_receive {:disconnected, _reason2, ts2}, 1000

      # Start another server
      {:ok, server_pid3} =
        Bandit.start_link(
          plug: EchoServer.Router,
          port: port_from_url(url),
          ip: :loopback,
          startup_log: false
        )

      Process.unlink(server_pid3)
      assert_receive :connected, 2000

      # The reconnect delay after the second disconnect should be short
      # (base_delay level, not accumulated), proving the counter was reset
      now = System.monotonic_time(:millisecond)
      # Should have reconnected within a reasonable time from ts2
      assert now - ts2 < 1000

      Parley.disconnect(pid)
      Supervisor.stop(server_pid3, :normal, 1000)
    end
  end

  describe "{:reconnect, state} without option uses defaults" do
    test "uses default backoff values", %{url: url, server_pid: server_pid} do
      defmodule ReconnectNoOptionClient do
        use Parley

        @impl true
        def handle_connect(%{test_pid: pid} = state) do
          send(pid, :connected)
          {:ok, state}
        end

        @impl true
        def handle_disconnect(reason, %{test_pid: pid} = state) do
          send(pid, {:disconnected, reason})
          {:reconnect, state}
        end
      end

      # No reconnect option, but callback forces reconnect
      {:ok, pid} =
        Parley.start_link(ReconnectNoOptionClient, %{test_pid: self()}, url: url)

      assert_receive :connected, 1000

      # Kill the server — handle_disconnect returns {:reconnect, state}
      Supervisor.stop(server_pid, :normal, 1000)
      assert_receive {:disconnected, _reason}, 1000

      # Should get another disconnect (from the failed reconnect attempt using
      # default backoff), proving reconnection was attempted
      assert_receive {:disconnected, _reason}, 3000

      # Process should still be alive (infinite retries with defaults)
      assert Process.alive?(pid)

      # Clean up
      Parley.disconnect(pid)
    end
  end

  defp port_from_url(url) do
    URI.parse(url).port
  end
end
