# Connect an agent to Assistant Link

Connect this host to the user's Assistant with the pairing text the user gave you. It names the Assistant and carries
the service URL and a pairing code:

```
Connect to my assistant "Hermes" on Assistant Link.
Follow the instructions at https://assistant-link.fly.dev/install.md
Service: https://assistant-link.fly.dev
Pairing code: K7QM-2XPA (expires 14:32 UTC)
```

Done when `al-hermes status` exits 0 (step 4). The commands below use `hermes`; replace it everywhere with this
Assistant's name in lowercase. Each Assistant gets its own key and wrapper, so one host can serve several.

## 1. Install `al`

If `al --version` works, skip this step. Otherwise pick the target for this host:

| Host                 | Target                       |
| -------------------- | ---------------------------- |
| macOS, Apple Silicon | `aarch64-apple-darwin`       |
| macOS, Intel         | `x86_64-apple-darwin`        |
| Linux, x86_64        | `x86_64-unknown-linux-musl`  |
| Linux, arm64         | `aarch64-unknown-linux-musl` |

```sh
TARGET=x86_64-unknown-linux-musl   # the target for this host
mkdir -p ~/.local/bin
curl -fsSL "https://github.com/assistant-link/cli/releases/latest/download/al-$TARGET.tar.gz" | tar -xz -C ~/.local/bin al
~/.local/bin/al --version
```

If `~/.local/bin` is not on your `PATH`, add it. With no binary for this host, build it with Rust installed:
`cargo install --git https://github.com/assistant-link/cli al`.

## 2. Pair

`al` uses `https://assistant-link.fly.dev`. If the "Service:" line names another URL, run `export AL_SERVER=<that URL>`
first, and add the same line to the wrapper in step 3.

```sh
mkdir -p -m 700 ~/.config/assistant-link
al pair K7QM-2XPA --key-file ~/.config/assistant-link/hermes.key   # the "Pairing code:" line
```

`al` keeps nothing on the host. It writes the Link key to the file, readable only by you, and prints the Link id and
Assistant name. Always use `--key-file`: without it `al pair` prints the key into your transcript.

## 3. Store the key

Use the first option that works, and never print the key. Each option also creates the wrapper `al-hermes`, which
supplies the key to `al`.

```sh
mkdir -p ~/.local/bin
```

**macOS Keychain:**

```sh
printf 'add-generic-password -a hermes -s assistant-link -w %s\n' "$(cat ~/.config/assistant-link/hermes.key)" | security -i
rm ~/.config/assistant-link/hermes.key
cat >~/.local/bin/al-hermes <<'WRAPPER'
#!/bin/sh
export AL_LINK_KEY="$(security find-generic-password -a hermes -s assistant-link -w)"
exec al "$@"
WRAPPER
```

**Linux Secret Service** (needs a running keyring, as in a desktop session):

```sh
secret-tool store --label="Assistant Link: hermes" service assistant-link account hermes <~/.config/assistant-link/hermes.key
rm ~/.config/assistant-link/hermes.key
cat >~/.local/bin/al-hermes <<'WRAPPER'
#!/bin/sh
export AL_LINK_KEY="$(secret-tool lookup service assistant-link account hermes)"
exec al "$@"
WRAPPER
```

**Key file** (any host): keep `~/.config/assistant-link/hermes.key` where it is.

```sh
cat >~/.local/bin/al-hermes <<'WRAPPER'
#!/bin/sh
export AL_LINK_KEY="$(cat ~/.config/assistant-link/hermes.key)"
exec al "$@"
WRAPPER
```

Then make it executable. If `al` is not on the `PATH` of the shell that will run the wrapper, write its full path
instead of `exec al`.

```sh
chmod 700 ~/.local/bin/al-hermes
```

## 4. Check

```sh
~/.local/bin/al-hermes status
```

It exits 0 and prints one JSON object with the Assistant name, the Link id, and `"check": "accepted"`. From now on,
run `al` through the wrapper (`al-hermes <command>`) wherever it needs the Link key.

## If something fails

Stop and tell the user, instead of retrying, when:

- `al pair` exits 4: the code is invalid, already used, or expired. Ask for new pairing text.
- `al pair` refuses because the key file exists: it may hold another Link's key. Do not delete it; use another name.
- `al status` exits 3: the key did not reach `al`. Check the storage command in the wrapper.
- `al status` exits 4: the service did not accept the key. Check that `AL_SERVER` matches the "Service:" line; if it
  does, the Link no longer exists (for example the user logged out of the app). Ask for new pairing text.
- A command exits 5 several times over a minute: the service is unreachable. Report the service URL.
- `al` cannot be installed: report `uname -sm` and the error.

Run `al help` and follow it.
