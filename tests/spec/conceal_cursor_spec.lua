-- Normal-mode motions skip concealed text (issue #221): Emacs never leaves
-- point inside invisible text, so C-f / C-b over a descriptive link move
-- through its description only.

--- Run a Normal-mode motion and the CursorMoved that follows it (the
--- main loop doesn't run it after :normal).
local function press(keys)
  vim.cmd("normal! " .. keys)
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = 0 })
end

--- Put the cursor at byte column `c` (0-based), as a motion would.
local function at(c)
  vim.api.nvim_win_set_cursor(0, { vim.fn.line("."), c })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = 0 })
end

local function col()
  return vim.api.nvim_win_get_cursor(0)[2]
end

--- Byte columns of the cursor after each of `n` presses of `keys`.
local function walk(keys, n)
  local out = {}
  for i = 1, n do
    press(keys)
    out[i] = col()
  end
  return out
end

local LINE = "See [[https://example.org][the site]] end"
-- byte columns: "See " 0-3, "[[https://example.org][" 4-26,
-- "the site" 27-34, "]]" 35-36, " end" 37-40

describe("cursor on concealed text", function()
  before_each(function()
    vim.cmd("syntax on")
  end)

  it("moves through a link's description with l and h", function()
    org_buffer({ LINE }, { 1, 2 })
    eq(2, vim.wo.conceallevel)
    eq({ 3, 27, 28 }, walk("l", 3))
    at(33)
    eq({ 34, 37, 38 }, walk("l", 3))
    eq({ 37, 34 }, walk("h", 2))
    at(28)
    eq({ 27, 3, 2 }, walk("h", 3))
  end)

  it("stays on the description at the start and end of a line", function()
    org_buffer({ "[[https://example.org][site]]", "x" }, { 2, 0 })
    press("k")
    eq(23, col())
    press("$")
    eq(26, col())
    press("l")
    eq(26, col())
    press("0")
    eq(23, col())
    press("h")
    eq(23, col())
  end)

  it("goes forward after a motion from another line or over hidden text", function()
    org_buffer({ "aaaaaa", LINE }, { 1, 5 })
    press("j")
    eq(27, col())
    -- w from "site" stops on the hidden "]]": the space after it
    at(31)
    press("w")
    eq(37, col())
  end)

  describe("with hide_emphasis_markers", function()
    with_config({ ui = { hide_emphasis_markers = true } })
    it("skips hidden emphasis markers and multibyte descriptions", function()
      org_buffer({ "a *b* [[x][é!]]" }, { 1, 0 })
      eq({ 1, 3, 5, 11, 13 }, walk("l", 5))
    end)
  end)

  it("leaves the cursor alone where the line isn't concealed", function()
    org_buffer({ LINE }, { 1, 3 })
    vim.wo.concealcursor = ""
    press("l")
    eq(4, col())
    vim.wo.concealcursor = "nc"
    vim.wo.conceallevel = 1
    press("l")
    eq(5, col())
  end)
end)
