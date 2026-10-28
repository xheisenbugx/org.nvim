-- Global visibility (startup, then S-TAB three times) with inline tasks
-- and text before the first headline, as Emacs Org 9.8.10 with
-- org-inlinetask loaded (org-inlinetask-min-level 15) shows it: each
-- expected string has "v" (visible) or "h" (hidden) per line, from Emacs
-- (scripts/emacs-parity/difftest.el, the visibility oracle).
local config = require("org.config")
local fold = require("org.fold")

local S = string.rep("*", 15)

describe("visibility with inline tasks and text before the first headline", function()
  local saved, path

  before_each(function()
    saved = config.opts.inlinetask_min_level
    config.opts.inlinetask_min_level = 15
    path = vim.fn.tempname() .. ".org"
  end)

  after_each(function()
    config.opts.inlinetask_min_level = saved
    vim.cmd("silent! %bwipeout!")
    os.remove(path)
  end)

  local function shown()
    local out = {}
    for l = 1, vim.fn.line("$") do
      out[#out + 1] = fold.line_visible(l) and "v" or "h"
    end
    return table.concat(out)
  end

  ---@param lines string[]
  ---@param want { startup: string, S1: string, S2: string, S3: string }
  local function check(lines, want)
    vim.fn.writefile(lines, path)
    vim.cmd("silent! only!")
    vim.cmd("silent! %bwipeout!")
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    local echo = vim.api.nvim_echo
    vim.api.nvim_echo = function() end
    local got = { startup = shown() }
    vim.w.org_last_global = nil
    for i = 1, 3 do
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      fold.global_cycle()
      got["S" .. i] = shown()
    end
    vim.api.nvim_echo = echo
    eq(want, got)
  end

  it("an inline task's END line hides in CONTENTS, not in OVERVIEW before the first headline", function()
    check({
      S .. " gamma",
      S .. " END",
    }, {
      startup = "vv",
      S1 = "vv",
      S2 = "vh",
      S3 = "vv",
    })
  end)

  it("the text after an inline task before the first headline hides", function()
    check({
      S .. " TODO",
      "| 5 | task |",
    }, {
      startup = "vv",
      S1 = "vh",
      S2 = "vh",
      S3 = "vv",
    })
  end)

  it("blank lines at the end of the buffer show", function()
    check({
      "** DONE",
      S .. " =verbatim=",
      "",
    }, {
      startup = "vvv",
      S1 = "vhv",
      S2 = "vvv",
      S3 = "vvv",
    })
  end)

  it("an END line without its inline task shows in CONTENTS", function()
    check({
      "* plan",
      S .. " END",
    }, {
      startup = "vv",
      S1 = "vh",
      S2 = "vv",
      S3 = "vv",
    })
  end)

  it("a drawer before the first heading folds, and stays folded", function()
    check({
      ":NOTES:",
      "x",
      ":END:",
      "text",
      "* A",
      "body",
    }, {
      startup = "vvvvvv",
      S1 = "vhhvvh",
      S2 = "vhhvvh",
      S3 = "vhhvvv",
    })
  end)

  it("a plain list before the first heading stays open", function()
    check({
      "- a",
      "  - b",
      "  body",
      "",
      "- c",
      "* A",
      "body",
    }, {
      startup = "vvvvvvv",
      S1 = "vvvvvvh",
      S2 = "vvvvvvh",
      S3 = "vvvvvvv",
    })
  end)

  it("OVERVIEW shows inline tasks with no more stars than those above them", function()
    check({
      S .. "* deep",
      "x",
      S .. " mid",
      "y",
      "* A",
      S .. " in",
      "z",
      S .. " END",
      "w",
      "** B",
      "",
      "",
      S .. " t",
    }, {
      startup = "vvvvvvvvvvvvv",
      S1 = "vhvhvhhhhhhhh",
      S2 = "vhvhvvhhhvhvv",
      S3 = "vvvvvvvvvvvvv",
    })
  end)

  it("inline tasks don't fold at startup (no org-cycle-hook)", function()
    check({
      "#+STARTUP: content",
      "* A",
      S .. " t",
      "x",
      S .. " END",
      "y",
      "",
      "",
      S .. " u",
    }, {
      startup = "vvvhvhhvv",
      S1 = "vvhhhhhhh",
      S2 = "vvvhhhhvv",
      S3 = "vvvvvvvvv",
    })
  end)

  it("startup OVERVIEW with an inline task first", function()
    check({
      "#+STARTUP: overview",
      S .. " t",
      "x",
      S .. " END",
      "y",
      "* A",
    }, {
      startup = "vvhvhv",
      S1 = "vvhvhv",
      S2 = "vvhhhv",
      S3 = "vvvvvv",
    })
  end)

  it("an END line without its task folds from the inline task line above it", function()
    check({
      "* A",
      S .. " a",
      S .. " END",
      "* B",
      S .. " END",
      "z",
    }, {
      startup = "vvvvvv",
      S1 = "vhhvhh",
      S2 = "vvhhhh",
      S3 = "vvvvvv",
    })
  end)

  -- TAB on a headline: CHILDREN folds the inline tasks of its text
  -- (org-inlinetask-hide-tasks 'children, from org-cycle-hook)
  it("TAB to CHILDREN folds the inline tasks of the entry", function()
    vim.fn.writefile({
      "#+STARTUP: content",
      "* Top",
      "top text",
      S .. " TODO inline task",
      "inline body",
      S .. " END",
      "after inline",
      "** Child",
      "child text",
      S .. " inline no end",
      "* Second",
    }, path)
    vim.cmd("silent! only!")
    vim.cmd("silent! %bwipeout!")
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    local echo = vim.api.nvim_echo
    vim.api.nvim_echo = function() end
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    local got = {}
    for i = 1, 3 do
      fold.cycle()
      got["T" .. i] = shown()
    end
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    fold.cycle()
    got.inline = shown()
    vim.api.nvim_echo = echo
    eq({
      T1 = "vvhhhhhhhhv",
      T2 = "vvvvhhvvhhv",
      T3 = "vvvvvvvvvvv",
      inline = "vvvvhhvvvvv",
    }, got)
  end)
end)
