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

## Voice calls

The app's voice calls connect to the service over WebRTC, on UDP only, and the service relays them to OpenAI
GPT-Live. The app never contacts OpenAI. Set `OPENAI_API_KEY` to turn voice on; without it, the rest of the service
runs as usual and starting a voice chat answers `503` `voice_unavailable`.

The phone sends its audio straight to the service, with no TURN server in between, so:

- The host needs a public IPv4 address that the phone can reach on the UDP ports in `WEBRTC_PORT_RANGE`. Each
  active call uses one port. The service advertises `WEBRTC_PUBLIC_IP` to the phone.
- A call lives in the memory of the machine that answered its WebRTC request. Run one machine for voice, so that
  the HTTP request and the call's UDP traffic both reach it.
- On shutdown, as in a deploy, the service takes no new calls and waits up to 280 seconds for active ones to
  end. Give the platform's stop timeout at least 300 seconds.

With Docker Compose on a host with a public IP, publish the UDP range next to port 4000 (for example
`"50000-50019:50000-50019/udp"`) and set `WEBRTC_PUBLIC_IP` and `WEBRTC_PORT_RANGE` to match.

On Fly.io:

1. Allocate a dedicated IPv4 address with `fly ips allocate-v4`. Shared IPv4 addresses do not carry UDP.
2. Set `WEBRTC_LISTEN_HOST = 'fly-global-services'`, `WEBRTC_PUBLIC_IP` (the dedicated address) and
   `WEBRTC_PORT_RANGE` in `[env]`, and `fly secrets set OPENAI_API_KEY=...`. Fly delivers UDP only to sockets
   bound to `fly-global-services`.
3. Add one UDP service per port in the range, with the same port inside and out, as in the commented block of
   [`fly/fly.toml`](fly/fly.toml).
4. Keep the machine running during calls: UDP traffic does not count as a connection for Fly's auto-stop, so set
   `min_machines_running = 1` (or `auto_stop_machines = 'off'`), and keep one machine with `fly scale count 1`.
5. Keep `kill_timeout = '5m'` from the template, so a deploy lets active calls end first. With one machine, the
   service takes no new requests while it waits.

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
| `RESEND_API_KEY`    | no       | none                       | [Resend](https://resend.com) API key for wake emails. Without it, no wake email is sent.  |
| `WAKE_EMAIL_FROM`   | no       | `no-reply@mail.assistantlink.ai` | Sender of wake emails, on a domain verified in your Resend account.                |
| `APNS_KEY_P8`       | no       | none                       | Contents of the APNs auth key (`.p8`) for push notifications to the app. Without it, no push is sent. |
| `APNS_KEY_ID`       | with key |                            | Key ID of that APNs key.                                                                  |
| `APNS_TEAM_ID`      | with key |                            | Apple Developer team ID that owns the key.                                                |
| `APNS_TOPIC`        | no       | `ai.assistantlink.app`     | Bundle ID of the app that receives the pushes.                                            |
| `APNS_ENV`          | no       | `production`               | `production` (App Store and TestFlight builds) or `sandbox` (builds run from Xcode).      |
| `OPENAI_API_KEY`    | no       | none                       | OpenAI API key for voice calls. Without it, each voice chat answers `voice_unavailable`.   |
| `WEBRTC_PUBLIC_IP`  | for voice | none                      | Public IPv4 address the phone sends call audio to.                                         |
| `WEBRTC_PORT_RANGE` | for voice | any free port             | UDP ports for call audio, such as `50000-50019`; one per active call.                      |
| `WEBRTC_LISTEN_HOST`| no       | every interface            | Host whose address the call audio is received on. On Fly.io, `fly-global-services`.        |

Keep `DATABASE_URL`, `SECRET_KEY_BASE`, `RESEND_API_KEY`, `APNS_KEY_P8` and `OPENAI_API_KEY` in your platform's secret
store, never in the repository.
