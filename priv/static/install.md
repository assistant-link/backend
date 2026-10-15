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

`al` uses `https://assistant-link.fly.dev` unless told otherwise. If the "Service:" line of the pairing text names
another URL, set `AL_SERVER` to it for every `al` command below, and in the wrapper in step 5. If your shell does not
keep variables between commands, put it in front of each `al` command instead.

```sh
export AL_SERVER=https://assistant-link.example   # only if the "Service:" line is not https://assistant-link.fly.dev
```

### 3. Pair

`al` keeps nothing on the host: it hands you the Link key, and you store it. Each Assistant on a host keeps its own
key under its own name. The commands below use `hermes`; replace it everywhere with this Assistant's name, in
lowercase.

```sh
mkdir -p -m 700 ~/.config/assistant-link
al pair K7QM-2XPA --key-file ~/.config/assistant-link/hermes.key   # the "Pairing code:" line of the pairing text
```

It prints the service URL, the Link id, and the Assistant name as one JSON object, and writes the Link key to the file,
readable only by your user. Every `al` command prints JSON by default; add `--human` for text. Use `--key-file` as
shown: without it, `al pair` prints the key, and it would end up in your transcript.

### 4. Store the key and check the connection

Keep the key in the best storage this host has. Use the first option that works, and never print the key.

**macOS Keychain:**

```sh
printf 'add-generic-password -a hermes -s assistant-link -w %s\n' "$(cat ~/.config/assistant-link/hermes.key)" | security -i
rm ~/.config/assistant-link/hermes.key
AL_LINK_KEY="$(security find-generic-password -a hermes -s assistant-link -w)" al status
```

**Linux Secret Service** (needs a running keyring, as in a desktop session):

```sh
secret-tool store --label="Assistant Link: hermes" service assistant-link account hermes <~/.config/assistant-link/hermes.key
rm ~/.config/assistant-link/hermes.key
AL_LINK_KEY="$(secret-tool lookup service assistant-link account hermes)" al status
```

**Key file** (any host): keep `~/.config/assistant-link/hermes.key` where it is.

```sh
al status --key-file ~/.config/assistant-link/hermes.key
```

`al status` exits 0 and prints one JSON object with the Assistant name, the Link id, and `"check": "accepted"`.

### 5. Stay online

`al wait` holds the connection, so the Assistant Link is online while it runs. Write a small wrapper that supplies the
key, for the storage you chose. If you set `AL_SERVER` in step 2, add the same `export AL_SERVER=...` line to it
before `exec`.

**macOS Keychain:**

```sh
mkdir -p ~/.local/bin
cat >~/.local/bin/al-wait-hermes <<'WRAPPER'
#!/bin/sh
export AL_LINK_KEY="$(security find-generic-password -a hermes -s assistant-link -w)"
exec al wait
WRAPPER
chmod 700 ~/.local/bin/al-wait-hermes
```

**Linux Secret Service:**

```sh
mkdir -p ~/.local/bin
cat >~/.local/bin/al-wait-hermes <<'WRAPPER'
#!/bin/sh
export AL_LINK_KEY="$(secret-tool lookup service assistant-link account hermes)"
exec al wait
WRAPPER
chmod 700 ~/.local/bin/al-wait-hermes
```

**Key file:**

```sh
mkdir -p ~/.local/bin
cat >~/.local/bin/al-wait-hermes <<'WRAPPER'
#!/bin/sh
exec al wait --key-file ~/.config/assistant-link/hermes.key
WRAPPER
chmod 700 ~/.local/bin/al-wait-hermes
```

If `al` is not on the `PATH` of the shell that will run the wrapper, use its full path, for example
`~/.local/bin/al`. Then run the wrapper as a long-running process, for example in the background:

```sh
nohup ~/.local/bin/al-wait-hermes >>al-events-hermes.log 2>>al-wait-hermes.log &
```

It reconnects on its own after network drops. Standard output is reserved for events from the user; status messages go
to standard error as JSON lines. Stop it with SIGINT or SIGTERM, which takes the Link offline.

## Exit codes

| Code | Meaning                                                                                       |
| ---- | --------------------------------------------------------------------------------------------- |
| 0    | Success                                                                                       |
| 1    | Unexpected error                                                                              |
| 2    | Usage error, including a `--key-file` path that already exists for `al pair`                  |
| 3    | No Link key supplied: set `AL_LINK_KEY` or pass `--key-file`                                  |
| 4    | Rejected by the service: invalid or expired code, or a Link key it does not accept            |
| 5    | Service unreachable                                                                           |

## Stop conditions

Stop and tell the user what happened, instead of retrying, when:

- `al pair` exits 4: the code is invalid, already used, or expired. Ask the user to create a new pairing code in the app
  and send you the new pairing text.
- `al pair` exits 2 with `key_file_exists`: a key file with that name already exists and may hold another Link's key.
  Do not delete it; pick another name. The code was not used, so you can pair again with it.
- `al status` or `al wait` exits 3: the key did not reach `al`. Check the storage command in your wrapper.
- `al status` or `al wait` exits 4: the service did not accept the key. First check that `AL_SERVER` matches the
  "Service:" line of the pairing text you paired with, since a key only works with the service that issued it. If it
  does, the Link no longer exists, for example because the user logged out of the app, which deletes their
  Assistants. Ask the user for new pairing text.
- Any command exits 5 more than a few times over a minute: the service is unreachable. Report the service URL.
- `al` cannot be installed on this host: report the platform (`uname -sm`) and the error.
