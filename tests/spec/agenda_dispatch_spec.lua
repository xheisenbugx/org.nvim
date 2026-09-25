-- Agenda dispatcher keys and custom command types (sparse trees, block
-- agenda settings).
local config = require("org.config")
local date = require("org.date")
local utils = require("org.utils")
vim.g.org_test = true

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
local path = dir .. "/d.org"
local agenda = require("org.agenda")
local view = require("org.agenda.view")

local today = date.today()
local function ts(offset)
  return "<" .. today:add(offset, "d"):to_string({ brackets = false }) .. ">"
end

local lines = {
  "* TODO Alpha :work:",
  "  SCHEDULED: " .. ts(0),
  "** NEXT Beta",
  "* WAITING Gamma :home:",
  "  some banana text",
  "* Delta",
}

local function setup(agenda_opts)
  utils.writefile(path, lines)
  local b = utils.find_buffer(path)
  if b then
    vim.api.nvim_buf_delete(b, { force = true })
  end
  config.setup({
    agenda_files = { path },
    org_directory = dir,
    todo_keywords = { "TODO NEXT WAITING | DONE" },
    agenda = agenda_opts or {},
  })
end

local function visible_lines()
  local out = {}
  for i = 1, vim.api.nvim_buf_line_count(0) do
    if vim.fn.foldclosed(i) == -1 then
      out[#out + 1] = i
    end
  end
  return out
end

describe("agenda custom command types", function()
  after_each(function()
    pcall(view.quit, true)
    agenda.lock = nil
  end)

  it("tags-tree, todo-tree and occur-tree build sparse trees in the org buffer", function()
    setup({
      custom_commands = {
        w = { type = "tags-tree", match = "work" },
        n = { type = "todo-tree", match = "NEXT" },
        o = { type = "occur-tree", match = "ban+ana" },
      },
    })
    vim.cmd("edit! " .. vim.fn.fnameescape(path))
    agenda.dispatch({ custom = "w" })
    -- Beta inherits :work: (org-match-sparse-tree honours tag inheritance)
    eq({ 1, 3 }, vim.tbl_map(function(x)
      return x.lnum
    end, vim.fn.getloclist(0)))
    agenda.dispatch({ custom = "n" })
    eq({ 3 }, vim.tbl_map(function(x)
      return x.lnum
    end, vim.fn.getloclist(0)))
    -- occur-tree takes an Emacs regexp
    agenda.dispatch({ custom = "o" })
    eq({ 5 }, vim.tbl_map(function(x)
      return x.lnum
    end, vim.fn.getloclist(0)))
    ok(#visible_lines() < #lines)
    -- no agenda buffer was opened
    eq("org", vim.bo.filetype)
    vim.cmd("bwipeout!")
  end)

  it("refuses sparse trees outside org buffers", function()
    setup({ custom_commands = { w = { type = "tags-tree", match = "work" } } })
    vim.cmd("enew")
    local orig = utils.error
    local msg
    utils.error = function(s)
      msg = s
    end
    agenda.dispatch({ custom = "w" })
    utils.error = orig
    ok(msg and msg:find("Cannot execute Org agenda command"), msg)
  end)

  it("applies the settings of a block agenda to every block", function()
    setup({
      custom_commands = {
        b = {
          description = "blocks",
          types = {
            { type = "todo" },
            { type = "tags", match = "home", header = "Own header" },
          },
          settings = { org_agenda_overriding_header = "Shared", sorting = { "alpha-down" } },
        },
      },
    })
    agenda.dispatch({ custom = "b" })
    local v = view.state.view
    ok(v.multi)
    eq("Shared", v.blocks[1].header)
    eq("Own header", v.blocks[2].header)
    eq({ "alpha-down" }, v.blocks[1].sorting)
    local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    ok(text:find("Shared", 1, true) and text:find("Own header", 1, true), text)
    -- no per-block "Press ..." hints in a block agenda
    ok(not text:find("Press ", 1, true), text)
  end)

  it("single-block commands are not composite", function()
    setup({ custom_commands = { t = { type = "todo", org_agenda_overriding_header = "Mine" } } })
    agenda.dispatch({ custom = "t" })
    ok(not view.state.view.multi)
    eq("Mine", view.state.view.blocks[1].header)
  end)
end)

describe("agenda dispatcher keys", function()
  after_each(function()
    pcall(view.quit, true)
    agenda.lock = nil
    config.opts.agenda.sticky = false
  end)

  it("* toggles sticky agendas", function()
    setup()
    local msgs = {}
    local orig = utils.notify
    utils.notify = function(m)
      msgs[#msgs + 1] = m
    end
    agenda.dispatch("*")
    ok(config.opts.agenda.sticky)
    agenda.dispatch("*")
    utils.notify = orig
    ok(not config.opts.agenda.sticky)
    eq("Sticky agenda buffers are now on", msgs[1])
    eq("Sticky agenda buffers are now off", msgs[2])
  end)

  it("> removes the restriction lock", function()
    setup()
    vim.cmd("edit! " .. vim.fn.fnameescape(path))
    agenda.set_restriction_lock()
    ok(agenda.lock)
    agenda.dispatch(">")
    eq(nil, agenda.lock)
    vim.cmd("bwipeout!")
  end)

  it("> in the menu drops the restriction and stays in the dispatcher", function()
    setup()
    vim.cmd("edit! " .. vim.fn.fnameescape(path))
    agenda.set_restriction_lock()
    local ui = require("org.ui")
    local orig = ui.menu
    local seen = {}
    local answers = { "__unrestrict", "t" }
    ui.menu = function(o)
      local keys = {}
      for _, it in ipairs(o.items) do
        if it.key then
          keys[it.key] = true
        end
      end
      seen[#seen + 1] = keys
      return table.remove(answers, 1)
    end
    agenda.prompt()
    ui.menu = orig
    ok(seen[1][">"] and seen[1]["e"] and seen[1]["*"])
    eq(nil, seen[2][">"])
    eq(nil, agenda.lock)
    eq("todo", view.state.view.blocks[1].type)
  end)

  it("e stores the agenda views and :Org agenda export writes a file", function()
    setup({ custom_commands = { x = { type = "todo", export_files = dir .. "/todo.txt" } } })
    agenda.dispatch("e")
    ok(utils.readfile(dir .. "/todo.txt")[1]:find("Global list of TODO items"))
    agenda.command("t")
    agenda.command("export " .. dir .. "/cmd.txt")
    ok(utils.readfile(dir .. "/cmd.txt")[1]:find("Global list of TODO items"))
  end)
end)
