-- What reads or adds to an org buffer's highlighting: the buffer drawn by
-- the parser highlighter (org.ui.decorations), the syntax only including
-- the languages of src blocks.

local deco = require("org.ui.decorations")

--- The groups of the marks over byte `col` (0-based) of `row`.
local function groups_at(buf, row, col)
  local out = {}
  for _, m in ipairs(deco.line_marks(buf, row)) do
    local o = m[2]
    if o.hl_group and col >= m[1] and col < (o.end_col or m[1] + 1) then
      out[#out + 1] = o.hl_group
    end
  end
  return out
end

describe("parser highlighter consumers", function()
  with_config({ ui = {} })

  it("draws the beamer tags of org-beamer-mode", function()
    local beamer = require("org.export.beamer_mode")
    local line = "* Slide :B_block:BMCOL:x:"
    local buf = org_buffer({ line, "text" }, { 1, 0 })
    eq(false, vim.tbl_contains(groups_at(buf, 0, line:find("B_block") - 1), "orgBeamerTag"))
    beamer.mode(buf, true)
    ok(vim.tbl_contains(groups_at(buf, 0, line:find("B_block") - 1), "orgBeamerTag"))
    ok(vim.tbl_contains(groups_at(buf, 0, line:find("BMCOL") - 1), "orgBeamerTag"))
    eq(false, vim.tbl_contains(groups_at(buf, 0, line:find(":x:") + 0), "orgBeamerTag"))
    ok(vim.tbl_contains(groups_at(buf, 0, line:find(":x:") + 0), "orgTags"))
    beamer.mode(buf, false)
    eq(false, vim.tbl_contains(groups_at(buf, 0, line:find("B_block") - 1), "orgBeamerTag"))
  end)

  it("gives the sticky headline context the parser's marks", function()
    local context = require("org.ui.context")
    local lines = { "* TODO Read *the* [[https://x.org][docs]]" }
    for i = 2, 60 do
      lines[i] = "Body " .. i
    end
    org_buffer(lines, { 1, 0 })
    local win = vim.api.nvim_get_current_win()
    vim.wo[win].conceallevel = 2
    context.enable()
    local okc, err = pcall(function()
      vim.api.nvim_win_set_cursor(win, { 20, 0 })
      vim.fn.winrestview({ topline = 15 })
      context.update(win, true)
      local f = context.float(win)
      ok(f, "a context float")
      local fbuf = vim.api.nvim_win_get_buf(f --[[@as integer]])
      local groups, conceal = {}, 0
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(fbuf, -1, 0, -1, { details = true })) do
        if m[4].hl_group then
          groups[m[4].hl_group:lower()] = true
        end
        if m[4].conceal then
          conceal = conceal + 1
        end
      end
      ok(groups.orgbold and groups.orgtodo and groups.orglink and groups.orgheadlinelevel1, vim.inspect(groups))
      ok(conceal >= 2, "conceal marks: " .. conceal)
    end)
    context.disable()
    assert(okc, err)
  end)

  it(":Org inspect lists the ephemeral marks :Inspect doesn't see", function()
    local inspect = require("org.ui.inspect")
    local line = "* Note with *bold* and [cite:@key] =v="
    local buf = org_buffer({ line }, { 1, 0 })
    local function find(items, source, group)
      for _, it in ipairs(items) do
        if it.source == source and it.hl_group == group then
          return it
        end
      end
    end
    local at_bold = inspect.at(buf, 0, line:find("bold") - 1)
    ok(find(at_bold, "emphasis", "orgBold"), vim.inspect(at_bold))
    ok(find(at_bold, "parser", "orgHeadlineLevel1"), vim.inspect(at_bold))
    local at_key = inspect.at(buf, 0, line:find("@key"))
    ok(find(at_key, "citations", "OrgCite"), vim.inspect(at_key))
    local at_v = inspect.at(buf, 0, line:find("=v=") + 0)
    local found = false
    for _, it in ipairs(at_v) do
      found = found or it.spell == false
    end
    ok(found, vim.inspect(at_v))
    vim.api.nvim_win_set_cursor(0, { 1, line:find("bold") - 1 })
    local echo = vim.api.nvim_echo
    local shown
    vim.api.nvim_echo = function(chunks)
      shown = table.concat(
        vim.tbl_map(function(c)
          return c[1]
        end, chunks),
        ""
      )
    end
    local okr, err = pcall(require("org.actions").run, "inspect")
    vim.api.nvim_echo = echo
    assert(okr, err)
    ok(shown and shown:find("orgBold", 1, true), shown)
  end)
end)
