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
