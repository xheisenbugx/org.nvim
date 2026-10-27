-- Inline tasks with odd levels only (#+STARTUP: odd, odd_levels_only): as
-- org-inlinetask-outline-regexp and org-element count them, an inline task
-- then has 2 * inlinetask_min_level - 1 stars or more (29 for 15), and 15
-- to 28 stars make headlines (15 stars: level 8). The faces are compared
-- with Emacs in emacs_faces_headline_spec.lua
-- (tests/fixtures/emacs/faces/inlinetask.org); the visibility and command
-- results below are what Emacs Org 9.8.12 gives (org-inlinetask loaded).
local config = require("org.config")
local fold = require("org.fold")
local parser = require("org.parser")

local function stars(n)
  return string.rep("*", n)
end

local ODD = {
  "#+STARTUP: odd",
  "* A",
  "text",
  stars(15) .. " B fifteen",
  "body of B",
  stars(29) .. " TODO task",
  "task body",
  stars(29) .. " END",
  "after task",
  "*** C",
  "c body",
}

describe("inline tasks with odd levels only", function()
  with_config({ inlinetask_min_level = 15 })

  it("start at 2 * inlinetask_min_level - 1 stars", function()
    eq(15, parser.inlinetask_min_level({ startup = {} }))
    eq(29, parser.inlinetask_min_level({ startup = { odd = true } }))
    eq(15, parser.inlinetask_min_level({ startup = { oddeven = true } }))
    config.opts.odd_levels_only = true
    eq(29, parser.inlinetask_min_level({ startup = {} }))
    eq(15, parser.inlinetask_min_level({ startup = { oddeven = true } }))
    config.opts.odd_levels_only = false
    config.opts.inlinetask_min_level = false
    eq(nil, parser.inlinetask_min_level({ startup = { odd = true } }))
    config.opts.inlinetask_min_level = 15
  end)

  it("parse 15 to 28 stars as headlines", function()
    local file = parser.parse(ODD)
    eq(29, file._min_inline)
    local titles, inline = {}, {}
    for _, hl in ipairs(file.headlines) do
      titles[#titles + 1] = hl.title
      inline[#inline + 1] = hl.inlinetask or false
    end
    eq({ "A", "B fifteen", "task", "C" }, titles)
    eq({ false, false, true, false }, inline)
    local b = file.headlines[2]
    eq(file.headlines[1], b.parent)
    -- the inline task is text of B's entry, which runs to *** C
    eq(9, b.body_end)
    eq("B fifteen", file:headline_at(9).title)
    eq("task", file:headline_at(7).title)
    -- org-outline-level of a 15 stars headline
    eq(15, parser.outline_level(ODD[4], file))
    eq(nil, parser.outline_level(ODD[6], file))
    -- without odd levels, 15 stars is an inline task
    local even = vim.list_slice(ODD, 2)
    eq(15, parser.parse(even)._min_inline)
    ok(parser.parse(even).headlines[2].inlinetask)
  end)

  it("follow the buffer's #+STARTUP for folds", function()
    org_buffer(vim.deepcopy(ODD), { 1, 0 })
    local levels = fold.compute(ODD)
    eq({ 0, ">1", 1, ">2", 2, ">3", 3, "<3", 2, ">2", 2 }, levels)
  end)

  it("show and hide as in Emacs on S-TAB", function()
    local path = vim.fn.tempname() .. ".org"
    vim.fn.writefile(ODD, path)
    vim.cmd("silent! only!")
    vim.cmd("silent! %bwipeout!")
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    local function shown()
      local out = {}
      for l = 1, vim.fn.line("$") do
        out[#out + 1] = fold.line_visible(l) and "v" or "h"
      end
      return table.concat(out)
    end
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
    vim.cmd("silent! %bwipeout!")
    os.remove(path)
    -- org-cycle-global from Emacs: OVERVIEW, CONTENTS (the inline task's
    -- body and END line folded by org-inlinetask-hide-tasks), SHOW ALL
    eq({
      startup = "vvvvvvvvvvv",
      S1 = "vvhhhhhhhhh",
      S2 = "vvhvhvhhhvh",
      S3 = "vvvvvvvvvvv",
    }, got)
  end)

  it("draw 15 stars as a level 8 headline, 29 as an inline task", function()
    local hl = require("tests.helpers.highlighter")
    config.opts.ui.highlighter = "parser"
    org_buffer(vim.deepcopy(ODD), { 1, 0 })
    ok(hl.has(4, 1, "orgheadlinelevel8"), hl.groups(4, 1))
    ok(not hl.groups(4, 1):find("orginlinetask"), hl.groups(4, 1))
    ok(hl.has(6, 1, "orghiddenstars") and hl.has(6, 28, "orgInlinetask"), hl.groups(6, 28))
    ok(not hl.groups(6, 1):find("orgheadlinelevel"), hl.groups(6, 1))
  end)

  it("are inserted with 29 stars, demoted and promoted by two", function()
    local buf = org_buffer({ "#+STARTUP: odd", "* A", "text" }, { 3, 0 })
    require("org.inlinetask").insert()
    vim.cmd("stopinsert")
    eq({ stars(29) .. " ", stars(29) .. " END" }, vim.list_slice(buf_lines(buf), 4, 5))
    buf = org_buffer(vim.deepcopy(ODD), { 6, 0 })
    require("org.structure").demote_heading()
    eq(stars(31) .. " TODO task", buf_lines(buf)[6])
    eq(stars(31) .. " END", buf_lines(buf)[8])
    require("org.structure").promote_heading()
    eq(stars(29) .. " TODO task", buf_lines(buf)[6])
    eq(stars(29) .. " END", buf_lines(buf)[8])
    -- Emacs would make a 27 stars headline of it (org-differences)
    local warn = vim.notify
    vim.notify = function() end
    require("org.structure").promote_heading()
    vim.notify = warn
    eq(stars(29) .. " TODO task", buf_lines(buf)[6])
  end)

  it("demote a 15 stars headline as a headline", function()
    local buf = org_buffer(vim.deepcopy(ODD), { 4, 0 })
    require("org.structure").demote_heading()
    eq(stars(17) .. " B fifteen", buf_lines(buf)[4])
  end)
end)
