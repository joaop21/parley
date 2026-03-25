# Parley

WebSocket client library for Elixir built on `gen_statem` and Mint.

## Quick Reference

```bash
mix deps.get          # Install dependencies
mix compile           # Compile
mix test              # Run tests
mix test --failed     # Re-run failed tests
mix format            # Format code
mix format --check-formatted  # Check formatting
mix credo --strict    # Static analysis
mix dialyzer          # Type checking
```

## Architecture

Parley provides a callback-based API (`use Parley`) backed by a `gen_statem` state machine.

### Core Modules

- `Parley` (`lib/parley.ex`) — Behaviour definition with callbacks + `__using__` macro
- `Parley.Connection` (`lib/parley/connection.ex`) — `gen_statem` implementation with state machine: `disconnected → connecting → connected`
- `Parley.Application` (`lib/parley/application.ex`) — OTP Application supervisor

### Callbacks

```elixir
@callback init(init_arg) :: {:ok, state} | {:stop, reason}
@callback handle_connect(state) :: {:ok, state} | {:push, frame, state} | {:stop, reason, state}
@callback handle_frame(frame, state) :: {:ok, state} | {:push, frame, state} | {:stop, reason, state}
@callback handle_ping(payload, state) :: {:ok, state} | {:push, frame, state} | {:stop, reason, state}
@callback handle_info(message, state) :: {:ok, state} | {:push, frame, state} | {:stop, reason, state}
@callback handle_disconnect(reason, state) :: {:ok, state}
```

### Connection Options

Options passed to `Parley.start_link/3` or `Parley.start/3`:

- `:url` (required) — WebSocket URL (`"ws://..."` or `"wss://..."`)
- `:name` — name registration (atom, `{:global, term}`, or `{:via, module, term}`)
- `:headers` — custom headers sent with the WebSocket upgrade request (default: `[]`)
- `:connect_timeout` — timeout in ms for the WebSocket upgrade handshake (default: `10_000`)
- `:transport_opts` — options passed to the transport layer (`:gen_tcp` / `:ssl`), for TLS config, timeouts, etc.
- `:protocols` — Mint HTTP protocols (default: `[:http1]`)

### State Machine

- **`:disconnected`** — Initial state. Triggers connection via internal event. Rejects sends with `{:error, :disconnected}`.
- **`:connecting`** — TCP connected, WebSocket upgrade in progress. Sends are postponed (auto-retried on connect).
- **`:connected`** — Active. Frames flow through callbacks. Pings auto-responded with pong.

### Dependencies

- `mint_web_socket` / `castore` (production)
- `bandit` / `websock_adapter` (test only)
- `credo` / `dialyxir` (dev/test only)

## Tests

Tests use a local echo WebSocket server (Bandit) defined in `test/support/echo_server.ex`.
Test client is in `test/support/test_client.ex` — sends messages to the test process for assertions.

Test support modules are compiled via `elixirc_paths(:test)` in `mix.exs`.

## Conventions

- Elixir 1.19, OTP 28
- Use `mix format` before committing
- Tests are async (`use ExUnit.Case, async: true`)
- Follow existing patterns: callbacks return `{:ok, state}`, public API goes through `Parley.Connection`
