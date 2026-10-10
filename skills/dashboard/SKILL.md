---
name: dashboard
description: Open the chartroom dashboard (the local, read-only web view of the crew) in the browser, starting it first if it is not running. Use when the user invokes /dashboard or $dashboard, or asks to "open the dashboard", "show me the board", or "where's the dashboard".
---

# Dashboard

Run exactly this, once (if `chartroom` is not on PATH, use `../../bin/chartroom` relative to
this skill's directory):

```bash
chartroom dashboard open
```

It reuses the dashboard already running for this home, or starts one in the background, then
opens it in the default browser. Reply with one line: the URL it printed. If it printed
"open it yourself", say the browser could not be opened and give the URL. If it failed, give
its error in one line; do not retry, stop, or restart anything on your own.

Only when the commander asks to see the board from another device: tell them to run
`chartroom dashboard stop` and then `chartroom dashboard open --expose` (or `--host <address>`),
which puts it on the network behind an access token and prints the URLs to open there. Never
expose it on your own.
