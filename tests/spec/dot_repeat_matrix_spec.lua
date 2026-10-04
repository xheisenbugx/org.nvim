-- Dot-repeat must do what pressing the key again would: for each repeatable
-- key, an edit (or none) in between, and a cursor move, "." and the key
-- give the same text and cursor.
local function keys(k)
  vim.api.nvim_feedkeys(vim.keycode(k), "xt", false)
end
local function snap(buf)
  return { lines = buf_lines(buf), cur = vim.api.nvim_win_get_cursor(0) }
end

local docs = {
  list = { "* H", "- [ ] one", "- [ ] two", "- [ ] three", "- [ ] four" },
  list_plain = { "* H", "- one", "- two", "- three", "- four" },
  nested = { "* H [/]", "- [ ] one", "  - [ ] sub", "- [ ] two", "- [X] three", "- [ ] four" },
  heads = { "* A", "** B", "text b", "** C", "* D", "** E" },
  todo = { "* TODO A", "* B", "* [#B] C", "* D <2026-10-04 Sun>", "* E" },
  table = { "| a | b |", "|---+---|", "| 1 | 2 |", "| 3 | 4 |" },
}
-- key, doc, start cursor, move between
local repeatable = {
  { "<M-l>", "list", { 3, 0 } },
  { "<M-h>", "nested", { 3, 2 } },
  { "<M-j>", "list", { 2, 0 } },
  { "<M-k>", "list", { 5, 0 } },
  { "<M-L>", "list", { 3, 0 } },
  { "<S-Right>", "list", { 2, 0 } },
  { "<S-Left>", "list_plain", { 2, 0 } },
  { "<C-Space>", "list", { 2, 0 } },
  { ">>", "heads", { 2, 0 } },
  { "<<", "heads", { 2, 0 } },
  { ">s", "heads", { 2, 0 } },
  { "cit", "todo", { 1, 0 } },
  { "<S-Up>", "todo", { 1, 0 } },
  { "<S-Right>", "todo", { 1, 0 } },
  { "<C-a>", "todo", { 4, 10 } },
  { "<M-j>", "table", { 3, 2 } },
  { "<M-l>", "table", { 1, 2 } },
  { "<M-K>", "table", { 3, 2 } },
  { "<C-c>-", "list_plain", { 2, 0 } },
  { "<C-c>*", "list_plain", { 2, 0 } },
}
local between = { "", "<C-c><C-c>", "<C-Space>", "<Tab>", "u", "ix<Esc>", "zc", "yy", "<C-c><C-c>u" }
local moves = { "j", "" }

describe("dot-repeat matrix: . = pressing the key again", function()
  local saved
  before_each(function()
    saved = { vim.fn.input, vim.ui.input, vim.ui.select, vim.fn.confirm }
    vim.fn.input = function()
      return ""
    end
    vim.ui.input = function(_, cb)
      cb(nil)
    end
    vim.ui.select = function(_, _, cb)
      cb(nil)
    end
    vim.fn.confirm = function()
      return 2
    end
  end)
  after_each(function()
    vim.fn.input, vim.ui.input, vim.ui.select, vim.fn.confirm = unpack(saved)
  end)
  for _, case in ipairs(repeatable) do
    for _, mid in ipairs(between) do
      for _, mv in ipairs(moves) do
        local key, doc, cur = case[1], case[2], case[3]
        it(("%s | %s | %s | %s"):format(key, doc, mid, mv), function()
          local function run(second)
            local buf = org_buffer(docs[doc], cur)
            keys(key)
            -- the in-between key may itself be repeatable (C-Space): it then
            -- owns "." in both runs, so "again" means that key
            local again = key
            if mid ~= "" then
              keys(mid)
              if mid == "<C-Space>" and doc ~= "table" then
                again = "<C-Space>"
              end
              if mid:find("ix") then
                again = "."
              end -- native insert owns .
            end
            keys(mv)
            keys(second and again or ".")
            local s = snap(buf)
            vim.cmd("bwipe!")
            return s
          end
          local dot = run(false)
          local direct = run(true)
          eq(direct.lines, dot.lines)
          eq(direct.cur, dot.cur)
        end)
      end
    end
  end
end)
