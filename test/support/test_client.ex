defmodule Parley.Test.Client do
  @moduledoc false
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
