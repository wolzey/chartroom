# The chartroom app

The app is one place for every home on the brain. It opens on Needs me and acts through chartroom's own verbs. This page covers running it, how access works, and how it is built.

## Run it on the brain

```bash
# once: the one person the app lets in, in the brain's config file (~/.config/chartroom/config)
CHARTROOM_APP_USER=<your Tailscale login, e.g. you@example.com>

chartroom app serve --daemon     # 127.0.0.1:4516
chartroom app doctor             # what is running, who may come in, and the Serve command
```

To put it on your tailnet, run the command `doctor` prints, once. It is the standard Tailscale CLI; on a Mac with the app store version, the binary is `/Applications/Tailscale.app/Contents/MacOS/Tailscale`:

```bash
tailscale serve --bg --https=443 http://127.0.0.1:4516
```

Then open `https://<brain>.<tailnet>.ts.net/` on any of your devices. HTTPS is not optional. Installing the PWA, its service worker and push notifications all need a secure context, so a plain `http://studio:4520` cannot carry them.

On the brain itself, before Serve is set up, `chartroom app serve --daemon --no-auth` and `chartroom app open` give this machine's browser the app without an identity.

## Who gets in

- **Binding.** The server binds 127.0.0.1 only. Nothing on the network reaches it except through Tailscale Serve.
- **Identity.** Tailscale Serve adds `Tailscale-User-Login` to every request it forwards from a tailnet user, and clients cannot set that header through Serve. The server compares it, ignoring case, with `CHARTROOM_APP_USER`. A request without it, or with anyone else's, gets a 403. `/healthz` is the one exception, so the CLI can tell the server is up.
- **`--no-auth`.** There is no identity check. A request is served only if it came straight to `127.0.0.1` or `localhost`: no `X-Forwarded-For`, no Tailscale identity header, and no other `Host`. So with Serve pointed at a `--no-auth` server, every request from the tailnet is refused. Use it for this machine's own browser, never as the tailnet's way in.
- **Writes.** A write must be a `POST` with `Content-Type: application/json` and the app's own `X-Chartroom-App: 1` header, which no form, link or image can send. When the browser says where the request came from (`Sec-Fetch-Site`, `Origin`), that must be this app.
- **Accepted caveat.** A process on the brain could reach 127.0.0.1 and set the identity header itself. Such a process already runs as you and can run `chartroom` and read every home, so the app gives it nothing new.

## What it reads, and how

- **Which homes.** The server reads every registered home on the machine (`chartroom homes --json`) and leaves out client homes, whose records live on their brain. A home registered later appears within a minute.
- **How each home is read.** Each home has its own background thread running `chartroom app snapshot --json` in it. That is `lib/app.sh` plus `lib/app/snapshot.jq`: the task rows `status` builds, the inbox, open artifacts, cards and their answers, snoozes and the told messages, classified there and never in the server.
- **When.** A thread looks every 2 s at the home's change stamp and the few files the app writes. It reads again when one moves, and at least every 20 s, because a worker's live state changes with no record written.
- **Updates.** The page loads `GET /api/v1/state`. It loads again on each `version` event from `GET /api/v1/stream` (server-sent events), and polls every 10 s when the stream is down.

## What it writes

The server never writes a record itself. Each write runs one chartroom verb in that home, on the brain, with a fixed argv; the commander's words go on stdin:

| In the app | Verb |
|---|---|
| Send an answer, approve a plan, request changes | `ask answer <card> --via app -` |
| A typed message with no card | `tell --via app [--re <ref>] -` |
| Accept, close | `accept <id>`, `close <id>` (never `--discard`) |
| Snooze, undo | `snooze <ref> --for/--until`, `snooze off <ref>` |
| Mark done | `todo done <i-id>`, `artifact done <ref>` |

## Cards and answers

- **Ids.** A card is a posted card (`q-xxxx`, `questions/<id>.json`), a worker's ask (`ev-<task>-<byte offset>` of its decision, blocked, failed or awaiting-input line), or an open inbox question (`i-xxxx`).
- **First answer wins.** An answer is `questions/<id>.answer.json`, created only if absent, so the first answer wins from any side. A second answer is refused and names the first.
- **Reaching the XO.** An answer from the app is also told to the XO (`relays/inbox.ndjson`, `kind: "commander"`), whose `watch` wakes with `[commander <cm-id>] [via app] ...`. The XO acks it (`tell ack`), and the app then shows "read by the XO".
- **No XO open.** The conn lease and resident XOs (one brain, step 3) are not built yet. Until they are, a message waits in the mailbox until the home's XO next runs `watch`, and the app says it has not been read yet.

## The code

```
app/index.html          the shell: vendored React, the dashboard's eventfmt.js and markdown.js, then src/
app/src/model.js        what is shown, pure (test/js/app-model.test.js)
app/src/main.js         routes, data, actions, keyboard
app/src/needs.js        the list and the quick view
app/src/round.js        a card of several questions
app/src/details.js      a task's brief, plan, report and events (until the ticket view)
app/src/palette.js      ⌘K
app/styles/             tokens, base and layout from the approved prototypes; app.css adds to them
app/vendor/             react 18.3.1, react-dom 18.3.1, htm 3.1.1 (LICENSES.md)
lib/app.sh              chartroom app: serve, open, stop, status, doctor, snapshot
lib/app/server.py       the server
lib/app/snapshot.jq     Needs me and the seven statuses
lib/tell.sh, lib/ask.sh, lib/snooze.sh
```

There is no build step: the files in `app/` are what the browser loads. Tests: `test/app.bats` (the verbs and the snapshot), `test/app-server.bats` (access, writes, files, the stream, sweep) and `test/js/app-model.test.js`.
