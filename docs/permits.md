# Permission cards: a worker's prompts come to chartroom

A Claude worker that needs a permission no longer waits at a prompt only its terminal can answer.
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

### Answering a card

```
chartroom permit ls                      # open cards (--all: answered, expired, lapsed)
chartroom permit show p-1a2b             # one card as JSON
chartroom permit answer p-1a2b once      # allow this call
chartroom permit answer p-1a2b always    # allow this pattern until the task closes
chartroom permit answer p-1a2b deny --note "use the staging project instead"
```

- **The first answer wins.** A second answer is refused and names the first.
- **The wait.** The hook waits up to `CHARTROOM_PERMIT_WAIT_SECONDS` (900), then denies. The
  worker is told to post a `decision` naming what it needed. Nothing hangs, and nothing runs
  unapproved.
- **A late answer.** An allow given after the wait ran out becomes a one-time pre-approval of
  that exact call, and the worker is steered to run it again.
- **Retry cards.** A card raised by `PermissionDenied` works the same way, because the worker has
  already moved on.
- **"Always for this task"** stores the pattern shown on the card. For Bash that is Claude's own
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
with `permit grant`:

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

A grant only covers an outward-facing match. A command that also touches production, secrets,
the feature-flag service, money or another machine is still a card.

## The policy: `lib/permit.jq`

All the rules live in one file. **First match wins:**

1. **`guard:*` → deny.**
   - `guard:store`: the permit store (`$CR_HOME/permits`).
   - `guard:self-answer`: `permit answer|grant|revoke`.
   - `guard:controls`: the task's `meta.json`, `claude-settings.json` or `launch.sh`.
2. **Questions** (`AskUserQuestion`, `ExitPlanMode`) get no opinion. They are not permissions.
3. **`preapproved:<p-id>` → allow**, once.
4. **`always:<p-id>` → allow.**
5. **`commander:*` → card**, unless a grant covers every match (then `grant:<name>` → allow):
   - **production:** `prod`/`production` in an infra command; `kubectl`/`helm`/`terraform`/
     `pulumi` changes; `gcloud`/`az`/`aws`/`gsutil` mutations; a database client on a remote host.
   - **secrets:** `.env*` (not `.env.example`); `~/.ssh`, cloud credentials, `.netrc`, `.npmrc`,
     keychains; `op`, `vault`, `security`, `gh auth token`, `gh secret`; printing the
     environment.
   - **flags:** the feature-flag service (`ldcli`, its API and MCP tools).
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
   - reads anywhere, since secrets were carded already;
   - writes, tests, installs, local git, a dev server on localhost and scratch files inside the
     worktree, the task dir, the scratchpad and `/tmp`.
7. **Otherwise:** a card for a prompt (`commander:unlisted`). For `PreToolUse`, no opinion:
   Claude's own flow decides.

**How Bash is read.**
- The command is split into commands at `; & | ( ) { }`, backticks and newlines, respecting
  quotes.
- `$(...)`, `` `...` ``, `sh -c '...'` and `eval` are read too.
- Heredoc bodies are skipped unless they are fed to a shell.
- `cd` is followed.
- A path containing `$` is never trusted.

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
