---
name: continue
description: Jump the commander straight to one crew item by its short id from the dashboard (a task like 21ba, or an inbox item like i-7f3a) and bring them to the point - ask the pending decision, report the outcome, or give a one-line status. Use when the user invokes /continue <id> or $continue <id>, or says "continue <id>" / "pick up <id>". Runs in the XO session.
---

# Continue

You are the XO (the chartroom skill's rules apply). The commander gave an id; take them
straight to what it needs from them. No digest, no re-deriving, no essays. (If `chartroom` is
not on PATH, use `../../bin/chartroom` relative to this skill's directory.)

1. **Resolve.** `chartroom resolve <id> --json`. On an error (unknown or ambiguous), say it in
   one line, listing the candidates it named, and stop.
2. **Gather** only this:
   - **Inbox item** (`type: "inbox"`): its `text` and `date`. That is the question.
   - **Task** (`type: "task"`): `state`, `title`, `waiting_on`/`waiting_until`; in
     `$CHARTROOM_HOME/tasks/<id>/`: the last `decision`/`blocked`/`failed`/`done` line of
     `events.log`, the outcome section of `report.md` (if any), and PR/MR URLs in either file.
     `plan.md` only if the decision is a plan gate.
3. **Bring the commander to the point**, by state:
   - `decision`, `blocked`, `awaiting-input`, or an inbox item: ask that one question, in plain
     terms, with your agent's question tool (AskUserQuestion in Claude Code; otherwise one short
     message): the worker's recommended option first, marked as recommended, then the others.
     Then carry out the answer exactly as the chartroom skill says: `chartroom steer` it to the
     worker (and append the commander's words to the brief's intent), write approvals into the
     brief, record lasting preferences in `commander.md`, and remove the answered `inbox.md` line.
   - `done`: Verify (chartroom skill step 7) if you have not already, then give the outcome,
     the risk and the evidence in two or three lines, with full PR URLs, and ask how to land it
     (merge locally / open a PR / leave it).
   - `failed`, `stopped-silent`, `waiting-overdue`: one line on what went wrong and what you
     propose; ask only if it needs the commander's call.
   - `working`, `drafting`, `waiting`: one line of status (for `waiting`: on what, until when).
     Ask nothing.
   - `closed`: one line on how it ended.
