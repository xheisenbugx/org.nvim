-- What org buffers look like beyond the faces of the parser highlighter
-- (ui_highlight_*_spec.lua): checkbox icons, pretty entities, indent mode,
-- the buffer setup, and the Vim syntax of src block languages without a
-- tree-sitter parser (the regions org.syntax still defines).
local hl = require("tests.helpers.highlighter")

--- An org file opened with :edit (setup that reads the file).
local function edit(lines)
  local f = vim.fn.tempname() .. ".org"
  vim.fn.writefile(lines, f)
  vim.cmd("edit! " .. f)
  return vim.api.nvim_get_current_buf()
end

--- Screen text of rows 1..n.
local function screen(n)
  local out = {}
  for r = 1, n do
    local s = {}
    for c = 1, vim.o.columns do
      s[#s + 1] = vim.fn.screenstring(r, c)
    end
    out[r] = (table.concat(s):gsub("%s+$", ""))
  end
  return out
end

describe("ui decorations: checkboxes", function()
  it("draws checkbox icons as org.lists reads the item", function()
    local saved = require("org.config").opts.ui.checkboxes
    require("org.config").opts.ui.checkboxes = { "U", "P", "C" }
    vim.o.columns = 60
    edit({ "- [@3] [X] counter box", "- [ ]no space", "- [x] lower", "- [ ] plain" })
    vim.cmd("redraw!")
    local s = screen(4)
    require("org.config").opts.ui.checkboxes = saved
    eq("- [@3] [C] counter box", s[1])
    eq("- [ ]no space", s[2])
    eq("- [x] lower", s[3])
    eq("- [U] plain", s[4])
  end)
end)

describe("ui decorations: pretty entities", function()
  local saved
  before_each(function()
    saved = require("org.config").opts.ui.pretty_entities
    require("org.config").opts.ui.pretty_entities = true
    vim.o.columns = 80
  end)
  after_each(function()
    require("org.config").opts.ui.pretty_entities = saved
  end)

  local function render(lines)
    edit(lines)
    vim.wo.foldenable = false
    vim.api.nvim_win_set_cursor(0, { #lines, 0 })
    vim.cmd("redraw!")
    return screen(#lines)
  end

  it("follows #+OPTIONS: ^:{} for sub- and superscripts", function()
    local s = render({ "#+OPTIONS: ^:{}", "snake_case x^2 a_{i}", "" })
    eq("snake_case x^2 aᵢ", s[2])
    s = render({ "#+OPTIONS: toc:nil ^:nil", "snake_case x^2", "" })
    eq("snake_case x^2", s[2])
  end)

  it("doesn't raise scripts in property names, links, footnotes, tags, emphasis and comments", function()
    local s = render({
      "* Head :tag_x:",
      ":PROPERTIES:",
      ":CUSTOM_ID: abc",
      ":END:",
      "file:my_notes.org",
      "see[fn:my_note]",
      "*e_f* /g_h/",
      "# a_b",
      "a=b x^2 c=d",
      "",
    })
    eq("* Head :tag_x:", s[1])
    eq(":CUSTOM_ID: abc", s[3])
    eq("file:my_notes.org", s[5])
    eq("see[fn:my_note]", s[6])
    eq("*e_f* /g_h/", s[7])
    eq("# a_b", s[8])
    eq("a=b x² c=d", s[9])
  end)

  it("shows entities in quote and verse blocks, not in src blocks", function()
    local s = render({
      "#+begin_quote",
      "\\alpha x^2",
      "#+end_quote",
      "#+begin_src text",
      "\\beta",
      "#+end_src",
      "",
    })
    eq("α x²", s[2])
    eq("\\beta", s[5])
  end)
end)

describe("ui decorations: indent mode", function()
  local function inline_marks(buf, row)
    local ns = vim.api.nvim_get_namespaces()["org.decorations.inline"]
    return vim.api.nvim_buf_get_extmarks(buf, ns, { row or 0, 0 }, { row or -1, -1 }, { details = true })
  end

  it("prefixes empty lines too", function()
    vim.o.columns = 60
    local buf = edit({ "#+STARTUP: indent", "* A", "** B", "body", "", "more" })
    vim.cmd("redraw!")
    local width = 0
    for _, m in ipairs(inline_marks(buf, 4)) do
      for _, c in ipairs(m[4].virt_text or {}) do
        width = width + vim.fn.strdisplaywidth(c[1])
      end
    end
    eq(4, width)
  end)

  it("removes the prefixes after a reload with #+STARTUP: noindent", function()
    local f = vim.fn.tempname() .. ".org"
    vim.fn.writefile({ "#+STARTUP: indent", "* A", "text1", "** B", "body" }, f)
    vim.cmd("edit! " .. f)
    vim.cmd("redraw!")
    ok(#inline_marks(0) > 0)
    vim.fn.writefile({ "#+STARTUP: noindent", "* A", "text1", "** B", "body" }, f)
    vim.cmd("edit!")
    vim.cmd("redraw!")
    require("org.files").get_buffer(0)
    vim.cmd("redraw!")
    eq(0, #inline_marks(0))
  end)

  it("doesn't decorate rows hidden in a closed fold", function()
    local lines = { "#+STARTUP: indent", "* A" }
    for i = 1, 2000 do
      lines[#lines + 1] = "text line " .. i
    end
    lines[#lines + 1] = "* B"
    local buf = edit(lines)
    vim.wo.foldenable = true
    vim.cmd("2")
    vim.cmd("normal! zM")
    vim.cmd("redraw!")
    vim.api.nvim_buf_set_text(buf, 1, 3, 1, 3, { "x" })
    vim.cmd("redraw")
    ok(#inline_marks(buf) < 100, #inline_marks(buf))
  end)
end)

describe("ui buffer setup", function()
  it("sets concealing for org windows only", function()
    vim.cmd("enew!")
    vim.o.conceallevel, vim.o.concealcursor = 0, ""
    edit({ "* Head [[https://x.com][desc]]", "body" })
    eq(2, vim.wo.conceallevel)
    eq(0, vim.go.conceallevel)
    eq("", vim.go.concealcursor)
    vim.cmd("enew!")
    eq(0, vim.wo.conceallevel)
    eq("", vim.wo.concealcursor)
  end)

  it("undoes the org setup when the filetype changes", function()
    edit({ "* TODO Head", "body", "** sub", "text" })
    local undo = vim.b.undo_ftplugin or ""
    ok(not undo:match("^%s*|"), undo)
    local out = vim.api.nvim_exec2("set ft=org", { output = true }).output
    ok(not out:find("TODO Head", 1, true), out)
    vim.cmd("set ft=text")
    ok(not vim.wo.foldexpr:find("org"), vim.wo.foldexpr)
    ok(not vim.bo.indentexpr:find("org"), vim.bo.indentexpr)
    local m = vim.fn.maparg("<Tab>", "n", false, true)
    ok(not (m.desc and m.desc:find("org")), m.desc)
    vim.cmd("set ft=org")
    eq("v:lua.require'org.fold'.foldexpr(v:lnum)", vim.wo.foldexpr)
  end)
end)

describe("ui: src block languages", function()
  -- Emacs shows a block as typed: the json syntax doesn't hide quotes in
  -- it (g:vim_json_conceal), markdown's no emphasis markers
  -- (g:markdown_syntax_conceal), and the user's own setting stays
  it("includes json and markdown without their concealing", function()
    vim.g.vim_json_conceal = 1
    org_buffer({
      "#+begin_src json",
      '{"answer": "yes"}',
      "#+end_src",
      "#+begin_src markdown",
      "some *stars* here",
      "#+end_src",
    })
    vim.wo.conceallevel = 2
    for c = 1, #'{"answer": "yes"}' do
      eq(0, vim.fn.synconcealed(2, c)[1])
    end
    for c = 1, #"some *stars* here" do
      eq(0, vim.fn.synconcealed(5, c)[1])
    end
    eq(1, vim.g.vim_json_conceal)
    eq(nil, vim.g.markdown_syntax_conceal)
    vim.g.vim_json_conceal = nil
  end)

  -- c.vim's `syn sync ccomment` used to replace org's syncing for the buffer
  it("keeps org's syncing with an included src language", function()
    edit({ "* H", "#+begin_src c", "int x;", "#+end_src" })
    local out = vim.api.nvim_exec2("syntax sync", { output = true }).output
    ok(not out:find("C%-style"), out)
    ok(out:find("orgSyncHeadline", 1, true), out)
  end)

  -- syntax/org.vim of Neovim defined its own orgBold for the whole buffer
  it("doesn't include Neovim's bundled org syntax for org src blocks", function()
    org_buffer({ "* Top", "** Second level", "*** Third", "#+begin_src org", ",* nested", "#+end_src" })
    for l = 2, 3 do
      for c = 1, l do
        ok(not hl.has(l, c, "orgbold"), l .. ":" .. c .. " " .. hl.groups(l, c))
      end
    end
  end)

  it("highlights c++ blocks as cpp and export blocks in their language", function()
    org_buffer({
      "#+begin_src c++",
      "class Foo { public: int x; };",
      "#+end_src",
      "#+begin_src C",
      "int y;",
      "#+end_src",
      "#+begin_export html",
      "<b>hi</b>",
      "#+end_export",
    })
    ok(hl.has(2, 1, "orgsrcblock_cpp"), hl.groups(2, 1))
    ok(hl.has(5, 1, "orgsrcblock_c"), hl.groups(5, 1))
    ok(hl.has(8, 2, "orgsrcblock_html"), hl.groups(8, 2))
  end)

  it("highlights a src block of a language added after the buffer was opened", function()
    local buf = edit({ "* H", "text" })
    vim.api.nvim_buf_set_lines(buf, 2, 2, false, { "#+begin_src python", "def f(): return 1", "#+end_src" })
    vim.cmd("doautocmd TextChanged")
    ok(hl.has(4, 1, "orgsrcblock_python"), hl.groups(4, 1))
    -- and another one after that
    vim.api.nvim_buf_set_lines(buf, 2, 2, false, { "#+begin_src lua", "local x = 1", "#+end_src" })
    vim.cmd("doautocmd TextChanged")
    ok(hl.has(4, 1, "orgsrcblock_lua"), hl.groups(4, 1))
  end)
end)
