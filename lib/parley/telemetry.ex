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
end
