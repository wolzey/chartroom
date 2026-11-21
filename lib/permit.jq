# permit.jq - the permission policy for chartroom's Claude workers: the one place its rules live.
#
# lib/permit.sh feeds it one request and acts on the verdict. Input:
#   {event: "pre-tool"|"permission"|"denied", tool, input (the tool's input object), sig, cwd,
#    roots: {worktree, task_dir, scratch, permits, user_home, db},
#    branch (the task's branch), current_branch (the worktree's; "" when not looked up),
#    grants: [name], always: [{tool, pattern, from}], pre: <p-id of a one-time pre-approval> | null}
# Output: {verdict: "allow"|"deny"|"card"|"none", rule, why}
#
# The rules, first match wins:
#   1. guard:*      deny   touching the permit store, answering or granting a permit, rewriting
#                          the task's own control files (meta.json, claude-settings.json, launch.sh,
#                          and the machine's task store)
#   -  question     none   AskUserQuestion and ExitPlanMode are questions, not permissions
#   2. preapproved  allow  a one-time pre-approval for exactly this call (a late or retry answer)
#   3. always:*     allow  an "Always for this task" pattern the commander chose
#   4. commander:*  card   production, secrets, flags (the feature-flag service), money, outward-facing,
#                          elsewhere (other places and machines, sudo), controls (the worker's own
#                          settings, hooks, git config); except that when every match is
#                          `outward` and a task grant covers each one: grant:<name> allow
#   5. local:*      allow  only for "permission" (a prompt Claude would show): reads anywhere, a
#                          web search, and writes, tests, installs, local git, a dev server,
#                          scratch files inside the worktree, the task dir, the scratchpad and /tmp
#   6. otherwise    card for "permission"; none for "pre-tool" (Claude's own flow decides)
#
# Bash is read as quoted words split into commands at ; & | ( ) { } backticks and newlines, with
# $(...) and `...` (not inside '...', where the shell runs nothing), `sh -c '...'` and `eval` read
# too, heredoc bodies skipped (unless fed to a shell), each command named by its first word past
# VAR=value and wrappers (env, timeout, xargs, ...). It is a classifier for routine work, not a
# sandbox: what it cannot read never becomes an allow.

def lc: ascii_downcase;
def esc: gsub("(?<c>[.+?^$()\\[\\]{}|\\\\*])"; "\\\(.c)");

# ---------------------------------------------------------------- paths

def expand($home): if . == "~" then $home elif startswith("~/") then $home + .[1:] else . end;
def normpath:
  (startswith("/")) as $abs
  | reduce (split("/")[]) as $s ([]; if $s == "" or $s == "." then . elif $s == ".." then (if length > 0 then .[:-1] else . end) else . + [$s] end)
  | (if $abs then "/" else "" end) + join("/");
def resolve($cwd; $home): expand($home) | (if startswith("/") then . else $cwd + "/" + . end) | normpath;
def under($r): $r != "" and (. == $r or startswith($r + "/"));
def under_any($rs): . as $p | any($rs[]; . as $r | $p | under($r));

def tmp_roots: ["/tmp", "/private/tmp", "/var/folders", "/private/var/folders"];
def work_roots($R): [$R.worktree, $R.task_dir, $R.scratch] + tmp_roots | map(select(. != null and . != ""));
def dev_roots: ["/dev/null", "/dev/stdout", "/dev/stderr", "/dev/stdin", "/dev/tty", "/dev/fd"];

