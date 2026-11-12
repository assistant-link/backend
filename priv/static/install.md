# Connect an agent to Assistant Link

Connect this host to the user's Assistant with the pairing text the user gave you. It names the Assistant and carries
the install link and a pairing code:

```
Connect to my assistant "Hermes" on Assistant Link.
Follow the instructions at https://assistant-link.fly.dev/install.md
Pairing code: K7QM-2XPA (expires 14:32 UTC)
```

Done when `al-hermes status` exits 0 (step 4) and, if your platform supports webhooks or email, a webhook or a confirmed
wake email is registered (step 5). The
commands below use `hermes`; replace it everywhere with this Assistant's name in lowercase. Each Assistant gets its own
key and wrapper, so one host can serve several.

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

`al` pairs with `https://assistant-link.fly.dev` by default; set nothing. Only if the install.md link is on another
host (a self-hosted service), run `export AL_SERVER=<that host's URL>` first, and add the same line to the wrapper in
step 3.

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

## 5. Get woken up automatically

`al-hermes wait` hears the user only while it runs. If your platform supports incoming webhooks (a URL that wakes or
triggers you), create a new webhook for this Link there and register its URL with the service:

```sh
al-hermes webhook set https://<your-webhook-url>
al-hermes webhook show    # prints the webhook, with the Authorization value masked
```

To protect the URL, have your webhook check an Authorization header and pass it with
`--header "Authorization: <value>"`, or set `AL_WEBHOOK_HEADER` instead to keep it off the command line. Keep that value
secret like the Link key. A Link has one webhook: `webhook set` replaces it, and `al-hermes webhook clear` removes it.

When the user writes or starts a call while no `al-hermes wait` or `al-hermes call` is connected, the service POSTs
`{"type":"wake","link_id":"..."}` to the URL, with the Authorization header if set. Opening the app also sends one, so
a ping can come with nothing to read. The ping carries no message content, comes at most once every 30 seconds, and is
best effort. On a ping, run `al-hermes read` and answer each message with `al-hermes send`; if there is a
`call_started` without a later `call_ended`, run `al-hermes call` instead.

Without `al`, use the API it calls (on the `AL_SERVER` host, if you set one). `GET` on the same path shows the webhook,
and `DELETE` removes it:

```
PUT https://assistant-link.fly.dev/alp/v1/link/webhook
Authorization: Bearer <Link key>
Content-Type: application/json

{"url": "https://<your-webhook-url>", "authorization": "<value>"}
```

If your platform has no webhooks but you can receive email, the service can wake you by email instead:

```sh
al-hermes wake-email set <your-email-address>
al-hermes wake-email show    # prints the address and whether it is confirmed
```

The service sends a confirmation email to that address from `no-reply@mail.assistantlink.ai`. Within 24 hours, open its
link and press Confirm (opening the link alone, as a mail scanner does, confirms nothing), or run the
`curl -X POST <link>` line it gives. Until then it sends nothing else there. Setting the confirmed address again keeps
it confirmed and sends nothing. A Link has one wake email: `wake-email set` replaces it, and `al-hermes wake-email clear`
removes it. A Link with a webhook is woken only by the webhook; setting a wake email does not remove the webhook.

When the user writes or starts a call while nothing is connected, the service emails the address, at most once every
30 seconds. The email quotes the message that triggered it, but newer ones may be waiting: run `al-hermes read` and
answer each message with `al-hermes send`, or run `al-hermes call` for a `call_started` without a later `call_ended`.
Do not reply to the email; nobody reads replies.

Without `al`, use the API it calls. `GET` on the same path shows the address and whether it is confirmed, and `DELETE`
removes it:

```
PUT https://assistant-link.fly.dev/alp/v1/link/wake_email
Authorization: Bearer <Link key>
Content-Type: application/json

{"address": "<your-email-address>"}
```

If you can receive neither, keep `al-hermes wait` running instead.

## If something fails

Stop and tell the user, instead of retrying, when:

- `al pair` exits 4: the code is invalid, already used, or expired. Ask for new pairing text.
- `al pair` refuses because the key file exists: it may hold another Link's key. Do not delete it; use another name.
- `al status` exits 3: the key did not reach `al`. Check the storage command in the wrapper.
- `al status` exits 4: the service did not accept the key. If the install.md link is on another host, check that
  `AL_SERVER` is that host's URL. If it is, the Link no longer exists (for example the user logged out of the app).
  Ask for new pairing text.
- A command exits 5 several times over a minute: the service is unreachable. Report the service URL.
- `al` cannot be installed: report `uname -sm` and the error.

Run `al help` and follow it.
