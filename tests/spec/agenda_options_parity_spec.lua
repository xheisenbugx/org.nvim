-- Agenda options pinned to Emacs Org 9.8.10: skipping, line format,
-- dispatcher and window options. Expected texts come from Emacs 9.8.10
-- probes on the same files (noted per test).
local date = require("org.date")
local config = require("org.config")
local utils = require("org.utils")
local view = require("org.agenda.view")
local agenda = require("org.agenda")

local today = date.today()
local function ts(offset, extra)
  local s = today:add(offset, "d"):to_string({ brackets = false })
  return "<" .. s .. (extra and (" " .. extra) or "") .. ">"
end

local dir = vim.uv.fs_realpath((function()
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, "p")
  return d
end)())
local path = dir .. "/skip.org"

local function open(lines, opts, spec)
  utils.writefile(path, lines)
  local b = utils.find_buffer(path)
  if b then
    vim.api.nvim_buf_delete(b, { force = true })
  end
  config.setup(vim.tbl_deep_extend("force", { agenda_files = { path }, org_directory = dir }, opts or {}))
  config.opts.clock.persist = false
  if spec then
    agenda.open(spec)
  else
    agenda.open_agenda({ span = "day" })
  end
end

local function buf_text()
  return vim.api.nvim_buf_get_lines(view.state.buf, 0, -1, false)
end

--- The agenda lines of items (no headers).
local function item_lines()
  local out = {}
  local lines = buf_text()
  local nums = vim.tbl_keys(view.state.line_items)
  table.sort(nums)
  for _, l in ipairs(nums) do
    out[#out + 1] = lines[l]
  end
  return out
end

local function press(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), "mx", false)
end

describe("agenda skipping", function()
  after_each(function()
    pcall(view.quit, true)
  end)

  local lines = { "* COMMENT Proj", "** TODO Inside", "* TODO Keep", "* TODO Skip me" }

  -- Emacs 9.8.10, org-todo-list with org-agenda-skip-comment-trees nil:
  --   "  skip:       TODO Inside", "  skip:       TODO Keep", "  skip:       TODO Skip me"
  it("skip_comment_trees = false lists entries of COMMENT trees", function()
    open(lines, { agenda = { skip_comment_trees = false } }, { type = "todo" })
    eq({ "  skip:       TODO Inside", "  skip:       TODO Keep", "  skip:       TODO Skip me" }, item_lines())
  end)

  -- Emacs 9.8.10, with org-agenda-skip-function-global skipping "Skip me":
  --   "  skip:       TODO Keep"
  it("skip_function_global applies to every view", function()
    local skip = function(hl)
      return hl:plain_title():find("Skip me", 1, true) ~= nil
    end
    open(lines, { agenda = { skip_function_global = skip } }, { type = "todo" })
    eq({ "  skip:       TODO Keep" }, item_lines())
    view.quit(true)
    agenda.open_search("TODO")
    for _, l in ipairs(item_lines()) do
      ok(not l:find("Skip me", 1, true), l)
    end
  end)
end)

describe("custom command contexts", function()
  -- Emacs 9.8.10 (org-contextualize-keys in a fundamental-mode buffer):
  -- p (only in text-mode) is dropped, q runs r's command, r is hidden, z
  -- has no rule and stays: ((q R cmd tags x) (z Z alltodo ""))
  it("filters and remaps custom commands by the current buffer", function()
    config.setup({
      agenda = {
        custom_commands = {
          p = { description = "P cmd", type = "todo" },
          r = { description = "R cmd", type = "tags", match = "x" },
          q = { description = "Q cmd", type = "search" },
          z = { description = "Z", type = "todo" },
        },
        custom_commands_contexts = {
          { "p", { { in_mode = "^text$" } } },
          { "q", "r", { { not_in_mode = "^text$" } } },
        },
      },
    })
    vim.cmd("enew")
    local cmds = agenda.custom_commands()
    eq({ "q", "z" }, vim.fn.sort(vim.tbl_keys(cmds)))
    eq("R cmd", cmds.q.description)
    vim.bo.filetype = "text"
    eq({ "p", "r", "z" }, vim.fn.sort(vim.tbl_keys(agenda.custom_commands())))
    vim.cmd("bwipe!")
  end)
end)

describe("dispatcher custom command lines", function()
  -- org-agenda-get-restriction-and-command (Emacs 9.8.10): the
  -- description, or a name for the type, then ": MATCH" with
  -- org-agenda-menu-show-matcher; two columns split the lines in halves.
  local function menu_lines(opts)
    config.setup({
      agenda = vim.tbl_extend("force", {
        custom_commands = {
          p = { description = "Projects", type = "tags", match = "+project" },
          w = { type = "todo", match = "WAITING" },
          x = { type = "search" },
          y = { description = "Block", types = { { type = "agenda" } } },
        },
      }, opts or {}),
    })
    local shown
    local ui = require("org.ui")
    local float = ui.float
    ui.float = function(lines, o)
      shown = lines
      return float(lines, o)
    end
    local getchar = utils.getchar
    utils.getchar = function()
      return nil
    end
    local ok2, err = pcall(agenda.prompt)
    ui.float, utils.getchar = float, getchar
    assert(ok2, err)
    local out = {}
    local on = false
    for _, l in ipairs(shown) do
      if l == "Custom commands" then
        on = true
      elseif on and l ~= "" and not l:find("Esc", 1, true) then
        out[#out + 1] = l
      end
    end
    return out
  end

  it("shows the match after the description", function()
    eq({
      " [p]  Projects: +project",
      " [w]  TODO keyword: WAITING",
      " [x]  Word search",
      " [y]  Block",
    }, menu_lines())
  end)

  it("menu_show_matcher = false hides it; menu_two_columns pairs the lines", function()
    eq({
      " [p]  Projects                            [x]  Word search",
      " [w]  TODO keyword                        [y]  Block",
    }, menu_lines({ menu_show_matcher = false, menu_two_columns = true }))
  end)
end)
