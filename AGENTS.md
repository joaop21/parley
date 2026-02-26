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

- `Parley` (`lib/parley.ex`) — Behaviour definition with 3 callbacks + `__using__` macro
- `Parley.Connection` (`lib/parley/connection.ex`) — `gen_statem` implementation with state machine: `disconnected → connecting → connected`
- `Parley.Application` (`lib/parley/application.ex`) — OTP Application supervisor

### Callbacks

```elixir
@callback handle_connect(state) :: {:ok, state}
@callback handle_frame(frame, state) :: {:ok, state}
@callback handle_disconnect(reason, state) :: {:ok, state}
```

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
