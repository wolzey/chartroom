---
name: bearings
description: Give the captain a short digest of everything the first mate's crew is doing (what landed, what needs a decision, what's under way, what failed), then walk open decisions one at a time. Use when the user invokes /bearings, or asks "where are we", "status", "what's going on", "catch me up", or "what needs me".
---

# Bearings

A calm, complete picture in under a minute of reading. It is built from durable records,
never from conversation memory.

1. Get the facts:
   ```bash
   ~/.agents/skills/captain/bin/chartroom status --json
   ```
   For every task in `done`, `decision`, `blocked`, `failed`, `stopped-silent`, or `lost`
   state, read its `~/.chartroom/tasks/<id>/report.md` if one exists, and the last few lines
   of `events.log`. Run `chartroom peek <id>` only when those don't explain the state. If the
   captain says "include PRs", also check PR state for tasks that opened one (`gh` for GitHub, `az repos` for Azure DevOps).

2. Write the digest in exactly these four sections, omitting any section that's empty:

   **Needs you**: decisions and blockers only a human can resolve, highest impact first.
   One line each: the project, the question, and the recommendation.

   **Ready**: finished work waiting for the captain's word (review, merge, or PR). One line
   each: the outcome, the risk, the evidence ("tests pass", "3 files"), and the full PR URL if there is one.

   **Under way**: one line per project, saying what is being worked on. No progress chatter.

   **Trouble**: failures, lost workers, and silent stops, with what you're doing about each.

   Use plain language: outcomes, not machinery. No task ids, paths, branch names, backend
   names, or status words unless the captain needs one to act. If nothing is open, say so in
   one line.

3. If **Needs you** is non-empty, walk the decisions one at a time, starting with the
   highest-impact one. Ask the question, wait for the answer, and carry it out through the
   captain skill's rules (`chartroom steer` to relay it, and record lasting preferences in
   `~/.chartroom/captain.md`). Then move to the next one.

If the captain asks for a file version (`/bearings file`), also write the digest to
`~/.chartroom/bearings-<YYYY-MM-DD>.md`, replacing today's, and link it.
