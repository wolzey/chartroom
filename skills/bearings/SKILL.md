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
   chartroom focus --json
   chartroom status --json
   ```
   **Focus mode.** When `focus --json` says `on: true`, the digest is about the focused
   projects only: lead it with the focus line, exactly as `chartroom focus` prints it
   (`🎯 focus: webapp · 7 held (since 2h)`). Leave out every task row whose `in_focus` is false,
   every inbox item in its `items` list (the held items; `--breaking` ones are never there),
   and their artifacts. Don't list or walk the held items: the count stands for them. When it says `on:
   false` with `ran_out` set, open with one line: the focus on those projects ran out at
   `until`, and everything is back in view.
   Also read `$CHARTROOM_HOME/inbox.md`: questions waiting on the commander and chat
   approvals not yet in a brief, `chartroom artifact list --json`: drafts still to send
   or run, and `chartroom relay list --json`: relays from other homes' XOs not yet acked. A
   relay is the XO's to weigh: it goes in the digest only when it needs the commander, under
   **Needs you**, led with its home (`**[from <home> · <project>]**`). Run `chartroom sweep` (a dry run, a few lines): its
   "needs a human" lines go under **Needs you**, and its summary line under **Trouble** only
   if it found much to free (then offer `--apply`).
   **Across homes.** When the commander asks about every home ("everything", "every
   company"), or this home's preferences say it oversees the others, read them all instead:
   `chartroom status --all-homes --json` and `chartroom inbox list --all-homes --json` (one
   `{home, path, result}` per home; each `result.relays` is that home's open relays), and
   `chartroom todo --all-homes` for each home's open artifacts. A task's records are under its home's `path`. Lead every line with its home,
   `**[<home> · <project>]**`, and give each home's focus line if it has one. In step 3, walk
   only this home's decisions; for another home's, say which home's XO to answer it in.
   For every task in `done`, `decision`, `blocked`, `failed`, `stopped-silent`,
   `waiting-overdue`, `awaiting-input` or `lost` state, read its `$CHARTROOM_HOME/tasks/<id>/report.md` if one
   exists, and the last few lines of `events.log`. Run `chartroom peek <id>` only when those
   don't explain the state. If the commander says "include PRs", also check PR state for tasks
   that opened one with the project's forge CLI (`gh` for GitHub, `az repos` for Azure DevOps,
   `glab` for GitLab).

2. Write the digest in exactly these four sections, omitting any section that's empty:

   **Needs you**: decisions and blockers only a human can resolve, highest impact first.
   One line each, project first: `**[<project>]** <question> (recommend: <option>)`. Use
   `**[multi]**` for a question that spans projects, `**[chartroom]**` for one about the crew
   itself. Include every open item under "Waiting on the commander" in `inbox.md`, with the
   `[project]` its line carries (an unlabelled line: infer it from the question, else say so).
   Every open `message` or `runbook` artifact is a line too, with its ref (the commander copies
   it with `chartroom artifact copy <ref>`): `**[<project>]** send: <title> (<ref>)`, or
   `run: <title> (<ref>)`. Put it on the line of the inbox item it belongs to, if any.

   **Ready**: finished work waiting for the commander's word (review, merge, or PR). One line
   each: the outcome, the risk, the evidence ("tests pass", "3 files"), and the full PR URL if there is one.
   A task with an open `page` artifact (a report to read) names its ref too: `read: <ref>`
   (`chartroom artifact open <ref>` shows it).

   **Under way**: one line per project, saying what is being worked on. No progress chatter.
   A `waiting` task is under way: say what it waits on and until when (`waiting_on`,
   `waiting_until`).

   **Trouble**: failures, lost workers, silent stops, and overdue waits (`waiting-overdue`),
   with what you're doing about each.

   Use plain language: outcomes, not machinery. No task ids, paths, branch names, backend
   names, or status words unless the commander needs one to act. If nothing is open, say so in
   one line.

3. If **Needs you** is non-empty, walk the decisions one at a time, starting with the
   highest-impact one. Right after the commander comes out of focus (`chartroom focus off`
   listed what was held), walk those held items first. Ask the question, led by its project as in the digest (with a question
   tool, its header is the project name), wait for the answer, and carry it out through the
   chartroom skill's rules (`chartroom steer` to relay it, and record lasting preferences with
   `chartroom rule add`). Then move to the next one.

If the commander asks for a file version (`bearings file`), also write the digest to
`$CHARTROOM_HOME/bearings-<YYYY-MM-DD>.md`, replacing today's, and link it.
