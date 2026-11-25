# shellcheck shell=bash
# env.sh - the fleet's env files (docs/multi-machine.md, "Env files"): the gitignored .env files a
# project needs to run, given to the clones chartroom makes on other machines (lib/guest.sh).
# Development values only.
#
#   chartroom env scan [<repo>] [--json]      which machine has which repo's env files: names, modes,
#                                             dates and the names of their keys. Never a value.
#   chartroom env owner <repo> <device>|here|never [--drop KEY,...] [--keep KEY,...]
#                                             whose copy of a repo's files is the one, on the commander's word
#   chartroom env collect <repo>...|--all     takes the owners' files into the store
#   chartroom env ls [--json]                 the store: each repo's owner and files, and which nodes have them
#   chartroom env refresh [<repo>...]         takes what changed at its owner, and gives it to the nodes that have it
#   chartroom env forget <repo>|--node <device>    deletes a repo everywhere, or a node's copies
#   chartroom device share-env on|off         on the machine itself (a terminal there, or ssh): may its env
#                                             files be listed and taken? Off at first; the brain cannot turn it on
#
# The store is on the brain (fleet/env/<repo>/), every file encrypted to the store's own key, which is in the
# brain's login keychain. Each repo has one owner machine, and only its copy is ever taken: two machines that
# differ are shown, never merged. A file leaves its machine encrypted (CMS) to the store's key, and the
# brain for a node encrypted to that node's, so no queue, result, log or command line holds a value.
#
# And a repo's package-registry login (the commander's ruling: part of the environment the fleet shares), as one more
# file named `npm-login`: of the owner's npm user config (NPM_CONFIG_USERCONFIG, else ~/.npmrc), only the
# lines of the registries the repo's own tracked .npmrc files name (`@scope:registry=https://host/`), and
# only their auth (`//host/:_authToken=...` and the like). On a node it is a 0600 file of chartroom's own
# inside the clone's .git (`.git/chartroom/npmrc`), given to its setup as NPM_CONFIG_USERCONFIG; the
# node's own ~/.npmrc is never read or written.
#
# What counts as an env file: `.env` and `.env.*` in the main checkout (three levels deep), gitignored,
# regular, up to 32 KB; never an example, nor one whose name says production, staging or preview.
# What is left out of it, line by line, on its own machine before it goes: a key or value that says
# production or live, and a database or queue address that is not on the machine itself, unless the commander keeps
# that key by name (--keep); and any key they drop (--drop). A file they cannot be read out of is not taken.
#
# A node gets a repo's files with its next worker of it (before the setup) and on refresh: into a clone
# chartroom made and nowhere else, 0600, only where git ignores the path, never over a file it did not
# write. It keeps a list of what it wrote, deletes it all when told, or when the brain answers it
# with 401 (revoked). Every copy is a line of fleet/env/log.ndjson: what, from, to, when; never a value.
# A worker may run none of this.

CR_ENV_MAX=32768
CR_ENV_KEYCHAIN_SERVICE=chartroom-env
CR_ENV_REL_RE='^([A-Za-z0-9_@+][A-Za-z0-9._@+-]*/){0,3}\.env(\.[A-Za-z0-9_-]+)*$'
CR_ENV_KEY_RE='^[A-Za-z_][A-Za-z0-9_]{0,100}$'

