-- Startup cost: setup() must not load the heavy modules (parser, agenda,
-- capture, babel) nor define the highlight groups; those happen on first
-- use. Each case runs in a fresh Neovim, since this test process has long
-- loaded everything.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")

-- Run `body` (Lua) in a fresh `nvim --clean` with org.nvim on the
-- runtimepath; `body` returns a table, which comes back decoded.
local function fresh(body)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local script = dir .. "/script.lua"
  vim.fn.writefile(
    vim.split(
      table.concat({
        "vim.opt.rtp:prepend(" .. vim.inspect(root) .. ")",
        "vim.cmd('runtime plugin/org.lua')",
        "local ok, res = pcall(function()",
        body,
        "end)",
        "io.stdout:write(vim.json.encode(ok and res or { error = tostring(res) }))",
        "vim.cmd('qa!')",
      }, "\n"),
      "\n"
    ),
    script
  )
  local env = { XDG_DATA_HOME = dir .. "/data", XDG_STATE_HOME = dir .. "/state", XDG_CONFIG_HOME = dir .. "/cfg" }
  local r = vim
    .system({ vim.v.progpath, "--headless", "--clean", "-l", script }, { env = env, text = true })
    :wait(30000)
  vim.fn.delete(dir, "rf")
  local ok, out = pcall(vim.json.decode, r.stdout or "")
  if not ok then
    error("fresh nvim failed: " .. tostring(r.stdout) .. tostring(r.stderr))
  end
  if out.error then
    error(out.error)
  end
  return out
end

local HEAVY = {
  "org.parser",
  "org.keywords",
  "org.element",
  "org.agenda",
  "org.agenda.render",
  "org.agenda.view",
  "org.agenda.items",
  "org.capture",
  "org.babel",
  "org.babel.ob",
  "org.export.hooks",
  "org.dblock",
}

local function loaded_list()
  return "local l = {} for _, m in ipairs(vim.json.decode("
    .. vim.inspect(vim.json.encode(HEAVY))
    .. ")) do if package.loaded[m] then l[#l + 1] = m end end"
end

describe("startup", function()
  it("setup() with the default config loads no heavy module and defines no group", function()
    local out = fresh("require('org').setup({})\n" .. loaded_list() .. [[
      return { loaded = l, todo = vim.fn.hlexists("OrgTodo") }
    ]])
    eq({}, out.loaded)
    eq(0, out.todo)
  end)

  it("setup() with extensions defers their hooks into the agenda, capture and babel", function()
    local out = fresh([[
      require("org").setup({
        agenda_files = { vim.fn.tempname() .. "/*.org" },
        capture = { templates = { t = { description = "Task", template = "* TODO %?", target = "inbox.org" } } },
        extensions = {
          ql = {}, super_agenda = {}, quickadd = {}, ics = {}, code = {},
          diagrams = { languages = { "mermaid" } }, transclusion = {},
        },
      })
      ]] .. loaded_list() .. [[
      local ql = require("org.extensions.ql")
      local sa = require("org.extensions.super_agenda")
      local render = require("org.agenda.render")
      local items = require("org.agenda.items")
      local capture = require("org.capture")
      local ob = require("org.babel.ob")
      local hooks = require("org.export.hooks")
      return {
        loaded = l,
        ql = render.sources.ql ~= nil,
        grouper = render.grouper == sa.grouper,
        refresh = require("org.agenda.view").refresh_hooks.ql ~= nil,
        code_todos = render.sources.code_todos ~= nil,
        ics = items.day_sources.ics ~= nil,
        quickadd = capture.store_filters.quickadd ~= nil,
        code_expansion = capture.expansions["git-branch"] ~= nil,
        mermaid = ob.HANDLERS.mermaid == require("org.extensions.diagrams.render").mermaid,
        transclusion = hooks.preprocessors.transclusion ~= nil,
      }
    ]])
    eq({}, out.loaded)
    eq(true, out.ql)
    eq(true, out.grouper)
    eq(true, out.refresh)
    eq(true, out.code_todos)
    eq(true, out.ics)
    eq(true, out.quickadd)
    eq(true, out.code_expansion)
    eq(true, out.mermaid)
    eq(true, out.transclusion)
  end)

  it("an extension turned off before the module loads leaves no hook behind", function()
    local out = fresh([[
      require("org").setup({ extensions = { ql = {}, super_agenda = {}, diagrams = { languages = { "mermaid" } } } })
      require("org").setup({})
      local render = require("org.agenda.render")
      return {
        ql = render.sources.ql ~= nil,
        grouper = render.grouper ~= nil,
        mermaid = require("org.babel.ob").HANDLERS.mermaid == require("org.extensions.diagrams.render").mermaid,
      }
    ]])
    -- the ql source stays, and reports the extension as off
    eq(true, out.ql)
    eq(false, out.grouper)
    eq(false, out.mermaid)
  end)

  it("hooks also apply when the module is already loaded", function()
    local out = fresh([[
      require("org.agenda.render")
      require("org").setup({ extensions = { ql = {} } })
      return { ql = require("org.agenda.render").sources.ql ~= nil }
    ]])
    eq(true, out.ql)
  end)

  it("defines the highlight groups on the first org buffer and keeps them across :colorscheme", function()
    local out = fresh([[
      require("org").setup({})
      -- a user override made before any org buffer
      vim.api.nvim_set_hl(0, "OrgDone", { fg = "#123456" })
      local before = vim.fn.hlexists("OrgTodo")
      local f = vim.fn.tempname() .. ".org"
      vim.fn.writefile({ "* TODO Task" }, f)
      vim.cmd.edit(f)
      local after = vim.fn.hlexists("OrgTodo")
      local done = vim.api.nvim_get_hl(0, { name = "OrgDone" }).fg
      vim.cmd.colorscheme("default")
      local cs = next(vim.api.nvim_get_hl(0, { name = "OrgTodo" })) ~= nil
      local lvl = next(vim.api.nvim_get_hl(0, { name = "OrgHeadlineLevel1" })) ~= nil
      return { before = before, after = after, done = done, cs = cs, lvl = lvl, parser = package.loaded["org.parser"] ~= nil }
    ]])
    eq(0, out.before)
    eq(1, out.after)
    eq(0x123456, out.done)
    eq(true, out.cs)
    eq(true, out.lvl)
    eq(true, out.parser)
  end)

  it("defines the highlight groups for an :Org command before any org buffer", function()
    local out = fresh([[
      require("org").setup({})
      vim.cmd("Org version")
      return { a = vim.fn.hlexists("OrgMenuKey") }
    ]])
    eq(1, out.a)
  end)

  it("still detects the -*- mode: org -*- line", function()
    local out = fresh([[
      local f = vim.fn.tempname() .. ".txt"
      vim.fn.writefile({ "-*- mode: org -*-", "* Heading" }, f)
      vim.cmd.edit(f)
      return { ft = vim.bo.filetype }
    ]])
    eq("org", out.ft)
  end)
end)
