// A reference ALP client for agents that cannot install software: it uses only HTTPS, a standard
// WebSocket, and JSON-RPC 2.0, as in the "Protocol only" path of /install.md. Node.js 22 or later,
// no packages. The service's tests run it, so it stays in step with the protocol.
//
//   node client.mjs pair <service URL> <pairing code> <store file>
//   node client.mjs status <store file>
//   node client.mjs platform <store file> <platform>
//   node client.mjs webhook <store file> <url>      # AL_WEBHOOK_AUTHORIZATION: optional header value
//   node client.mjs answer <store file>
//
// The store file stands in for the agent's secret store: it holds the Link token together with the
// service URL it was issued by, and every request goes to that URL only. Nothing here prints the token.

import { readFileSync, writeFileSync } from "node:fs";

const [command, ...args] = process.argv.slice(2);
const print = (value) => console.log(JSON.stringify(value));

function fail(error) {
  console.error(JSON.stringify({ error }));
  process.exit(1);
}

// Lowercases the scheme and host and drops trailing slashes, so one service has one spelling.
const normalize = (service) => new URL(service).href.replace(/\/+$/, "");

const load = (store) => JSON.parse(readFileSync(store, "utf8"));

async function request(method, url, { token, body } = {}) {
  const headers = { "content-type": "application/json" };
  if (token) headers.authorization = `Bearer ${token}`;
  const response = await fetch(url, { method, headers, body: body && JSON.stringify(body) });
  const json = response.status === 204 ? null : await response.json();
  if (!response.ok) fail(json?.error ?? { status: response.status });
  return json;
}

function linkRequest(store, method, path, body) {
  const { service, token } = load(store);
  return request(method, `${service}/alp/v1${path}`, { token, body });
}

// A random UUID with the current Unix time in milliseconds in its first 48 bits (RFC 9562).
function uuidv7() {
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  const now = Date.now();
  for (let i = 0; i < 6; i++) bytes[i] = Math.floor(now / 2 ** (8 * (5 - i))) & 0xff;
  bytes[6] = (bytes[6] & 0x0f) | 0x70;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = Buffer.from(bytes).toString("hex");
  return [hex.slice(0, 8), hex.slice(8, 12), hex.slice(12, 16), hex.slice(16, 20), hex.slice(20)].join("-");
}

async function pair(service, code, store) {
  service = normalize(service);
  const { link_id, assistant_name, token } = await request("POST", `${service}/alp/v1/pair`, { body: { code } });
  // The token is returned only once; "wx" keeps another Link's token from being overwritten.
  writeFileSync(store, JSON.stringify({ service, token }), { mode: 0o600, flag: "wx" });
  print({ link_id, assistant_name });
}

// Reads the events that are waiting, answers each text message, and stays through a call until it ends.
function answer(store) {
  const { service, token } = load(store);
  const ws = new WebSocket(`${service.replace(/^http/, "ws")}/alp/v1/connect`, {
    headers: { authorization: `Bearer ${token}` },
  });
  const handled = new Set();
  let caughtUp = false;
  let onCall = false;
  let closing = false;

  const send = (message) => ws.send(JSON.stringify({ jsonrpc: "2.0", ...message }));

  function closeUnlessOnCall() {
    if (caughtUp && !onCall) {
      closing = true;
      ws.close();
    }
  }

  async function deliver(id, event) {
    // Delivery is at least once: an event seen before is only acknowledged again.
    if (handled.has(event.id)) return send({ id, result: { event_id: event.id } });
    handled.add(event.id);
    print({ event: event.type, id: event.id, ...event.text_message });
    send({ id, result: { event_id: event.id } });

    if (event.type === "call_started") onCall = true;
    if (event.type === "call_ended") onCall = false;

    if (event.type === "text_message" && !event.deleted) {
      const text = `You said: ${event.text_message.text}`;
      await linkRequest(store, "POST", "/messages", { text, idempotency_key: uuidv7() });
      print({ replied: text });
    }

    closeUnlessOnCall();
  }

  async function handle(message) {
    switch (message.method) {
      case "connection.ready":
        return print({ ready: message.params.link_id });
      case "connection.caught_up":
        caughtUp = true;
        print({ caught_up: true, on_call: onCall });
        return closeUnlessOnCall();
      case "connection.closing":
        return fail({ closing: message.params.reason });
      case "event.deliver":
        return deliver(message.id, message.params);
      default:
        if (message.method && message.id !== undefined) {
          send({ id: message.id, error: { code: -32601, message: `Method not found: ${message.method}` } });
        }
    }
  }

  // One message at a time, so a reply is posted before the next event is handled.
  let queue = Promise.resolve();
  ws.onmessage = ({ data }) => (queue = queue.then(() => handle(JSON.parse(data))));
  ws.onerror = () => fail({ connection: "failed" });
  ws.onclose = ({ code }) => (closing ? process.exit(0) : fail({ connection: "closed", code }));
}

switch (command) {
  case "pair":
    await pair(...args);
    break;
  case "status":
    print(await linkRequest(args[0], "GET", "/link"));
    break;
  case "platform":
    print(await linkRequest(args[0], "PATCH", "/assistant", { platform: args[1] }));
    break;
  case "webhook":
    print(
      await linkRequest(args[0], "PUT", "/link/webhook", {
        url: args[1],
        authorization: process.env.AL_WEBHOOK_AUTHORIZATION,
      }),
    );
    break;
  case "answer":
    answer(args[0]);
    break;
  default:
    fail({ usage: "pair | status | platform | webhook | answer" });
}
