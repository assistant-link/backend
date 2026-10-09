# Assistant Link service

The Assistant Link service: one Phoenix app that serves the web pages, the app API, and the agent protocol. It is part
of [Assistant Link](https://github.com/assistant-link/assistant-link); start there for an overview of the project and
how the components fit together.

- [`docs/alp/v1.md`](docs/alp/v1.md): the Assistant Link Protocol (ALP), the public API agents use to pair and connect.
- [`deploy/SELF_HOSTING.md`](deploy/SELF_HOSTING.md): running your own service with Docker Compose or on Fly.io.

## Prerequisites

- [mise](https://mise.jdx.dev). This repository's `mise.toml` pins Erlang and Elixir.
- [Postgres.app](https://postgresapp.com) (PostgreSQL 18) running on `localhost:5432`. The dev and test configs
  connect as `postgres`/`postgres`, which Postgres.app accepts by default. `mix setup` and `mix test` create
  `assistant_link_dev` and `assistant_link_test`. Any PostgreSQL 18 with that user works too, for example
  `docker run -d -p 5432:5432 -e POSTGRES_PASSWORD=postgres postgres:18`.

## Setup

Install the pinned toolchain:

```sh
mise trust
mise install
```

Then fetch deps, create the dev database, and build assets:

```sh
mise exec -- mix setup
```

Run all `mix` commands through mise (`mise exec -- mix ...`, or directly in a shell where mise is activated).

## Running

```sh
mise exec -- mix phx.server
```

- <http://localhost:4000/> shows the home page.
- <http://localhost:4000/health> returns `{"status":"ok"}`.

In dev, the Tidewave MCP server is at `http://localhost:4000/tidewave/mcp`.

## Tests and the quality gate

```sh
mise exec -- mix test
mise exec -- mix precommit
```

`mix precommit` is the single quality gate. Run it before every commit. It runs, in order:

- `hex.audit`: retired Hex packages
- `compile --warnings-as-errors`: compiler and type-checker warnings, and Boundary violations
- `deps.unlock --check-unused`: stale entries in `mix.lock`
- `format --check-formatted`: formatting, including Styler rewrites (fix with `mix format`)
- `credo --strict`: Credo plus all ExSlop checks
- `ex_dna`: duplicated code
- `sobelow --config`: security findings at any confidence (`.sobelow-conf`)
- `deps.audit`: dependencies with known vulnerabilities
- `excellent_migrations.check_safety`: unsafe migrations
- `test`

Boundaries: `AssistantLink` is the core and exports nothing yet. `AssistantLinkWeb` may depend on the core.

## Deploying

See [`deploy/SELF_HOSTING.md`](deploy/SELF_HOSTING.md) for Docker Compose, the Fly.io template, and every environment
variable the release reads. The `Dockerfile` and `rel/` come from `mix phx.gen.release --docker`.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Licensed under the [MIT License](LICENSE).
