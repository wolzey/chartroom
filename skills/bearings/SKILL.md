---
name: bearings
description: Give the commander a short digest of everything the XO's crew is doing (what landed, what needs a decision, what's under way, what failed), then walk open decisions one at a time. Use when the user invokes /bearings or $bearings, or asks "where are we", "status", "sitrep", "what's going on", "catch me up", or "what needs me".
---

# Bearings

A calm, complete picture in under a minute of reading. It is built from durable records,
never from conversation memory. (If `chartroom` is not on PATH, use
`../../bin/chartroom` relative to this skill's directory.)

1. Get the facts:
   ```bash
   chartroom status --json
   ```
   Also read `$CHARTROOM_HOME/inbox.md`: questions waiting on the commander and chat
   approvals not yet in a brief.
   For every task in `done`, `decision`, `blocked`, `failed`, `stopped-silent`,
   `waiting-overdue`, `awaiting-input` or `lost` state, read its `$CHARTROOM_HOME/tasks/<id>/report.md` if one
   exists, and the last few lines of `events.log`. Run `chartroom peek <id>` only when those
   don't explain the state. If the commander says "include PRs", also check PR state for tasks
   that opened one with the project's forge CLI (`gh` for GitHub, `az repos` for Azure DevOps,
   `glab` for GitLab).

2. Write the digest in exactly these four sections, omitting any section that's empty:

   **Needs you**: decisions and blockers only a human can resolve, highest impact first.
   One line each: the project, the question, and the recommendation. Include every open item
   under "Waiting on the commander" in `inbox.md`.

   **Ready**: finished work waiting for the commander's word (review, merge, or PR). One line
   each: the outcome, the risk, the evidence ("tests pass", "3 files"), and the full PR URL if there is one.

   **Under way**: one line per project, saying what is being worked on. No progress chatter.
   A `waiting` task is under way: say what it waits on and until when (`waiting_on`,
   `waiting_until`).

   **Trouble**: failures, lost workers, silent stops, and overdue waits (`waiting-overdue`),
   with what you're doing about each.

   Use plain language: outcomes, not machinery. No task ids, paths, branch names, backend
   names, or status words unless the commander needs one to act. If nothing is open, say so in
   one line.

3. If **Needs you** is non-empty, walk the decisions one at a time, starting with the
   highest-impact one. Ask the question, wait for the answer, and carry it out through the
   chartroom skill's rules (`chartroom steer` to relay it, and record lasting preferences in
   `commander.md`). Then move to the next one.

If the commander asks for a file version (`bearings file`), also write the digest to
`$CHARTROOM_HOME/bearings-<YYYY-MM-DD>.md`, replacing today's, and link it.
