# Connect an agent to Assistant Link

## Objective

Connect this agent host to the user's Assistant on Assistant Link, using the pairing text the user gave you. The
pairing text names the Assistant and contains the service URL and a pairing code, for example:

```
Connect to my assistant "Hermes" on Assistant Link.
Follow the instructions at https://assistant-link.fly.dev/install.md
Service: https://assistant-link.fly.dev
Pairing code: K7QM-2XPA (expires 14:32 UTC)
```

You install `al`, the Assistant Link command-line tool, pair with the code, and keep the connection open.

## Done when

- `al status` exits 0 and reports the Assistant named in the pairing text.
- `al wait` is running, so the user's app shows the Assistant Link as online.

## Steps

### 1. Install `al`

If `al --version` already works, skip to step 2.

Download the binary for this host from the latest release and put it on your `PATH`:

| Host                  | Target                       |
| --------------------- | ---------------------------- |
| macOS, Apple Silicon  | `aarch64-apple-darwin`       |
| macOS, Intel          | `x86_64-apple-darwin`        |
| Linux, x86_64         | `x86_64-unknown-linux-musl`  |
| Linux, arm64          | `aarch64-unknown-linux-musl` |

```sh
TARGET=aarch64-apple-darwin   # the target for this host, from the table
mkdir -p ~/.local/bin
curl -fsSL "https://github.com/assistant-link/cli/releases/latest/download/al-$TARGET.tar.gz" | tar -xz -C ~/.local/bin al
~/.local/bin/al --version
```

If `~/.local/bin` is not on your `PATH`, call it by its full path or add it to `PATH`.

If no binary fits this host, build it from source with Rust installed:

```sh
cargo install --git https://github.com/assistant-link/cli al
```

### 2. Point `al` at the service

Use the service URL from the pairing text for every command in this session:

```sh
export AL_SERVER=https://assistant-link.fly.dev   # the "Service:" line of the pairing text
```

### 3. Pair

```sh
al pair K7QM-2XPA   # the "Pairing code:" line of the pairing text
```

It prints the service URL, the Link id, and the Assistant name as one JSON object, and stores the Link's credential in
`~/.config/assistant-link/credentials.json` (or under `$XDG_CONFIG_HOME`). One host user holds one Link: pairing again
replaces the stored credential. To run several Assistants on one host, use a separate OS user or `XDG_CONFIG_HOME`
for each.

### 4. Check the connection

```sh
al status
```

It exits 0 and prints one JSON object with the Assistant name, the Link id, and `"check": "accepted"`. Every `al`
command prints JSON by default; add `--human` for text.

### 5. Stay online

Run `al wait` as a long-running process, for example in the background:

```sh
nohup al wait >>al-events.log 2>>al-wait.log &
```

The Assistant Link is online while `al wait` runs. It reconnects on its own after network drops. Standard output is
reserved for events from the user; status messages go to standard error as JSON lines. Stop it with SIGINT or SIGTERM, which takes
the Link offline.

## Exit codes

| Code | Meaning                                                      |
| ---- | ------------------------------------------------------------ |
| 0    | Success                                                      |
| 1    | Unexpected error                                             |
| 2    | Usage error                                                  |
| 3    | Not paired: run `al pair <code>`                             |
| 4    | Rejected by the service: invalid or expired code, or credential no longer valid |
| 5    | Service unreachable                                          |
| 6    | Server mismatch: the stored credential belongs to a different service URL |

## Stop conditions

Stop and tell the user what happened, instead of retrying, when:

- `al pair` exits 4: the code is invalid, already used, or expired. Ask the user to create a new pairing code in the app
  and send you the new pairing text.
- `al status` or `al wait` exits 4: the service no longer accepts this Link, for example because the user logged out
  of the app, which deletes their Assistants. Ask the user for new pairing text.
- `al status` or `al wait` exits 6: `AL_SERVER` (or `--server`) differs from the service this host paired with, and
  `al` refuses to send the credential to it. Set `AL_SERVER` to the "Service:" line of the pairing text you paired
  with, or pair again with new pairing text for the other service.
- Any command exits 5 more than a few times over a minute: the service is unreachable. Report the service URL.
- `al` cannot be installed on this host: report the platform (`uname -sm`) and the error.
