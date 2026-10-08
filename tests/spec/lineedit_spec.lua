-- org-beginning-of-line / org-end-of-line / org-kill-line with
-- org-special-ctrl-a/e, org-special-ctrl-k and org-ctrl-k-protect-subtree.
-- Expected columns and text come from Emacs 9.8.10 (Insert mode, where the
-- cursor is Emacs's point).
local config = require("org.config")
local utils = require("org.utils")
local le = require("org.lineedit")
vim.g.org_test = true

local function col()
  return vim.api.nvim_win_get_cursor(0)[2]
end

local function in_insert(buf, pos, fn)
  vim.api.nvim_win_set_cursor(0, pos)
  local result
  vim.keymap.set("i", "<F8>", function()
    result = fn()
  end, { buffer = buf })
  vim.api.nvim_feedkeys(vim.keycode("A<F8><Esc>"), "xt", false)
  return result
end

describe("special C-a / C-e", function()
  local saved
  before_each(function()
    saved = config.opts.special_ctrl_a_e
  end)
  after_each(function()
    config.opts.special_ctrl_a_e = saved
  end)

  local text = { "* TODO [#A] Title here   :tag:", "- [ ] item text", "1. plain" }

  -- run the motion in Insert mode `n` times from column `from`, collecting
  -- the columns reached
  local function run(fn, row, from, n)
    local buf = org_buffer(text, { row, 0 })
    local cols = {}
    vim.api.nvim_win_set_cursor(0, { row, from })
    vim.keymap.set("i", "<F8>", function()
      fn()
      cols[#cols + 1] = col()
    end, { buffer = buf })
    vim.api.nvim_feedkeys(vim.keycode("i" .. string.rep("<F8>", n) .. "<Esc>"), "xt", false)
    return cols
  end

  it("t: title start, then column 0", function()
    config.opts.special_ctrl_a_e = true
    eq({ 12, 0, 12 }, run(le.beginning_of_line, 1, 20, 3))
    eq({ 0 }, run(le.beginning_of_line, 1, 5, 1))
    eq({ 22, 30, 22 }, run(le.end_of_line, 1, 3, 3))
    eq({ 6, 0, 6 }, run(le.beginning_of_line, 2, 10, 3))
    eq({ 3 }, run(le.beginning_of_line, 3, 0, 1))
  end)

  it("reversed: the line boundary first", function()
    config.opts.special_ctrl_a_e = "reversed"
    eq({ 0, 12, 0 }, run(le.beginning_of_line, 1, 20, 3))
    eq({ 30, 22, 30 }, run(le.end_of_line, 1, 3, 3))
    eq({ 0, 6, 0 }, run(le.beginning_of_line, 2, 10, 3))
  end)

  it("off: plain line boundaries", function()
    config.opts.special_ctrl_a_e = false
    eq({ 0, 0 }, run(le.beginning_of_line, 1, 20, 2))
    eq({ 30 }, run(le.end_of_line, 1, 3, 1))
  end)

  it("per key", function()
    config.opts.special_ctrl_a_e = { a = true, e = false }
    eq({ 12 }, run(le.beginning_of_line, 1, 20, 1))
    eq({ 30 }, run(le.end_of_line, 1, 3, 1))
  end)

  it("Normal mode: end of line is the last character", function()
    config.opts.special_ctrl_a_e = true
    org_buffer(text, { 1, 3 })
    le.end_of_line()
    eq(21, col()) -- on the last character of the title
    le.end_of_line()
    eq(29, col())
  end)
end)

describe("kill_line", function()
  local saved_k, saved_p
  before_each(function()
    saved_k, saved_p = config.opts.special_ctrl_k, config.opts.ctrl_k_protect_subtree
  end)
  after_each(function()
    config.opts.special_ctrl_k, config.opts.ctrl_k_protect_subtree = saved_k, saved_p
  end)

  it("special: kills the title up to the tags and realigns them", function()
    config.opts.special_ctrl_k = true
    local buf = org_buffer({ "* TODO Title here   :tag:" }, { 1, 12 })
    le.kill_line()
    eq({ "* TODO Title                                                            :tag:" }, buf_lines(buf))
    eq(" here", vim.fn.getreg('"'))
  end)

  -- Emacs org-kill-line realigns the tags only with org-auto-align-tags
  it("special: keeps the tags in place without auto_align_tags", function()
    config.opts.special_ctrl_k = true
    local saved = config.opts.auto_align_tags
    config.opts.auto_align_tags = false
    local buf = org_buffer({ "* TODO Title here   :tag:" }, { 1, 12 })
    le.kill_line()
    config.opts.auto_align_tags = saved
    eq({ "* TODO Title   :tag:" }, buf_lines(buf))
    eq(" here", vim.fn.getreg('"'))
  end)

  it("special: kills the title up to non-ASCII tags", function()
    config.opts.special_ctrl_k = true
    local buf = org_buffer({ "* Hello world :café:" }, { 1, 8 })
    le.kill_line()
    eq({ "* Hello                                                                :café:" }, buf_lines(buf))
  end)

  it("special: on the tags kills them", function()
    config.opts.special_ctrl_k = true
    local buf = org_buffer({ "* TODO Title here   :tag:" }, { 1, 18 })
    le.kill_line()
    eq({ "* TODO Title here " }, buf_lines(buf))
    eq("  :tag:", vim.fn.getreg('"'))
  end)

  it("kills the hidden subtree of a folded headline", function()
    local buf = org_buffer({ "* H1", "body", "** H2", "* H3" }, { 1, 0 })
    vim.cmd("normal! zx")
    vim.cmd("1foldclose")
    vim.api.nvim_win_set_cursor(0, { 1, 2 })
    le.kill_line()
    eq({ "* ", "* H3" }, buf_lines(buf))
    eq("H1\nbody\n** H2", vim.fn.getreg('"'))
  end)

  it("ctrl_k_protect_subtree = error refuses", function()
    config.opts.ctrl_k_protect_subtree = "error"
    local buf = org_buffer({ "* H1", "body", "* H3" }, { 1, 0 })
    vim.cmd("normal! zx")
    vim.cmd("1foldclose")
    vim.api.nvim_win_set_cursor(0, { 1, 2 })
    local msg
    local orig = utils.error
    utils.error = function(m)
      msg = m
    end
    le.kill_line()
    utils.error = orig
    eq("kill_line aborted as it would kill a hidden subtree", msg)
    eq({ "* H1", "body", "* H3" }, buf_lines(buf))
  end)

  it("ctrl_k_protect_subtree = true asks", function()
    config.opts.ctrl_k_protect_subtree = true
    local buf = org_buffer({ "* H1", "body", "* H3" }, { 1, 0 })
    vim.cmd("normal! zx")
    vim.cmd("1foldclose")
    vim.api.nvim_win_set_cursor(0, { 1, 2 })
    local asked
    local orig = utils.confirm
    utils.confirm = function(m)
      asked = m
      return true
    end
    le.kill_line()
    utils.confirm = orig
    eq("Kill hidden subtree along with headline? ", asked)
    eq({ "* ", "* H3" }, buf_lines(buf))
  end)

  it("at the end of a line joins the next one", function()
    local buf = org_buffer({ "abc", "def" }, { 1, 0 })
    in_insert(buf, { 1, 0 }, le.kill_line) -- A: after the last character
    eq({ "abcdef" }, buf_lines(buf))
  end)
end)
