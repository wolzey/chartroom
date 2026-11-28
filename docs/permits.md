# Permission cards: a worker's prompts come to chartroom

A Claude or agy worker that needs a permission no longer waits at a prompt only its terminal can answer.
Each call ends one of two ways:
- **The policy answers it**, by the commander's rulings. This covers routine work inside the
  worker's worktree and whatever its brief explicitly grants.
- **It becomes a card for the commander.** The card goes to the watch's wake stream (and the
  XO), `chartroom permit ls` and the app. The answer goes back to the worker, so it carries on.

Codex workers are not covered yet (stage 2 of the design: Codex has its own approval mechanism).

## How it works

Every Claude worker chartroom launches has three hooks in its per-task settings
(`claude_settings_file`). That covers hc, herdr, tmux, cmux and headless.

| Hook | Runs | Does |
|---|---|---|
| `PreToolUse` → `hook <id> pre-tool` | before every tool call, before Claude's own permission check | **Guards** deny (the pattern-kill guard; touching the permit store; answering a permit; rewriting the task's control files). **Grants** and "always" rules allow: an allow here comes before auto mode's classifier. A call that is the **commander's** is sent to a prompt (`ask`) so the next hook makes it a card. A headless worker has no prompt, so the hook holds that call on the card itself. Anything else gets no opinion. |
| `PermissionRequest` → `hook <id> permission` | when Claude would show a permission dialog | The policy answers it, or it becomes a card that the hook waits on. |
| `PermissionDenied` → `hook <id> denied` | when auto mode's classifier refuses a call | Records the refusal, and raises a card offering the commander to allow a retry. |

agy uses a catch-all `PreToolUse` hook in the task's `.agents/hooks.json`. It normalizes
native and legacy file-tool arguments, then applies the same policy's guards, grants, local
rules and commander classes. The hook holds the call until a card is answered or expires;
it does not rely on an approval callback. Unknown tools, including MCP, browser and background
input, require cards. agy defaults to bypass mode; `CHARTROOM_AGY_PERMISSION` or task
`permission` can select `auto`, `accept-edits` or `plan` to retain agy's approvals. In those
modes an allowed hook returns no opinion, so agy still decides whether to prompt.

