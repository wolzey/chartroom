# Adapt agy's tool contract to the shared policy. Keep every original argument in the
# signature/card so a one-time answer cannot authorize different content or commands.
# Native 1.5.18 tools and the legacy tool names documented by Google are both supported.
# Everything else (MCP, browser, task input, subagents, new tools) remains unlisted.
def required_string: select(type == "string" and length > 0);
.toolCall.name as $name | .toolCall.args as $args
| select(($name | type) == "string" and ($args | type) == "object")
| (if $name == "run_command" then
     {tool: "Bash", input: {command: ($args.CommandLine | required_string)}}
   elif $name | IN("read_file", "view_file") then
     {tool: "Read", input: {file_path: ((if $name == "read_file" then $args.Path else $args.AbsolutePath end) | required_string)}}
   elif $name | IN("write_file", "write_to_file", "edit_file", "replace_file_content", "multi_replace_file_content") then
     {tool: (if $name | IN("write_file", "write_to_file") then "Write" else "Edit" end),
      input: {file_path: ((if $name | IN("write_file", "edit_file") then $args.Path else $args.TargetFile end) | required_string)}}
   elif $name == "list_dir" then
     {tool: "LS", input: {path: ($args.DirectoryPath | required_string)}}
   elif $name == "find_by_name" then
     {tool: "Glob", input: {path: ($args.SearchDirectory | required_string)}}
   elif $name == "grep_search" then
     {tool: "Grep", input: {path: ($args.SearchPath | required_string)}}
   elif $name == "search_web" then {tool: "WebSearch", input: {}}
   elif $name == "ask_question" then {tool: "AskUserQuestion", input: {}}
   else {tool: ("agy:" + $name), input: {}} end) as $mapped
| {tool_name: $mapped.tool,
   tool_input: ($args + $mapped.input + {agy_tool: $name, description: ($args.Description // $args.toolSummary // "")}),
   chartroom_agent: "agy", session_id: .conversationId}
  # Never use workspacePaths[0] as cwd: --add-dir can put the task record first. The
  # recorded worktree is the default. Only run_command's explicit Cwd overrides it.
  + (if $name == "run_command" and ($args.Cwd // "") != "" then {cwd: ($args.Cwd | required_string)} else {} end)
