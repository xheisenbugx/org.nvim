-- Demo config for docs/media/tapes/code.tape: init.lua plus the code
-- extension, and a small git repository in $ORG_DEMO_DIR/app (branch
-- feature/login) with TODO comments and its project file .org/tasks.org.
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
dofile(here .. "/init.lua")

local dir = (vim.env.ORG_DEMO_DIR or "/tmp/org-nvim-demo") .. "/app"
vim.fn.mkdir(dir .. "/src", "p")
vim.fn.mkdir(dir .. "/.org", "p")
vim.fn.writefile({
  "local M = {}",
  "",
  "-- TODO: read the port from the environment",
  "M.port = 8080",
  "",
  "--- Greet a user who logged in.",
  "function M.greet(name)",
  "  -- FIXME(org:login-flow): escape the name",
  '  return "Hello, " .. name .. "!"',
  "end",
  "",
  "--- Start the server.",
  "function M.start(name)",
  "  local greeting = M.greet(name)",
  "  print(greeting)",
  "  return greeting",
  "end",
  "",
  "return M",
}, dir .. "/src/app.lua")
vim.fn.writefile({
  "local M = {}",
  "",
  "-- HACK: retry until the socket is free",
  "function M.wait(sock)",
  "  return sock",
  "end",
  "",
  "return M",
}, dir .. "/src/net.lua")
vim.fn.writefile({
  "#+title: app",
  "",
  "* Tasks",
  "** TODO Login flow",
  "   SCHEDULED: <" .. os.date("%Y-%m-%d %a") .. ">",
  "   :PROPERTIES:",
  "   :ID:       login-flow",
  "   :BRANCH:   feature/login",
  "   :END:",
}, dir .. "/.org/tasks.org")
local function git(args)
  local cmd = { "git", "-C", dir, "-c", "user.name=Demo", "-c", "user.email=demo@example.com" }
  vim.list_extend(cmd, { "-c", "commit.gpgsign=false" })
  vim.list_extend(cmd, args)
  vim.system(cmd):wait()
end
git({ "init", "-q", "-b", "main" })
git({ "add", "." })
git({ "commit", "-q", "-m", "Start the app" })
git({ "checkout", "-q", "-b", "feature/login" })

local opts = vim.deepcopy(require("org.config").opts)
opts.extensions = { code = { link_path = "relative" } }
require("org").setup(opts)
vim.cmd.cd(dir)
