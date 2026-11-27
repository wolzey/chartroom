---
name: dashboard
description: Open the chartroom app (the web view of every home - Needs me, the board, a task's ticket, Fleet, Usage; it replaces the retired web dashboard) in the browser. Use when the user invokes /dashboard or $dashboard, or asks to "open the dashboard", "open the app", "show me the board", or "where's the dashboard".
---

# Dashboard

The old web dashboard is retired; the chartroom app replaces it, and `chartroom dashboard open`
opens the app. Run exactly this, once (if `chartroom` is not on PATH, use `../../bin/chartroom`
relative to this skill's directory):

```bash
chartroom dashboard open
```

It opens the app in the default browser, starting its server if none runs. Reply with one line,
by what it printed:

- `app open: <url>`: the browser opened; give the URL.
- `app running: <url>`, or (in a client home) `app: <url> (… open it yourself)`: the browser
  could not be opened; say so and give the URL.
- An error: give its own words in one line (it says why, such as the app not running or Tailscale
  Serve not pointed at it; `chartroom app doctor` says what it needs). Do not retry, stop, restart
  or set anything up on your own.

In a client home (one brain) it asks the brain for its app's tailnet address and opens that here;
this machine must be on the tailnet. If the brain answered with its own loopback address, the
error names the causes (an older chartroom there, or its app without Tailscale Serve): relay it
as written.

Where to point the commander, in the app: **Needs me** for what waits on them, a task's ticket
for one task (its question, PRs, plan, report, pages and drafts, the worker's terminal),
**Fleet** for every machine and session, and **Usage** (Fleet → Usage, or `#/usage`) for what each
subscription has left. For every agent in the terminal, `chartroom radar`; for the lanes in the
terminal, `chartroom board`.
