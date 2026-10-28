-- PreToolUse hook (.claude/settings.json): refuse an agent's Edit / Write
-- of a file that only a make target may write (AGENTS.md: golden files
-- and Emacs fixtures are regenerated, never edited by hand). The tool's
-- input comes as JSON on stdin; exit status 2 blocks the call and shows
-- stderr to the agent.
--
--   nvim --headless --clean -l .claude/hooks/guard_generated.lua < input.json
local GENERATED = {
  { "tests/fixtures/screen/", "make snapshots (check the golden file diff)" },
  { "tests/fixtures/emacs/", "make parity-fixtures (needs Emacs with Org, scripts/emacs-parity/README.md)" },
  { "docs/playground/", "make playground" },
  { "doc/tags", "the helptags the build makes" },
}

local ok, input = pcall(vim.json.decode, io.read("*a") or "")
local path = ok and type(input) == "table" and type(input.tool_input) == "table" and input.tool_input.file_path
if type(path) ~= "string" then
  os.exit(0)
end
local rel = vim.fs.normalize(path)
local root = vim.env.CLAUDE_PROJECT_DIR and vim.fs.normalize(vim.env.CLAUDE_PROJECT_DIR)
if root and vim.startswith(rel, root .. "/") then
  rel = rel:sub(#root + 2)
end
for _, g in ipairs(GENERATED) do
  if vim.startswith(rel, g[1]) then
    io.stderr:write(("%s is generated: write it with %s, not by hand.\n"):format(rel, g[2]))
    os.exit(2)
  end
end
os.exit(0)
