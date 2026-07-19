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
    assert metadata.uri == URI.parse(url)

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
    assert metadata.uri == URI.parse(url)

    Parley.disconnect(pid)
  end

  test "emits [:parley, :frame, :received] for a ping frame", %{url: url} do
    ref = :telemetry_test.attach_event_handlers(self(), [[:parley, :frame, :received]])

    {:ok, pid} = Client.start_link(%{test_pid: self()}, url: url)
    assert_receive :connected, 1000

    # Ask the echo server to send us a ping carrying a 3-byte payload. Ping is
    # dispatched from a distinct dispatch_frame/2 clause (send_pong + handle_ping)
    # than text/binary, so it exercises a separate path to the shared emit site.
    :ok = Parley.send_frame(pid, {:text, "send_ping:abc"})

    assert_receive {[:parley, :frame, :received], ^ref, measurements, metadata}, 1000

    # "abc" is 3 bytes; assert the literal, not a recomputation.
    assert measurements == %{size: 3}
    assert metadata.type == :ping
    assert metadata.pid == pid
    assert metadata.module == Client
    assert metadata.uri == URI.parse(url)

    Parley.disconnect(pid)
  end

  test "does not emit [:parley, :frame, :received] for a close frame", %{url: url} do
    ref = :telemetry_test.attach_event_handlers(self(), [[:parley, :frame, :received]])

    {:ok, pid} = Client.start_link(%{test_pid: self()}, url: url)
    assert_receive :connected, 1000

    # The echo server answers "close" with a close frame. Close is lifecycle,
    # not data, so it must not emit frame:received. The disconnect arrives after
    # the frame would have been processed, so any wrongful event is already in
    # the mailbox by the time refute_received runs.
    :ok = Parley.send_frame(pid, {:text, "close"})

    assert_receive {:disconnected, {:remote_close, 1000, _}}, 1000
    refute_received {[:parley, :frame, :received], ^ref, _measurements, _metadata}
  end

  test "emits [:parley, :reconnect, :scheduled] with post-increment attempts 1, 2, 3" do
    # A failed connection with reconnect enabled will EXIT once retries are
    # exhausted; trap it so the linked test process survives.
    Process.flag(:trap_exit, true)

    ref = :telemetry_test.attach_event_handlers(self(), [[:parley, :reconnect, :scheduled]])

    # A refused port drives repeated connect failures; each one schedules a
    # retry. base_delay is tiny so the three retries land quickly.
    dead_url = "ws://127.0.0.1:1/ws"

    {:ok, pid} =
      Client.start_link(%{test_pid: self()},
        url: dead_url,
        reconnect: [base_delay: 20, max_delay: 100, max_retries: 3]
      )

    # :scheduled reports the POST-increment attempt, so consecutive events
    # increase by 1 starting at 1 (not the pre-increment 0, 1, 2).
    for expected_attempt <- 1..3 do
      assert_receive {[:parley, :reconnect, :scheduled], ^ref, measurements, metadata}, 2000

      assert metadata.attempt == expected_attempt
      assert metadata.module == Client
      assert metadata.uri == URI.parse(dead_url)
      assert metadata.pid == pid

      # delay is the backoff the retry was scheduled after — a positive integer.
      assert is_integer(measurements.delay)
      assert measurements.delay > 0
    end
  end

  test "emits [:parley, :reconnect, :exhausted] at the ceiling with attempt == max_retries" do
    Process.flag(:trap_exit, true)

    ref = :telemetry_test.attach_event_handlers(self(), [[:parley, :reconnect, :exhausted]])

    dead_url = "ws://127.0.0.1:1/ws"
    max_retries = 3

    {:ok, pid} =
      Client.start_link(%{test_pid: self()},
        url: dead_url,
        reconnect: [base_delay: 20, max_delay: 100, max_retries: max_retries]
      )

    assert_receive {[:parley, :reconnect, :exhausted], ^ref, measurements, metadata}, 2000

    # attempt is a MEASUREMENT here (metadata everywhere else) and equals
    # exactly max_retries — the guard trips at equality.
    assert measurements == %{attempt: max_retries}
    assert metadata.module == Client
    assert metadata.uri == URI.parse(dead_url)
    assert metadata.pid == pid
    refute Map.has_key?(metadata, :attempt)

    # :exhausted is the only signal for permanently giving up; the process
    # stops right after.
    assert_receive {:EXIT, ^pid, {:error, :max_retries_exceeded}}, 2000
  end
end
