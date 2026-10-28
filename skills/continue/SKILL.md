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
   - **Inbox item** (`type: "inbox"`): its `project`, `text` and `date`. That is the question.
   - **Task** (`type: "task"`): `project`, `state`, `title`, `waiting_on`/`waiting_until`; in
     `$CHARTROOM_HOME/tasks/<id>/`: the last `decision`/`blocked`/`failed`/`done` line of
     `events.log`, the outcome section of `report.md` (if any), and PR/MR URLs in either file.
     `plan.md` only if the decision is a plan gate.
   - Either: its open drafts, `chartroom artifact list <id>`. Give each one's ref and title in
     your answer (`chartroom artifact copy <ref>` copies it), and `chartroom artifact done
     <ref>` once the commander says it went out or ran. A `page` is a report to read: offer
     `chartroom artifact open <ref>` (the dashboard's viewer) or `chartroom artifact pdf <ref>`.
3. **Bring the commander to the point**, by state:
   - `decision`, `blocked`, `awaiting-input`, or an inbox item: ask that one question, in plain
     terms, with your agent's question tool (AskUserQuestion in Claude Code, its `header` the
     project name, shortened to 12 characters if needed; otherwise one short message that starts
     with `**[<project>]**`): the worker's recommended option first, marked as recommended,
     then the others. An inbox item without a project: infer it from the question.
     Then carry out the answer exactly as the chartroom skill says: `chartroom steer` it to the
     worker (and append the commander's words to the brief's intent), write approvals into the
     brief, record lasting preferences with `chartroom rule add`, and remove the answered `inbox.md` line.
   - Every other answer below also starts with `**[<project>]**`.
   - `review` (the worker reported `done`; it waits on the commander): Verify (chartroom skill
     step 7) if you have not already, then give the outcome, the risk and the evidence in two or
     three lines, with full PR URLs, and ask how to land it (merge locally / open a PR / leave
     it). It leaves `review` only on the commander's word: `chartroom close <id>` once it has
     landed or they drop it, or `chartroom accept <id>` when they call it done but want it kept.
   - `done`: the commander accepted it; one line on whether it has landed, and offer to close it.
   - `failed`, `stopped-silent`, `waiting-overdue`: one line on what went wrong and what you
     propose; ask only if it needs the commander's call.
   - `working`, `drafting`, `waiting`: one line of status (for `waiting`: on what, until when).
     Ask nothing.
   - `closed`: one line on how it ended.