def control_files($R): [$R.task_dir + "/meta.json", $R.task_dir + "/claude-settings.json", $R.task_dir + "/launch.sh"]
  + (if ($R.db // "") != "" then [$R.db, $R.db + "-wal", $R.db + "-journal"] else [] end);
def control_tree($R): [$R.worktree + "/.claude", $R.worktree + "/.mcp.json", $R.worktree + "/.git/config", $R.worktree + "/.git/hooks"];

# ---------------------------------------------------------------- reading Bash

# Heredoc bodies are data, so they are left out, unless the line feeds them to a shell.
def strip_heredocs:
  reduce split("\n")[] as $l ({out: [], tag: null, keep: false};
    if .tag != null then
      (if ($l | gsub("^[[:space:]]+"; "")) == .tag then .tag = null else . end)
      | if .keep then .out += [$l] else . end
    else
      ($l | capture("<<-?[[:space:]]*[\"']?(?<t>[A-Za-z_][A-Za-z0-9_]*)[\"']?") // null) as $c
      | .out += [$l]
      | if $c != null and ($l | test("<<<") | not) then
          .tag = $c.t | .keep = ($l | test("(^|[[:space:];|&(])(bash|sh|zsh|dash|ksh|ssh|eval|source|xargs)([[:space:]]|$)"))
        else . end
    end)
  | .out | join("\n");

def tokens: [scan("(?:\"(?:[^\"\\\\]|\\\\.)*\"|'[^']*'|\\$\\((?:[^()]|\\([^()]*\\))*\\)|\\$\\{[^{}]*\\}|[^[:space:];&|(){}`\"'$]+|\\$)+|[;&|(){}`\n]+")];
def is_sep: test("^[;&|(){}`\n]+$");
def unq: gsub("[\"']"; "");
# (Not arithmetic: $((off + 100)) runs no command.)
def subs: [scan("\\$\\(((?:[^()]|\\([^()]*\\))*)\\)") | .[0] | select(test("^\\([\\s\\S]*\\)$") | not)] + [scan("`([^`]*)`") | .[0]];
# A word without its top-level single-quoted parts: the shell runs no $(...) or `...` inside
# '...'. A $(...) piece is kept whole (its own quotes are read at the next level), and so is an
# escaped character (don\'t).
def unsq: [scan("\\\\[\\s\\S]|\"(?:[^\"\\\\]|\\\\.)*\"|'[^']*'|\\$\\((?:[^()]|\\([^()]*\\))*\\)|[^\"'\\\\$]+|[\\s\\S]")]
  | map(select(startswith("'") | not)) | join("");
def shells: ["bash", "sh", "zsh", "dash", "ksh"];
def is_redirect: test("^[0-9]*[<>]");

def wrappers: ["sudo","doas","exec","command","builtin","env","nohup","nice","time","timeout","setsid","xargs","do","then","else","elif","if","while","until","!","caffeinate","gtimeout"];
def strip_wrappers:
  if (.w | length) == 0 then .
  elif (.w[0] | test("^[A-Za-z_][A-Za-z0-9_]*=")) then .env += [.w[0]] | .w |= .[1:] | strip_wrappers
  elif (.w[0] | split("/") | last) as $h0 | wrappers | index($h0) then
    (.w[0] | split("/") | last) as $h
    | .sudo = (.sudo or ($h | IN("sudo", "doas"))) | .xargs = (.xargs or $h == "xargs")
    | .w |= .[1:]
    | .w |= until(length == 0 or (((.[0] | startswith("-")) or ($h | IN("timeout", "gtimeout")) and (.[0] | test("^[0-9.]+[smhd]?$"))) | not); .[1:])
    | strip_wrappers
  else . end;

# The commands of a command line: [{env, sudo, xargs, path, head, args}].
def fdredirs: gsub("[0-9]*>&[0-9-]+"; " ") | gsub("&>>?"; ">");
def segments($depth):
  # (An empty {} is a word, as in `xargs -I{} cmd {}` or `find -exec cmd {} \;`, not a group.)
  strip_heredocs | fdredirs | gsub("\\{\\}"; "%braces%") | tokens
  | (reduce .[] as $x ({cur: [], segs: []};
       if ($x | is_sep) then (if (.cur | length) > 0 then .segs += [.cur] | .cur = [] else . end) else .cur += [$x] end)
     | .segs + (if (.cur | length) > 0 then [.cur] else [] end))
  | [ .[] | . as $toks
      # Redirects come from unquoted tokens only: an arrow inside quoted text is not one.
      | (reduce range(0; $toks | length) as $i ({w: [], r: [], skip: false};
           if .skip then .skip = false
           elif ($toks[$i] | test("^[0-9]*>>?$")) then .r += [($toks[$i + 1] // "") | unq] | .skip = true
           elif ($toks[$i] | test("^[0-9]*>>?[^>]")) then .r += [$toks[$i] | sub("^[0-9]*>>?"; "") | unq]
           elif ($toks[$i] | test("^[0-9]*<+$")) then .skip = true
           elif ($toks[$i] | test("^[0-9]*<[^<]")) then .
           else .w += [$toks[$i] | unq] end)) as $parts
      | ({w: $parts.w, env: [], sudo: false, xargs: false} | strip_wrappers
         | select((.w | length) > 0 or (.env | length) > 0)
         | {env, sudo, xargs, path: (.w[0] // ""), head: ((.w[0] // "") | split("/") | last // ""), args: .w[1:],
            redirs: [$parts.r[] | select(. != "" and (startswith("&") | not))]}) as $s
      | $s,
        (if $depth < 3 then
           ($toks[] | unsq | subs[] | segments($depth + 1)[]),
           # A shell's -c script, wherever the shell is named (`find -exec sh -c '...'`, `docker
           # exec x bash -c '...'`), and eval's words.
           (([$s.path] + $s.args) as $w
            | range(0; $w | length) as $i
            | select(($w[$i] | split("/") | last) | IN(shells[]))
            | ($w[$i + 1:] | until(length == 0 or (.[0] | test("^-[A-Za-z]*c$")); .[1:])) as $r
            | select(($r | length) > 1)
            | $r[1] | segments($depth + 1)[]),
           (if $s.head == "eval" then ($s.args | join(" ")) | segments($depth + 1)[] else empty end)
         else empty end) ];
def segments: segments(0);

# Redirect targets: ">file", ">>file", or ">" then the file, of every command of a line.
def redirect_targets: [segments[] | .redirs[]?];

# The words of a command that name paths: absolute, ~, ./ ../ or with a slash (not a URL, a flag
# or user@host:), and --opt=<path> values.
def path_args:
  [.args[] | (if test("^--?[A-Za-z0-9-]+=") then sub("^--?[A-Za-z0-9-]+="; "") else . end)
   | select(. != "" and (test("[[:space:]]") | not) and (startswith("-") | not) and (test("://") | not) and (test("^[A-Za-z0-9.+_-]+@[A-Za-z0-9.-]+:") | not))
   | select(startswith("/") or startswith("~") or startswith("./") or startswith("../") or . == ".." or test("/"))];

# The git subcommand past -C <path>, -c <k=v> and other global flags, and its args.
def git_sub:
  .args as $a
  | {i: 0} | until(.i >= ($a | length) or ($a[.i] | startswith("-") | not);
      if ($a[.i] | IN("-C", "-c", "--git-dir", "--work-tree", "--namespace")) then .i += 2 else .i += 1 end)
  | {sub: ($a[.i] // ""), sargs: $a[(.i + 1):]};

def is_local_url: test("^(https?://)?(localhost|127\\.0\\.0\\.1|0\\.0\\.0\\.0|\\[::1\\])([:/]|$)");
def urls: [.args[] | select(test("^[a-z]+://") or is_local_url)];

# ---------------------------------------------------------------- commander classes

def prod_word: test("(^|[^A-Za-z0-9])(prod|production|prd)([^A-Za-z0-9]|$)"; "i");
def secret_text:
  (gsub("\\.env\\.(example|sample|template|dist|defaults)"; "") | test("(^|[/[:space:]=\"'])\\.env(\\.[A-Za-z0-9_-]+)?($|[[:space:]\"'/;|&)])"))
  or test("\\.ssh/|(^|[/[:space:]])id_(rsa|ed25519|ecdsa|dsa)([^A-Za-z0-9]|$)|\\.aws/(credentials|config)|\\.config/gcloud|\\.netrc|\\.npmrc|\\.pypirc|\\.docker/config\\.json|\\.kube/config|credentials\\.json|service[-_]?account[^[:space:]]*\\.json|\\.(pem|p12|pfx)([^A-Za-z0-9]|$)|\\.keychain(-db)?([^A-Za-z0-9]|$)");
def flags_text: test("launch[-_ ]?darkly|ldcli"; "i");
def money_text: test("sk_live_|rk_live_|api\\.stripe\\.com|dashboard\\.stripe\\.com"; "i");

def infra_heads: ["kubectl","helm","terraform","tofu","pulumi","gcloud","gsutil","bq","az","aws","doctl","flyctl","fly","heroku","vercel","netlify","psql","mysql","sqlcmd","pg_dump","pg_restore","redis-cli","mongosh","mongo","ssh","scp","rsync","sftp","curl","wget","http","https","xh","docker","argocd","kustomize","ansible","ansible-playbook","firebase","wrangler","railway"];
def cloud_mutation: test("^(create|delete|update|set|add|remove|deploy|assign|grant|revoke|patch|put|start|stop|restart|swap|import|attach|detach|rotate|enable|disable|set-iam-policy|add-iam-policy-binding|remove-iam-policy-binding|assign-roles|reset|rm|cp|mv|sync|publish|ssh|scp|apply|destroy|up|scale|resize|upgrade|rollback|purge|terminate|reboot|modify|tag|untag|execute|exec|run)$");
def publish_verbs: "^(publish|unpublish|deprecate|dist-tag|owner|access|login|adduser|logout|token|team|org|star)$";

# Each commander match of one command, as {class, kind, seg}.
def seg_classes:
  . as $s | (.args | join(" ")) as $line | .head as $h | (.args[0] // "") as $a0 | (.args[1] // "") as $a1
  # the words that name things (a quoted phrase with spaces is text, not a target)
  | ([.args[] | select(test("[[:space:]]") | not)] | join(" ")) as $names
  # the subcommand words, up to the first flag
  | ([.args[] | select(test("[[:space:]]") | not)]
     | reduce .[] as $w ({v: [], stop: false}; if .stop or ($w | startswith("-")) then .stop = true else .v += [$w] end) | .v) as $verbs
  | [
      (if .sudo then {class: "elsewhere", kind: "sudo"} else empty end),
      (if $h == "git" then (git_sub as $g
        | if $g.sub == "push" then {class: "outward", kind: "git-push", g: $g}
          elif $g.sub == "remote" and (($g.sargs[0] // "") | test("^(add|set-url|remove|rm|rename)$")) then {class: "outward", kind: "git-remote"}
          elif ($g.sub | IN("send-email", "request-pull")) then {class: "outward", kind: "git-mail"}
          elif $g.sub == "config" and ($g.sargs | any(test("^--?(get|get-all|get-regexp|list|l|show-origin|show-scope|name-only)$")) | not) and (($g.sargs | map(select(startswith("-") | not)) | length) > 1 or ($g.sargs | any(test("^--(unset|unset-all|add|replace-all|edit|e|remove-section|rename-section)$"))))
            then {class: "controls", kind: "git config"}
          else empty end) else empty end),
      (if $h == "gh" then
        if $a0 == "pr" and ($a1 | test("^(create|merge|comment|review|close|edit|ready|reopen|lock|unlock)$")) then {class: "outward", kind: "gh-pr-\($a1)"}
        elif $a0 == "issue" and ($a1 | test("^(create|comment|close|edit|reopen|delete|transfer|lock|unlock|pin|unpin|develop)$")) then {class: "outward", kind: "gh issue \($a1)"}
        elif $a0 == "release" and ($a1 | test("^(create|delete|edit|upload|delete-asset)$")) then {class: "outward", kind: "gh release \($a1)"}
        elif $a0 == "repo" and ($a1 | test("^(create|delete|fork|edit|rename|archive|unarchive|sync|set-default|deploy-key)$")) then {class: "outward", kind: "gh repo \($a1)"}
        elif ($a0 | test("^(workflow|run)$")) and ($a1 | test("^(run|enable|disable|rerun|cancel|delete)$")) then {class: "outward", kind: "gh \($a0) \($a1)"}
        elif ($a0 | test("^(secret|variable)$")) then {class: "secrets", kind: "gh \($a0)"}
        elif ($a0 | test("^(gist|label|ssh-key|gpg-key|codespace|project|ruleset|cache)$")) and ($a1 | test("^(create|edit|delete|add|remove|upload|close|item-add|item-edit|item-delete|link|unlink)$")) then {class: "outward", kind: "gh \($a0) \($a1)"}
        elif $a0 == "auth" and (($a1 | test("^(token|login|refresh|setup-git|switch)$")) or ($line | test("--show-token"))) then {class: "secrets", kind: "gh auth"}
        elif $a0 == "api" and (($line | test("(^|[[:space:]])(-X|--method)[[:space:]=]*(POST|PATCH|PUT|DELETE)"; "i")) or ($s.args | any(test("^(-f|-F|--field|--raw-field|--input)$|^--(field|raw-field|input)=")))) then {class: "outward", kind: "gh api write"}
        else empty end else empty end),
      (if ($h | test("^(npm|pnpm|yarn|bun)$")) and ($a0 | test(publish_verbs)) then {class: "outward", kind: "\($h) \($a0)"} else empty end),
      (if $h == "docker" and (($a0 | test("^(push|login|logout)$")) or ($line | test("(^|[[:space:]])--push([[:space:]=]|$)"))) then {class: "outward", kind: "docker push"} else empty end),
      (if ($h | test("^(vercel|netlify|fly|flyctl|heroku|firebase|wrangler|railway|render|serverless|sls|eb|cdk|sam|amplify)$")) then {class: "outward", kind: "deploy (\($h))"} else empty end),
      (if ($h | test("^(slack|gog|mail|mailx|mutt|sendmail|msmtp|twilio|jira|acli|linear|osascript|terminal-notifier)$")) then {class: "outward", kind: "message (\($h))"} else empty end),
      (if ($h | test("^(curl|wget|http|https|xh|httpie)$")) then
        ($s | urls) as $u
        | if ($u | length) > 0 and ($u | all(is_local_url)) then empty
          elif ($line | test("(^|[[:space:]])(-X|--request|--method)[[:space:]=]*(POST|PUT|PATCH|DELETE)"; "i"))
            or ($s.args | any(test("^(-d|--data|--data-[a-z]+|-F|--form|--form-string|-T|--upload-file|--post-data|--post-file|--body-data|--body-file)(=|$)")))
            or (($h | test("^(http|https|xh|httpie)$")) and ($s.args | any(test("^(POST|PUT|PATCH|DELETE)$"; "i") or test("^[A-Za-z0-9_-]+(=|:=)"))))
          then {class: "outward", kind: "http write (\($h))"}
          else empty end
       else empty end),
      (if ($h | test("^(ssh|scp|sftp|mosh|telnet|nc|ncat|socat)$")) then {class: "elsewhere", kind: "another machine (\($h))"}
       elif $h == "rsync" and ($s.args | any(test("^[^/[:space:]]+:") and (test("://") | not))) then {class: "elsewhere", kind: "another machine (rsync)"}
       else empty end),
      (if (infra_heads | index($h)) and (($names | prod_word) or ($s.env | any(prod_word))) then {class: "production", kind: "\($h) against production"} else empty end),
      (if ($h | test("^(kubectl|helm|terraform|tofu|pulumi|argocd|ansible)$")) and ($a0 | test("^(apply|create|delete|edit|patch|replace|scale|rollout|set|label|annotate|drain|cordon|uncordon|taint|untaint|exec|cp|install|upgrade|uninstall|rollback|destroy|import|state|force-unlock|up|refresh|stack|config|sync|run|app)$")) or $h == "ansible-playbook"
       then {class: "production", kind: "\($h) \($a0)"} else empty end),
      (if $h == "az" and (($verbs[0] // "") | test("^(repos|boards|pipelines|devops|artifacts)$")) and (($verbs | any(cloud_mutation)) or (($verbs | index("invoke")) and ($line | test("--http-method[[:space:]=]*(POST|PUT|PATCH|DELETE)"; "i"))))
       then {class: "outward", kind: "az \($verbs[0:3] | join(" "))"}
       elif ($h | test("^(gcloud|az|aws|gsutil|doctl)$")) and (($verbs | any(cloud_mutation)) or (($verbs | index("invoke")) and ($line | test("--http-method[[:space:]=]*(POST|PUT|PATCH|DELETE)"; "i"))))
          or ($h == "bq" and ($a0 | test("^(query|load|rm|mk|update|insert|cp)$")))
       then {class: "production", kind: "\($h) change"} else empty end),
      (if ($h | test("^(psql|mysql|sqlcmd|pg_dump|pg_restore|redis-cli|mongosh|mongo)$")) and ($line | test("(^|[[:space:]])(-h|-H|-S|--host|--uri)([[:space:]=]|$)|://|@")) and ($line | test("localhost|127\\.0\\.0\\.1|::1|0\\.0\\.0\\.0|/tmp/|\\.s\\.PGSQL") | not)
       then {class: "production", kind: "\($h) on a remote host"} else empty end),
      (if ($h | test("^(op|vault|bw|lpass|pass|aws-vault|doppler|sops|gpg|keybase|printenv)$")) or ($h == "security" and ($a0 | test("^(find-|dump-|export|unlock|show-keychain|add-generic|add-internet|delete-)"))) or ($h == "env" and (.args | length) == 0)
       then {class: "secrets", kind: $h} else empty end),
      (if ($h == "gcloud" and ($line | test("auth (print-access-token|print-identity-token|application-default print)"))) or ($h == "az" and ($line | test("get-access-token"))) or ($h == "aws" and ($line | test("^(sts|configure get|secretsmanager|ssm get)")))
       then {class: "secrets", kind: "\($h) token"} else empty end),
      (if $h == "ldcli" then {class: "flags", kind: "ldcli"} else empty end),
      (if $h == "stripe" or (($h | test("^(gcloud|az|aws)$")) and ($line | test("(^|[[:space:]])(billing|budgets|ce|consumption)([[:space:]]|$)"))) then {class: "money", kind: $h} else empty end)
    ]
  | map(. + {seg: $s});

def text_classes($t; $u): # <names and paths> <URLs and command names>
  [ (if $t | secret_text then {class: "secrets", kind: "a secret's path"} else empty end),
    (if $u | flags_text then {class: "flags", kind: "the feature-flag service"} else empty end),
    (if $t | money_text then {class: "money", kind: "Stripe"} else empty end) ];

def file_tools: ["Write","Edit","MultiEdit","NotebookEdit","Read","Glob","Grep","LS"];
def write_tools: ["Write","Edit","MultiEdit","NotebookEdit"];
def tool_paths($R):
  [(.input.file_path // .input.notebook_path // .input.path // empty) | strings | select(. != "") | resolve($R.cwd; $R.user_home)];

# An MCP tool whose name says it reads, and does not say it writes.
def mcp_read_only: lc | test("(^|_)(get|list|search|read|query|view|fetch|show|describe|status|logs|health|snapshot|traffic)(_|$)")
  and (test("(^|_)(send|post|create|update|delete|remove|comment|publish|deploy|merge|upload|write|set|add|schedule|invite|share|transfer|pay|charge|refund|edit|draft|reply|forward|trash|archive|label|move|rename|revoke|rollback|promote|unset|apply|self|request|call|run|exec|execute)(_|$)") | not);
def mcp_classes:
  (.tool | lc) as $n
  | [ (if ($n | test("launch[-_ ]?darkly")) then {class: "flags", kind: .tool} else empty end),
      (if ($n | test("stripe|billing|payment|invoice|charge|refund")) then {class: "money", kind: .tool} else empty end),
      (if ($n | test("(^|_)(send|post|create|update|delete|remove|comment|publish|deploy|merge|upload|write|set|add|schedule|invite|share|transfer|pay|charge|refund|edit|draft|reply|forward|trash|archive|label|move|rename|revoke|rollback|promote|unset|apply|self)(_|$)")) then {class: "outward", kind: .tool} else empty end),
      (if ((.input | tostring) | prod_word) and ($n | test("(^|_)(get|list|search|read|query|view|fetch|show|describe|status|logs|health|snapshot|traffic)(_|$)") | not) then {class: "production", kind: .tool} else empty end) ];

# ---------------------------------------------------------------- grants

def value_flags: ["-b","--body","-F","--body-file","-t","--title","-R","--repo","-H","--head","-B","--base","-a","--assignee","-l","--label","-r","--reviewer","-m","--milestone","-p","--project","--subject","--match-head-commit","--author-email","-T","--template","-e","--editor"];
def positionals: reduce .[] as $w ({out: [], skip: false};
  if .skip then .skip = false
  elif ($w | startswith("-")) then (if (value_flags | index($w)) then .skip = true else . end)
  else .out += [$w] end) | .out;
def no_repo_flag: .args | any(test("^(-R|--repo)(=|$)")) | not;
# gh pr <verb> [<the task's branch>] without -R: no target means the current branch's PR.
def gh_target_ok($b; $cur): (.args[2:] | positionals | first // "") as $t | no_repo_flag and $b != "" and (($t == "" and $cur == $b) or $t == $b);

def push_ok($b; $cur):
  .g.sargs as $a
  | [$a[] | select(startswith("-"))] as $flags | [$a[] | select(startswith("-") | not)] as $pos
  | $b != "" and ((.seg.args[0] // "") == "push") # nothing before the subcommand: no -C, -c, --git-dir
    and ($flags | all(test("^(-u|--set-upstream|-q|--quiet|-v|--verbose|--porcelain|-n|--dry-run|--no-verify|--progress)$")))
    and (($pos | length) <= 2) and (($pos[0] // "origin") | test("^[A-Za-z0-9._-]+$"))
    and (if ($pos | length) < 2 then $cur == $b
         else ($pos[1] | IN($b, "HEAD:" + $b, $b + ":" + $b, "HEAD:refs/heads/" + $b, "refs/heads/" + $b, $b + ":refs/heads/" + $b)) end);

def grant_for($R; $grants): # one outward match -> the grant that covers it, or null
  . as $m | $R.branch as $b | $R.current_branch as $cur | .seg as $s
  | if $m.kind == "git-push" and ($grants | index("push-branch")) and ($m | push_ok($b; $cur)) then "push-branch"
    elif ($m.kind | IN("gh-pr-edit", "gh-pr-ready")) and ($grants | index("open-pr")) and ($s | gh_target_ok($b; $cur)) then "open-pr"
    elif $m.kind == "gh-pr-create" and ($grants | index("open-pr")) and ($s | no_repo_flag) and $b != ""
         and (($s.args | join(" ")) as $l | if ($l | test("(^|[[:space:]])(-H|--head)([[:space:]=]|$)")) then ($l | test("(^|[[:space:]])(-H|--head)[[:space:]=]+" + ($b | esc) + "([[:space:]]|$)")) else $cur == $b end)
      then "open-pr"
    elif $m.kind == "gh-pr-merge" and ($grants | index("merge-auto")) and ($s.args | index("--auto")) and ($s.args | any(IN("--squash", "-s")))
         and ($s.args | any(test("^(--admin|--merge|-m|--rebase|-r|--delete-branch|-d|--body|-b|--body-file|-F|--subject|-t)(=|$)")) | not) and ($s | gh_target_ok($b; $cur))
      then "merge-auto"
    elif $m.kind == "gh-pr-comment" and ($grants | index("comment-pr")) and ($s | gh_target_ok($b; $cur)) then "comment-pr"
    else null end;

# ---------------------------------------------------------------- prod-read: calls that only read

# The positional words of a command's args, past its flags and the values of <valued> flags.
def pos_words($valued): reduce .[] as $w ({out: [], skip: false};
  if .skip then .skip = false
  elif ($w | startswith("-")) then (if ($w | contains("=") | not) and ($valued | index($w)) then .skip = true else . end)
  else .out += [$w] end) | .out;
# A word that is only a variable ($OPTS, ${M}): it could expand to anything, a method or a body.
def bare_var: test("^\\$(\\{[^}]*\\}|[A-Za-z_][A-Za-z0-9_]*)$");

# curl: no method but GET or HEAD, no body, no upload, no config file. Fails closed: a method or
# word it cannot read is not a read.
def curl_reads: .args as $a
  | ([range(0; $a | length) as $i | select($a[$i] | test("^(-[A-Za-z]*X|--request)$")) | $a[$i + 1] // ""]
     + [$a[] | select(test("^-[A-Za-z]*X.") or startswith("--request=")) | sub("^(-[A-Za-z]*X|--request=)"; "")]) as $methods
  | ($methods | all(test("^(GET|HEAD)$"; "i")))
    and ($a | any(test("^(--data|--data-[a-z]+|--form|--form-string|--upload-file|--json|--config|--post[0-9]*)(=|$)")
                  or test("^-[A-Za-z]*[dFTK]") or bare_var) | not);
# The files curl writes: -o/-D/-c and their long forms, --output-dir, and the like. (-O and -J
# write into the current directory, which the local rule keeps inside the work roots.)
def curl_out_files: .args as $a
  | [range(0; $a | length) as $i | $a[$i] as $w
     | if ($w | test("^-[A-Za-z]*[oDc]$")) then $a[$i + 1] // ""
       elif ($w | test("^-[A-Za-z]*[oDc].")) and ($w | startswith("--") | not) then $w | sub("^-[A-Za-z]*?[oDc]"; "")
       elif ($w | test("^--(output|dump-header|cookie-jar|output-dir|trace|trace-ascii|stderr|libcurl|etag-save|hsts|alt-svc)$")) then $a[$i + 1] // ""
       elif ($w | test("^--(output|dump-header|cookie-jar|output-dir|trace|trace-ascii|stderr|libcurl|etag-save|hsts|alt-svc)=")) then $w | sub("^--[a-z-]+="; "")
       else empty end];
def kubectl_valued: ["-n","--namespace","--context","--cluster","--user","-s","--server","--kubeconfig","--token","--as","--as-group","-l","--selector","-o","--output","-c","--container","--field-selector","--since","--since-time","--tail","--sort-by","--request-timeout","--template","--chunk-size"];
# kubectl: a verb that reads, past -n/--context and the like; never a secret's value or the raw
# kubeconfig.
def kubectl_reads: (.args | pos_words(kubectl_valued)) as $p | ($p[0] // "") as $v | ($p[1] // "") as $v1
  | (($v | IN("get", "describe", "logs", "top", "explain", "version", "api-resources", "api-versions", "cluster-info", "events"))
     or ($v == "config" and ($v1 | IN("view", "get-contexts", "current-context", "get-clusters", "get-users")))
     or ($v == "auth" and $v1 == "can-i")
     or ($v == "rollout" and ($v1 | IN("status", "history"))))
    # never a secret, by name or by path (get --raw /api/v1/.../secrets/x), nor the raw kubeconfig
    and (.args | any(test("secret"; "i") or startswith("--raw")) | not)
    # a bare $X could name a secret or add --raw; after logs, top, events or rollout it cannot
    and (($v | IN("logs", "top", "events", "rollout")) or (.args | any(bare_var) | not));
# gcloud: groups, then a verb that reads (describe, list, get-credentials, logging read, ...), and
# no word that changes anywhere on the line (run and deploy are also group names before the verb:
# gcloud run services describe), nor a word before the verb the line cannot read (`gcloud $G list`
# could be any command).
def gcloud_reads: [.args[] | select((startswith("-") or test("[[:space:]]")) | not)] as $w
  | ([range(0; $w | length) | select($w[.] | test("^(describe|list|list-[a-z-]+|get-credentials|get-iam-policy|get-value|read|tail)$"))] | first) as $i
  | $i != null
    and ([range(0; $w | length) as $k | $w[$k] | select(cloud_mutation and (($k < $i and IN("run", "deploy")) | not))] | length) == 0
    and ($w[0:$i] | any(test("[$`]")) | not)
    and (.args[0:(.args | index($w[$i]))] | any(bare_var) | not);
# (Never a command fed its words by xargs, which could be anything. wget and httpie are not
# covered: they save files by default.)
def seg_reads:
  if .sudo or .xargs then false
  elif .head == "curl" then curl_reads
  elif .head == "kubectl" then kubectl_reads
  elif .head == "gcloud" then gcloud_reads
  else false end;

# The commands a production or flags match stands for: its own, or for a flag-service URL (a text
# match, with no command of its own) every command whose URL names the service.
def match_segs($segs): if .seg != null then [.seg] else [$segs[] | select(([.head] + urls) | join(" ") | flags_text)] end;
# Under prod-read a kubectl or gcloud read is covered wherever it points (which cluster or project
# is production is not on the line). A curl read is covered only as a production or flags match's
# command: a GET to any host could carry data out in its URL.
def cloud_reads($segs): [$segs[] | select(.head | IN("kubectl", "gcloud")) | select(seg_reads)];

# ---------------------------------------------------------------- local

def git_readonly:
  git_sub as $g
  | ($g.sub | test("^(status|log|diff|show|blame|grep|ls-files|ls-tree|rev-parse|rev-list|describe|cat-file|shortlog|merge-base|for-each-ref|show-ref|reflog|name-rev|count-objects|version|help)$"))
    or (($g.sub | IN("branch", "tag")) and ($g.sargs | map(select(startswith("-") | not)) | length) == 0
        and ($g.sargs | any(test("^-(d|D|m|M|c|C|f)$|^--(delete|move|copy|force|set-upstream-to|unset-upstream|edit-description)")) | not))
    or ($g.sub == "stash" and (($g.sargs[0] // "") | IN("list", "show")))
    or ($g.sub == "worktree" and (($g.sargs[0] // "") == "list"))
    or ($g.sub == "remote" and (($g.sargs[0] // "-v") | IN("-v", "show", "get-url")));

# Commands that only read: their paths may be anywhere (a secret's path was carded before this).
def ro_heads: ["ls","cat","head","tail","wc","grep","egrep","fgrep","rg","ag","diff","cmp","comm","stat","file","du","df","tree","less","more","od","hexdump","xxd","strings","md5","md5sum","shasum","sha1sum","sha256sum","find","fd","which","type","basename","dirname","realpath","readlink","echo","printf","test","[","[[","]]","jq","yq","sort","uniq","cut","tr","awk","gawk","sed","paste","join","column","fold","nl","rev","tac","lsof","ps","pgrep","whoami","id","hostname","uname","sw_vers","nproc","date","sleep","pwd","true","false",":","export","unset","set","local","read","wait","exit","return","break","continue","shift","for","case","esac","in","done","fi","then","do","seq","bc","expr","uptime","git","gh","chartroom"];
def seg_readonly:
  .head as $h | (ro_heads | index($h)) != null
  and (.head != "find" or (.args | any(test("^-(delete|exec|execdir|ok|okdir|fprint|fprintf|fls)$")) | not))
  and (.head != "fd" or (.args | any(test("^(-x|-X|--exec|--exec-batch)$")) | not))
  and (.head != "sed" or (.args | any(test("^-[a-zA-Z]*i|^--in-place")) | not))
  and (((.head | IN("awk", "gawk")) | not) or (.args | any(test("inplace|system")) | not))
  and (.head != "git" or git_readonly)
  and (.head != "gh" or ((.args[0] // "") as $a0 | (.args[1] // "") as $a1
       | (($a0 | test("^(pr|issue|run|release|repo|workflow|search|status|label|cache|ruleset|project|gist)$")) and ($a1 | test("^(view|list|checks|diff|status|watch|download|ls)$")))
         or ($a0 == "api" and ((.args | join(" ")) | test("(-X|--method)[[:space:]=]*(POST|PATCH|PUT|DELETE)|(^|[[:space:]])(-f|-F|--field|--raw-field|--input)([[:space:]=]|$)"; "i") | not))
         or ($a0 == "auth" and $a1 == "status" and ((.args | join(" ")) | test("--show-token") | not))))
  and (.head != "chartroom" or ((.args[0] // "") | test("^(event|status|ls|show|peek|board|todo|version|help|resolve|doctor)$")));

# Commands that change only their own paths, which must be inside the work roots.
def rw_heads: ["mkdir","touch","cp","mv","rm","rmdir","ln","chmod","tee","tar","zip","unzip","gzip","gunzip","bzip2","xz","zcat","patch","mktemp","sed","awk","gawk","base64","sqlite3","kill","git","node","npx","bunx","bun","npm","pnpm","yarn","deno","tsx","ts-node","tsc","python","python3","pip","pip3","uv","uvx","poetry","pytest","ruby","bundle","rake","go","cargo","rustc","make","cmake","ninja","bats","shellcheck","shfmt","eslint","prettier","vitest","jest","playwright","dotnet","java","javac","mvn","gradle","swift","perl","curl","wget","open","pbcopy","pbpaste","yes","envsubst"];
def mutating: ["rm","mv","cp","ln","chmod","tee","touch","mkdir","rmdir","patch","sed","perl"];

# $VAR and ${VAR} replaced by the values a line assigned before (S=/tmp/x; cat $S/a), $HOME and
# $PWD; what is left with a $ in it is not trusted.
def expand_vars($v): reduce ($v | keys[]) as $k (.; if $v[$k] == null then . else gsub("\\$\\{?" + $k + "\\}?(?![A-Za-z0-9_])"; $v[$k]) end);
def assign($v; $kv):
  ($kv | capture("^(?<k>[A-Za-z_][A-Za-z0-9_]*)=(?<v>.*)$")) as $a
  | if ($a.v | test("`|\\$\\(")) then .[$a.k] = null else .[$a.k] = ($a.v | expand_vars($v)) end;

# Every command of the line is local, except the <covered> ones a grant already answers for (their
# redirects are still checked).
def bash_local($R; $covered):
  (work_roots($R)) as $wr
  | (.input.command // "") as $cmd
  | ($cmd | segments) as $segs
  | ($R.cwd | under_any($wr)) and ($segs | length) > 0
    and (reduce $segs[] as $s ({cwd: $R.cwd, ok: true, v: {HOME: $R.user_home}};
      .v.PWD = .cwd
      # assignments: VAR=value on its own (not a VAR=value prefix, which its own words do not see),
      # or after export
      | reduce (($s.env[]? | select($s.head == "")), (if $s.head == "export" then $s.args[] | select(test("^[A-Za-z_][A-Za-z0-9_]*=")) else empty end)) as $kv (.; .v = (.v | assign(.; $kv)))
      | (.v) as $vars | (.cwd) as $c0
      # its redirects, with the line's variables
      | if (.ok | not) then .
        elif ($s.redirs | any(expand_vars($vars) | (test("[$`]")) or (resolve($c0; $R.user_home) | under_any($wr + dev_roots) | not))) then .ok = false
        elif $s.head == "" or $s.head == "export" then .
        # A command a grant covers: only the files it writes are still checked (curl -o).
        elif any($covered[]; . == $s) then
          (if ($s | curl_out_files | all(expand_vars($vars) | (test("[$`]") | not) and (resolve($c0; $R.user_home) | under_any($wr + dev_roots)))) then . else .ok = false end)
        else
          ($s | .path |= expand_vars($vars) | .args |= map(expand_vars($vars))) as $s
          | if false then .
      elif ($s.head | IN("cd", "pushd")) then
        ($s.args | map(select(startswith("-") | not)) | first // "~") as $d | .cwd as $c
        | if ($d | test("[$`]")) or $d == "-" then .ok = false
          else ($d | resolve($c; $R.user_home)) as $n | if ($n | under_any($wr)) then .cwd = $n else .ok = false end end
      elif ($s.head == "popd") or ($s.path | test("[$`]")) then .ok = false
      elif ($s | seg_readonly) then .
      # A command that changes things, given a word the line cannot resolve ($X, $(...)): unknown.
      elif ($s.args | any(test("[$`]") and (test("[[:space:]]") | not))) then .ok = false
      # A script or binary inside the work roots (scripts/check.sh, ./gradlew, bin/tool): the
      # worktree's own code, like `node script.js`; its path arguments are still checked below.
      elif (.cwd as $c | ($s.path | test("/")) and ($s.path | resolve($c; $R.user_home) | under_any($wr)) and ($R.worktree != "")) | not and (rw_heads | index($s.head)) == null then .ok = false
      elif $s.xargs and (mutating | index($s.head)) then .ok = false
      # Code given inline (python3 -c, node -e, a heredoc or stdin) is code this policy cannot read:
      # it could push or deploy as easily as a script could. (A script file in the worktree still
      # passes, like the tests the brief allows: that is the worktree's own code.)
      elif ($s.head | test("^(python[0-9.]*|node|nodejs|deno|bun|tsx|ts-node|ruby|perl|php|lua|osascript|Rscript)$"))
           and (($s.args | any(test("^(-c|-e|-E|-p|--eval|--print|-r|--require|-|eval|-pe|-ne|-lne|-le)$") or startswith("<<")))
                or ($s.args | length) == 0)
        then .ok = false
      # git told to run something else (an alias, a config, an environment override), or deleting
      # what other worktrees share: refs and the stash.
      elif $s.head == "git" and (($s.args | any(test("^(-c|--config-env|--exec-path)(=|$)") or startswith("--git-dir") or startswith("--work-tree")))
           or ($s.env | any(test("^GIT_"))))
        then .ok = false
      elif $s.head == "git" and ($s | git_sub | (.sub == "branch" and (.sargs | any(test("^(-d|-D|--delete|-m|-M|--move|-f|--force)$"))))
           or (.sub == "stash" and ((.sargs[0] // "") | IN("drop", "pop", "clear")))
           or (.sub == "tag" and (.sargs | any(test("^(-d|--delete|-f|--force)$"))))
           or (.sub == "worktree" and ((.sargs[0] // "") | IN("remove", "prune", "move")))
           or (.sub | IN("update-ref", "reflog", "gc", "prune", "replace", "notes")))
        then .ok = false
      elif $s.head == "git" and ($s | git_sub | .sub | test("^(push|remote|config|send-email|request-pull|credential|filter-branch|filter-repo|lfs|daemon|svn|p4)$")) then .ok = false
      elif ($s.head | test("^(npm|pnpm|yarn|bun)$")) and (($s.args[0] // "") | test(publish_verbs)) then .ok = false
      elif ($s.head | IN("curl", "wget")) and (($s | urls) as $u | ($u | length) == 0 or ($u | all(is_local_url) | not)) then .ok = false
      elif $s.head == "open" and ($s.args | all(startswith("-") or is_local_url) | not) then .ok = false
      elif (.cwd as $c | $s | path_args | all((test("[$`]") | not) and (resolve($c; $R.user_home) | under_any($wr + dev_roots)))) | not then .ok = false
      else . end
        end) | .ok);
def bash_local($R): bash_local($R; []);

# ---------------------------------------------------------------- the decision

def decide:
  . as $q
  | (.roots + {cwd: (.cwd // .roots.worktree), branch: (.branch // ""), current_branch: (.current_branch // "")}) as $R
  | (.tool // "") as $tool | (.input // {}) as $in
  | ($q | tool_paths($R)) as $paths
  | (if $tool == "Bash" then ($in.command // "") else "" end) as $cmd
  | (if $tool == "Bash" then ($cmd | segments) else [] end) as $segs
  # What the text checks (secrets, flags, money) read: for Bash the commands, their words and
  # URLs, never quoted phrases or heredoc bodies (a commit message, a script's text). A web search
  # or fetch reads and changes nothing, so the words it carries are never a class.
  | (if $tool == "Bash" then [$segs[] | .path, (.args[] | select(test("[[:space:]]") | not)), .redirs[]] | join(" ")
     elif (file_tools | index($tool)) then $paths | join(" ")
     elif ($tool | startswith("mcp__")) then ($in | tostring)
     else "" end) as $text
  # The flag service is reached by its CLI, its API's URL or an MCP tool, not by a path, a search
  # pattern or a read-only MCP tool's input that names it.
  | (if $tool == "Bash" then [$segs[] | .head, (urls[])] | join(" ")
     elif ($tool | startswith("mcp__")) and ($tool | mcp_read_only | not) then $text
     else "" end) as $utext
  | ([$segs[] | .redirs[] | select(test("[$`]") | not) | resolve($R.cwd; $R.user_home)]) as $redir
  # What a Bash line writes: its redirects, and the paths of commands that change files.
  | ($redir + [$segs[] | select((.head | IN("rm", "mv", "cp", "ln", "chmod", "chown", "tee", "touch", "mkdir", "rmdir", "patch", "truncate", "dd", "install", "rsync", "tar", "unzip"))
                         or (.head == "sed" and (.args | any(test("^-[a-zA-Z]*i|^--in-place"))))
                         or (.head == "perl" and (.args | any(test("^-[a-zA-Z]*i")))))
                | path_args[], (.args[] | select((startswith("-") or test("[[:space:]/]")) | not) | select(test("[$`]") | not))
                | select(test("[$`]") | not) | resolve($R.cwd; $R.user_home)]) as $wpaths
  # A script that names a control file (python3 - <<EOF ... meta.json): the commander's look.
  | ($tool == "Bash" and ($segs | any(.head | test("^(python3?|node|ruby|perl|bash|sh|zsh|jq)$")))) as $interp
  | ((($q.grants // []) | index("prod-read")) != null) as $prodread
  # 1. guards
  | if ($R.permits // "") != "" and (($cmd | contains($R.permits)) or ($paths | any(under($R.permits))) or (($tool | startswith("mcp__")) and ($text | contains($R.permits))))
      then {verdict: "deny", rule: "guard:store", why: "touches chartroom's permit store"}
    elif $segs | any(.args as $a | ([.head] + $a) as $w | any(range(0; ($w | length) - 1); $w[.] == "permit" and ($w[. + 1] | IN("answer", "grant", "revoke"))))
      then {verdict: "deny", rule: "guard:self-answer", why: "answers or grants a chartroom permission"}
    elif ((write_tools | index($tool)) and ($paths | any(IN(control_files($R)[]))))
      or ($wpaths | any(IN(control_files($R)[])))
      then {verdict: "deny", rule: "guard:controls", why: "rewrites the task's own control files"}
    elif ($tool | IN("AskUserQuestion", "ExitPlanMode")) then {verdict: "none", rule: "question", why: "a question, not a permission"}
    elif $q.event == "denied" then {verdict: "none", rule: "denied", why: "recorded"}
    # 2. a one-time pre-approval
    elif $q.pre != null then {verdict: "allow", rule: "preapproved:\($q.pre)", why: "the commander allowed exactly this call"}
    else
      ([$q.always[]? | select(.tool == $tool) | select(
          # A prefix or glob pattern covers one plain command only: never a line that chains,
          # substitutes or redirects another command onto it (`npm test && git push ...`).
          if $tool == "Bash" then (.pattern as $p
            | ($cmd | test("[;&|`\n<>]|\\$\\(") | not) as $plain
            | if ($p | endswith(":*")) then $plain and ($segs | length) == 1 and ($cmd == $p[:-2] or ($cmd | startswith($p[:-2] + " ")))
              elif ($p | contains("*")) then $plain and ($segs | length) == 1 and ($cmd | test("^" + ($p | split("*") | map(esc) | join(".*")) + "$"))
              else $cmd == $p end)
          elif (file_tools | index($tool)) then ($paths | index(.pattern)) != null
          else .pattern == "sig:\($q.sig)" end)] | first) as $a
      # 3. always for this task
      | if $a != null then {verdict: "allow", rule: "always:\($a.from)", why: "the commander said always for this task"}
        else
          # 4. commander classes
          ( [$segs[] | seg_classes[]]
            + text_classes($text; $utext)
            + (if ($tool | startswith("mcp__")) then ($q | mcp_classes) else [] end)
            + (if (write_tools | index($tool)) and ($paths | any(under_any(control_tree($R)))) then [{class: "controls", kind: "the worker's own settings or hooks"}] else [] end)
            + (if ($wpaths | any(under_any(control_tree($R)))) then [{class: "controls", kind: "the worker's own settings or hooks"}] else [] end)
            + (if $interp and (control_files($R) | any(. as $f | $cmd | contains($f))) and ($cmd | test(">|write|dump|open\\([^)]*[\"']w")) then [{class: "controls", kind: "a script that may rewrite the task's control files"}] else [] end)
            # The machine's task store (lib/store.sh), which holds a store task's record.
            # (Its own path, or that path under ~: never the bare name, which code and tests use.)
            + (if $tool == "Bash" and ($R.db // "") != "" and (($cmd | contains($R.db))
                 or (($R.user_home // "") != "" and ($R.db | startswith($R.user_home + "/")) and ($cmd | contains("~" + ($R.db | ltrimstr($R.user_home))))))
               then [{class: "controls", kind: "chartroom's task store"}] else [] end)
            + (if (write_tools | index($tool)) and ($paths | any(under_any(work_roots($R)) | not)) then [{class: "elsewhere", kind: "a file outside the worktree"}] else [] end)
            + (if ($redir | any(under_any(work_roots($R) + dev_roots) | not)) then [{class: "elsewhere", kind: "a write outside the worktree"}] else [] end)
          ) as $m
          | if ($m | length) > 0 then
              # Each match needs a grant that covers it: an outward one by its own grant, a production
              # or flags one by prod-read when its commands only read. Then the line's other
              # commands must be ones the local rule would pass, so a grant never carries an
              # unread command along (`git push origin <branch>; rm -rf ~/x`).
              [$m[] | if .class == "outward" then {g: grant_for($R; $q.grants // []), segs: [.seg]}
                elif $tool == "Bash" and (.class | IN("production", "flags")) and (($q.grants // []) | index("prod-read"))
                     and (match_segs($segs) as $ms | ($ms | length) > 0 and ($ms | all(seg_reads)))
                  then {g: "prod-read", segs: match_segs($segs)}
                else {g: null} end] as $c
              | if ($c | all(.g != null)) and ($tool != "Bash" or ($q | bash_local($R; [$c[].segs[]] + (if $prodread then cloud_reads($segs) else [] end))))
                  then {verdict: "allow", rule: "grant:\([$c[].g] | unique | join(","))", why: "the task's grant covers it"}
                else ([$m[] | select(.class != "outward")] + [$m[] | select(.class == "outward")] | first) as $f
                  | {verdict: "card", rule: "commander:\($f.class)", why: $f.kind}
                end
            # 5. local, only for a prompt Claude would show
            elif $q.event == "pre-tool" then {verdict: "none", rule: "none", why: ""}
            elif (file_tools | index($tool)) and ($paths | length) > 0 and ((write_tools | index($tool)) == null or ($paths | all(under_any(work_roots($R)))))
              then {verdict: "allow", rule: "local:files", why: "inside the worktree"}
            elif $tool == "Bash" and ($q | bash_local($R)) then {verdict: "allow", rule: "local:bash", why: "inside the worktree"}
            elif $tool == "Bash" and $prodread and (cloud_reads($segs) | length) > 0 and ($q | bash_local($R; cloud_reads($segs)))
              then {verdict: "allow", rule: "grant:prod-read", why: "the task's grant covers it"}
            elif $tool == "WebSearch" then {verdict: "allow", rule: "local:search", why: "a web search reads only"}
            else {verdict: "card", rule: "commander:unlisted", why: "no rule covers it"}
            end
        end
    end;

decide
