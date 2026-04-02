defmodule Parley.DisconnectReturnTest do
  use ExUnit.Case, async: true

  alias Parley.Test.EchoServer

  setup do
    {port, server_pid} = EchoServer.start()

    on_exit(fn ->
      if Process.alive?(server_pid), do: Supervisor.stop(server_pid, :normal, 1000)
    end)

    %{port: port, url: "ws://localhost:#{port}/ws", server_pid: server_pid}
  end

  describe "handle_connect returning {:disconnect, reason, state}" do
    test "disconnects gracefully and handle_disconnect receives the reason", %{url: url} do
      defmodule DisconnectOnConnectClient do
        use Parley

        @impl true
        def handle_connect(%{test_pid: pid} = state) do
          send(pid, :connected)
          {:disconnect, :not_authorized, state}
        end

        @impl true
        def handle_disconnect(reason, %{test_pid: pid} = state) do
          send(pid, {:disconnected, reason})
          {:ok, state}
        end
      end

      {:ok, pid} =
        Parley.start_link(DisconnectOnConnectClient, %{test_pid: self()}, url: url)

      assert_receive :connected, 1000
      assert_receive {:disconnected, :not_authorized}, 1000

      assert Process.alive?(pid)
      Parley.disconnect(pid)
    end
  end

  describe "handle_frame returning {:disconnect, reason, state}" do
    test "disconnects gracefully and handle_disconnect receives the reason", %{url: url} do
      defmodule DisconnectOnFrameClient do
        use Parley

        @impl true
        def handle_connect(%{test_pid: pid} = state) do
          send(pid, :connected)
          {:ok, state}
        end

        @impl true
        def handle_frame({:text, "bye"}, state) do
          {:disconnect, :server_said_bye, state}
        end

        def handle_frame(_frame, state), do: {:ok, state}

        @impl true
        def handle_disconnect(reason, %{test_pid: pid} = state) do
          send(pid, {:disconnected, reason})
          {:ok, state}
        end
      end

      {:ok, pid} =
        Parley.start_link(DisconnectOnFrameClient, %{test_pid: self()}, url: url)

      assert_receive :connected, 1000

      :ok = Parley.send_frame(pid, {:text, "bye"})
      assert_receive {:disconnected, :server_said_bye}, 1000

      assert Process.alive?(pid)
      Parley.disconnect(pid)
    end
  end

  describe "handle_ping returning {:disconnect, reason, state}" do
    test "disconnects gracefully and handle_disconnect receives the reason", %{url: url} do
      defmodule DisconnectOnPingClient do
        use Parley

        @impl true
        def handle_connect(%{test_pid: pid} = state) do
          send(pid, :connected)
          {:ok, state}
        end

        @impl true
        def handle_ping(_payload, state) do
          {:disconnect, :ping_triggered_disconnect, state}
        end

        @impl true
        def handle_frame(_frame, state), do: {:ok, state}

        @impl true
        def handle_disconnect(reason, %{test_pid: pid} = state) do
          send(pid, {:disconnected, reason})
          {:ok, state}
        end
      end

      {:ok, pid} =
        Parley.start_link(DisconnectOnPingClient, %{test_pid: self()}, url: url)

      assert_receive :connected, 1000

      # Trigger a server-sent ping
      :ok = Parley.send_frame(pid, {:text, "send_ping"})
      assert_receive {:disconnected, :ping_triggered_disconnect}, 1000

      assert Process.alive?(pid)
      Parley.disconnect(pid)
    end
  end

  describe "handle_info returning {:disconnect, reason, state}" do
    test "disconnects gracefully while connected", %{url: url} do
      defmodule DisconnectOnInfoClient do
        use Parley

        @impl true
        def handle_connect(%{test_pid: pid} = state) do
          send(pid, :connected)
          {:ok, state}
        end

        @impl true
        def handle_info(:please_disconnect, state) do
          {:disconnect, :info_disconnect, state}
        end

        def handle_info(_message, state), do: {:ok, state}

        @impl true
        def handle_disconnect(reason, %{test_pid: pid} = state) do
          send(pid, {:disconnected, reason})
          {:ok, state}
        end
      end

      {:ok, pid} =
        Parley.start_link(DisconnectOnInfoClient, %{test_pid: self()}, url: url)

      assert_receive :connected, 1000

      send(pid, :please_disconnect)
      assert_receive {:disconnected, :info_disconnect}, 1000

      assert Process.alive?(pid)
      Parley.disconnect(pid)
    end

    test "stays disconnected when already disconnected, updates state", %{url: url} do
      defmodule DisconnectOnInfoWhileDisconnectedClient do
        use Parley

        @impl true
        def handle_connect(%{test_pid: pid} = state) do
          send(pid, :connected)
          {:ok, state}
        end

        @impl true
        def handle_info(:try_disconnect, state) do
          {:disconnect, :already_off, %{state | got_disconnect_info: true}}
        end

        def handle_info(:check_state, %{test_pid: pid} = state) do
          send(pid, {:state, state})
          {:ok, state}
        end

        def handle_info(_message, state), do: {:ok, state}

        @impl true
        def handle_disconnect(reason, %{test_pid: pid} = state) do
          send(pid, {:disconnected, reason})
          {:ok, state}
        end
      end

      {:ok, pid} =
        Parley.start_link(
          DisconnectOnInfoWhileDisconnectedClient,
          %{test_pid: self(), got_disconnect_info: false},
          url: url
        )

      assert_receive :connected, 1000

      # First disconnect normally
      :ok = Parley.disconnect(pid)
      assert_receive {:disconnected, :closed}, 1000

      # Now send {:disconnect, ...} while already disconnected
      send(pid, :try_disconnect)

      # Should NOT get another handle_disconnect call
      refute_receive {:disconnected, _}, 200

      # Verify state was updated
      send(pid, :check_state)
      assert_receive {:state, %{got_disconnect_info: true}}, 1000

      assert Process.alive?(pid)
      Parley.disconnect(pid)
    end
  end

  describe "disconnect return with reconnection" do
    test "handle_frame disconnect triggers reconnection via handle_disconnect", %{
      url: url,
      server_pid: server_pid
    } do
      defmodule DisconnectThenReconnectClient do
        use Parley

        @impl true
        def handle_connect(%{test_pid: pid} = state) do
          send(pid, :connected)
          {:ok, state}
        end

        @impl true
        def handle_frame({:text, "disconnect_me"}, state) do
          {:disconnect, :unauthorized, state}
        end

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

      {:ok, pid} =
        Parley.start_link(DisconnectThenReconnectClient, %{test_pid: self()}, url: url)

      assert_receive :connected, 1000

      # Trigger the disconnect from handle_frame
      :ok = Parley.send_frame(pid, {:text, "disconnect_me"})
      assert_receive {:disconnected, :unauthorized}, 1000

      # Should reconnect since handle_disconnect returns {:reconnect, state}
      assert_receive :connected, 5000

      # Verify we can exchange frames after reconnecting
      :ok = Parley.send_frame(pid, {:text, "after reconnect"})
      assert_receive {:frame, {:text, "after reconnect"}}, 1000

      assert Process.alive?(pid)
      Parley.disconnect(pid)
    end
  end

  describe "state is preserved through disconnect" do
    test "handle_frame disconnect preserves updated state", %{url: url} do
      defmodule StatePreservingDisconnectClient do
        use Parley

        @impl true
        def handle_connect(%{test_pid: pid} = state) do
          send(pid, :connected)
          {:ok, state}
        end

        @impl true
        def handle_frame({:text, "disconnect_me"}, state) do
          {:disconnect, :done, %{state | disconnected_by_frame: true}}
        end

        def handle_frame(_frame, state), do: {:ok, state}

        @impl true
        def handle_info(:check_state, %{test_pid: pid} = state) do
          send(pid, {:state, state})
          {:ok, state}
        end

        @impl true
        def handle_disconnect(reason, %{test_pid: pid} = state) do
          send(pid, {:disconnected, reason, state})
          {:ok, state}
        end
      end

      {:ok, pid} =
        Parley.start_link(
          StatePreservingDisconnectClient,
          %{test_pid: self(), disconnected_by_frame: false},
          url: url
        )

      assert_receive :connected, 1000

      :ok = Parley.send_frame(pid, {:text, "disconnect_me"})

      # handle_disconnect should see the updated state
      assert_receive {:disconnected, :done, %{disconnected_by_frame: true}}, 1000

      assert Process.alive?(pid)
      Parley.disconnect(pid)
    end
  end
end
