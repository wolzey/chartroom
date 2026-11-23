# The chartroom app

The app is one place for every home on the brain. It opens on Needs me and acts through chartroom's own verbs. This page covers running it, how access works, and how it is built.

## What it does

One app for every home on the brain, served by chartroom and reached over the tailnet: it opens
on **Needs me**, one inbox of every decision, plan to approve, blocker and report across every
home, answered in place from a quick view beside the list. It is a React PWA in `app/`, shipped
in this repo with no build step (React and htm are vendored), and served by `lib/app/server.py`
(Python standard library). The [dashboard](dashboard.md#dashboard) keeps running beside it until the app
covers everything it does.

```bash
chartroom app serve --daemon     # 127.0.0.1:4516 (CHARTROOM_APP_PORT), for Tailscale Serve
chartroom app service on         # macOS: a LaunchAgent keeps it up and starts it again after a reboot
chartroom app doctor             # the server, who may come in, and the Serve command to run
chartroom app open               # this machine's browser (start it first with --no-auth)
chartroom app stop               # (or: status); the LaunchAgent only when it runs for this config
```

- **Who gets in.** The server listens on 127.0.0.1 only. `tailscale serve --bg --https=443
  http://127.0.0.1:4516` puts it on your tailnet over HTTPS (which the PWA needs) and names the
  person at each request; only `CHARTROOM_APP_USER`, your Tailscale login, gets in. There is no
  password. `--no-auth` drops the identity check for this machine's own browser, and then
  refuses anything that came through a proxy. [docs/app.md](app.md) has the details.
- **Acting from it.** Mark read, accept, close and snooze run as they would in the terminal
  (`artifact done`, `todo done`, `accept`, `close`, `snooze`). Answers, approvals and anything
  typed go to that home's XO as your own words (`chartroom tell`), and its `watch` wakes with
  `[commander <id>] ...`. The app shows when the XO has read one.
- **Instant.** Every action is queued in the page: the item moves at once, and an outbox kept in
  the browser sends it in the background, retrying while the server cannot be reached. The
  server accepts it at once and runs the verb behind it in order, per home. An action that
  fails comes back with the reason and a Retry.
- **Several at once.** Select rows (their checkbox, `x`, `Shift+J`/`Shift+K`, shift-click, `⌘A`)
  and a bar acts on all of them: Mark done (an inbox question or a draft is marked done; a
  finished task is accepted), Accept, Close, Snooze. One action per item: each one succeeds or
  fails on its own, and Close never discards work: a task that cannot be closed cleanly
  refuses and says why.
- **Question cards.** A worker's `decision` (its options parsed from its own words), an inbox
  question, and a card the XO posts with `chartroom ask` are all cards. Only an explicit
  marker (`(1) RECOMMENDED: ...`) recommends an option, one per question at most. An ask with
  several questions is a grilling round, answered on its own page and submitted together. The
  first answer wins, from the app or the terminal (`chartroom ask answer`).
- **The note box.** It grows with what is in it, typed or accepted from a writing assistant, up to
  320 px (less on a short screen), and scrolls past that. A suggestion drawn over the page, before
  it is accepted, is not in the box, so the box cannot grow for it.
- **Readable.** Every text colour measures at least 4.5:1 (WCAG AA), light and dark, and every
  URL is a link; a GitHub PR or issue reads `repo#123`.
- **Keys.** `j`/`k` move, `Enter` answers with the recommendation (or approves, or accepts),
  `1`-`9` pick an option, `⌘↵` sends, `o` opens details, `s` snoozes, `x` selects, `⌘K` or `/`
  opens the palette. Dark and light follow the system, and the moon toggles them.
- **Tickets and the board.** A task opens as a ticket: its question, its PRs (state and checks
  from `gh`), its description (the brief, edited in place), plan, report, attachments (25 MB
  each; `chartroom attachment`), and the activity with comments that steer the worker (`@xo`
  asks the XO). The board shows every home's tasks in seven columns, filtered by home, project,
  initiative and machine. `c` anywhere writes a new task, which goes to that home's XO as a
  request (`chartroom request`).
- **Every home.** It reads each registered home on the machine (`chartroom homes`) in the
  background with `chartroom app snapshot --json`, again whenever a home's records change. A
  client home is left out, and refuses `chartroom app`: the app runs on its brain.

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

Then open `https://<brain>.<tailnet>.ts.net/` on any of your devices. HTTPS is not optional. Installing the PWA, its service worker and push notifications all need a secure context, so a plain `http://desk:4520` cannot carry them.

On the brain itself, before Serve is set up, `chartroom app serve --daemon --no-auth` and `chartroom app open` give this machine's browser the app without an identity.

## On the phone, and notifications

- **Install.** Open the HTTPS address and add it to the home screen (Safari: Share, Add to Home Screen; Chrome: Install). It opens full screen with a tab bar: Needs me, Board, Initiatives, Fleet. A selected item opens as a sheet from the bottom.
- **Offline.** The service worker (`/sw.js`) keeps the shell and the last state. With the brain out of reach the app still opens, says how old what it shows is, and keeps your actions in the outbox until the brain is back. It always asks the network first, so a new version shows at once.
- **Notifications, with no third party.** "Turn on notifications" (the sidebar's foot, or ⌘K) asks the browser once. While the app is open in the background, a new Needs me item shows a notification. Each item notifies once per device, and what is already open when the app loads never does.
- **A tap lands on the item.** The notification links to `#/n/<home>:<id>`, which opens the item's own page:
  - a task's question, blocker or finished work: the task's details, with its question at the top;
  - a grilling round: its round page; stories to approve: their initiative; a failed sign-in: its machine on Fleet;
  - a permission card, or a question that belongs to no task: Needs me, with that card open (a sheet on the phone).
  An item answered since then opens its task, when it has one, and says it was answered.
- **However the app is.** The service worker (`app/sw.js`, `openAt`) handles the tap:
  - open, on any page, in front or behind: the window is focused and told where to go. It answers that it heard, because `navigate()` fails for a window the worker does not control and Safari has none;
  - an older page that does not answer is navigated there;
  - closed: a new window opens at the item. An installed app may open at its start page instead, so the worker keeps the target for two minutes, and a page that starts asks for it once.
- **Web Push, for a closed app.** Off unless the brain's config says `CHARTROOM_APP_PUSH=on`. Then the server sends each new item through the push service of the browser's maker (Apple, Google, Mozilla). The payload is encrypted end to end (RFC 8291, `lib/app/push.mjs` with node's built-in `node:crypto`), so that service sees only the endpoint, the size and the time. It needs node on the brain; `chartroom app doctor` says whether push can send. `CHARTROOM_APP_PUSH_SUBJECT` is the contact the push services see (a `mailto:` or `https:` URL; the default is a placeholder). On iOS, push reaches only the installed app (iOS 16.4 or later).
- **The XO answers first.** A worker's permission card, or a worker's decision or plan approval, wakes the XO at once.
  - **When it is pushed:** only if it is still open after `CHARTROOM_APP_PUSH_HOLD` seconds (120 by default). One the XO answers on a ruling never reaches your devices.
  - **When it is pushed at once:** a breaking one; one the XO hands over with `chartroom permit escalate <p-id> [--note …]`, which the card then marks as "The XO left this one to you"; and a card with less than the hold left on its clock.
  - **Withdrawn when answered:** a pushed item answered later is withdrawn. A "close" push takes the notification away instead of leaving it to say it was answered.
  - **iPhone and iPad:** Apple's push service revokes a subscription whose push shows nothing, so Apple devices get no "close" push. There the app closes such notifications when it opens. Posted cards (`chartroom ask`) and inbox questions are already for you, and push at once.
- **What the server keeps.** The VAPID keys and each device's subscription live beside the pid file (`app-push-keys.json`, `app-push-subs.json`, both 0600), never in a home. A subscription is a write (the same checks), only for an https endpoint, 20 devices at most; one the push service reports gone (404, 410) is dropped. An item is pushed once, when it first appears; what is open when the server starts, or when a home is first read, is only remembered.

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
- **Fleet.** One background thread runs `chartroom app fleet --json`: `chartroom nodes` (each machine's probe, over ssh for the others) through `lib/app/fleet.jq`, which decides each machine's health. It runs every 5 minutes while the app is open, and at once on `POST /api/v1/fleet/check` (the page's Check again; it starts ssh probes, so it passes a write's checks). The result rides in the state as `fleet`; a failed sign-in in it is a Needs me item of no home.
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
| New initiative, approve its stories | `initiative new --via app`, `initiative approve <id> - --via app` |
| A comment on the plan, a proposed edit | `initiative comment <id> --section S --via app -`, `initiative propose <id> -` |
| Confirm a close | `initiative close <id> --confirm --via app` |
| A permission card: Allow once, Always for this task, Deny | `permit answer <p-id> once\|always\|deny --by app --via app [--note T]` (the permission broker, `lib/permit.sh`) |

### Instant, queued, never twice

The page never waits on a verb:

- **In the page.** An action changes the page at once and goes into an outbox, kept in the browser's `localStorage`, so a reload or a dropped tunnel loses nothing. The outbox sends each action with an id (`X-Chartroom-Action`), retries with growing waits while the server does not answer, and marks it failed when the server refuses it.
- **On the server.** A write is answered `202` as soon as it is checked. The verb runs in the background, in order, one queue per home. `GET /api/v1/state` carries each action's outcome (`actions`): `done`, or `failed` with the verb's own reason, shown with a Retry.
- **No double runs.** An id seen before is the same action, never a second run. The server keeps its actions in `app-actions.ndjson` beside the pid file (0600). After a restart, an action accepted but not finished runs, and a finished one is not repeated.
- **Bulk actions.** These are the same thing, one entry per item, so each item succeeds or fails on its own.

## Permission cards

A Claude worker's tool call that chartroom's policy would not answer by itself waits on the commander as a permission card (the permission broker: `lib/permit.sh`, `docs/permits.md`). In Needs me:

- **What it shows.**
  - **The lead:** what the worker wants, in a sentence ("Wants to use your Azure login to read who can approve deploys"), from its own description and the rule.
  - **Why it came to you, in plain words:** "Asked because it uses your Azure login", with the repo and the time left. It never shows the rule code.
  - **The call:** its first line that does something; Show command unfolds the whole call, never cut.
  - **An escalated card:** "The XO left this one to you", with the XO's note.
- **The clock.** A countdown to the broker's deny (15 minutes by default). A retry card, for a call auto mode already refused, says so instead.
- **The answers.** One row: Allow once, Always for this task, Deny, and a note. Under the row, what Always covers, in a few words ("any command starting with `git push`", or "this exact command"), never less than it allows. The note goes to the worker with a deny, and with an allow on a retry card.
  - The first answer wins. A second one fails with the broker's own words, which name the first.
- **A missed card.** One whose wait ran out, or that the worker went on without, stays for an hour with "Allow now (the worker will retry)" and no Deny. The broker takes only a late allow, and then tells the worker to run the call again.
- **Order and safety.** Live blocking cards come first, nearest expiry first; they are the only items with a clock. A task waiting on its card shows the card, not a bare "decision". No key press, bulk action or snooze answers one: Enter only puts the cursor in the note.
- **Notifications.** A new card notifies (and pushes, when push is on) as "Allow <the call>?".

## Cards and answers

- **Ids.** A card is a posted card (`q-xxxx`, `questions/<id>.json`), a worker's ask (`ev-<task>-<byte offset>` of its decision, blocked, failed or awaiting-input line), or an open inbox question (`i-xxxx`).
- **First answer wins.** An answer is `questions/<id>.answer.json`, created only if absent, so the first answer wins from any side. A second answer is refused and names the first.
- **Decisions, kept.** Every answered card that belongs to a task stays on that task's page under Decisions, newest first: each question in its own words, the answer, the note, when, and where it was answered. The list comes from `decisions_json` in `lib/ask.sh`, read by `chartroom app task <id> --json`.
  - **Which cards:** a card the XO posted with `--task`, whether answered in the app or recorded with `ask answer`, and the task's own ask answered in the app. A withdrawn card decided nothing.
  - **The initiative's page** shows the same decisions, by story, under "From its tasks" (`initiative show <id> --json`, `task_decisions`).
  - **Back from a round:** the round's page says which task or initiative it belongs to and links there. A decision links back to its round for as long as the round is still in the app (48 hours after its answer).
- **Reaching the XO.** An answer from the app is also told to the XO (`relays/inbox.ndjson`, `kind: "commander"`), whose `watch` wakes with `[commander <cm-id>] [via app] ...`. The XO acks it (`tell ack`), and the app then shows "read by the XO".
- **No XO open.** The conn lease and resident XOs (one brain, step 3) are not built yet. Until they are, a message waits in the mailbox, and the app says it has not been read yet. The next XO to start that home's `watch` (streaming, or the first `--once`) wakes with every message not yet acked, and `chartroom status` counts them (`told: N unread`).
- **Versions.** Only a chartroom with `tell` wakes an XO with these messages. An older `watch` reads past them without a wake. So land and install this version, re-run `chartroom install-skills`, and restart each XO's watch before answering from the app.

## The code

```
app/index.html          the shell: vendored React, the dashboard's eventfmt.js and markdown.js, then src/
app/src/model.js        what is shown, pure (test/js/app-model.test.js)
app/src/main.js         routes, data, actions, keyboard
app/src/needs.js        the list and the quick view
app/src/round.js        a card of several questions
app/src/ticket.js       a task as a ticket: its question, PRs, description, plan, report, attachments, activity
app/src/read.js         a ticket or an initiative, read one at a time and always shown
app/src/outbox.js       every action queued, sent in the background, retried (pure)
app/src/palette.js      ⌘K
app/src/initiatives.js  initiatives: the list, the page (plan, stories, decisions, PRs), the approval checklist
app/src/fleet.js        Fleet: the machines, their checks and budgets, the workers
app/src/notify.js       the service worker's registration, notifications, the push subscription
app/sw.js               the service worker: the offline shell and last state, notifications
app/manifest.webmanifest, app/icons/   what makes it installable
lib/app/push.mjs        the Web Push sender (node:crypto; RFC 8291 and 8292)
app/styles/             tokens, base and layout from the approved prototypes; app.css adds to them
app/vendor/             react 18.3.1, react-dom 18.3.1, htm 3.1.1 (LICENSES.md)
lib/app.sh              chartroom app: serve, open, stop, status, doctor, snapshot
lib/app/server.py       the server
lib/app/snapshot.jq     Needs me and the seven statuses
lib/app/fleet.jq        each machine's health, and its failed sign-ins as Needs me items
lib/tell.sh, lib/ask.sh, lib/snooze.sh, lib/initiative.sh
```

There is no build step: the files in `app/` are what the browser loads. Tests: `test/app.bats` (the verbs and the snapshot), `test/app-server.bats` (access, writes, files, the stream, sweep), `test/app-ticket.bats`, `test/app-initiative.bats`, `test/app-fleet.bats` (over the invented machines in `test/fixtures/app-nodes.json`, read through `CHARTROOM_APP_NODES`), `test/app-push.bats` (pushes to a fake push service on this machine, `test/js/push-sink.js`, which decrypts them as a browser would; `CHARTROOM_APP_PUSH_ALLOW_HTTP=1` lets it be plain http on 127.0.0.1, for tests only), `test/js/app-push.test.js` (the sender, against the RFC 8291 vector) and `test/js/app-model.test.js`.
