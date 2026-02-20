# Parley

[![CI](https://github.com/joaop21/parley/actions/workflows/ci.yml/badge.svg)](https://github.com/joaop21/parley/actions/workflows/ci.yml)

WebSocket client for Elixir built on [`gen_statem`](https://www.erlang.org/doc/apps/stdlib/gen_statem.html) and [Mint.WebSocket](https://github.com/elixir-mint/mint_web_socket).

## Installation

Add `parley` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:parley, "~> 0.1.0"}
  ]
end
```

## Usage

Define a client module with `use Parley` and implement the callbacks you need:

```elixir
defmodule MyClient do
  use Parley

  @impl true
  def handle_connect(state) do
    IO.puts("Connected!")
    {:ok, state}
  end

  @impl true
  def handle_frame({:text, msg}, state) do
    IO.puts("Received: #{msg}")
    {:ok, state}
  end

  @impl true
  def handle_disconnect(reason, state) do
    IO.puts("Disconnected: #{inspect(reason)}")
    {:ok, state}
  end
end
```

Then start the client and send frames:

```elixir
{:ok, pid} = MyClient.start_link(url: "wss://example.com/ws")
MyClient.send_frame(pid, {:text, "hello"})
MyClient.disconnect(pid)
```

### Options

`start_link/1` accepts the following options:

- `:url` (required) — the WebSocket URL to connect to (`ws://` or `wss://`)
- `:state` — initial user state passed to callbacks (default: `nil`)
- `:name` — an optional name for the process (passed to `:gen_statem`)

### Callbacks

All callbacks are optional — default implementations are provided via `use Parley`.

| Callback | Description |
|---|---|
| `handle_connect(state)` | Called when the WebSocket handshake completes |
| `handle_frame(frame, state)` | Called when a frame is received from the server |
| `handle_disconnect(reason, state)` | Called when the connection is lost or closed |

All callbacks return `{:ok, state}`.

### Frame Types

Frames are tuples matching the type `{:text, String.t()} | {:binary, binary()} | {:ping, binary()} | {:pong, binary()}`.

Ping frames from the server are automatically answered with pong — no user code needed.

### Sends During Connection

Frames sent while the WebSocket handshake is still in progress are automatically queued and delivered once the connection is established.
