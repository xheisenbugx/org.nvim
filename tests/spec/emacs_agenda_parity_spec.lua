-- Agenda views compared with Emacs Org 9.8.10 (tests/fixtures/emacs/agenda,
-- scripts/emacs-parity/agenda.el): day/week agendas, TODO lists, tags
-- matches and search over two fixed files, default settings.

local P = require("tests.emacs_parity")
local config = require("org.config")
local date = require("org.date")
local agenda = require("org.agenda")
local view = require("org.agenda.view")

local dir = P.dir .. "/agenda"

-- Cases that still differ from Emacs, with the reason. A case listed here
-- must keep failing (remove it once it matches).
local KNOWN = {}

-- Emacs renders the views in a batch frame 80 columns wide
local WIDTH = 80

local function render(case)
  local kind, a, b = case[2], case[3], case[4]
  if kind == "agenda" or kind == "log" then
    config.opts.agenda.start_with_log_mode = kind == "log"
    agenda.open_agenda({ span = a, anchor = date.read_date(b):days() })
  elseif kind == "todo" then
    agenda.open_todo(a ~= "-" and a or nil)
  elseif kind == "tags" or kind == "tags-todo" then
    agenda.open_tags(a, kind == "tags-todo")
  elseif kind == "search" then
    agenda.open_search(a)
  else
    error("unknown kind " .. kind)
  end
  local lines = view.build(WIDTH).lines
  vim.cmd("silent! %bwipeout!")
  return lines
end

describe("agenda views match Emacs", function()
  P.freeze_time()
  before_each(function()
    config.setup({
      org_directory = dir,
      agenda_files = { dir .. "/work.org", dir .. "/home.org" },
      -- the current-time line depends on the clock: off on both sides
      agenda = { show_current_time_in_grid = false },
    })
    config.opts.clock.persist = false
  end)
  after_each(function()
    -- back to the setup of tests/minimal_init.lua
    config.setup({
      org_directory = P.root .. "/tests/fixtures",
      agenda_files = { P.root .. "/tests/fixtures/*.org" },
    })
  end)
  local expected = P.sections(dir .. "/expected.txt")
  for _, case in ipairs(P.cases(dir .. "/cases.txt")) do
    local name = case[1]
    it(name, function()
      ok(expected[name], "no Emacs output for " .. name .. " (run make parity-fixtures)")
      P.compare(P.normalise("agenda", expected[name].lines), render(case), KNOWN[name])
    end)
  end
end)
