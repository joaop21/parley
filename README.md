# Parley

[![CI](https://github.com/joaop21/parley/actions/workflows/ci.yml/badge.svg)](https://github.com/joaop21/parley/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/parley.svg)](https://hex.pm/packages/parley)
[![Docs](https://img.shields.io/badge/docs-hexdocs-blue.svg)](https://hexdocs.pm/parley)

WebSocket client for Elixir built on [`gen_statem`](https://www.erlang.org/doc/apps/stdlib/gen_statem.html) and [Mint WebSocket](https://hexdocs.pm/mint_web_socket).

[Full documentation on HexDocs](https://hexdocs.pm/parley).

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
{:ok, pid} = MyClient.start_link(%{}, url: "wss://example.com/ws")
Parley.send_frame(pid, {:text, "hello"})
Parley.disconnect(pid)
```

### Options

`start_link/2` accepts the following options:

- `:url` (required) — the WebSocket URL to connect to (`ws://` or `wss://`)
- `:name` — an optional name for the process (passed to `:gen_statem`)
- `:connect_timeout` — timeout in milliseconds for the WebSocket upgrade handshake (default: `10_000`)

The first argument is the initial user state accessible in callbacks.

### Callbacks

All callbacks are optional — default implementations are provided via `use Parley`.

| Callback | Description | Return values |
|---|---|---|
| `handle_connect(state)` | Called when the WebSocket handshake completes | `{:ok, state}`, `{:push, frame, state}`, `{:stop, reason, state}` |
| `handle_frame(frame, state)` | Called when a frame is received from the server | `{:ok, state}`, `{:push, frame, state}`, `{:stop, reason, state}` |
| `handle_disconnect(reason, state)` | Called when the connection is lost or closed | `{:ok, state}` |

- `{:ok, state}` — update state
- `{:push, frame, state}` — send a frame from within the callback
- `{:stop, reason, state}` — stop the process

### Frame Types

Frames are tuples matching the type `{:text, String.t()} | {:binary, binary()} | {:ping, binary()} | {:pong, binary()}`.

Ping frames from the server are automatically answered with pong — no user code needed.

### Sends During Connection

Frames sent while the WebSocket handshake is still in progress are automatically queued and delivered once the connection is established.
