defmodule Parley.TelemetryTest do
  # async: false is a deliberate deviation from the repo convention that
  # tests run async. Telemetry handlers are registered globally, so
  # :telemetry_test.attach_event_handlers/2 forwards matching events from
  # every process — a concurrent test's connection would satisfy our
  # assert_receive on [:parley, :frame, :received]. ExUnit runs sync
  # modules alone after every async module has finished, giving us an
  # isolated global handler registry.
  use ExUnit.Case, async: false

  alias Parley.Test.{Client, EchoServer}

  setup do
    {port, server_pid} = EchoServer.start()

    on_exit(fn ->
      if Process.alive?(server_pid), do: Supervisor.stop(server_pid, :normal, 1000)
    end)

    %{url: "ws://localhost:#{port}/ws"}
  end

  test "emits [:parley, :frame, :received] for a text frame", %{url: url} do
    ref = :telemetry_test.attach_event_handlers(self(), [[:parley, :frame, :received]])

    {:ok, pid} = Client.start_link(%{test_pid: self()}, url: url)
    assert_receive :connected, 1000

    :ok = Parley.send_frame(pid, {:text, "hello"})

    assert_receive {[:parley, :frame, :received], ^ref, measurements, metadata}, 1000

    # "hello" is 5 bytes; assert the literal, not a recomputation.
    assert measurements == %{size: 5}
    assert metadata.type == :text
    assert metadata.pid == pid
    assert metadata.module == Client
    assert %URI{} = metadata.uri

    Parley.disconnect(pid)
  end

  test "emits [:parley, :frame, :received] for a binary frame", %{url: url} do
    ref = :telemetry_test.attach_event_handlers(self(), [[:parley, :frame, :received]])

    {:ok, pid} = Client.start_link(%{test_pid: self()}, url: url)
    assert_receive :connected, 1000

    :ok = Parley.send_frame(pid, {:binary, <<1, 2, 3, 4>>})

    assert_receive {[:parley, :frame, :received], ^ref, measurements, metadata}, 1000

    # <<1, 2, 3, 4>> is 4 bytes; assert the literal, not a recomputation.
    assert measurements == %{size: 4}
    assert metadata.type == :binary
    assert metadata.pid == pid
    assert metadata.module == Client
    assert %URI{} = metadata.uri

    Parley.disconnect(pid)
  end
end
