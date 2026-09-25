-- Shrunk table columns (Emacs org-table-shrink, org-table-expand and
-- org-table-toggle-column-width, C-c TAB in a table).
local tbl = require("org.table")
local shrink = require("org.table.shrink")

--- Virtual texts drawn by shrinking, per line: { [lnum] = { text, ... } }.
local function shown(buf)
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, shrink.ns, 0, -1, { details = true })) do
    local l = m[2] + 1
    out[l] = out[l] or {}
    table.insert(out[l], m[4].virt_text[1][1])
  end
  return out
end

describe("shrinking table columns", function()
  local lines = {
    "| <3>    | x   |",
    "|--------+-----|",
    "| abcdef | yy  |",
    "| ab     | zzz |",
  }

  it("shrink shows the first W characters of columns with a cookie", function()
    local buf = org_buffer(lines, { 3, 2 })
    tbl.shrink(buf, 3)
    eq({
      [1] = { " <3>…" },
      [2] = { "----…" },
      [3] = { " abc…" },
      [4] = { " ab …" },
    }, shown(buf))
    -- the text is unchanged
    eq(lines, buf_lines(buf))
    eq(2, vim.wo.conceallevel)
    tbl.expand(buf, 3)
    eq({}, shown(buf))
  end)

  it("C-c TAB toggles the current column (one character without a cookie)", function()
    local buf = org_buffer(lines, { 3, 11 })
    tbl.toggle_column_width(0)
    eq({ [1] = { "…" }, [2] = { "…" }, [3] = { "…" }, [4] = { "…" } }, shown(buf))
    tbl.toggle_column_width(0)
    eq({}, shown(buf))
    -- count 4: columns with a width cookie; 16: expand all
    tbl.toggle_column_width(4)
    eq(" abc…", shown(buf)[3][1])
    tbl.toggle_column_width(16)
    eq({}, shown(buf))
  end)

  it("asks for column ranges outside the columns", function()
    local buf = org_buffer(lines, { 3, 0 })
    tbl.toggle_column_width(0, "1-")
    eq(2, #shown(buf)[3])
    eq({ [1] = true, [2] = true }, shrink.parse_ranges("-", 2))
    eq({ [2] = true, [3] = true, [5] = true }, shrink.parse_ranges("2-3 5", 6))
  end)

  it("stays shrunk after aligning and follows moved columns", function()
    local buf = org_buffer(lines, { 3, 2 })
    tbl.shrink(buf, 3)
    vim.api.nvim_win_set_cursor(0, { 3, 2 })
    tbl.move_column(1)
    eq({ [2] = true }, shrink.get(buf, 3))
    eq(" abc…", shown(buf)[3][1])
    tbl.align()
    eq(" abc…", shown(buf)[3][1])
  end)

  describe("with #+STARTUP: shrink", function()
    it("shrinks tables when the buffer is opened", function()
      local path = vim.fn.tempname() .. ".org"
      vim.fn.writefile({ "#+STARTUP: shrink", "| <2> |", "| abcd |" }, path)
      vim.cmd("edit! " .. path)
      local buf = vim.api.nvim_get_current_buf()
      vim.wait(200, function()
        return shown(buf)[3] ~= nil
      end)
      eq(" ab…", shown(buf)[3][1])
      vim.cmd("bwipe!")
    end)
  end)
end)
