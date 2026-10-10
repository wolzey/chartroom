---
name: join
description: Join this running agent session to a chartroom crew, so the commander's XO supervises it like a worker it launched - the session registers itself, writes its own brief, and listens for the XO's messages. Use when the user says "join chartroom", "join the chartroom", "join the crew", or invokes /join or $join, optionally with a chartroom home path or name.
hooks:
  Stop:
    - hooks:
        - type: command
          command: 'p="$(cat)"; f="${XDG_STATE_HOME:-$HOME/.local/state}/chartroom/sessions/$(printf %s "$p" | sed -n "s/.*\"session_id\"[[:space:]]*:[[:space:]]*\"\([A-Za-z0-9_-]*\)\".*/\1/p" | head -n 1)"; [ -f "$f" ] && printf %s "$p" | "$(cut -f3 "$f")" hook --session stop >/dev/null 2>&1; exit 0'
  Notification:
    - hooks:
        - type: command
          command: 'p="$(cat)"; f="${XDG_STATE_HOME:-$HOME/.local/state}/chartroom/sessions/$(printf %s "$p" | sed -n "s/.*\"session_id\"[[:space:]]*:[[:space:]]*\"\([A-Za-z0-9_-]*\)\".*/\1/p" | head -n 1)"; [ -f "$f" ] && printf %s "$p" | "$(cut -f3 "$f")" hook --session notification >/dev/null 2>&1; exit 0'
  UserPromptSubmit:
    - hooks:
        - type: command
          command: 'p="$(cat)"; f="${XDG_STATE_HOME:-$HOME/.local/state}/chartroom/sessions/$(printf %s "$p" | sed -n "s/.*\"session_id\"[[:space:]]*:[[:space:]]*\"\([A-Za-z0-9_-]*\)\".*/\1/p" | head -n 1)"; [ -f "$f" ] && printf %s "$p" | "$(cut -f3 "$f")" hook --session prompt-submit >/dev/null 2>&1; exit 0'
---

# Join chartroom

You are an agent session the commander started themselves. They want the XO (the agent
running their chartroom) to supervise this work from now on. You join from here; the XO does
not need to reach into your terminal. From now on your reports go to the XO, and the
commander may still talk to you directly in this session.

**Helper.** Use the chartroom that ships with this skill, so the two always match: resolve
this skill's directory through symlinks and go two levels up,
`CR="$(cd -P "<this skill's directory>" && cd ../.. && pwd)/bin/chartroom"`. Only if that file
does not exist, use `chartroom` from PATH. Call it `$CR` below.

**Home.** If the user named a home: a path is used as is; a bare name `x` means `~/.x` (or
`~/x` if only that exists). Otherwise use `$CHARTROOM_HOME` if set, else `~/.chartroom`.
Prefix every `$CR` command with `CHARTROOM_HOME=<home>` when it is not the default. If the
home does not exist, say so in one line and stop.

1. **Register.** From your working directory (the one this session works in), run
   `CHARTROOM_HOME=<home> $CR join --title "<short title of what you are doing>"`
   (add `--kind scout` if this session is investigating, not changing code). It prints the
   task `id`, the `brief` path and the steps below. Running it again in this session is safe:
   it returns the same task.
2. **Write the brief.** Fill the brief's two placeholder sections, replacing the comments:
   - *Commander's intent*: what the user asked this session for, in their words where you
     have them (quote them), as best you know.
   - *Spec*: where the work stands (done, in progress, next), what done looks like, the
     constraints the user gave, and open questions.
   Leave the Authority and Worker protocol sections as written; they now bind you.
3. **Listen.** Start the listener the join output printed (`... listen <id>`):
   - Claude Code: as a **background** Bash command (`run_in_background: true`). It blocks
     until the XO sends a message, prints it, and exits; Claude Code then wakes this session
     even if it is idle. Read the message, act on it under the protocol, report with an event,
     and **start the listener again**. Keep exactly one running; re-arm after every exit,
     including an error or timeout.
   - Agents without background commands (Codex and others): run it with `--check` between
     steps and before ending each turn. Tell the user that messages from the XO reach you only
     then.
4. **Report and carry on.** Send one `progress` event saying you joined and where things
   stand, then continue the work under the brief's worker protocol: events (`progress`,
   `waiting`, `decision`, `blocked`, `done`, `failed`), `report.md` before `done`/`failed`,
   stop at decisions, never push or open a PR without a decision.
5. Tell the user in one or two lines: the task id, that the XO now supervises this session,
   and how messages reach you (woken in the background, or between steps).
