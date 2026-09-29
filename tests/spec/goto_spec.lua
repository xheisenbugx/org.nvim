-- org-goto: the outline browsing interface (org-goto-location) and the
-- outline path completion interface, like Emacs Org 9.8.10's org-goto.el.
local config = require("org.config")
local utils = require("org.utils")
vim.g.org_test = true

local text = { "* A", "a body", "** A1", "a1 body", "* B", "b body", "** B1 :tag:", "* C" }

local function keys(k)
  vim.api.nvim_feedkeys(vim.keycode(k), "xt", false)
end

local function quiet(body)
  local orig = vim.notify
  vim.notify = function() end
  local ok_, err = pcall(body)
  vim.notify = orig
  if not ok_ then
    error(err, 0)
  end
end

describe("goto: outline interface", function()
  local saved
  before_each(function()
    saved = { config.opts.goto_interface, config.opts.goto_auto_isearch }
  end)
  after_each(function()
    config.opts.goto_interface, config.opts.goto_auto_isearch = saved[1], saved[2]
  end)

  local function start(pos)
    local buf = org_buffer(text, pos or { 1, 0 })
    vim.cmd("normal! zR") -- the source keeps its visibility
    quiet(function()
      require("org.actions").run("buffer_goto")
    end)
    return buf
  end

  it("is the default and shows a read-only copy in overview", function()
    local src = start({ 4, 0 })
    local goto_buf = vim.api.nvim_get_current_buf()
    ok(goto_buf ~= src)
    eq("*org-goto*", vim.fn.fnamemodify(vim.api.nvim_buf_get_name(goto_buf), ":t"))
    eq(false, vim.bo.modifiable)
    eq(text, buf_lines(goto_buf))
    -- overview, with the start position revealed
    eq(4, vim.api.nvim_win_get_cursor(0)[1])
    eq(-1, vim.fn.foldclosed(4))
    eq(5, vim.fn.foldclosed(6) == -1 and 0 or 5)
    ok(vim.wo.winbar:find("RET=jump", 1, true))
    quiet(function()
      keys("<C-g>")
    end)
  end)

  it("<Down> and <CR> jump to the next headline, keeping the source folds", function()
    local src = start({ 1, 0 })
    quiet(function()
      keys("<Down><CR>")
    end)
    eq(src, vim.api.nvim_get_current_buf())
    eq({ 5, 0 }, vim.api.nvim_win_get_cursor(0))
    eq(-1, vim.fn.foldclosed(2)) -- the source is still expanded
    eq("", vim.wo.winbar)
    eq(-1, vim.fn.bufnr("*org-goto*"))
  end)

  it("<C-g> quits without moving", function()
    local src = start({ 2, 0 })
    local msg
    local orig = vim.notify
    vim.notify = function(m)
      msg = m
    end
    keys("<Down><C-g>")
    vim.notify = orig
    eq(src, vim.api.nvim_get_current_buf())
    eq(2, vim.api.nvim_win_get_cursor(0)[1])
    eq("Quit", msg)
  end)

  it("typing searches the headline text", function()
    local src = start({ 1, 0 })
    quiet(function()
      keys("B1<CR><CR>")
    end)
    eq(src, vim.api.nvim_get_current_buf())
    eq(7, vim.api.nvim_win_get_cursor(0)[1])
  end)

  it("<Left> jumps only from a headline", function()
    config.opts.goto_auto_isearch = false -- j moves (typing would search)
    local src = start({ 1, 0 })
    quiet(function()
      keys("<Tab>j<Left>")
    end)
    -- "a body": not a heading, still in the goto buffer
    ok(vim.api.nvim_get_current_buf() ~= src)
    quiet(function()
      keys("<Down><Right>")
    end)
    eq(src, vim.api.nvim_get_current_buf())
    eq(3, vim.api.nvim_win_get_cursor(0)[1])
  end)

  it("without auto-isearch: n p f b u move and q quits", function()
    config.opts.goto_auto_isearch = false
    local src = start({ 1, 0 })
    quiet(function()
      keys("fn")
    end)
    eq(8, vim.api.nvim_win_get_cursor(0)[1])
    quiet(function()
      keys("bq")
    end)
    eq(src, vim.api.nvim_get_current_buf())
    eq(1, vim.api.nvim_win_get_cursor(0)[1])
  end)

  it("a count uses the other interface", function()
    local buf = org_buffer(text, { 1, 0 })
    local seen
    local orig = utils.select
    utils.select = function(items, opts)
      seen = vim.tbl_map(opts.format_item, items)
      return items[3]
    end
    vim.keymap.set("n", "<F9>", function()
      require("org.actions").run("buffer_goto")
    end, { buffer = buf })
    keys("4<F9>")
    utils.select = orig
    eq({ "A", "A/A1", "B", "B/B1", "C" }, seen)
    eq(5, vim.api.nvim_win_get_cursor(0)[1])
  end)
end)

describe("goto: outline path completion", function()
  after_each(function()
    config.opts.goto_interface = "outline"
    config.opts.goto_max_level = 5
  end)

  it("offers headlines down to goto_max_level", function()
    config.opts.goto_interface = "outline-path-completion"
    config.opts.goto_max_level = 1
    org_buffer(text, { 1, 0 })
    local seen
    local orig = utils.select
    utils.select = function(items, opts)
      seen = vim.tbl_map(opts.format_item, items)
      return nil
    end
    quiet(function()
      require("org.actions").run("buffer_goto")
    end)
    utils.select = orig
    eq({ "A", "B", "C" }, seen)
  end)
end)
