-- How the display extensions (transclusion, present, kanban, timeline)
-- draw their text.

local root = vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))

local function restore()
  require("org").setup({
    org_directory = root .. "/tests/fixtures",
    agenda_files = { root .. "/tests/fixtures/*.org" },
  })
end

local function today()
  return "<" .. require("org.date").today():to_string({ brackets = false }) .. ">"
end

describe("transclusion virtual lines", function()
  local T = require("org.extensions.transclusion")
  local dir

  local function setup(extra)
    require("org").setup(vim.tbl_extend("force", {
      org_directory = dir,
      agenda_files = { dir .. "/*.org" },
      extensions = { transclusion = { watch = false, debounce = 1 } },
    }, extra or {}))
  end

  before_each(function()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    setup()
  end)

  after_each(function()
    restore()
    vim.cmd("silent! %bwipeout!")
    vim.fn.delete(dir, "rf")
  end)

  --- Open notes.org transcluding src.org; the virtual lines as chunk lists.
  local function show(src, notes)
    vim.fn.writefile(src, dir .. "/src.org")
    vim.fn.writefile(notes or { "* Notes", "#+transclude: [[file:src.org::*Src]]" }, dir .. "/notes.org")
    vim.cmd("edit! " .. vim.fn.fnameescape(dir .. "/notes.org"))
    local buf = vim.api.nvim_get_current_buf()
    T.render(buf)
    local out = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, T.ns, 0, -1, { details = true })) do
      vim.list_extend(out, m[4].virt_lines or {})
    end
    return out
  end

  --- The text of a virtual line, without its border.
  local function text(vl)
    local t = {}
    for _, c in ipairs(vl) do
      t[#t + 1] = c[1]
    end
    return (table.concat(t):gsub("^%s*│ ", ""))
  end

  it("keeps the text between a plain link and a described one", function()
    local v = show({ "* Src", "See [[https://a.org]] and [[https://b.org][bee]] here." })
    eq("See https://a.org and bee here.", text(v[2]))
  end)

  it("shows headlines as written, COMMENT and tag alignment included", function()
    local src = {
      "* Src",
      "** COMMENT Draft idea",
      "** Aligned                                 :work:",
      "**  TODO [#A]  Spaced  :a:b:",
    }
    local v = show(src)
    for i, want in ipairs(src) do
      eq(want, text(v[i]))
    end
    local groups = {}
    for _, c in ipairs(v[4]) do
      groups[c[1]] = c[2]
    end
    eq("OrgTodo", groups["TODO"])
    eq("OrgPriority", groups["[#A]"])
    eq("OrgTags", groups[":a:b:"])
  end)

  it("colours the source file's own TODO keywords", function()
    local v = show({ "#+TODO: WAIT | OK", "* Src", "** WAIT Reply", "** TODO Not a keyword here", "** OK Done" })
    local function group_of(vl, word)
      for _, c in ipairs(vl) do
        if c[1] == word then
          return c[2]
        end
      end
    end
    eq("OrgTodo", group_of(v[2], "WAIT"))
    eq(nil, group_of(v[3], "TODO"))
    ok(text(v[3]):find("TODO Not a keyword", 1, true))
    eq("OrgDone", group_of(v[4], "OK"))
  end)

  it("lines up with the keyword in indent mode", function()
    setup({ ui = { indent_mode = true } })
    local v = show(
      { "* Src", "body" },
      { "* Notes", "** Deep", "text under deep", "#+transclude: [[file:src.org::*Src]] :level 3", "after" }
    )
    -- org-indent: text under a level-2 headline starts at column 4
    local _, prefix = require("org.ui.decorations").indent_widths({ indent_indentation_per_level = 2 }, 2)
    eq(4, prefix)
    for _, vl in ipairs(v) do
      eq(string.rep(" ", prefix), vl[1][1])
      eq("│ ", vl[2][1])
    end
  end)

  it("expands tabs to the source's tab stops", function()
    local v = show({ "* Src", "*b*\tx", "é\ty" })
    for i, ch in ipairs({ "x", "y" }) do
      local l = text(v[i + 1])
      eq(8, vim.fn.strdisplaywidth(l:sub(1, l:find(ch, 1, true) - 1)))
    end
  end)
end)

