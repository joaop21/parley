defmodule ParleyTest do
  use ExUnit.Case, async: true

  alias Parley.Test.{Client, EchoServer}

  setup do
    {port, server_pid} = EchoServer.start()

    on_exit(fn ->
      if Process.alive?(server_pid), do: Supervisor.stop(server_pid, :normal, 1000)
    end)

    %{port: port, url: "ws://localhost:#{port}/ws"}
  end

  describe "connecting" do
    test "invokes handle_connect on successful connection", %{url: url} do
      {:ok, pid} = Client.start_link(%{test_pid: self()}, url: url)

      assert_receive :connected, 1000

      Parley.disconnect(pid)
    end
  end

  describe "sending and receiving frames" do
    test "echoes text frames", %{url: url} do
      {:ok, pid} = Client.start_link(%{test_pid: self()}, url: url)
      assert_receive :connected, 1000

      :ok = Parley.send_frame(pid, {:text, "hello"})
      assert_receive {:frame, {:text, "hello"}}, 1000

      Parley.disconnect(pid)
    end

    test "echoes binary frames", %{url: url} do
      {:ok, pid} = Client.start_link(%{test_pid: self()}, url: url)
      assert_receive :connected, 1000

      :ok = Parley.send_frame(pid, {:binary, <<1, 2, 3>>})
      assert_receive {:frame, {:binary, <<1, 2, 3>>}}, 1000

      Parley.disconnect(pid)
    end

    test "handles multiple frames in sequence", %{url: url} do
      {:ok, pid} = Client.start_link(%{test_pid: self()}, url: url)
      assert_receive :connected, 1000

      :ok = Parley.send_frame(pid, {:text, "one"})
      :ok = Parley.send_frame(pid, {:text, "two"})
      :ok = Parley.send_frame(pid, {:text, "three"})

      assert_receive {:frame, {:text, "one"}}, 1000
      assert_receive {:frame, {:text, "two"}}, 1000
      assert_receive {:frame, {:text, "three"}}, 1000

      Parley.disconnect(pid)
    end
  end

  describe "disconnecting" do
    test "graceful disconnect invokes handle_disconnect", %{url: url} do
      {:ok, pid} = Client.start_link(%{test_pid: self()}, url: url)
      assert_receive :connected, 1000

      :ok = Parley.disconnect(pid)
      assert_receive {:disconnected, :closed}, 1000
    end

    test "send_frame returns error when disconnected", %{url: url} do
      {:ok, pid} = Client.start_link(%{test_pid: self()}, url: url)
      assert_receive :connected, 1000

      :ok = Parley.disconnect(pid)
      assert_receive {:disconnected, :closed}, 1000

      assert {:error, :disconnected} = Parley.send_frame(pid, {:text, "hello"})
    end

    test "disconnect when already disconnected returns ok", %{url: url} do
      {:ok, pid} = Client.start_link(%{test_pid: self()}, url: url)
      assert_receive :connected, 1000

      :ok = Parley.disconnect(pid)
      assert_receive {:disconnected, :closed}, 1000

      assert :ok = Parley.disconnect(pid)
    end
  end

  describe "custom state" do
    test "initial state is passed through to callbacks", %{url: url} do
      {:ok, pid} = Client.start_link(%{test_pid: self(), counter: 0}, url: url)
      assert_receive :connected, 1000

      Parley.disconnect(pid)
    end
  end

  describe "name registration" do
    test "start_link with atom name allows addressing by name", %{url: url} do
      {:ok, _pid} = Client.start_link(%{test_pid: self()}, url: url, name: :parley_test)
      assert_receive :connected, 1000

      :ok = Parley.send_frame(:parley_test, {:text, "named"})
      assert_receive {:frame, {:text, "named"}}, 1000

      Parley.disconnect(:parley_test)
    end

    test "start_link with duplicate name returns error", %{url: url} do
      {:ok, pid} = Client.start_link(%{test_pid: self()}, url: url, name: :parley_dup)
      assert_receive :connected, 1000

      assert {:error, {:already_started, ^pid}} =
               Client.start_link(%{test_pid: self()}, url: url, name: :parley_dup)

      Parley.disconnect(:parley_dup)
    end

    test "start_link with invalid name raises ArgumentError", %{url: url} do
      assert_raise ArgumentError, ~r/expected :name option/, fn ->
        Client.start_link(%{test_pid: self()}, url: url, name: 123)
      end
    end

    test "start_link with {:global, term} name", %{url: url} do
      {:ok, _pid} =
        Client.start_link(%{test_pid: self()}, url: url, name: {:global, :parley_global})

      assert_receive :connected, 1000

      :ok = Parley.send_frame({:global, :parley_global}, {:text, "global"})
      assert_receive {:frame, {:text, "global"}}, 1000

      Parley.disconnect({:global, :parley_global})
    end
  end

  describe "child_spec/1" do
    test "returns a valid child spec", %{url: url} do
      spec = Client.child_spec({%{test_pid: self()}, url: url})

      assert spec == %{
               id: Client,
               start: {Client, :start_link, [%{test_pid: self()}, [url: url]]}
             }
    end

    test "can be started under a supervisor", %{url: url} do
      children = [
        {Client, {%{test_pid: self()}, url: url, name: :parley_supervised}}
      ]

      {:ok, sup} = Supervisor.start_link(children, strategy: :one_for_one)
      assert_receive :connected, 1000

      :ok = Parley.send_frame(:parley_supervised, {:text, "supervised"})
      assert_receive {:frame, {:text, "supervised"}}, 1000

      Supervisor.stop(sup)
    end

    test "child_spec is overridable" do
      defmodule CustomSpecClient do
        use Parley

        def child_spec(_arg) do
          %{id: :custom, start: {__MODULE__, :start_link, [%{}, []]}}
        end
      end

      spec = CustomSpecClient.child_spec(:ignored)
      assert spec.id == :custom
    end
  end

  describe "start/3" do
    test "starts process without link", %{url: url} do
      {:ok, pid} = Parley.start(Client, %{test_pid: self()}, url: url)
      assert_receive :connected, 1000

      :ok = Parley.send_frame(pid, {:text, "unlinked"})
      assert_receive {:frame, {:text, "unlinked"}}, 1000

      Parley.disconnect(pid)
    end
  end

  describe "options validation" do
    test "start_link without :url raises KeyError" do
      assert_raise KeyError, ~r/key :url not found/, fn ->
        Client.start_link(%{test_pid: self()}, [])
      end
    end
  end
end