The agy hook timeout is the card wait plus 60 seconds; the wait is pinned at launch. Invalid
payloads, unavailable task records and broker errors deny. Its launcher refuses to start if
hook creation fails. The [backend notes](../skills/chartroom/references/backends.md#agy-antigravity-cli-hcagy-herdragy-nodeagy)
cover tool names and limits. The later discussion of Claude's classifier, transcripts and
fail-open hook behavior describes Claude only.

### Answering a card

```
chartroom permit ls                      # open cards (--all: answered, expired, lapsed)
chartroom permit show p-1a2b             # one card as JSON
chartroom permit answer p-1a2b once      # allow this call
chartroom permit answer p-1a2b always    # allow this pattern until the task closes
chartroom permit answer p-1a2b deny --note "use the staging project instead"
chartroom permit answer 71b6/p-1a2b once # the card of that task (its id or short id)
```

- **A card's id** is `p-` and 8 hex digits, never one another card of this home had. Cards from a worker on a
  device are made there, where this home's ids cannot be seen; if two tasks ever have one id, a plain id means
  the one card of them still open. With none or several open, the answer is refused and names each as
  `<task>/<p-id>`: an answer lets a call run, so it is never guessed. The app always names the task.

- **The first answer wins.** A second answer is refused and names the first.
- **The wait.** The hook waits up to `CHARTROOM_PERMIT_WAIT_SECONDS` (900), then denies. The
  worker is told to post a `decision` naming what it needed. Nothing hangs, and nothing runs
  unapproved.
- **A late answer.** An allow given after the wait ran out becomes a one-time pre-approval of
  that exact call, and the worker is steered to run it again.
- **Retry cards.** A card raised by `PermissionDenied` works the same way, because the worker has
  already moved on.
- **A card Claude goes on without closes at once.** That happens when its terminal's dialog was
  answered, or the worker stopped. Claude does not stop a waiting hook when the terminal answers,
  so the hook watches for the call's result in the session transcript. It also closes the card on
  a signal or when its parent claude is gone. Either way it logs
  `permit: closed p-xxxx: the worker went on without chartroom's answer`, and the task is no longer
  `decision`. An allow given later is kept as a pre-approval.
- **"Always for this task"** stores the pattern shown on the card (also printed in the `asks` line
  and in `permit ls`). A prefix or glob pattern covers one plain command only, never a line that
  chains, substitutes or redirects something else onto it, so `npm test:*` does not cover
  `npm test && git push`. For Bash that is Claude's own
  suggested rule (`npm run test:*`) when it gives one, otherwise the exact command. For a file
  tool it is the path; for any other tool, the exact call. The rule ends when the task closes.
  `close` moves the task's `permits/` record into `tasks/<id>/permits/`, where nothing reads it as
  policy.
- **`--by` and `--via`.** `--by app` is the app's answer; `--by commander` (the default) is an
  answer given in a terminal. `--via xo` marks an answer the XO typed on the commander's relayed
  words, and is filled in for an XO session. The XO never answers a card on its own judgment.

### Grants

A brief's Authority is prose in a file the worker can edit, so the policy does not read it.
Grants that the policy enforces are named. They are set at creation with `--grant`, or later
with `permit grant`. A ship task starts with `push-branch`, `open-pr` and `comment-pr` (`CHARTROOM_DEFAULT_GRANTS`,
or `new --grant none`):

```
chartroom new --project ~/src/app --title "..." --grant push-branch --grant merge-auto
chartroom permit grant <id> open-pr         # permit revoke <id> <name>; permit grants <id>
```

| Grant | Lets through | Never |
|---|---|---|
| `push-branch` | `git push [-u] [origin] [<task branch>\|HEAD:<task branch>]`, and a bare `git push` while the worktree is on the task branch | `--force`, `--delete`, `--mirror`, `--tags`, another branch |
| `open-pr` | `gh pr create` for the task branch, and `gh pr edit` / `gh pr ready` on its PR | `-R/--repo` |
| `merge-auto` | `gh pr merge [<task branch>] --squash --auto` | `--admin`, `--merge`, `--rebase`, `--delete-branch`, a PR number, `-R` |
| `comment-pr` | `gh pr comment [<task branch>]` | `-R` |
| `prod-read` | Calls that only read production or the feature-flag service. **curl:** no method but `GET`/`HEAD`, and any file it writes (`-o`, `-D`, `-c`, `--output-dir`) inside the work roots or `/dev/null`. **kubectl:** `get`, `describe`, `logs`, `top`, `events`, `explain`, `config view\|get-contexts`, `rollout status\|history`. **gcloud:** `describe`, `list`, `get-credentials`, `logging read`, `get-iam-policy`. A kubectl or gcloud read is covered on any cluster or project. A curl read is covered only when the call is a production or flags match, since a GET to any other host could carry data out. | A body or upload (`-d`, `--json`, `-F`, `-T`, even with `-G`), a config file (`-K`), a method or word the line cannot read (`-X "$M"`, `curl $OPTS`), a command fed by `xargs`, a secret (any kubectl word naming one, any `--raw`, `gcloud secrets versions access`), `exec`, `port-forward`, `cp`, `ssh`, and anything that changes |

A grant covers its own matches only. Production and flags matches are covered by `prod-read`;
outward-facing ones by the other grants. A command that also touches secrets, money or another
machine is still a card. So is a line whose other commands the local rule would not pass:
`git push origin <task branch>; rm -rf ~/x` is a card even with `push-branch`. `prod-read`
cannot tell which host is production; it judges what a call does, not where it goes. A word
that is only a variable (`$OPTS`) is never trusted, but a variable inside a word
(`https://…/x$EXTRA`) is read as part of a URL. wget, httpie, aws, az, helm, ldcli and MCP tools
are not covered.

## The policy: `lib/permit.jq`

All the rules live in one file. **First match wins:**

1. **`guard:*` → deny.**
   - `guard:store`: the permit store (`$CR_HOME/permits`).
   - `guard:self-answer`: `permit answer|grant|revoke`.
   - `guard:controls`: the task's `meta.json`, `claude-settings.json` or `launch.sh`, or the machine's
     task store (`CHARTROOM_DB`); a Bash line that names the store is a `commander:controls` card.
2. **Questions** (`AskUserQuestion`, `ExitPlanMode`) get no opinion. They are not permissions.
3. **`preapproved:<p-id>` → allow**, once.
4. **`always:<p-id>` → allow.** For Bash, an always answer stores each command of the line by its
   program and fixed leading words: up to four, stopping at the first flag, path, id, number,
   quote or `=` (`gh run view 123 --log | tail -5` stores `gh run view:*` and `tail:*`). A lone
   program stays exact unless it is a read-only filter (`grep`, `head`, `tail`, `jq`, ...; not `rg`,
   `sort` or `uniq`, which can run a program or write a file); so do
   script runners and hosts (`python3`, `node`, `ssh`, `awk`, `sed`, ...) and any command whose
   words name `push`, `api`, `delete`, `merge`, `deploy` or a like verb, where the open part would
   be the branch, the method or the target. A later line is allowed only when every one of its
   commands is covered by a record, it is plain (no `$(...)`, backticks, `<`, `$'...'`, a quote
   escaped outside quotes, `${...}` other than a plain name, `VAR=value`, `sudo`, `xargs`, a wrapper
   given flags, a shell or `eval`, and redirects only to `/dev/null` and the like), and the policy
   without "always" would allow it or card it under the same rule and reason as the answered card:
   `gh pr:*` answered for `gh pr view` never covers `gh pr comment`. A line it cannot read this
   way keeps the whole line as its pattern, matched exactly.
5. **`commander:*` → card**, unless a grant covers every match (then `grant:<name>` → allow):
   - **production:** `prod`/`production` in an infra command; `kubectl`/`helm`/`terraform`/
     `pulumi` changes; `gcloud`/`az`/`aws`/`gsutil` mutations; a database client on a remote host.
   - **secrets:** `.env*` (not `.env.example`); `~/.ssh`, cloud credentials, `.netrc`, `.npmrc`,
     keychains; `op`, `vault`, `security`, `gh auth token`, `gh secret`; printing the
     environment.
   - **flags:** the feature-flag service (`ldcli`, its API's URL, and MCP tools named for it or
     sent to it). Words that only name it are not a use: a web search, a fetched page, the
     input of an MCP tool whose name says it only reads.
   - **money:** Stripe, cloud billing.
   - **outward:**
     - git: `git push`, `git remote add|set-url`;
     - GitHub: `gh pr|issue|release|repo|workflow` writes, `gh api` writes;
     - publishing: package publish, `docker push`;
     - deploy CLIs;
     - messages: Slack, mail, Jira, Linear;
     - HTTP writes;
     - an MCP tool whose name says send, create, update, delete, ….
   - **elsewhere:** `ssh`/`scp`/`rsync` to a host, `sudo`, a write outside the worktree.
   - **controls:** the worktree's `.claude/`, `.mcp.json`, `.git/config`, `.git/hooks`, and
     `git config`.
6. **`local:*` → allow**, only for a prompt Claude would show:
   - reads anywhere, since secrets were carded already, and a web search (`local:search`);
   - writes, tests, installs, local git, a dev server on localhost and scratch files inside the
     worktree, the task dir, the scratchpad and `/tmp`.
7. **Otherwise:** a card for a prompt (`commander:unlisted`). For `PreToolUse`, no opinion:
   Claude's own flow decides.

**How Bash is read.**
- The command is split into commands at `; & | ( ) { }`, backticks and newlines, respecting
  quotes.
- `$(...)`, `` `...` ``, `sh -c '...'` and `eval` are read too. A shell's `-c` script is read
  wherever the shell is named (`find -exec sh -c '...'`, `docker exec x bash -c '...'`).
- Text inside single quotes is data: the shell runs no `$(...)` there, so
  `node -e 'f("$(az account get-access-token)")'` names a token command without running it.
  Inside double quotes it runs, and is read.
- Heredoc bodies are skipped unless they are fed to a shell.
- `cd` is followed, and so are the line's own `VAR=value` assignments (`S=/tmp/x; cat $S/a`).
- A word it cannot resolve (`$X`, `$(...)`) is never trusted in a command that writes.
- Code given inline is never local: `python3 -c`, `node -e`, `perl -e`, or a heredoc or stdin
  fed to an interpreter. Neither is git told to run something else (`-c`, `--config-env`,
  `GIT_*=`), or git deleting shared things (`branch -D`, `stash drop|pop|clear`, `tag -d`,
  `worktree remove`).
- **What `local:bash` does allow: running the worktree's own code.** That covers `node x.js`,
  `python3 -m pytest`, `scripts/check.sh` and `./gradlew`. That code can do anything a worker
  could type, so a worker that writes a script and runs it gets past the classes above. The policy
  gates what is visible on the command line; it does not inspect files.
- A grant never covers a command with git's global options before the subcommand (`-C`, `-c`).

It is a policy classifier for routine work, not a sandbox. What it cannot read never becomes an
allow, only a card or no opinion. To change a rule, edit `lib/permit.jq`. `test/permit.bats` has
the table of example calls and their verdicts.

## The record and the audit trail

`$CR_HOME/permits/<task>/` holds:
- `grants.json`;
- one `<p-id>.json` per card, with its `<p-id>.answer.json` (written once) and `<p-id>.late.json`;
- `always.ndjson`;
- `pre/<sig>` one-time pre-approvals.

It sits outside every directory a worker is given.

Every outcome is a `permit:` line in the task's `events.log`:

```
permit: allowed Edit /…/wt/lib/a.sh by policy (local:files)
permit: allowed Bash "git push -u origin cap/x" by the task's grant (push-branch)
permit: asks p-1a2b: Bash "git push origin main" (commander:outward, git-push); waits 15m, then denies. Answer: …
permit: allowed p-1a2b once by commander (via xo): Bash "git push origin main"
permit: denied p-3c4d: no answer within 15m (expired)
permit: auto mode refused Bash "…". Reason: [Unsanctioned Communication]
permit: refused Bash "chartroom permit answer p-1a2b once" (guard:self-answer)
```

`permit:` is a core event kind. `chartroom event <id> permit …` is refused.

## Cost and volume (measured)

- **Each hook call costs about 85 ms** on an M-series Mac (a bare `chartroom version` is 36 ms).
  The policy's jq is 14 ms of that. It runs on every tool call of every Claude worker.
- **Replayed against 45,775 Bash commands from 244 past worker transcripts,** `PreToolUse` gives no
  opinion on 93% of them. The other 6.9% become cards:
  - 1,902 outward: `git push` 931, Azure DevOps API writes and PR updates or creates about 510,
    `gh pr` writes;
  - 440 secrets: cloud access tokens, `.env` reads;
  - 387 elsewhere: other machines, writes outside the worktree;
  - 370 production; 21 controls; 14 flags; 2 money.

  Grants (`push-branch`, `open-pr`, `merge-auto`) and "always" cover most of the outward ones.
- **Replayed as prompts** (`PermissionRequest`, what Claude would ask about), 56% are allowed by
  the `local:*` rules. Most of the rest is inline code (`python3 - <<EOF` file edits) and lines
  outside the worktree. Real prompts are far rarer than calls: about a dozen in one busy home's history.

## Security, and what it is not

The worker runs as the same Unix user as the XO and the app, so this is a set of layers, not a
sandbox:
- **The record is out of the worker's reach.** It is not under `tasks/<id>/` or the worktree. A
  tool call that touches it is denied in `PreToolUse`, before Claude's own flow.
- **`permit answer`, `grant` and `revoke` refuse a worker.** A worker is detected by its
  environment (`CHARTROOM_TASK`), or by an ancestor process started with a task's
  `claude-settings.json` in this home or a registered one. A refusal is logged and raises a
  `[breaking]` decision.
- **A worker cannot loosen its own settings.** Settings are rewritten at every launch and resume.
  Edits to the task's control files are denied, and edits to the worktree's `.claude/` are cards.
- **The audit trail.** Every answer records who gave it (`by`) and how (`via`).
- **The hooks never fail the worker.** Bad input or a crash gives no opinion, and Claude's own
  flow decides as before.
- **The one fail-open path.** A `PreToolUse` hold that dies (a stopped worker) falls through to
  Claude's flow, because a timed-out `PreToolUse` does not block. The hold therefore denies itself
  before its timeout (the settings give `CHARTROOM_PERMIT_WAIT_SECONDS` + 60).

A real boundary, Claude Code's sandbox with the record unreadable from a worker's Bash, is a
planned follow-up.

## What Claude Code does here (verified on 2.1.330)

- **`PermissionRequest` fires for real prompts.** It fires in default and auto mode, interactive
  and `-p`, and its allow or deny settles the call.
- **A hook's `ask` reaches it interactively, but not in `-p`.** Interactively, a `PreToolUse`
  `ask` shows the dialog and `PermissionRequest` runs (and can answer it). In `-p`, the `ask` is
  refused. That is why headless workers hold the card in `PreToolUse` instead.
- **Long holds are honoured.** A 640 s hold under `timeout: 900` was answered and applied.
- **A hook that times out is cancelled**, and the call falls back to Claude's normal flow.
- **Auto mode's classifier refusals cannot be reversed afterwards.** `PermissionDenied` can only
  tell the model it may retry.
- **A `PreToolUse` allow comes before the classifier.** I ran a harmless `mkdir` outside the
  working directory in auto mode, with `--debug-file`, twice:
  - **Without the hook,** the permission decision took 471 ms: the classifier's round trip.
  - **With the hook's `allow`,** the log says "Hook approved tool use for Bash, bypassing
    permission prompt" and the decision took 10 ms. That is too fast for a remote classifier call.

  This does not show that a call the classifier would *refuse* passes. The `denied` hook logs
  `although chartroom allowed it` if a granted call is still refused, so the first real worker
  with a grant shows it. If it shows up, the fallback is a `permissions.allow` rule for the granted
  shapes, or `--permission-mode default` for granted workers.
- **Hooks merge across settings.** The user's own `PreToolUse` hooks run beside a worker's
  `--settings` hooks; both appear in the same debug log.
