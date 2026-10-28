---
name: sweep
description: Free what the XO's crew left running (sessions of finished tasks, done tasks safe to close, orphaned chartroom loops, dev servers and daemons in closed worktrees) with one `chartroom sweep --apply`, relay one line, and ask the commander only about what needs a human. Use at session start after status, when the fleet goes quiet, when the commander says the machine is hot or slow, or when the user invokes /sweep or $sweep.
---

# Sweep

Housekeeping for the machine the crew runs on. `chartroom sweep` does all the detection,
classification and acting in code, and prints a few lines. Don't read `ps` output, peek at
processes or investigate further yourself: the command is the whole job. (If `chartroom` is
not on PATH, use `../../bin/chartroom` relative to this skill's directory.)

**When:** at session start, right after `chartroom status` is reconciled; whenever the fleet
goes quiet; and whenever the commander says the machine is hot, slow or loud.

1. Run `chartroom sweep --apply`, without asking. It acts only on the safe set: it closes done
   tasks (ones the commander accepted; never one still in `review`) whose worktree is clean
   with nothing unlanded (through `chartroom close`), stops
   sessions of closed tasks, and kills orphaned chartroom loops and dev processes left in
   closed or missing worktrees. It never touches in-flight work, never discards anything, and
   logs every act to `sweep.log` in the home and to the task's events.
2. Its first line is the summary. Relay it in one plain sentence ("Freed 4 idle sessions and 2
   stray dev servers, about 1.1 GB."), or say nothing when it freed nothing and nothing needs
   a human.
3. Each line after it is an item that needs a human, with the reason. Ask the commander about
   those only, one at a time, project first (`**[project]**`, as the chartroom skill says),
   with a recommendation. Carry out the answer with the usual commands: `chartroom close <id>`
   once the work has landed or they say to drop it, `chartroom steer`, and never
   `close --discard` without their explicit word for that task.

Use `--verbose` (the safe set item by item) or `--json` only when the commander asks for detail.

Never add a daemon for this. A harness that can schedule may run `chartroom sweep --apply`
periodically (Claude Code: `/loop 2h chartroom sweep --apply`; or cron); a sweep with nothing to
do changes nothing.