env_dir() { printf '%s/env' "$(fleet_dir)"; }
env_repo_dir() { printf '%s/%s' "$(env_dir)" "${1//\//+}"; } # <remote> (a canonical remote holds no +)
env_log() { # <act> <repo> <files json> <from> <to>
  mkdir -p "$(env_dir)"; ( umask 077; jq -cn --arg at "$(now)" --arg a "$1" --arg r "$2" --argjson f "$3" --arg from "$4" --arg to "$5" \
    '{at: $at, act: $a, repo: $r, files: $f, from: $from, to: $to}' >>"$(env_dir)/log.ndjson" )
}
env_refuse_worker() { ! permit_from_worker || die "a worker may not use chartroom env: it moves secrets, which only the commander does (through the XO or a terminal)"; }
env_remote() { # <repo as a person names it> -> its canonical remote
  local r="$1"; [[ "$r" == */*/* || "$r" == *:* ]] || r="github.com/$r"
  r="$(node_canon_remote "$r")"
  [[ "$r" =~ $CR_NODE_REMOTE_RE && "$r" != *+* && "$r" != *..* ]] || die "env: '$1' is not a repository (owner/repo)"
  printf '%s' "$r"
}

# ---------------------------------------------------------------- on any machine: its own env files

env_share_on() { [[ "$(cfg_value_in "$(node_config_path)" CHARTROOM_NODE_SHARE_ENV)" == on ]]; }

cmd_device_share_env() { # on|off, at the machine itself
  local f v tmp; f="$(node_config_path)"; v="${1:-}"
  [[ "$v" =~ ^(on|off)$ && $# -eq 1 ]] || die "usage: chartroom device share-env on|off (may this machine's env files be listed and taken for the fleet?)"
  env_refuse_worker
  [[ -f "$f" ]] || die "device share-env: this machine is not a node yet (chartroom node init)"
  tmp="$f.tmp.$$"
  awk -v v="$v" '/^[[:space:]]*CHARTROOM_NODE_SHARE_ENV[[:space:]]*=/ { if (!d) print "CHARTROOM_NODE_SHARE_ENV=" v; d = 1; next } { print } END { if (!d) print "CHARTROOM_NODE_SHARE_ENV=" v }' "$f" >"$tmp" && mv "$tmp" "$f"
  if [[ "$v" == on ]]; then echo "this machine's env files can be listed, and taken for repos it owns (chartroom env, on the brain)"; else echo "this machine's env files are not shared"; fi
}

CR_ENV_NPM=npm-login
env_rel_ok() { [[ "$1" == "$CR_ENV_NPM" || ( "$1" =~ $CR_ENV_REL_RE && "$1" != *..* ) ]]; } # <rel>
env_npm_file() { printf '%s/.git/chartroom/npmrc' "$1"; } # <clone>: where a node keeps a repo's registry login
env_path_in() { if [[ "$2" == "$CR_ENV_NPM" ]]; then env_npm_file "$1"; else printf '%s/%s' "$1" "$2"; fi; } # <checkout> <rel>

# The registries (hosts) a repo's tracked .npmrc files name, other than npm's own, one a line.
env_registries_of() { # <checkout>
  local d="$1" f
  git -C "$d" ls-files -- '.npmrc' '*/.npmrc' 2>/dev/null | head -50 | while IFS= read -r f; do
    sed -nE 's#^[[:space:]]*(@[A-Za-z0-9._-]+:)?registry[[:space:]]*=[[:space:]]*https?://([A-Za-z0-9.-]+(:[0-9]+)?)(/.*)?$#\2#p' "$d/$f" 2>/dev/null
  done | tr '[:upper:]' '[:lower:]' | grep -vE '^registry\.(npmjs\.org|yarnpkg\.com)$' | sort -u || true
}
env_npm_userconfig() { local f="${NPM_CONFIG_USERCONFIG:-${npm_config_userconfig:-$HOME/.npmrc}}"; [[ -f "$f" && ! -L "$f" ]] && printf '%s' "$f"; } # this machine's
# This machine's registry login for a repo: only the lines of its registries' auth; nothing when there is none.
# A line that names a variable (`_authToken=${TOKEN}`, as npm reads it from the environment) gets its value from
# this user's login shell, where npm would find it; a variable not set there leaves the line out (ENV_NPM_UNSET says which).
env_npm_login_of() { env_npm_login_get "$1"; printf '%s' "$ENV_NPM_LOGIN"; } # <checkout>
# The same, into ENV_NPM_LOGIN and ENV_NPM_UNSET (the variables not set), in this shell.
env_npm_login_get() { # <checkout>
  local raw names line out="" v
  ENV_NPM_UNSET="" ENV_NPM_LOGIN=""
  raw="$(env_npm_lines_of "$1")"; [[ -n "$raw" ]] || return 0
  names="$(grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]{0,100}\}' <<<"$raw" | sort -u | tr -d '${}' || true)"
  local -A val=()
  if [[ -n "$names" ]]; then
    local sh got i=0 n; sh="$(login_shell)"; mapfile -t n <<<"$names"
    if [[ "$sh" != none && -x "$sh" ]]; then
      # (the values, \036 apart, read in one login shell; never on a command line or in a file)
      got="$(perl -e 'alarm 10; exec @ARGV' "$sh" -lic "$(printf 'printf "\\036%%s" "${%s-}"; ' "${n[@]}")printf '\\036'" </dev/null 2>/dev/null || true)"
      got="${got#*$'\036'}"
      for v in "${n[@]}"; do val[$v]="${got%%$'\036'*}"; got="${got#*$'\036'}"; i=$((i + 1)); done
    fi
  fi
  while IFS= read -r line; do
    local bad=""
    for v in $(grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]{0,100}\}' <<<"$line" | tr -d '${}' || true); do
      if [[ -z "${val[$v]:-}" || "${val[$v]}" == *$'\n'* ]]; then bad="$v"; break; fi
      line="${line//"\${$v}"/"${val[$v]}"}"
    done
    if [[ -n "$bad" ]]; then ENV_NPM_UNSET+="${ENV_NPM_UNSET:+ }$bad"; continue; fi
    out+="$line"$'\n'
  done <<<"$raw"
  ENV_NPM_LOGIN="$out"
}
# The lines themselves, as the npm config has them.
env_npm_lines_of() { # <checkout>
  local hosts f; hosts="$(env_registries_of "$1")"; [[ -n "$hosts" ]] || return 0
  f="$(env_npm_userconfig)" || return 0
  (( $(wc -c <"$f") <= CR_ENV_MAX )) || return 0
  # (space apart: a BSD awk refuses a -v value with a newline in it)
  awk -v hosts="$(tr '\n' ' ' <<<"$hosts")" 'BEGIN { n = split(hosts, h, " ") }
    { line = $0; sub(/\r$/, "", line); l = line; sub(/^[[:space:]]+/, "", l)
      if (l !~ /^\/\//) next
      host = substr(l, 3); sub(/[\/:].*/, "", host); host = tolower(host)
      for (i = 1; i <= n; i++) if (host == h[i] && l ~ /:(_authToken|_auth|_password|username|email|always-auth|certfile|keyfile)[[:space:]]*=/) { print l; break } }' "$f"
}

# A checkout's env files that count, one relative path a line.
env_files_of() { # <checkout>
  local d="$1" f rel
  while IFS= read -r f; do
    rel="${f#"$d"/}"
    [[ "$rel" =~ $CR_ENV_REL_RE && ! -L "$f" ]] || continue
    [[ ! "${rel,,}" =~ \.(example|sample|template|dist|defaults|test|prod|production|staging|stage|preview|live)(\.|$) ]] || continue
    (( $(wc -c <"$f") <= CR_ENV_MAX )) || continue
    git -C "$d" check-ignore -q -- "$rel" 2>/dev/null || continue
    [[ -z "$(git -C "$d" ls-files -- "$rel" 2>/dev/null)" ]] || continue
    printf '%s\n' "$rel"
  done < <(find "$d" -maxdepth 4 \( -name node_modules -o -name .git -o -name .worktrees -o -name worktrees -o -name vendor -o -name .venv \) -prune -o -type f \( -name .env -o -name '.env.*' \) -print 2>/dev/null | LC_ALL=C sort)
}

# An env file read as assignments (stdin). `keys`: "<KEY> <why it is left out, or ->" a line. `file`: the file with the
# lines that are left out replaced by a comment. Exit 3 when a line is not an assignment, a comment or empty.
env_parse() { # keys|file <dropped, comma> <kept, comma>
  perl -e '
    use strict; my ($mode, $drop, $keep) = @ARGV; my %drop = map { $_ => 1 } split /,/, $drop; my %keep = map { $_ => 1 } split /,/, $keep;
    local $/; my $t = <STDIN>; $t =~ s/\r\n/\n/g; my @out;
    while (length $t) {
      if ($t =~ s/\A([ \t]*(?:#[^\n]*)?)(?:\n|\z)//) { push @out, $1 if $mode eq "file"; next }
      if ($t =~ s/\A([ \t]*(?:export[ \t]+)?([A-Za-z_][A-Za-z0-9_]{0,100})[ \t]*=[ \t]*)("(?:[^"\\]|\\.)*"|\x27[^\x27]*\x27|`[^`]*`|[^\n]*)([^\n]*)(?:\n|\z)//s) {
        my ($pre, $k, $v, $post) = ($1, $2, $3, $4); my $why = "";
        my $say = qr/(?:prod|production|live)/i;
        if ($drop{$k}) { $why = "dropped" }
        elsif ($keep{$k}) { $why = "" }
        elsif ($k =~ /(?:^|_)$say(?:_|$)/) { $why = "production" }
        elsif ($v =~ /(?<![A-Za-z])$say(?![A-Za-z])/) { $why = "production" }
        else {
          while ($v =~ m{\b(postgres(?:ql)?|mysql2?|mariadb|mongodb(?:\+srv)?|rediss?|amqps?|mssql|sqlserver|clickhouse|libsql)://([^\s"\x27`]*)}gi) {
            my $h = $2; $h =~ s{[/?#].*}{}s; $h =~ s{.*@}{}s; $h =~ s{:\d+\z}{};
            $why = "remote database" unless $h eq "" || $h =~ /^(?:localhost|127\.\d+\.\d+\.\d+|\[?::1\]?|0\.0\.0\.0|host\.docker\.internal|[a-z0-9_-]+)$/i;
          }
          if (!$why && $k =~ /(?:DATABASE|DB|PG|POSTGRES|MYSQL|REDIS|MONGO)[A-Z]*_?HOST$/i) {
            my $h = $v; $h =~ s/^["\x27`]|["\x27`]$//g; $h =~ s/\s.*//s;
            $why = "remote database" unless $h eq "" || $h =~ /^(?:localhost|127\.\d+\.\d+\.\d+|::1|0\.0\.0\.0|host\.docker\.internal|[a-z0-9_-]+|\/.*)$/i;
          }
        }
        if ($mode eq "keys") { print "$k ", ($why || "-"), "\n" }
        else { push @out, $why ? "# $k is left out by chartroom ($why)" : "$pre$v$post" }
        next;
      }
      exit 3;
    }
    print join("\n", @out), "\n" if $mode eq "file";' "$1" "$2" "$3"
}

# One checkout's env files, as JSON: [{rel, mode, mtime, keys: [{k, why}], fp}] (fp: a fingerprint of what
# would go, keyed with the scan's own salt, so that machines can be compared and nothing be guessed from it).
env_describe() { # <checkout> <salt> <drop> <keep>
  local d="$1" rel mode mt keys fp
  while IFS= read -r rel; do
    mode="$(stat -c %a "$d/$rel" 2>/dev/null || stat -f %Lp "$d/$rel" 2>/dev/null || echo -)"
    mt="$(guest_mtime "$d/$rel")"
    if keys="$(env_parse keys "$3" "$4" <"$d/$rel" 2>/dev/null)"; then
      fp="$( { printf '%s\n' "$2"; env_parse file "$3" "$4" <"$d/$rel"; } | sha256_hex | cut -c1-16)"
    else keys="" fp=""; fi
    jq -cn --arg r "$rel" --arg m "$mode" --argjson t "${mt:-0}" --arg k "$keys" --arg fp "$fp" \
      '{rel: $r, mode: $m, mtime: $t, fp: (if $fp == "" then null else $fp end), keys: ($k | split("\n") | map(select(length > 0) | split(" ") | {k: .[0], why: (.[1:] | join(" ") | if . == "-" then null else . end)}))}'
  done < <(env_files_of "$d") | jq -s -c .
}
env_describe_npm() { # <checkout> <salt> -> [] or [{rel: npm-login, ...}] (its keys: the npmrc keys, never a value)
  local login f raw; env_npm_login_get "$1"; login="$ENV_NPM_LOGIN"; raw="$(env_npm_lines_of "$1")"
  [[ -n "$raw" ]] || { echo '[]'; return; }
  f="$(env_npm_userconfig)"
  # (each key, and where its value comes from: a variable of the login shell, or one that is not set there)
  jq -cn --arg k "$(awk -v unset=" $ENV_NPM_UNSET " '{ i = index($0, "="); if (!i) next; k = substr($0, 1, i - 1); val = substr($0, i + 1); sub(/[[:space:]]+$/, "", k)
      v = ""; if (match(val, /\$\{[A-Za-z_][A-Za-z0-9_]*\}/)) { n = substr(val, RSTART + 2, RLENGTH - 3); v = (index(unset, " " n " ") ? "\tunset:" n : "\tfrom:" n) }
      print k v }' <<<"$raw")" --arg m "$(stat -c %a "$f" 2>/dev/null || stat -f %Lp "$f" 2>/dev/null || echo -)" --argjson t "$(guest_mtime "$f")" \
    --arg fp "$([[ -z "$login" ]] || { printf '%s\n' "$2"; printf '%s\n' "$login"; } | sha256_hex | cut -c1-16)" --arg rel "$CR_ENV_NPM" \
    '[{rel: $rel, kind: "npm", mode: $m, mtime: $t, fp: (if $fp == "" then null else $fp end),
       keys: ($k | split("\n") | map(select(length > 0) | split("\t") | {k: .[0],
         why: (if (.[1] // "") | startswith("unset:") then "its variable \(.[1][6:]) is not set in the login shell" else null end),
         from: (if (.[1] // "") | startswith("from:") then .[1][5:] else null end)}))}]'
}

# The checkouts of this machine that have env files: [{remote, files: [rel]}]; chartroom's own clones are not a source.
env_list_here() {
  local r g d rem fs
  while IFS= read -r r; do
    while IFS= read -r g; do
      d="${g%/.git}"; ! guest_cloned "$d" || continue
      fs="$(env_files_of "$d")"; [[ -z "$(env_npm_login_of "$d")" ]] || fs+="${fs:+$'\n'}$CR_ENV_NPM"; [[ -n "$fs" ]] || continue
      rem="$(guest_remote_of "$d")"; [[ "$rem" =~ $CR_NODE_REMOTE_RE ]] || continue
      jq -cn --arg r "$rem" --arg f "$fs" '{remote: $r, files: ($f | split("\n") | map(select(length > 0)))}'
    done < <(find "$r" -mindepth 2 -maxdepth 3 -name .git -type d -prune 2>/dev/null)
  done < <(guest_roots) | jq -s -c 'group_by(.remote) | map({remote: .[0].remote, files: (map(.files) | add | unique)})'
}
env_checkout_here() { # <remote> -> this machine's own checkout of it (not a clone chartroom made)
  local d; d="$(guest_find_checkout "$1")" || return 1
  ! guest_cloned "$d" || return 1
  printf '%s' "$d"
}
env_csv() { jq -r --arg k "$2" '.[$k] // [] | map(select(test("^[A-Za-z_][A-Za-z0-9_]{0,100}$"))) | join(",")' <<<"$1"; } # <json> <key>

# The same three questions, asked of a device over the connection (rc 5: it does not share).
device_cmd_env_list() { env_share_on || { echo "it does not share its env files (chartroom device share-env on, there)" >&2; return 5; }; env_list_here; }
device_cmd_env_describe() { # <payload {remote, salt, drop, keep}>
  local d; env_share_on || { echo "it does not share its env files" >&2; return 5; }
  d="$(env_checkout_here "$(jq -r '.remote // ""' <<<"$1")")" || { echo "no checkout of it here" >&2; return 6; }
  jq -s -c 'add' <(env_describe "$d" "$(jq -r '.salt // ""' <<<"$1")" "$(env_csv "$1" drop)" "$(env_csv "$1" keep)") <(env_describe_npm "$d" "$(jq -r '.salt // ""' <<<"$1")")
}
device_cmd_env_get() { # <payload {remote, rel, cert, drop, keep}>: one file, encrypted to <cert>, as base64
  env_share_on || { echo "it does not share its env files" >&2; return 5; }
  env_get_here "$(jq -r '.remote // ""' <<<"$1")" "$(jq -r '.rel // ""' <<<"$1")" "$(jq -r '.cert // ""' <<<"$1")" "$(env_csv "$1" drop)" "$(env_csv "$1" keep)"
}
env_get_here() { # <remote> <rel> <cert pem> <drop> <keep>
  local d rel="$2" c rc=0; d="$(env_checkout_here "$1")" || { echo "no checkout of $1 here" >&2; return 6; }
  if [[ "$rel" == "$CR_ENV_NPM" ]]; then
    local login; login="$(env_npm_login_of "$d")"; [[ -n "$login" ]] || { echo "no registry login for $1 here" >&2; return 6; }
    c="$(mktemp)"; printf '%s\n' "$3" >"$c"
    printf '%s\n' "$login" | env_encrypt "$c" | base64 | tr -d '\n' || rc=7
    rm -f "$c"; return "$rc"
  fi
  grep -qxF -- "$rel" <<<"$(env_files_of "$d")" || { echo "$rel is not an env file of $1 here" >&2; return 6; }
  env_parse keys "$4" "$5" <"$d/$rel" >/dev/null || { echo "$rel could not be read as an env file; it is not taken" >&2; return 7; }
  c="$(mktemp)"; printf '%s\n' "$3" >"$c"
  env_parse file "$4" "$5" <"$d/$rel" | env_encrypt "$c" | base64 | tr -d '\n' || rc=7
  rm -f "$c"
  return "$rc"
}

# ---------------------------------------------------------------- the keys

env_encrypt() { openssl cms -encrypt -binary -aes-256-cbc -outform DER "$1"; } # <cert file> < plain
env_decrypt() { # <key DER base64> <cert file> < cms
  openssl cms -decrypt -binary -inform DER -recip "$2" -inkey <(printf '%s' "$1" | base64 -d | openssl pkey -inform DER 2>/dev/null)
}
env_new_key() { # <cert file> -> the key, DER, base64; the cert written
  local k; k="$(mktemp)"; chmod 600 "$k"
  openssl req -x509 -newkey rsa:3072 -nodes -keyout "$k" -out "$1" -subj /CN=chartroom-env -days 36500 >/dev/null 2>&1 || { rm -f "$k"; return 1; }
  openssl pkcs8 -topk8 -nocrypt -in "$k" -outform DER | base64 | tr -d '\n'; rm -f "$k"
}

# The store's key: in the login keychain of the brain (or, where CHARTROOM_KEYCHAIN=none, a 0600 file).
env_store_cert() { printf '%s/store.pem' "$(env_dir)"; }
env_store_key() {
  local k v; k="$(device_keychain)"
  if [[ -n "$k" ]]; then v="$("$k" find-generic-password -s "$CR_ENV_KEYCHAIN_SERVICE" -a store -w 2>/dev/null)" || v=""
  else v="$(cat "$(env_dir)/store.key" 2>/dev/null || true)"; fi
  [[ -n "$v" ]] || { echo "the store's key could not be read from the login keychain (in an ssh session it is closed: run this in the login session)" >&2; return 1; }
  printf '%s' "$v"
}
env_store_init() {
  local k v c; mkdir -p "$(env_dir)"; chmod 700 "$(env_dir)"; c="$(env_store_cert)"
  [[ ! -s "$c" ]] || return 0
  command -v openssl >/dev/null || die "env: openssl is needed"
  touch "$(env_dir)/.metadata_never_index"
  v="$(env_new_key "$c.tmp")" || die "env: the store's key could not be made"
  k="$(device_keychain)"
  if [[ -n "$k" ]]; then
    printf 'add-generic-password -U -s %s -a store -w %s\n' "$CR_ENV_KEYCHAIN_SERVICE" "$v" | "$k" -i >/dev/null 2>&1 || true
    [[ "$("$k" find-generic-password -s "$CR_ENV_KEYCHAIN_SERVICE" -a store -w 2>/dev/null)" == "$v" ]] ||
      { rm -f "$c.tmp"; die "env: the login keychain did not keep the store's key (run this in the login session); nothing was made"; }
  else ( umask 077; printf '%s' "$v" >"$(env_dir)/store.key" ); fi
  mv "$c.tmp" "$c"
}

# A node's own key, made when it is first asked for its certificate.
env_node_dir() { printf '%s/env' "$(guest_state)"; }
env_node_cert() {
  local d v; d="$(env_node_dir)"; mkdir -p "$d"; chmod 700 "$d"
  if [[ ! -s "$d/node.pem" || ! -s "$d/node.key" ]]; then
    v="$(env_new_key "$d/node.pem.tmp")" || return 1
    ( umask 077; printf '%s' "$v" >"$d/node.key" ); mv "$d/node.pem.tmp" "$d/node.pem"
  fi
  cat "$d/node.pem"
}
device_cmd_env_cert() { command -v openssl >/dev/null || { echo "openssl is missing" >&2; return 1; }; env_node_cert; }

# ---------------------------------------------------------------- on a node: its copies

# Writes a repo's files into chartroom's clone of it: 0600, only where git ignores the path, never over a file
# it did not write itself; and deletes those it wrote that the store no longer has.
env_put_here() { # <remote> <clone> <files json [{rel, b64}]>
  local remote="$1" d="$2" m n i rel t key man old
  guest_cloned "$d" || { echo "$d is not a clone chartroom made; no env file is written there" >&2; return 7; }
  m="$(env_node_dir)"; mkdir -p "$m"; chmod 700 "$m"; man="$m/${remote//\//+}.json"
  old="$(jq -c --arg p "$d" 'select(.path == $p) | .files' "$man" 2>/dev/null || true)"; [[ -n "$old" ]] || old='[]'
  key="$(cat "$m/node.key" 2>/dev/null || true)"
  n="$(jq length <<<"$3")"
  for ((i = 0; i < n; i++)); do
    rel="$(jq -r --argjson i "$i" '.[$i].rel' <<<"$3")"
    env_rel_ok "$rel" || { echo "'$rel' is not an env file's name" >&2; return 7; }
    local to; to="$(env_path_in "$d" "$rel")"
    if [[ "$rel" == "$CR_ENV_NPM" ]]; then
      [[ -d "$d/.git" && ! -L "$d/.git" ]] || { echo "the clone of $remote has no .git directory for its registry login" >&2; return 7; }
      mkdir -p "${to%/*}"; chmod 700 "${to%/*}"
    else
      git -C "$d" check-ignore -q -- "$rel" 2>/dev/null || { echo "$rel is not ignored by git in $remote here; not written" >&2; return 7; }
      if [[ -e "$to" || -L "$to" ]] && ! jq -e --arg r "$rel" 'index($r)' >/dev/null <<<"$old"; then echo "$rel is there already, and is not chartroom's; left as it is" >&2; continue; fi
      mkdir -p "$(dirname "$to")"
    fi
    [[ "$(cd "$(dirname "$to")" && pwd -P)/" == "$(cd "$d" && pwd -P)"/* ]] || { echo "$rel leads out of the clone" >&2; return 7; }
    t="$to.chartroom.$$"; ( umask 077; : >"$t" )
    if ! jq -r --argjson i "$i" '.[$i].b64' <<<"$3" | base64 -d 2>/dev/null | env_decrypt "$key" "$m/node.pem" >"$t" 2>/dev/null; then rm -f "$t"; echo "$rel could not be decrypted with this node's key" >&2; return 7; fi
    chmod 600 "$t"; mv -f "$t" "$to"
    old="$(jq -c --arg r "$rel" '. + [$r] | unique' <<<"$old")"
    ( umask 077; jq -cn --arg r "$remote" --arg p "$d" --argjson f "$old" '{remote: $r, path: $p, files: $f}' >"$man.tmp" ) && mv "$man.tmp" "$man"
  done
  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    ! env_rel_ok "$rel" || rm -f "$(env_path_in "$d" "$rel")"
    old="$(jq -c --arg r "$rel" '. - [$r]' <<<"$old")"
  done < <(jq -r --argjson now "$3" '. - ($now | map(.rel)) | .[]' <<<"$old")
  [[ ! -f "$man" ]] || { ( umask 077; jq -cn --arg r "$remote" --arg p "$d" --argjson f "$old" '{remote: $r, path: $p, files: $f}' >"$man.tmp" ) && mv "$man.tmp" "$man"; }
  device_log "env files of $remote: $(jq -r 'join(" ")' <<<"$old")"
}
device_cmd_env_put() { # <payload {remote, files}>: a refresh, for a clone that is here
  local r d; r="$(jq -r '.remote // ""' <<<"$1")"
  d="$(guest_find_checkout "$r")" && guest_cloned "$d" || { echo "no clone of $r here" >&2; return 6; }
  env_put_here "$r" "$d" "$(jq -c '.files // []' <<<"$1")"
}
env_forget_here() { # [remote]: deletes the copies this node wrote
  local f rel p; shopt -s nullglob
  for f in "$(env_node_dir)"/*.json; do
    [[ -z "${1:-}" || "$(jq -r .remote "$f")" == "$1" ]] || continue
    p="$(jq -r .path "$f")"
    while IFS= read -r rel; do ! env_rel_ok "$rel" || rm -f "$(env_path_in "$p" "$rel")"; done < <(jq -r '.files[]' "$f")
    device_log "env files of $(jq -r .remote "$f") deleted"
    rm -f "$f"
  done
  shopt -u nullglob
}
device_cmd_env_forget() { env_forget_here "$(jq -r '.remote // ""' <<<"$1")"; echo "deleted"; }

# ---------------------------------------------------------------- the brain

env_owners_file() { printf '%s/owners.json' "$(env_dir)"; }
env_owner_json() { local o; o="$(jq -c --arg r "$1" '.[$r] // empty' "$(env_owners_file)" 2>/dev/null || true)"; printf '%s' "${o:-null}"; } # <remote>
env_machine_name() { if [[ "$1" == here ]]; then radar_machine_name; else fleet_devices_json | jq -r --arg i "$1" '[.[] | select(.id == $i) | .name][0] // $i'; fi; } # <device id|here>
env_stored() { [[ -s "$(env_repo_dir "$1")/index.json" ]]; } # <remote>: are files of it kept?

# A question to a machine, this one or a device: its answer, its exit.
env_ask() { # <device id|here> <list|describe|get> <payload json>
  if [[ "$1" == here ]]; then ( "device_cmd_env_$2" "$3" ); return; fi
  fleet_device_json "$1" | jq -e '.status == "online" and ((.caps // []) | index("env"))' >/dev/null || { echo "it is away, or its chartroom is older" >&2; return 4; }
  fleet_call "$1" "env-$2" "$3" 60
}
env_machines() { echo here; fleet_devices_json | jq -r '.[] | select(.status != "revoked") | .id'; }

cmd_env() {
  local sub="${1:-}"; shift || true
  env_refuse_worker
  case "$sub" in
    scan) cmd_env_scan "$@" ;;
    owner) cmd_env_owner "$@" ;;
    collect) cmd_env_collect "$@" ;;
    ls|list) cmd_env_ls "$@" ;;
    refresh) cmd_env_refresh "$@" ;;
    forget) cmd_env_forget "$@" ;;
    *) die "usage: chartroom env scan [<repo>] [--json] | owner <repo> <device>|here|never [--drop K,..] [--keep K,..] | collect <repo>...|--all | ls [--json] | refresh [<repo>...] | forget <repo>|--node <device>" ;;
  esac
}

# [{machine, id, error, repos: [{remote, files: [...]}]}], each repo described when <repo> is given.
env_scan_json() { # <remote or "">
  local m out err rc salt own; salt="$(fleet_rand_hex 16)"; own="$(env_owner_json "${1:-}")"
  while IFS= read -r m; do
    rc=0; err="$(mktemp)"
    if [[ -z "$1" ]]; then out="$(env_ask "$m" list '{}' 2>"$err")" || rc=$?
    else
      out="$(env_ask "$m" describe "$(jq -cn --arg r "$1" --arg s "$salt" --argjson o "$own" '{remote: $r, salt: $s, drop: ($o.drop // []), keep: ($o.keep // [])}')" 2>"$err")" || rc=$?
      (( rc != 0 )) || out="$(jq -c --arg r "$1" 'if length == 0 then [] else [{remote: $r, files: .}] end' <<<"$out")"
    fi
    if (( rc == 6 )); then rc=0; out='[]'; fi
    jq -cn --arg i "$m" --arg n "$(env_machine_name "$m")" --arg e "$( (( rc == 0 )) || grep -v '^[[:space:]]*$' "$err" | tail -1 || true)" --argjson ok "$(( rc == 0 ? 1 : 0 ))" --argjson r "$( (( rc == 0 )) && printf '%s' "${out:-[]}" || echo '[]')" \
      '{machine: $n, id: $i, error: (if $ok == 1 then null else (if $e == "" then "no answer" else $e end) end), repos: $r}'
    rm -f "$err"
  done < <(env_machines) | jq -s -c .
}
cmd_env_scan() {
  local repo="" json=0 doc
  while [[ $# -gt 0 ]]; do case "$1" in --json) json=1 ;; -*) die "env scan: unknown flag $1" ;; *) repo="$(env_remote "$1")" || exit 1 ;; esac; shift; done
  doc="$(env_scan_json "$repo")"
  if (( json )); then jq . <<<"$doc"; return; fi
  jq -r --arg repo "$repo" '
    (.[] | select(.error != null) | "\(.machine): \(.error)"),
    (if $repo == "" then
      ([.[] | .machine as $m | .repos[] | {r: .remote, m: $m, f: .files}] | group_by(.r) | .[] | "\(.[0].r)", (.[] | "  \(.m): \(.f | join(" "))"))
     else
      ([.[] | .machine as $m | .repos[].files[] | . + {m: $m}] | group_by(.rel) | .[]
        | "\(.[0].rel)" + (if ([.[].fp] | unique | length) > 1 then "  (the machines differ)" else "" end),
          (.[] | "  \(.m): mode \(.mode), changed \(.mtime | todate[0:10]), " + (if .fp == null then "cannot be read as an env file: it would not be taken" else "\(.keys | length) keys"
              + ([.keys[] | select(.from != null) | "\(.k) from $\(.from)"] | if length > 0 then "; " + join(", ") else "" end)
              + ([.keys[] | select(.why != null) | "\(.k) (\(.why))"] | if length > 0 then "; left out: " + join(", ") else "" end) end)),
          ([.[].keys[].k] | unique) as $all
          | (.[] | ([.keys[].k]) as $have | ($all - $have) | select(length > 0) | . as $miss | "  missing on one of them: \($miss | join(", "))"))
     end)' <<<"$doc"
}

cmd_env_owner() {
  local repo="${1:-}" who="${2:-}" drop="" keep="" id k
  [[ -n "$repo" && -n "$who" ]] || die "usage: chartroom env owner <repo> <device>|here|never [--drop KEY,...] [--keep KEY,...]"
  shift 2; repo="$(env_remote "$repo")" || exit 1
  while [[ $# -gt 0 ]]; do case "$1" in --drop) drop="${2:-}"; shift 2 ;; --keep) keep="${2:-}"; shift 2 ;; *) die "env owner: unknown arg $1" ;; esac; done
  for k in ${drop//,/ } ${keep//,/ }; do [[ "$k" =~ $CR_ENV_KEY_RE ]] || die "env owner: '$k' is not a key's name"; done
  case "$who" in here|never) id="$who" ;; *) if [[ "$who" == "$(radar_machine_name)" ]]; then id=here; else id="$(fleet_resolve "$who")" || exit 1; fi ;; esac
  mkdir -p "$(env_dir)"; chmod 700 "$(env_dir)"
  fleet_lock; trap fleet_unlock EXIT
  local cur; cur="$(cat "$(env_owners_file)" 2>/dev/null || echo '{}')"
  fleet_write "$(env_owners_file)" "$(jq -c --arg r "$repo" --arg o "$id" --arg d "$drop" --arg k "$keep" --arg at "$(now)" \
    '.[$r] = {owner: $o, drop: ($d | split(",") | map(select(length > 0))), keep: ($k | split(",") | map(select(length > 0))), at: $at}' <<<"$cur")"
  fleet_unlock; trap - EXIT
  if [[ "$id" == never ]]; then env_drop_repo "$repo"; echo "$repo: its env files are never taken"; return 0; fi
  echo "$repo: $(env_machine_name "$id")'s env files are the ones${drop:+; left out: $drop}${keep:+; kept: $keep} (chartroom env collect ${repo#github.com/} takes them)"
}

# Takes a repo's files from its owner into the store. Prints what it took; 1 when it could not.
env_collect_one() { # <remote>
  local r="$1" o own doc n i rel mode out d tmp err files='[]'
  own="$(env_owner_json "$r")"; o="$(jq -r '.owner // ""' <<<"$own")"
  [[ -n "$o" ]] || { echo "$r: no owner yet (chartroom env scan ${r#github.com/}, then chartroom env owner)" >&2; return 1; }
  [[ "$o" != never ]] || { echo "$r: never, as the commander said" >&2; return 1; }
  env_store_init
  err="$(mktemp)"
  if ! doc="$(env_ask "$o" describe "$(jq -cn --arg r "$r" --argjson o "$own" '{remote: $r, salt: "", drop: $o.drop, keep: $o.keep}')" 2>"$err")"; then
    echo "$r: $(env_machine_name "$o"): $(tail -1 "$err")" >&2; rm -f "$err"; return 1
  fi
  d="$(env_repo_dir "$r")"; tmp="$d.new"; rm -rf "$tmp"; mkdir -p "$tmp"; chmod 700 "$tmp"
  n="$(jq length <<<"$doc")"
  for ((i = 0; i < n; i++)); do
    rel="$(jq -r --argjson i "$i" '.[$i].rel' <<<"$doc")"; mode="$(jq -r --argjson i "$i" '.[$i].mode' <<<"$doc")"
    env_rel_ok "$rel" || continue
    if ! out="$(env_ask "$o" get "$(jq -cn --arg r "$r" --arg f "$rel" --arg c "$(cat "$(env_store_cert)")" --argjson o "$own" '{remote: $r, rel: $f, cert: $c, drop: $o.drop, keep: $o.keep}')" 2>"$err")" || [[ -z "$out" ]]; then
      echo "$r: $(tail -1 "$err")" >&2; continue
    fi
    ( umask 077; printf '%s' "$out" | base64 -d >"$tmp/$i.cms" ) || { echo "$r: $rel did not arrive whole" >&2; continue; }
    files="$(jq -c --arg r "$rel" --arg m "$mode" --arg f "$i.cms" --argjson t "$(jq --argjson i "$i" '.[$i].mtime' <<<"$doc")" '. + [{rel: $r, mode: $m, file: $f, mtime: $t}]' <<<"$files")"
  done
  rm -f "$err"
  if [[ "$(jq length <<<"$files")" == 0 ]]; then rm -rf "$tmp"; echo "$r: $(env_machine_name "$o") has no env file of it to take" >&2; return 1; fi
  ( umask 077; jq -cn --arg r "$r" --arg o "$o" --arg at "$(now)" --argjson f "$files" --argjson own "$own" '{remote: $r, owner: $o, at: $at, files: $f, drop: $own.drop, keep: $own.keep}' >"$tmp/index.json" )
  rm -rf "$d.old"; [[ ! -d "$d" ]] || mv "$d" "$d.old"
  mv "$tmp" "$d"; rm -rf "$d.old"
  env_log collect "$r" "$(jq -c 'map({rel, mode})' <<<"$files")" "$(env_machine_name "$o")" store
  echo "$r: $(jq -r 'map(.rel) | join(" ")' <<<"$files") from $(env_machine_name "$o")"
}
cmd_env_collect() {
  local r rc=0 list=()
  [[ $# -gt 0 ]] || die "usage: chartroom env collect <repo>...|--all"
  if [[ "$1" == --all ]]; then mapfile -t list < <(jq -r 'to_entries[] | select(.value.owner != "never") | .key' "$(env_owners_file)" 2>/dev/null)
  else for r in "$@"; do list+=("$(env_remote "$r")") || exit 1; done; fi
  (( ${#list[@]} > 0 )) || die "env collect: no repo has an owner yet (chartroom env owner)"
  for r in "${list[@]}"; do env_collect_one "$r" || rc=1; done
  return "$rc"
}

# Has the owner's copy changed since it was taken? (dates alone: nothing is read; a machine that is away has not)
env_changed() { # <remote>
  local ix own o doc; ix="$(env_repo_dir "$1")/index.json"; own="$(env_owner_json "$1")"; o="$(jq -r '.owner // ""' <<<"$own")"
  [[ -n "$o" && "$o" != never ]] || return 1
  jq -e --argjson o "$own" '.owner == $o.owner and .drop == $o.drop and .keep == $o.keep' "$ix" >/dev/null 2>&1 || return 0
  doc="$(env_ask "$o" describe "$(jq -cn --arg r "$1" '{remote: $r, salt: "", drop: [], keep: []}')" 2>/dev/null)" || return 1
  [[ "$(jq -c 'map([.rel, .mtime]) | sort' <<<"$doc")" != "$(jq -c '.files | map([.rel, .mtime]) | sort' "$ix")" ]]
}

# A repo's files for a device, encrypted to its own key, as JSON [{rel, b64}] ([] when there is nothing to give).
env_files_for() { # <remote> <device id>
  local r="$1" d cert key n i out='[]' b ix tmp
  d="$(env_repo_dir "$r")"; ix="$d/index.json"; [[ -s "$ix" ]] || { echo '[]'; return 0; }
  fleet_device_json "$2" | jq -e '.status == "online" and ((.caps // []) | index("env"))' >/dev/null || { echo '[]'; return 0; }
  tmp="$(mktemp)"; fleet_call "$2" env-cert '{}' 30 >"$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  openssl x509 -in "$tmp" -noout >/dev/null 2>&1 || { rm -f "$tmp"; return 1; }
  key="$(env_store_key)" || { rm -f "$tmp"; return 1; }
  n="$(jq '.files | length' "$ix")"
  for ((i = 0; i < n; i++)); do
    b="$(env_decrypt "$key" "$(env_store_cert)" <"$d/$(jq -r --argjson i "$i" '.files[$i].file' "$ix")" | env_encrypt "$tmp" | base64 | tr -d '\n')"
    [[ -n "$b" ]] || { rm -f "$tmp"; return 1; }
    out="$(jq -c --arg r "$(jq -r --argjson i "$i" '.files[$i].rel' "$ix")" --arg b "$b" '. + [{rel: $r, b64: $b}]' <<<"$out")"
  done
  rm -f "$tmp"; printf '%s' "$out"
}
env_gave() { # <remote> <device id>: noted, with the log
  local f; f="$(env_dir)/nodes/$2.json"
  fleet_write "$f" "$(jq -c --arg r "$1" --arg at "$(now)" '.[$r] = $at' <<<"$(cat "$f" 2>/dev/null || echo '{}')")"
  env_log give "$1" "$(jq -c '.files | map({rel, mode: "600"})' "$(env_repo_dir "$1")/index.json")" store "$(env_machine_name "$2")"
}
# For a dispatch to a node that clones: what changed at its owner is taken first, then the files for it.
env_for_dispatch() { # <remote> <device id>
  env_stored "$1" || { echo '[]'; return 0; }
  if env_changed "$1"; then env_collect_one "$1" >/dev/null 2>&1 || true; fi
  env_files_for "$1" "$2"
}

cmd_env_refresh() {
  local list=() r id f rc=0 err
  if [[ $# -gt 0 ]]; then for r in "$@"; do list+=("$(env_remote "$r")") || exit 1; done
  else mapfile -t list < <(jq -r 'keys[]' "$(env_owners_file)" 2>/dev/null); fi
  for r in "${list[@]+"${list[@]}"}"; do
    env_stored "$r" || continue
    if env_changed "$r"; then env_collect_one "$r" || rc=1; else echo "$r: unchanged"; fi
    shopt -s nullglob
    for f in "$(env_dir)/nodes"/*.json; do
      jq -e --arg r "$r" 'has($r)' "$f" >/dev/null || continue
      id="$(basename "$f" .json)"; err="$(mktemp)"
      if fleet_call "$id" env-put "$(jq -cn --arg r "$r" --argjson f "$(env_files_for "$r" "$id" 2>/dev/null || echo '[]')" '{remote: $r, files: $f} | if (.files | length) == 0 then error("none") else . end')" 60 >/dev/null 2>"$err"; then env_gave "$r" "$id"; echo "$r: given to $(env_machine_name "$id")"
      else echo "$r: $(env_machine_name "$id") did not take it: $(tail -1 "$err")" >&2; rc=1; fi
      rm -f "$err"
    done
    shopt -u nullglob
  done
  return "$rc"
}

cmd_env_ls() {
  local doc; mkdir -p "$(env_dir)"
  doc="$( { shopt -s nullglob; for f in "$(env_dir)"/*/index.json; do jq -c . "$f"; done; } | jq -s -c --argjson o "$(cat "$(env_owners_file)" 2>/dev/null || echo '{}')" \
    --argjson n "$( { shopt -s nullglob; for f in "$(env_dir)/nodes"/*.json; do jq -c --arg i "$(basename "$f" .json)" '{id: $i, repos: keys}' "$f"; done; } | jq -s -c .)" '
    (map({key: .remote, value: .}) | from_entries) as $s
    | [($o | keys[]), ($s | keys[])] | unique | map(. as $r | {repo: $r, owner: ($o[$r].owner // null), files: ($s[$r].files // [] | map({rel, mode})), taken: ($s[$r].at // null), nodes: [$n[] | select(.repos | index($r)) | .id]})')"
  if [[ "${1:-}" == --json ]]; then jq . <<<"$doc"; return; fi
  jq -r --argjson d "$(fleet_devices_json | jq -c 'map({key: .id, value: .name}) | from_entries')" --arg here "$(radar_machine_name)" '
    if length == 0 then "no repo has an owner yet (chartroom env scan)" else
      .[] | "\(.repo): owner \(if .owner == "here" then $here elif .owner == null then "-" else ($d[.owner] // .owner) end)"
        + (if .taken then ", taken \(.taken): \(.files | map(.rel) | join(" "))" else ", nothing taken" end)
        + (if (.nodes | length) > 0 then "; on \(.nodes | map($d[.] // .) | join(", "))" else "" end) end' <<<"$doc"
}

env_drop_repo() { # <remote>: from the nodes that have it, then from the store
  local r="$1" f id; shopt -s nullglob
  for f in "$(env_dir)/nodes"/*.json; do
    jq -e --arg r "$r" 'has($r)' "$f" >/dev/null || continue
    id="$(basename "$f" .json)"
    if fleet_call "$id" env-forget "$(jq -cn --arg r "$r" '{remote: $r}')" 30 --keep >/dev/null 2>&1; then echo "$(env_machine_name "$id"): deleted"
    else echo "$(env_machine_name "$id"): away; it deletes them when it is back"; fi
    fleet_write "$f" "$(jq -c --arg r "$r" 'del(.[$r])' "$f")"
    env_log forget "$r" '[]' "$(env_machine_name "$id")" ""
  done
  shopt -u nullglob
  rm -rf "$(env_repo_dir "$r")"
}
env_drop_node() { # <device id>: its copies, and what they were (a revoked one is told first)
  local f; f="$(env_dir)/nodes/$1.json"; [[ -s "$f" && "$(jq length "$f")" != 0 ]] || return 0
  if fleet_call "$1" env-forget '{}' 15 >/dev/null 2>&1; then echo "its env files are deleted there ($(jq -r 'keys | join(", ")' "$f"))"
  else echo "it could not be told to delete its env files: if it is not yours any more, rotate what it had ($(jq -r 'keys | join(", ")' "$f")); its agent deletes them when it next asks"; fi
  env_log forget "$(jq -r 'keys | join(" ")' "$f")" '[]' "$(env_machine_name "$1")" ""
  rm -f "$f"
}
cmd_env_forget() {
  case "${1:-}" in
    --node) local id; id="$(fleet_resolve "${2:-}")" || exit 1; env_drop_node "$id" ;;
    ""|-*) die "usage: chartroom env forget <repo>|--node <device>" ;;
    *) local r; r="$(env_remote "$1")" || exit 1; env_drop_repo "$r"; echo "$r: no longer kept" ;;
  esac
}
