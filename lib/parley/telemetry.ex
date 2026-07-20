defmodule Parley.Telemetry do
  @moduledoc """
  Telemetry events emitted by Parley.

  Parley uses [`:telemetry`](https://hexdocs.pm/telemetry) to make the
  connection's activity observable. Attach a handler to any of the events
  below to feed metrics, tracing, or logging without changing your client
  callbacks.

  ## Events

  ### `[:parley, :frame, :received]`

  Emitted for every WebSocket frame received from the server, before the
  corresponding callback (`c:Parley.handle_frame/2` or
  `c:Parley.handle_ping/2`) runs. Close frames are part of the connection
  lifecycle rather than data and do **not** emit this event.

    * Measurements
      * `:size` — the payload size in bytes (`byte_size/1` of the frame
        payload, not the number of bytes on the wire)

    * Metadata
      * `:type` — the frame type: `:text`, `:binary`, `:ping`, or `:pong`
      * `:module` — the module implementing the `Parley` callbacks
      * `:uri` — the `t:URI.t/0` the connection was opened against
      * `:pid` — the connection process that received the frame

  ### `[:parley, :connect, :start]`

  Emitted when a connection attempt begins, immediately before the
  synchronous connect runs. Together with `[:parley, :connect, :stop]` it
  forms a span around every attempt, including reconnect retries.

    * Measurements
      * `:system_time` — `System.system_time/0` captured when the attempt
        began

    * Metadata
      * `:module` — the module implementing the `Parley` callbacks
      * `:uri` — the `t:URI.t/0` the connection was opened against
      * `:pid` — the connection process
      * `:attempt` — the zero-based attempt index: `0` for the initial
        connect, `N` for the `N`th reconnect retry

  ### `[:parley, :connect, :stop]`

  Emitted when a connection attempt settles, closing the span opened by
  `[:parley, :connect, :start]`. Every `:start` is paired with exactly one
  `:stop`.

    * Measurements
      * `:duration` — native time units elapsed since the matching
        `:start` (convert with `System.convert_time_unit/3`)

    * Metadata
      * `:module`, `:uri`, `:pid`, `:attempt` — as in `:start`; `:attempt`
        matches the paired `:start`
      * `:outcome` — one of:
        * `:ok` — the WebSocket upgrade completed and the connection is
          live
        * `:error` — the attempt failed (refused, timed out, or the
          upgrade was rejected); counts toward the connect failure rate
        * `:aborted` — the attempt was cancelled or the process shut down
          mid-connect; excluded from the failure rate
      * `:reason` — `nil` when `outcome` is `:ok`; otherwise the failure
        term (e.g. `:econnrefused`, `:connect_timeout`, `{:error, term}`,
        `:closed`, `:shutdown`, or a crash reason)

  ## Example

      :telemetry.attach(
        "log-received-frames",
        [:parley, :frame, :received],
        fn _event, %{size: size}, %{type: type}, _config ->
          IO.puts("received \#{type} frame (\#{size} bytes)")
        end,
        nil
      )
  """

  @frame_received [:parley, :frame, :received]
  @connect_start [:parley, :connect, :start]
  @connect_stop [:parley, :connect, :stop]

  @doc false
  @spec frame_received(tuple(), module(), URI.t()) :: :ok
  def frame_received({type, payload}, module, %URI{} = uri)
      when type in [:text, :binary, :ping, :pong] and is_binary(payload) do
    :telemetry.execute(
      @frame_received,
      %{size: byte_size(payload)},
      %{type: type, module: module, uri: uri, pid: self()}
    )
  end

  def frame_received(_frame, _module, _uri), do: :ok

  @doc false
  @spec connect_start(module(), URI.t(), non_neg_integer()) :: :ok
  def connect_start(module, %URI{} = uri, attempt)
      when is_atom(module) and is_integer(attempt) and attempt >= 0 do
    :telemetry.execute(
      @connect_start,
      %{system_time: System.system_time()},
      %{module: module, uri: uri, pid: self(), attempt: attempt}
    )
  end

  def connect_start(_module, _uri, _attempt), do: :ok

  @doc false
  @spec connect_stop(
          module(),
          URI.t(),
          non_neg_integer(),
          integer(),
          :ok | :error | :aborted,
          term()
        ) :: :ok
  def connect_stop(module, %URI{} = uri, attempt, duration, outcome, reason)
      when is_atom(module) and is_integer(attempt) and attempt >= 0 and
             is_integer(duration) and outcome in [:ok, :error, :aborted] do
    :telemetry.execute(
      @connect_stop,
      %{duration: duration},
      %{
        module: module,
        uri: uri,
        pid: self(),
        attempt: attempt,
        outcome: outcome,
        reason: reason
      }
    )
  end

  def connect_stop(_module, _uri, _attempt, _duration, _outcome, _reason), do: :ok
end
