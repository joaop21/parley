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

  ### `[:parley, :frame, :sent]`

  The send-side twin of `[:parley, :frame, :received]`. Emitted after a
  frame is successfully handed to the transport, from the single shared
  send path (a direct `send_frame/2`/`send_frame_async/2`, a `{:push, ...}`
  callback reply, or an automatic pong answering an inbound ping). Close
  frames are part of the connection lifecycle rather than data and do
  **not** emit this event.

  This event is emitted on **success only**: if encoding or the transport
  send fails, nothing is emitted. In particular a failed automatic pong is
  silent — the send path swallows the error, so the pong fails without a
  signal. This is a deliberate trade-off: the delivery signal is delayed,
  not lost, because a broken transport surfaces on the next inbound
  message.

    * Measurements
      * `:size` — the payload size in bytes (`byte_size/1` of the frame
        payload, not the number of bytes on the wire)

    * Metadata
      * `:type` — the frame type: `:text`, `:binary`, `:ping`, or `:pong`
      * `:module` — the module implementing the `Parley` callbacks
      * `:uri` — the `t:URI.t/0` the connection was opened against
      * `:pid` — the connection process that sent the frame

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

  ### `[:parley, :connection, :start]`

  Emitted once the WebSocket upgrade has completed and the connection is
  live, at the moment it enters the `:connected` state. Together with
  `[:parley, :connection, :stop]` it forms a span around the whole
  lifetime of a live connection. This is a different span from
  `[:parley, :connect, :start]`, which measures a single dial attempt:
  `:connect` spans one handshake, `:connection` spans everything from the
  upgrade completing until the connection ends.

    * Measurements
      * `:system_time` — `System.system_time/0` captured when the
        connection went live

    * Metadata
      * `:module` — the module implementing the `Parley` callbacks
      * `:uri` — the `t:URI.t/0` the connection was opened against
      * `:pid` — the connection process

  ### `[:parley, :connection, :stop]`

  Emitted when a live connection ends, closing the span opened by
  `[:parley, :connection, :start]`. Every `:start` is paired with exactly
  one `:stop`. The `:stop` fires before `c:Parley.handle_disconnect/2`
  runs, so a raise in that callback cannot leak the span.

    * Measurements
      * `:duration` — native time units the connection stayed live,
        elapsed since the matching `:start` (convert with
        `System.convert_time_unit/3`)

    * Metadata
      * `:module`, `:uri`, `:pid` — as in `:start`
      * `:outcome` — one of:
        * `:ok` — the connection ended cleanly: a local or remote close,
          or a client-requested disconnect. Any close frame is `:ok` —
          Parley does not classify close codes, so a peer that sent one
          spoke the protocol; a client that cares reads `:reason`
        * `:error` — a transport failure tore the connection down (a lost
          socket, a failed send, or a decode error)
        * `:aborted` — the connection process shut down or crashed while
          still live (e.g. a supervisor shutdown, or a callback returning
          `{:stop, ...}`)
      * `:reason` — the termination detail: `:closed`,
        `{:remote_close, code, text}`, `{:error, term}`, or an exit
        reason. `:connect_timeout` never appears here — it settles the
        `:connect` span, before this span opens

  ### `[:parley, :reconnect, :scheduled]`

  Emitted when a reconnect attempt has been scheduled after a failed or
  lost connection, once the backoff timer is armed. Not emitted when
  reconnection is disabled or suppressed by `c:Parley.handle_disconnect/2`.

    * Measurements
      * `:delay` — the backoff delay in milliseconds before the retry runs

    * Metadata
      * `:module` — the module implementing the `Parley` callbacks
      * `:uri` — the `t:URI.t/0` the connection was opened against
      * `:pid` — the connection process scheduling the retry
      * `:attempt` — the retry number, counting from 1 for the first retry.
        This is the **post-increment** value: it aligns with the `:attempt`
        carried by the matching connect event, so a `:scheduled` with
        `attempt: N` pairs with the connect attempt `N` that follows.

  ### `[:parley, :reconnect, :exhausted]`

  Emitted once when the configured `max_retries` is reached and Parley
  gives up reconnecting, just before the connection process stops. Fires
  only when `max_retries` is a finite number — never under the default
  `max_retries: :infinity`.

  This event is the **only** signal that a client has permanently given
  up: a connection that has exhausted its retries is otherwise
  indistinguishable from one about to retry. Attach to it to alert on
  clients that will never come back on their own.

    * Measurements
      * `:attempt` — the attempt count at exhaustion. Note this is a
        **measurement**, whereas `:attempt` is *metadata* on every other
        event. It is a measurement because `Telemetry.Metrics.counter/2`
        only accounts for an event whose measurement is present — a
        `%{}`-measurement event is uncountable.

    * Metadata
      * `:module` — the module implementing the `Parley` callbacks
      * `:uri` — the `t:URI.t/0` the connection was opened against
      * `:pid` — the connection process giving up

  > #### Metric choice {: .tip}
  >
  > `:attempt` here is always exactly `max_retries` (fixed per
  > connection; the guard trips at equality), so the intended metric is
  > `counter("parley.reconnect.exhausted.attempt", tags: [:module])` —
  > it counts give-ups. A `last_value/2` would graph a flat line and
  > tell you nothing.

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
  @frame_sent [:parley, :frame, :sent]
  @connect_start [:parley, :connect, :start]
  @connect_stop [:parley, :connect, :stop]
  @connection_start [:parley, :connection, :start]
  @connection_stop [:parley, :connection, :stop]
  @reconnect_scheduled [:parley, :reconnect, :scheduled]
  @reconnect_exhausted [:parley, :reconnect, :exhausted]

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

  @spec frame_sent(tuple(), module(), URI.t()) :: :ok
  def frame_sent({type, payload}, module, %URI{} = uri)
      when type in [:text, :binary, :ping, :pong] and is_binary(payload) do
    :telemetry.execute(
      @frame_sent,
      %{size: byte_size(payload)},
      %{type: type, module: module, uri: uri, pid: self()}
    )
  end

  def frame_sent(_frame, _module, _uri), do: :ok

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

  @doc false
  @spec connection_start(module(), URI.t()) :: :ok
  def connection_start(module, %URI{} = uri) when is_atom(module) do
    :telemetry.execute(
      @connection_start,
      %{system_time: System.system_time()},
      %{module: module, uri: uri, pid: self()}
    )
  end

  def connection_start(_module, _uri), do: :ok

  @doc false
  @spec connection_stop(module(), URI.t(), integer(), :ok | :error | :aborted, term()) :: :ok
  def connection_stop(module, %URI{} = uri, duration, outcome, reason)
      when is_atom(module) and is_integer(duration) and outcome in [:ok, :error, :aborted] do
    :telemetry.execute(
      @connection_stop,
      %{duration: duration},
      %{module: module, uri: uri, pid: self(), outcome: outcome, reason: reason}
    )
  end

  def connection_stop(_module, _uri, _duration, _outcome, _reason), do: :ok

  @doc false
  @spec reconnect_scheduled(map(), non_neg_integer()) :: :ok
  def reconnect_scheduled(%{module: module, uri: uri, reconnect_attempt: attempt}, delay)
      when is_integer(delay) do
    :telemetry.execute(
      @reconnect_scheduled,
      %{delay: delay},
      %{module: module, uri: uri, pid: self(), attempt: attempt}
    )
  end

  @doc false
  @spec reconnect_exhausted(map()) :: :ok
  def reconnect_exhausted(%{module: module, uri: uri, reconnect_attempt: attempt}) do
    :telemetry.execute(
      @reconnect_exhausted,
      %{attempt: attempt},
      %{module: module, uri: uri, pid: self()}
    )
  end
end
