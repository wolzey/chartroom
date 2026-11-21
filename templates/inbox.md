# Inbox

The XO keeps this current. It holds what would otherwise live only in chat: questions waiting on the commander, and approvals given in chat that are not yet written into a task brief. `bearings` reads it. Remove an item once it is answered or recorded in a brief. Add waiting items with `chartroom inbox add --project <project> "<question>"`: each line reads `- [i-xxxx] <date> — [<project>] <question>`, and the stable `[i-xxxx]` id is what the dashboard shows and `/continue <id>` takes. A draft the commander must send or run hangs off its item: `chartroom artifact add <i-xxxx> --kind message --title "<title>" <file>`. Write each question as one plain sentence you would say to the commander (what you need and why it matters), with no task ids or paths: it is a card in their app.

## Waiting on the commander
- (none)

## Approvals given in chat, not yet in a brief
- (none)

## Notes
- (none)
