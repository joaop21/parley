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
      {:ok, pid} = Client.start_link(url: url, state: %{test_pid: self()})

      assert_receive :connected, 1000

      Client.disconnect(pid)
    end
  end

  describe "sending and receiving frames" do
    test "echoes text frames", %{url: url} do
      {:ok, pid} = Client.start_link(url: url, state: %{test_pid: self()})
      assert_receive :connected, 1000

      :ok = Client.send_frame(pid, {:text, "hello"})
      assert_receive {:frame, {:text, "hello"}}, 1000

      Client.disconnect(pid)
    end

    test "echoes binary frames", %{url: url} do
      {:ok, pid} = Client.start_link(url: url, state: %{test_pid: self()})
      assert_receive :connected, 1000

      :ok = Client.send_frame(pid, {:binary, <<1, 2, 3>>})
      assert_receive {:frame, {:binary, <<1, 2, 3>>}}, 1000

      Client.disconnect(pid)
    end

    test "handles multiple frames in sequence", %{url: url} do
      {:ok, pid} = Client.start_link(url: url, state: %{test_pid: self()})
      assert_receive :connected, 1000

      :ok = Client.send_frame(pid, {:text, "one"})
      :ok = Client.send_frame(pid, {:text, "two"})
      :ok = Client.send_frame(pid, {:text, "three"})

      assert_receive {:frame, {:text, "one"}}, 1000
      assert_receive {:frame, {:text, "two"}}, 1000
      assert_receive {:frame, {:text, "three"}}, 1000

      Client.disconnect(pid)
    end
  end

  describe "disconnecting" do
    test "graceful disconnect invokes handle_disconnect", %{url: url} do
      {:ok, pid} = Client.start_link(url: url, state: %{test_pid: self()})
      assert_receive :connected, 1000

      :ok = Client.disconnect(pid)
      assert_receive {:disconnected, :closed}, 1000
    end

    test "send_frame returns error when disconnected", %{url: url} do
      {:ok, pid} = Client.start_link(url: url, state: %{test_pid: self()})
      assert_receive :connected, 1000

      :ok = Client.disconnect(pid)
      assert_receive {:disconnected, :closed}, 1000

      assert {:error, :disconnected} = Client.send_frame(pid, {:text, "hello"})
    end

    test "disconnect when already disconnected returns ok", %{url: url} do
      {:ok, pid} = Client.start_link(url: url, state: %{test_pid: self()})
      assert_receive :connected, 1000

      :ok = Client.disconnect(pid)
      assert_receive {:disconnected, :closed}, 1000

      assert :ok = Client.disconnect(pid)
    end
  end

  describe "custom state" do
    test "initial state is passed through to callbacks", %{url: url} do
      {:ok, pid} = Client.start_link(url: url, state: %{test_pid: self(), counter: 0})
      assert_receive :connected, 1000

      Client.disconnect(pid)
    end
  end
end
