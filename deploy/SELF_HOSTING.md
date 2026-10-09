# Self-hosting

The service is one Phoenix release on Postgres. It builds from the [`Dockerfile`](../Dockerfile) at the repository
root, runs migrations with `bin/migrate`, and serves HTTP and WebSockets with `bin/server`. You can run it anywhere that
runs a container and can reach a PostgreSQL 18 database.

Two ready-made paths are below: Docker Compose on one host, and Fly.io.

## Docker Compose

[`docker-compose.yml`](docker-compose.yml) runs the service and Postgres together. From the repository root:

```sh
SECRET_KEY_BASE="$(openssl rand -base64 48)" docker compose -f deploy/docker-compose.yml up --build
```

The service runs migrations, then listens on <http://localhost:4000>. Check it with:

```sh
curl http://localhost:4000/health
```

Keep the same `SECRET_KEY_BASE` across restarts, for example in a `.env` file next to `docker-compose.yml`, or every
signed-in web session ends. The database lives in the `db-data` volume.

Point `al` at it with `AL_SERVER=http://localhost:4000`. A debug build of the iOS app can use it with
`make run SERVICE_URL=http://localhost:4000` (see the [apple](https://github.com/assistant-link/apple) README).

### Serving it to other devices

For phones and agents on other hosts, put a TLS-terminating reverse proxy (Caddy, nginx, Traefik, a load balancer) in
front of port 4000. Forward WebSocket upgrades, and set `X-Forwarded-Proto`. Then set these in `.env`:

```sh
PHX_HOST=link.example.com
PHX_SCHEME=https
PHX_URL_PORT=443
```

Every request to a host other than `localhost` or `127.0.0.1` that arrives over plain HTTP is redirected to HTTPS,
except `/health`.

## Fly.io

[`fly/fly.toml`](fly/fly.toml) runs one small machine that stops when nothing is connected and starts on the next
request. You need [`flyctl`](https://fly.io/docs/flyctl/install/), signed in with `fly auth login`, and a PostgreSQL
database the machine can reach.

1. Copy the template to the repository root and fill in the placeholders:

   ```sh
   cp deploy/fly/fly.toml fly.toml
   ```

   Pick an app name and the [region](https://fly.io/docs/reference/regions/) closest to your database.

2. Create the app and set its secrets:

   ```sh
   fly apps create <your-app-name>
   fly secrets set DATABASE_URL="ecto://USER:PASS@HOST/DATABASE"
   fly secrets set SECRET_KEY_BASE="$(openssl rand -base64 48)"
   ```

3. Deploy:

   ```sh
   fly deploy
   ```

   Fly builds the image, runs `bin/migrate` as the release command, then starts the machine. `fly logs` streams the
   service logs.

## Environment variables

The release reads these at boot ([`config/runtime.exs`](../config/runtime.exs)). Dev and test need none of them.

| Variable            | Required | Default                    | Purpose                                                                                   |
| ------------------- | -------- | -------------------------- | ----------------------------------------------------------------------------------------- |
| `DATABASE_URL`      | yes      |                            | Postgres connection URL, `ecto://USER:PASS@HOST/DATABASE`, without `?...` options.        |
| `SECRET_KEY_BASE`   | yes      |                            | Signs and encrypts cookies. At least 64 bytes; generate with `openssl rand -base64 48`.  |
| `PHX_HOST`          | no       | `example.com`              | Public hostname in generated URLs, including the pairing text the app shows.              |
| `PHX_SCHEME`        | no       | `https`                    | Public URL scheme. Set `http` only for local use without TLS.                             |
| `PHX_URL_PORT`      | no       | `443` for https, else `80` | Public URL port, when it differs from the scheme's default.                               |
| `PORT`              | no       | `4000`                     | Port the server listens on inside the container.                                          |
| `PHX_SERVER`        | no       | set by `bin/server`        | Starts the HTTP server. `bin/server` sets it; set it yourself only to start the release another way. |
| `DATABASE_SSL`      | no       | `true`                     | Connect to Postgres over TLS, verified against the system CA store. `false` turns TLS off. |
| `POOL_SIZE`         | no       | `5`                        | Database connections in the pool.                                                         |
| `ECTO_IPV6`         | no       | off                        | `true` or `1` connects to the database over IPv6.                                         |
| `DNS_CLUSTER_QUERY` | no       | none                       | DNS name used to find other nodes to cluster with. Leave unset for one node.              |

Keep `DATABASE_URL` and `SECRET_KEY_BASE` in your platform's secret store, never in the repository.
