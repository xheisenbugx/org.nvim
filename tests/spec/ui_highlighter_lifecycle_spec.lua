-- ui.highlighter = "parser" over the life of a buffer: reloading it,
-- turning org off and on, errors while drawing, switching the highlighter
-- with setup() again and the rows kept over editing commands
-- (org.ui.decorations, org.ui.highlight).
local deco = require("org.ui.decorations")

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")

--- Every row's marks, as one string per row: as drawn (`fresh`: as a
--- scan of that row alone draws them, with the same parse).
local function all_marks(buf, fresh)
  local ui = fresh and deco.ui_options(buf, require("org.ui.highlight").file_in_use(buf))
  local out = {}
  for row = 0, vim.api.nvim_buf_line_count(buf) - 1 do
    local t = {}
    local marks = fresh and deco.compute(buf, row, row, ui)[row] or not fresh and deco.line_marks(buf, row) or {}
    for _, m in ipairs(marks) do
      local o = vim.tbl_extend("force", {}, m[2])
      o.ephemeral = nil
      t[#t + 1] = m[1] .. ":" .. vim.inspect(o, { newline = "", indent = "" })
    end
    table.sort(t)
    out[row + 1] = table.concat(t, " ")
  end
  return out
end

--- The groups drawn at byte `col` (0-based) of row `row`: by the
--- decorations, and by the syntax.
local function groups_at(buf, row, col)
  local marks = {}
  for _, m in ipairs(deco.line_marks(buf, row)) do
    if m[2].hl_group and col >= m[1] and col < (m[2].end_col or m[1] + 1) then
      marks[#marks + 1] = m[2].hl_group
    end
  end
  local syn = {}
  vim.api.nvim_buf_call(buf, function()
    for _, id in ipairs(vim.fn.synstack(row + 1, col + 1)) do
      syn[#syn + 1] = vim.fn.synIDattr(id, "name")
    end
  end)
  return marks, syn
end

describe("ui.highlighter = parser, over the life of a buffer", function()
  with_config({ ui = { highlighter = "parser" } })

  after_each(function()
    pcall(vim.cmd, "silent! %bwipeout!")
  end)

  it("keeps rows over an edit inside a line after :edit!", function()
    -- (:edit! detaches the buffer's on_bytes listener: the decorations
    -- must listen again, or no edit keeps rows any more)
    local f = dir .. "/reload.org"
    vim.fn.writefile({ "* H", "", "text *bold* a", "", "more" }, f)
    vim.cmd("edit! " .. vim.fn.fnameescape(f))
    local buf = vim.api.nvim_get_current_buf()
    vim.cmd("edit!")
    all_marks(buf)
    local carried = deco._carried
    vim.api.nvim_buf_set_text(buf, 4, 0, 4, 0, { "x" })
    eq(all_marks(buf, true), all_marks(buf))
    eq(carried + 1, deco._carried)
  end)

  it("keeps rows over an edit inside a line after the buffer was unloaded", function()
    local f = dir .. "/unload.org"
    vim.fn.writefile({ "* H", "", "text *bold* a", "", "more" }, f)
    vim.cmd("edit! " .. vim.fn.fnameescape(f))
    local buf = vim.api.nvim_get_current_buf()
    vim.cmd("enew")
    vim.cmd("bunload " .. buf)
    vim.cmd("buffer " .. buf)
    all_marks(buf)
    local carried = deco._carried
    vim.api.nvim_buf_set_text(buf, 4, 0, 4, 0, { "x" })
    eq(all_marks(buf, true), all_marks(buf))
    eq(carried + 1, deco._carried)
  end)

  it("forgets the parse of a buffer that stopped being org once it is wiped out", function()
    local hl = require("org.ui.highlight")
    local buf = org_buffer({ "* TODO H", "text *bold*" }, { 1, 0 })
    all_marks(buf)
    ok(hl._parses[buf] ~= nil)
    vim.bo[buf].filetype = "text"
    vim.cmd("bwipeout! " .. buf)
    eq(nil, hl._parses[buf])
  end)

  it("draws nothing and reports once when drawing fails, then draws again", function()
    local hl = require("org.ui.highlight")
    local add_marks = hl.add_marks
    local buf = org_buffer({ "* TODO H", "text *bold*" }, { 1, 0 })
    local notified = {}
    local notify = vim.notify
    vim.notify = function(msg)
      notified[#notified + 1] = msg
    end
    hl.add_marks = function()
      error("boom")
    end
    local ok_all, err = pcall(function()
      for i = 1, 3 do
        vim.api.nvim_buf_set_text(buf, 1, 0, 1, 0, { tostring(i) })
        vim.cmd("redraw!")
      end
      vim.wait(20)
    end)
    hl.add_marks = add_marks
    vim.notify = notify
    ok(ok_all, err)
    local errors = vim.tbl_filter(function(m)
      return m:find("Error in decoration provider", 1, true) ~= nil
    end, vim.split(vim.fn.execute("messages"), "\n"))
    eq({}, errors)
    eq(1, #notified)
    ok(notified[1]:find("boom", 1, true))
    -- (and the next edit is drawn)
    vim.api.nvim_buf_set_text(buf, 1, 0, 1, 0, { "x" })
    vim.cmd("redraw!")
    ok(vim.tbl_contains((groups_at(buf, 1, 10)), "orgBold"))
  end)
end)

describe("ui.highlighter switched with setup() again", function()
  local root = vim.fn.getcwd()
  local function setup(highlighter)
    require("org").setup({
      org_directory = root .. "/tests/fixtures",
      agenda_files = { root .. "/tests/fixtures/*.org" },
      ui = { highlighter = highlighter },
    })
  end

  after_each(function()
    setup("parser")
  end)

  it("draws open org buffers with the new highlighter", function()
    setup("parser")
    local buf = org_buffer({ "* TODO H", "text *bold* a" }, { 1, 0 })
    vim.cmd("redraw")
    local marks, syn = groups_at(buf, 1, 6)
    ok(vim.tbl_contains(marks, "orgBold"))
    eq({}, syn)
    setup("syntax")
    vim.cmd("redraw")
    marks, syn = groups_at(buf, 1, 6)
    eq({}, marks)
    ok(vim.tbl_contains(syn, "OrgBold"), vim.inspect(syn))
    setup("parser")
    vim.cmd("redraw")
    marks, syn = groups_at(buf, 1, 6)
    ok(vim.tbl_contains(marks, "orgBold"))
    eq({}, syn)
  end)
end)

-- The rows kept over edits (org.ui.decorations `carried`) after the edits
-- of Normal mode and Ex commands, not only nvim_buf_set_text: undo and
-- redo, :substitute, Visual block inserts, joins, puts and deletes.
describe("ui.highlighter = parser, rows kept over editing commands", function()
  with_config({ ui = { highlighter = "parser", hide_emphasis_markers = true, pretty_entities = true } })
  local fuzz = require("tests.helpers.fuzz")

  local OPS = {
    function(rng)
      vim.cmd("normal! " .. rng:int(1, 3) .. "x")
    end,
    function(rng)
      vim.cmd("normal! a" .. rng:pick({ "*", "/", "=", "a b", "[[", "]]", "~", "_", " " }))
    end,
    function()
      vim.cmd("silent! undo")
    end,
    function()
      vim.cmd("silent! redo")
    end,
    function()
      vim.cmd("silent! s/a/*/g")
    end,
    function()
      vim.cmd("silent! s/ /=/")
    end,
    function()
      vim.cmd('exe "normal! 0\\<C-v>jjI*\\<Esc>"')
    end,
    function()
      vim.cmd("normal! J")
    end,
    function()
      vim.cmd("normal! yyp")
    end,
    function()
      vim.cmd("normal! dd")
    end,
    function()
      vim.cmd("normal! ~")
    end,
    function(rng)
      vim.cmd("normal! r" .. rng:pick({ "*", "x", " ", "#", "\\" }))
    end,
  }

  it("draws every row as a fresh scan does", function()
    for _, seed in ipairs(fuzz.seeds(4)) do
      local rng = fuzz.rng(seed)
      local lines = fuzz.doc(rng, { crlf = false })
      local buf = org_buffer(lines, { 1, 0 })
      all_marks(buf)
      for _ = 1, 40 do
        local n = vim.api.nvim_buf_line_count(buf)
        local row = rng:int(1, n)
        local len = #vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1]
        vim.api.nvim_win_set_cursor(0, { row, len > 0 and rng:int(0, len - 1) or 0 })
        pcall(rng:pick(OPS), rng)
        local kept, fresh = all_marks(buf), all_marks(buf, true)
        local now = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        for i = 1, #fresh do
          if kept[i] ~= fresh[i] then
            error(fuzz.report(seed, ("row %d drawn after an edit differs"):format(i - 1), now, now))
          end
        end
      end
    end
  end)
end)
