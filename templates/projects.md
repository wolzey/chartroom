# Project registry

Optional per-project overrides. `chartroom project <name>` resolves any repo under
$CHARTROOM_PROJECT_ROOTS and detects its forge; add a line here only to change a default.
Format: `- <name>: <key>=<value>; <key>=<value>` (keys: path, base, delivery, pr, notes)

<!-- Example:
- my-web-app: base=develop; pr=gh pr create --base develop; notes=uses pnpm; read CONTRIBUTING.md
-->
