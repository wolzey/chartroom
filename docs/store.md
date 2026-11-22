# The store (stage 1, off by default)

With `CHARTROOM_STORE=sqlite` in a home's own `config`, every task born after that lives in one
SQLite database per machine, `${XDG_STATE_HOME:-~/.local/state}/chartroom/chartroom.db`
(`CHARTROOM_DB` moves it), which only `lib/store.py` opens (Python's own `sqlite3`: WAL, a 10 s
busy timeout, one short transaction per write). A task's place is fixed at birth:

- **Tasks born before the switch** stay `meta.json` and `events.log`, read and written as above,
  to the end. Nothing is moved or rewritten.
- **Store tasks** have a row and their events in the database. `tasks/<id>/` still holds what
  stays a file (`brief.md`, `plan.md`, `report.md`, `final.md`, `artifacts/`, `messages/`), but
  no `meta.json` and no `events.log`. Read them with `chartroom store meta|events <id>`, `show` or
  `status`. A process outside chartroom appends event lines to `tasks/<id>/events.spool` (the
  brief's fallback, a launch wrapper's `exited`), in the same line format; the store takes each
  whole line in once, keeping its time. An event the store cannot take waits there too.
- The home gets `.home-id`, written once: its uid in the store, and the database its first
  record went into, which the home keeps using (unless `CHARTROOM_DB` is set) even where
  `XDG_STATE_HOME` differs, as it can between a terminal and an ssh session. Records follow the
  uid, not the path, so a renamed or moved home keeps them.
- `status`, `board` and `todo` read all of a home's store tasks in one call to the store, the
  board's PR links, files and last event included; only liveness is still asked per open task.
- Every write still moves `.changed`, and a store write also rewrites `tasks/.store-stamp`; a
  reader that stats `meta.json` or `events.log` should stat one of those too, since a store task
  has neither.

`chartroom store doctor` shows the database and the Python it runs on; `store check` reports an
id found in both places; `store legacy` counts what the home still keeps as files from before.

With the switch on, new inbox items (`inbox add`) and the focus are store rows too; `inbox.md`
and `focus.json` from before are still read (the first focus write removes the old file).

So are the app's records, each kept as the JSON its file would hold, under its own id. The files
from before are still read beside them.
- **Snoozes:** one per ref. The newest by time wins across `snoozes.ndjson` and the store, so a
  snooze off ends an old file snooze.
- **Cards and answers:** the XO's `q-` cards (`questions/`). An answer lives where its card does,
  so the first answer wins in one place: a worker's ask follows its task, an inbox item's follows
  the item.
- **The mailbox:** tells, relays from other homes, and acks (`relays/inbox.ndjson`), plus the
  copies a home sends.
  - A record is born where the **receiving** home's switch says, in the database its `.home-id`
    names. A home with the switch off gets the file as before.
  - `chartroom store mail` prints a home's records from both halves.
  - The watch reads the store's mailbox under the cursor key `@mail`, beside the file's
    `@relays`.

`store legacy` counts these files too: open cards, answers, snooze lines and unacked mailbox
records. `requests/`, `initiatives/`, and a task's `links.ndjson` and `attachments.ndjson` stay
files: they live in the home's or the task's own folder.

**Removing work.** `chartroom remove <ref>... [--why T]` takes tasks, inbox items (`i-xxxx`) and
artifacts (`<id>/<slug>`) out of every view (status, board, todo, inbox list, artifact list, the
watch's wakes) at once, by a mark in the store, whatever the switch says and however old the item.
A removed task's or inbox item's artifacts leave with it. Nothing the item is made of is written: no record, worktree, branch or session, so unlanded work
stays where it is (`close` and `sweep` keep their own guards; sweep still sees removed tasks).
`chartroom restore <ref>...` undoes it for 30 days, `chartroom removed` lists what is removed, and
`chartroom done <ref>...` marks inbox items and artifacts done. A task whose worker is live is
refused unless `--stop`, which parks or ends the worker first. One call takes many refs: each is
checked on its own, all that pass are applied in one transaction, and the rest are reported by ref
(exit 1 when any failed; `--json` gives `{applied, failed}`). `accept` and `close` take several
ids the same way. In a home with a store, `todo done` and `artifact done` mark instead of editing
`inbox.md` or a sidecar. `sweep --apply` purges what removes no longer need (an inbox item removed
past 30 days, a mark on a file that is gone; a task's record and events never) and keeps one
backup of the database a day (`backups/` beside it, the newest 14).

The event line format, the brief protocol and `meta.json`'s `schema` field are stable from 0.1;
the change stamp's path and meaning are stable from the release that adds it. CLI flags may
change before 1.0.
