# Adapt agy's tool contract to the shared policy. Keep every original argument in the
# signature/card so a one-time answer cannot authorize different content or commands.
# Native 1.5.18 tools and the legacy tool names documented by Google are both supported.
# manage_task's captured TaskId is <conversationId>/task-N, never an arbitrary PID.
# Everything else (MCP, browser, new tools) remains unlisted; bypass blocks delegation below.
def required_string: select(type == "string" and length > 0);
# A legacy runtime may ignore Path; do not let a decoy Path hide its actual target.
def path_alias($native; $legacy):
  select($native == null or $legacy == null or $native == $legacy)
  | ($native // $legacy | required_string);
def own_task($conversation): type == "string" and startswith($conversation + "/")
  and (ltrimstr($conversation + "/") | test("^[A-Za-z0-9_-]+$"));
.toolCall.name as $name | .toolCall.args as $args | .conversationId as $conversation
| select(($name | type) == "string" and ($args | type) == "object")
| select($name != "manage_task" or ((.conversationId | type) == "string" and (.conversationId | length) > 0))
| (if $name == "run_command" then
     {tool: "Bash", input: {command: ($args.CommandLine | required_string)}}
   elif $name | IN("read_file", "view_file") then
     {tool: "Read", input: {file_path: ((if $name == "read_file" then $args.Path else $args.AbsolutePath end) | required_string)}}
   elif $name | IN("write_file", "write_to_file", "edit_file", "replace_file_content", "multi_replace_file_content") then
     {tool: (if $name | IN("write_file", "write_to_file") then "Write" else "Edit" end),
      input: {file_path: ((if $name | IN("write_file", "edit_file") then $args.Path else $args.TargetFile end) | required_string)}}
   elif $name == "list_dir" then
     {tool: "LS", input: {path: path_alias($args.Path; $args.DirectoryPath)}}
   elif $name == "find_by_name" then
     {tool: "Glob", input: {path: path_alias($args.Path; $args.SearchDirectory)}}
   elif $name == "grep_search" then
     {tool: "Grep", input: {path: path_alias($args.Path; $args.SearchPath)}}
   elif $name == "manage_task" and $args.Action == "send_input" then
     select($args.TaskId | own_task($conversation))
     | {tool: "Bash", input: {command: ($args.Input | required_string)}}
   elif $name == "manage_task" and ($args.Action | IN("status", "list", "output", "kill")) then
     select($args.Action == "list" or ($args.TaskId | own_task($conversation)))
     | {tool: "agy:own-task", input: {}}
   elif $name == "search_web" then {tool: "WebSearch", input: {}}
   elif $name == "ask_question" then {tool: "AskUserQuestion", input: {}}
   else {tool: ("agy:" + $name), input: {}} end) as $mapped
| {tool_name: $mapped.tool,
   tool_input: ($args + $mapped.input + {agy_tool: $name, description: ($args.Description // $args.toolSummary // "")}),
   chartroom_agent: "agy", session_id: .conversationId}
  # Never use workspacePaths[0] as cwd: --add-dir can put the task record first. The
  # recorded worktree is the default. Only run_command's explicit Cwd overrides it.
  + (if $name == "run_command" and ($args.Cwd // "") != "" then {cwd: ($args.Cwd | required_string)} else {} end)
