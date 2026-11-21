# app_fixture.bash - two invented homes for the app's tests and screenshots: acme (a web shop) and
# globex (an API), each with tasks in every state Needs me shows, a posted grilling round, a
# one-question card and inbox items. Invented data only.
#
#   app_fixture <dir> <project-repo>   creates <dir>/acme and <dir>/globex, registers both in the
#                                      homes file of $CHARTROOM_CONFIG, prints nothing
# Needs: $CHARTROOM (bin/chartroom). Tasks are marked dispatched in their records rather than run,
# so no worker process is started; their states come from their events alone.

app_fixture_task() { # <home> <project> <title> <intent> -> prints the id
  local out id
  out="$(CHARTROOM_HOME="$1" "$CHARTROOM" new --project "$2" --title "$3" --backend command --command true)"
  id="$(sed -n 's/^id=//p' <<<"$out")"
  perl -0pi -e "s/(## Commander's intent\n\n)/\$1$4\n/" "$1/tasks/$id/brief.md"
  CHARTROOM_HOME="$1" set_meta "$id" ".dispatched = \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\" | .worktree_created = \"1\""
  printf '%s' "$id"
}

app_fixture_event() { CHARTROOM_HOME="$1" "$CHARTROOM" event "${@:2}" >/dev/null; }

