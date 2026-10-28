-- PostToolUse hook (.claude/settings.json): run stylua over a Lua file
-- an agent just edited, in the paths `make format` covers, so `make lint`
-- doesn't fail on formatting at the end. Does nothing without stylua.
--
--   nvim --headless --clean -l .claude/hooks/format_lua.lua < input.json
local FORMATTED = {
  "lua/",
  "plugin/",
  "ftplugin/",
  "syntax/",
  "tests/",
  "scripts/site/",
  "scripts/playground/",
  "scripts/verify/",
  ".claude/hooks/",
}

local ok, input = pcall(vim.json.decode, io.read("*a") or "")
local path = ok and type(input) == "table" and type(input.tool_input) == "table" and input.tool_input.file_path
if type(path) ~= "string" or not path:match("%.lua$") or vim.fn.executable("stylua") ~= 1 then
  os.exit(0)
end
local root = vim.fs.normalize(vim.env.CLAUDE_PROJECT_DIR or vim.fn.getcwd())
local abs = vim.fs.normalize(path)
if not vim.startswith(abs, root .. "/") then
  os.exit(0)
end
local rel = abs:sub(#root + 2)
for _, prefix in ipairs(FORMATTED) do
  if vim.startswith(rel, prefix) then
    local res = vim.system({ "stylua", rel }, { cwd = root }):wait()
    if res.code ~= 0 then
      -- a syntax error: tell the agent, don't block
      io.stderr:write("stylua: " .. (res.stderr or "") .. "\n")
    end
    break
  end
end
os.exit(0)
