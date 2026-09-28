-- Emacs Lisp beyond the interpreter of table formulas, evaluated in an
-- external `emacs --batch` (babel.emacs_lisp): diary sexps, Babel header
-- arguments, link abbreviations with %(function) and elisp: links naming a
-- command. Expected values were produced by Emacs 31 / Org 9.8.10 in batch
-- (org-diary-sexp-entry, org-babel-parse-header-arguments,
-- org-link-expand-abbrev, call-interactively). The tests that need Emacs
-- return early without an `emacs` executable.
local config = require("org.config")
local date = require("org.date")
local utils = require("org.utils")

local function has_emacs()
  return require("org.babel.elisp").command() ~= nil
end

local function stub(tbl, key, fn)
  local orig = tbl[key]
  tbl[key] = fn
  return function()
    tbl[key] = orig
  end
end

describe("Emacs Lisp fallback", function()
  local saved
  before_each(function()
    saved = { vim.deepcopy(config.opts.babel.emacs_lisp), vim.deepcopy(config.opts.links) }
    config.opts.babel.confirm_evaluate = false
  end)
  after_each(function()
    config.opts.babel.emacs_lisp = saved[1]
    config.opts.links = saved[2]
  end)

  describe("diary sexps", function()
    local items = require("org.agenda.items")
    local parser = require("org.parser")
    local from = date.days_from_civil(2026, 9, 27)

    --- Agenda titles by date for 2026-09-27 .. 2026-10-03.
    local function week(lines)
      local file = parser.parse(lines, "/tmp/diary-fallback.org")
      local by_day = items.agenda({ file }, from, from + 6, { today = from })
      local out = {}
      for d = from, from + 6 do
        for _, it in ipairs(by_day[d] or {}) do
          local y, m, dd = date.civil_from_days(d)
          out[#out + 1] = string.format("%d-%02d-%02d %s", y, m, dd, it.title)
        end
      end
      return out
    end

    it("the emulation can't evaluate run in Emacs, once for the range", function()
      if not has_emacs() then
        return
      end
      items._emacs_sexps = {}
      eq({ "2026-09-28 Entry text", "2026-09-30 Entry text", "2026-10-02 Entry text" }, week({
        "* Dates",
        "%%(when (cl-evenp (calendar-extract-day date)) entry) Entry text",
      }))
      eq({
        "2026-09-27 ENTRY TEXT 27",
        "2026-09-28 ENTRY TEXT 28",
        "2026-09-29 ENTRY TEXT 29",
        "2026-09-30 ENTRY TEXT 30",
        "2026-10-01 ENTRY TEXT 1",
        "2026-10-02 ENTRY TEXT 2",
        "2026-10-03 ENTRY TEXT 3",
      }, week({ "* Dates", '%%(format "%s %d" (upcase entry) (calendar-extract-day date)) Entry text' }))
      eq({ "2026-09-29 Marked" }, week({
        "* Dates",
        "%%(and (= (calendar-extract-day date) 29) (progn (sit-for 0) (cons 'mark \"Marked\"))) Entry text",
      }))
      eq(3, vim.tbl_count(items._emacs_sexps))
    end)

    it("are skipped without Emacs", function()
      config.opts.babel.emacs_lisp.command = false
      items._emacs_sexps = {}
      local restore = stub(vim, "notify", function() end)
      local got = week({ "* Dates", "%%(when (cl-evenp (calendar-extract-day date)) entry) Entry text" })
      vim.wait(20) -- the warning is scheduled
      restore()
      eq({}, got)
    end)
  end)

  describe("Babel header arguments", function()
    local babel = require("org.babel")
    local blocks = require("org.babel.blocks")

    it("evaluate Lisp forms when they are read", function()
      config.opts.babel.emacs_lisp.command = false
      local args = blocks.merge({ vars = {}, results_spec = {} }, blocks.parse_header_string(':dir (concat "/" "tmp")'))
      eq("/tmp", args.dir)
      if not has_emacs() then
        return
      end
      config.opts.babel.emacs_lisp.command = saved[1].command
      local pairs_list = blocks.parse_header_string(':dir (directory-file-name "/tmp/")')
      args = blocks.merge({ vars = {}, results_spec = {} }, pairs_list)
      eq("/tmp", args.dir)
    end)

    it("evaluate :var forms in Emacs", function()
      if not has_emacs() then
        return
      end
      local buf = org_buffer({ "#+begin_src lua", "return x", "#+end_src" }, { 2, 0 })
      local b = babel.at_block(buf, 2)
      eq("cba", babel.resolve_var(buf, '(string-reverse "abc")', b.args, {}, { skip_confirm = true }))
    end)
  end)

  describe("link abbreviations with %(function)", function()
    local links = require("org.links")

    it("call functions Emacs considers safe", function()
      if not has_emacs() then
        return
      end
      config.opts.babel.emacs_lisp.args = {
        "-Q",
        "--batch",
        "--eval",
        "(progn (defun my-abbrev (tag) (concat \"https://example.org/\" (upcase tag)))"
          .. " (put 'my-abbrev 'org-link-abbrev-safe t))",
      }
      config.opts.links.abbreviations = { ex = "%(my-abbrev)/page", unsafe = "%(string-reverse)" }
      local warnings = {}
      local restore = stub(utils, "warn", function(m)
        warnings[#warnings + 1] = m
      end)
      org_buffer({ "" }, { 1, 0 })
      local a = links.expand_abbrev("ex:abc")
      local b = links.expand_abbrev("unsafe:abc")
      restore()
      eq("https://example.org/ABC/page", a)
      eq("unsafe:abc", b)
      ok(warnings[1] and warnings[1]:find("Disabling unsafe link abbrev: %(string-reverse)", 1, true), warnings[1])
    end)
  end)

  describe("elisp: links naming a command", function()
    local links = require("org.links")

    it("call it interactively in Emacs", function()
      if not has_emacs() then
        return
      end
      config.opts.links.confirm_elisp = false
      local msgs = {}
      local restore = stub(utils, "notify", function(m)
        msgs[#msgs + 1] = m
      end)
      org_buffer({ "" }, { 1, 0 })
      local r = links.open("elisp:emacs-version")
      restore()
      eq(true, r)
      ok(msgs[1]:match('^emacs%-version => "GNU Emacs'), msgs[1])
    end)

    it("need an Emacs", function()
      config.opts.links.confirm_elisp = false
      config.opts.babel.emacs_lisp.command = false
      local warnings = {}
      local restore = stub(utils, "warn", function(m)
        warnings[#warnings + 1] = m
      end)
      org_buffer({ "" }, { 1, 0 })
      local r = links.open("elisp:emacs-version")
      restore()
      eq(false, r)
      ok(warnings[1]:find("need an Emacs", 1, true), warnings[1])
    end)
  end)
end)