app_fixture() { # <dir> <project-repo>
  local d="$1" proj="$2" a g id
  a="$d/acme"; g="$d/globex"
  CHARTROOM_HOME="$a" "$CHARTROOM" init >/dev/null
  CHARTROOM_HOME="$g" "$CHARTROOM" init >/dev/null
  CHARTROOM_HOME="$a" "$CHARTROOM" homes add acme "$a" >/dev/null
  CHARTROOM_HOME="$g" "$CHARTROOM" homes add globex "$g" >/dev/null

  id="$(app_fixture_task "$a" "$proj" "Pick a cache for the search page" "Search feels slow on big catalogues; make it fast.")"
  app_fixture_event "$a" "$id" progress "measured: p95 is 1.8s on the 40k-item catalogue"
  app_fixture_event "$a" "$id" decision --detail "Options: (1) RECOMMENDED: an in-process LRU: no new service, 90% hit rate in the replay. (2) Redis: shared across instances, one more thing to run. Need: your pick." "Which cache for search?"
  id="$(app_fixture_task "$a" "$proj" "Checkout: one-page address form" "The address step loses people; one page, please.")"
  app_fixture_event "$a" "$id" decision "plan ready for approval: three steps, behind a flag"
  printf '# Plan\n\n1. Merge the two address steps.\n2. Keep the old form behind `checkout_v1`.\n3. Measure drop-off for a week.\n' >"$a/tasks/$id/plan.md"
  id="$(app_fixture_task "$a" "$proj" "Gift cards: refund to the card" "Refunds of gift-card orders should go back to the card.")"
  app_fixture_event "$a" "$id" blocked "the payments sandbox key expired. Need: a fresh sandbox key in the vault, then say go"
  id="$(app_fixture_task "$a" "$proj" "Fix the stock badge on product pages" "The badge says in stock when it is not.")"
  app_fixture_event "$a" "$id" "done" "the badge reads the live count now; PR https://github.com/acme/shop/pull/412"
  printf '# Report\n\nThe badge reads the live stock count.\n' >"$a/tasks/$id/report.md"
  id="$(app_fixture_task "$a" "$proj" "Nightly sitemap" "Search engines should see new products the next day.")"
  app_fixture_event "$a" "$id" waiting "on the CDN purge window. Details: until 02:00 UTC"
  CHARTROOM_HOME="$a" "$CHARTROOM" inbox add --project shop "Should the summer sale start on Monday or Wednesday?" >/dev/null
  CHARTROOM_HOME="$a" "$CHARTROOM" inbox add --project shop "Q12: merge https://github.com/acme/shop/pull/418 before the sale, or after it?" >/dev/null
  # a worker asking two things at once: a grilling round, answered in the main area
  id="$(app_fixture_task "$a" "$proj" "Search index: shape before building" "Decide the index's shape before any code.")"
  app_fixture_event "$a" "$id" decision "Two calls before I build. Options: (1) RECOMMENDED: one index per store. (2) one shared index. Storage: (1) Postgres full-text. (2) RECOMMENDED: a SQLite sidecar. Need: both answers."

  id="$(app_fixture_task "$g" "$proj" "Rate limits for the public API" "Partners hit us too hard at month end; protect the API.")"
  app_fixture_event "$g" "$id" decision --detail "Options: (A) per key, 100 requests a minute. (B) RECOMMENDED: per partner: one bucket for all their keys. Need: which." "How should we count requests?"
  # shaped like a real ask that once read badly: a label recommends option 1, option 2 says "Not
  # recommended" in its text, and the flag went into the headline ("... --detail ...")
  id="$(app_fixture_task "$g" "$proj" "Turn deploy-on-merge back on for demo day" "Demo day needs main to ship on merge again.")"
  app_fixture_event "$g" "$id" decision "The switch PR is green except the slow suite, which waits for auto-merge by design; merging needs you --detail PR: restore deploys on merge. Checks: 13 pass, 0 fail. Decision for you, because finishing the slow suite also merges the PR: (1) Recommended: you turn on auto-merge. That runs the slow suite and merges when it passes. (2) An admin bypass of the slow suite. Not recommended; it needs your explicit say-so."
  id="$(app_fixture_task "$g" "$proj" "Retire the v1 webhooks" "Nobody should still be on v1 by spring.")"
  app_fixture_event "$g" "$id" failed "the migration script hit a partner with 3 endpoints; stopped before any change"
  printf '%s' '{"title":"Search: what good looks like","kind":"grill","context":"Shaping the search initiative before stories.","round":{"n":1,"of":3},
    "questions":[{"text":"Who is search for first?","options":[{"label":"Shoppers","detail":"the storefront box"},{"label":"Staff","detail":"the admin catalogue"}],"recommended":0,"why":"Most of the slow queries come from the storefront."},
                 {"text":"What counts as fast?","options":["p95 under 300ms","p95 under 800ms"],"recommended":"p95 under 300ms"},
                 {"text":"Anything out of scope?"}]}' |
    CHARTROOM_HOME="$a" "$CHARTROOM" ask - >/dev/null
  # an initiative, shaped, with a plan, a milestone, a story linked to a task and two proposed
  local in ms s1
  in="$(CHARTROOM_HOME="$a" "$CHARTROOM" initiative new --name "Fast search" --intent "Search answers in under 300ms for every store.")"
  ms="$(CHARTROOM_HOME="$a" "$CHARTROOM" initiative milestone add "$in" --name "Index")"
  s1="$(CHARTROOM_HOME="$a" "$CHARTROOM" initiative story add "$in" --title "Pick a cache" --project proj --milestone "$ms")"
  CHARTROOM_HOME="$a" "$CHARTROOM" initiative story link "$in" "$s1" "$(CHARTROOM_HOME="$a" "$CHARTROOM" status --json | jq -r '.[] | select(.title | test("Pick a cache")) | .id')" >/dev/null
  CHARTROOM_HOME="$a" "$CHARTROOM" initiative story add "$in" --title "Build the index" --project proj --milestone "$ms" >/dev/null
  CHARTROOM_HOME="$a" "$CHARTROOM" initiative story add "$in" --title "Switch the search box" --project proj >/dev/null
  printf '## Intent\n\nSearch answers in under 300ms.\n\n## Goal and criteria\n\n- p95 under 300ms on the 40k catalogue\n\n## Risks\n\n- The index build may be slow on big stores.\n' >"$a/initiatives/$in/plan.md"
  # it was shaped in a meeting: its shaping round is withdrawn, and the XO has read the setup's words
  CHARTROOM_HOME="$a" "$CHARTROOM" ask withdraw "$(jq -r .card "$a/initiatives/$in/initiative.json")" "shaped in a meeting" >/dev/null
  local told; told="$(CHARTROOM_HOME="$a" "$CHARTROOM" tell list --json | jq -r '.[].id')"
  if [[ -n "$told" ]]; then
    # shellcheck disable=SC2086 # one id per word
    CHARTROOM_HOME="$a" "$CHARTROOM" tell ack $told >/dev/null
  fi
  CHARTROOM_HOME="$g" "$CHARTROOM" ask --title "Ship the SDK as 2.0 or 1.9?" --option "2.0: the auth change breaks callers" --option "1.9 with a shim" --recommend 1 --project api >/dev/null
}