describe("present folded slides", function()
  local present = require("org.extensions.present")

  -- Headless Neovim 0.11 draws no floating window into the screen
  -- that screenstring() reads, and a presentation is a float.
  local function floats_drawn()
    local b = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "FLOAT" })
    local w = vim.api.nvim_open_win(b, false, { relative = "editor", row = 0, col = 0, width = 5, height = 1 })
    vim.cmd("redraw!")
    local s = ""
    for c = 1, 5 do
      s = s .. vim.fn.screenstring(1, c)
    end
    vim.api.nvim_win_close(w, true)
    vim.api.nvim_buf_delete(b, { force = true })
    return s == "FLOAT"
  end

  after_each(function()
    present.quit()
    restore()
    vim.cmd("enew!")
  end)

  it("draws a closed slide headline as it is drawn open", function()
    require("org").setup({
      org_directory = root .. "/tests/fixtures",
      agenda_files = {},
      extensions = { present = { startup_folded = true } },
    })
    org_buffer({ "* TODO Read [[https://neovim.io][Neovim]]", "Body text.", "** Sub", "more" }, { 1, 0 })
    present.start()
    local st = present.state
    eq("", vim.wo[st.win].foldtext)
    vim.api.nvim_win_call(st.win, function()
      eq(1, vim.fn.foldclosed(1))
      -- the link shows its description, as on an open line
      local col = vim.fn.getline(1):find("[[", 1, true)
      ok(vim.wo.conceallevel >= 2)
      eq(1, vim.fn.synconcealed(1, col)[1])
    end)
    if not floats_drawn() then
      return
    end
    vim.cmd("redraw!")
    local found
    for r = 1, vim.o.lines do
      local t = {}
      for c = 1, vim.o.columns do
        t[#t + 1] = vim.fn.screenstring(r, c)
      end
      local s = table.concat(t)
      if s:find("Read", 1, true) then
        found = s
        break
      end
    end
    ok(found, "the slide headline is on screen")
    ok(found:find("TODO Read Neovim", 1, true), found)
    eq(nil, found:find("[[", 1, true))
  end)
end)

describe("boards with ambiwidth=double", function()
  local saved

  before_each(function()
    saved = vim.o.ambiwidth
  end)

  after_each(function()
    vim.o.ambiwidth = saved
    pcall(require("org.extensions.kanban").close)
    pcall(require("org.extensions.timeline").close)
    restore()
    vim.cmd("enew!")
  end)

  --- Display width of each line of the view `open` draws, with 'ambiwidth'
  --- single and double.
  local function widths(lines, open)
    local out = {}
    for _, amb in ipairs({ "single", "double" }) do
      vim.o.ambiwidth = amb
      org_buffer(lines)
      local st = open()
      local w = {}
      for i, l in ipairs(vim.api.nvim_buf_get_lines(st.buf, 0, -1, false)) do
        w[i] = vim.fn.strdisplaywidth(l)
      end
      out[amb] = w
    end
    return out.single, out.double
  end

  it("keeps kanban cards and columns their width", function()
    require("org").setup({
      org_directory = root .. "/tests/fixtures",
      agenda_files = {},
      todo_keywords = { "TODO NEXT | DONE" },
      extensions = { kanban = {} },
    })
    local single, double = widths({
      "* TODO First task with a rather long title that wraps and wraps",
      "* NEXT Second task :work:",
      "* DONE x",
    }, function()
      return require("org.extensions.kanban").open({ source = "buffer" })
    end)
    -- the board rows (after the title and hint lines)
    for i = 3, #single do
      eq(single[i], double[i], "line " .. i)
    end
  end)

  it("keeps the timeline's separator and bars in line", function()
    require("org").setup({
      org_directory = root .. "/tests/fixtures",
      agenda_files = {},
      extensions = { timeline = {} },
    })
    vim.o.ambiwidth = "double"
    org_buffer({ "* TODO Task", "  SCHEDULED: " .. today() })
    local st = require("org.extensions.timeline").open({ source = "buffer" })
    local lines = vim.api.nvim_buf_get_lines(st.buf, 0, -1, false)
    local width
    for i = 3, #lines do
      local w = vim.fn.strdisplaywidth(lines[i])
      width = width or w
      eq(width, w, "line " .. i)
      ok(w <= vim.api.nvim_win_get_width(st.win))
    end
    ok(table.concat(lines, "\n"):find("#", 1, true), "bars fall back to one-cell characters")
  end)
end)

describe("timeline labels", function()
  after_each(function()
    pcall(require("org.extensions.timeline").close)
    restore()
    vim.cmd("enew!")
  end)

  it("cuts a keyword wider than the label so the separator stays in line", function()
    require("org").setup({
      org_directory = root .. "/tests/fixtures",
      agenda_files = {},
      todo_keywords = { "TODO IN-PROGRESS | DONE" },
      extensions = { timeline = { label_width = 10 } },
    })
    org_buffer({
      "* IN-PROGRESS Ship the release",
      "  SCHEDULED: " .. today(),
      "* TODO Short",
      "  SCHEDULED: " .. today(),
    })
    local st = require("org.extensions.timeline").open({ source = "buffer" })
    local cols = {}
    for i, l in ipairs(vim.api.nvim_buf_get_lines(st.buf, 0, -1, false)) do
      local b = i > 2 and (l:find("│", 1, true) or l:find("┼", 1, true))
      if b then
        cols[#cols + 1] = vim.fn.strdisplaywidth(l:sub(1, b - 1))
      end
    end
    ok(#cols >= 5)
    for _, c in ipairs(cols) do
      eq(11, c)
    end
  end)
end)
