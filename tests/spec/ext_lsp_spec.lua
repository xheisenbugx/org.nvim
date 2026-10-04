local date = require("org.date")
local utils = require("org.utils")

local dir = vim.fs.normalize(vim.fn.tempname())
vim.fn.mkdir(dir, "p")
-- macOS: /var is /private/var; the server reports resolved names
dir = vim.fs.normalize(require("org.utils").realpath(dir))
local main = dir .. "/main.org"
local other = dir .. "/other.org"

local today = date.today()
local function ts(offset, extra)
  return "<" .. today:add(offset, "d"):to_string({ brackets = false }) .. (extra or "") .. ">"
end

local MAIN = {
  "#+TITLE: Main",
  "* TODO [#A] Write report :work:",
  "  SCHEDULED: " .. ts(3, " +1w"),
  "  :PROPERTIES:",
  "  :CUSTOM_ID: report",
  "  :ID: 1111-aaaa",
  "  :END:",
  "  See [[#report][the report]] and [[*Write report]].",
  "  :LOGBOOK:",
  "  CLOCK: [2026-01-05 Mon 10:00]--[2026-01-05 Mon 11:30] =>  1:30",
  "  :END:",
  "** Details",
  "   A <<anchor>> here and a footnote[fn:1].",
  "   #+NAME: numbers",
  "   | a | b |",
  "   | 1 | 2 |",
  "   #+NAME: hello",
  "   #+begin_src sh",
  "   echo hi",
  "   #+end_src",
  "* DONE Finished",
  "  Back to [[anchor]] and [[Details]].",
  "  Broken [[#nope]] link.",
  "",
  "[fn:1] The footnote text.",
}

local OTHER = {
  "* Elsewhere",
  "  Link [[file:main.org::#report][the report]]",
  "  And [[id:1111-aaaa][by id]] and [[file:main.org::*Write report][Write report]].",
  "  Plain id:1111-aaaa here.",
  "  #+begin_src org",
  "  [[#report]] is not a link in a block",
  "  #+end_src",
}

local function wipe(path)
  local b = utils.find_buffer(path)
  if b then
    vim.api.nvim_buf_delete(b, { force = true })
  end
end

local function setup(extra)
  for _, p in ipairs({ main, other }) do
    wipe(p)
  end
  utils.writefile(main, MAIN)
  utils.writefile(other, OTHER)
  require("org").setup(vim.tbl_deep_extend("force", {
    org_directory = dir,
    agenda_files = { main, other },
    extensions = { lsp = { diagnostics = { debounce = 10 } } },
  }, extra or {}))
end

local function open(path)
  -- a modified scratch buffer another spec left current can't be left
  if vim.bo.bufhidden == "wipe" then
    vim.bo.modified = false
  end
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  return vim.api.nvim_get_current_buf()
end

local function client_of(buf)
  local c
  vim.wait(2000, function()
    c = vim.lsp.get_clients({ bufnr = buf, name = "org" })[1]
    return c ~= nil and c.initialized == true
  end, 5)
  return c
end

local function request(buf, method, params)
  client_of(buf)
  local res = vim.lsp.buf_request_sync(buf, method, params, 3000)
  ok(res, "no response to " .. method)
  for _, r in pairs(res) do
    local e = r.err
    if e then
      return nil, e
    end
    return r.result
  end
end

local function tdp(buf, lnum, col)
  return {
    textDocument = { uri = vim.uri_from_bufnr(buf) },
    position = { line = lnum - 1, character = col - 1 },
  }
end

describe("lsp extension", function()
  before_each(function()
    setup()
  end)
  after_each(function()
    require("org").setup({
      org_directory = vim.fn.getcwd() .. "/tests/fixtures",
      agenda_files = { vim.fn.getcwd() .. "/tests/fixtures/*.org" },
    })
    for _, p in ipairs({ main, other }) do
      wipe(p)
    end
  end)

  it("attaches to org buffers", function()
    local buf = open(main)
    local c = client_of(buf)
    ok(c, "client attached")
    eq("org", c.name)
    eq("utf-8", c.offset_encoding)
  end)

  it("lists document symbols", function()
    local buf = open(main)
    local syms = request(buf, "textDocument/documentSymbol", { textDocument = { uri = vim.uri_from_bufnr(buf) } })
    eq(2, #syms)
    eq("Write report", syms[1].name)
    eq("TODO [#A] :work:", syms[1].detail)
    eq(vim.lsp.protocol.SymbolKind.Event, syms[1].kind)
    eq(vim.lsp.protocol.SymbolKind.Constant, syms[2].kind)
    eq(1, syms[1].range.start.line)
    eq(19, syms[1].range["end"].line)
    local details = syms[1].children[1]
    eq("Details", details.name)
    eq(
      { "numbers", "hello" },
      vim.tbl_map(function(s)
        return s.name
      end, details.children)
    )
    eq({ line = 13, character = 11 }, details.children[1].selectionRange.start)
  end)

  it("selects a #+NAME: symbol at its value when it also spells the keyword", function()
    local buf = open(main)
    vim.api.nvim_buf_set_lines(buf, 13, 14, false, { "   #+name: name" })
    local syms = request(buf, "textDocument/documentSymbol", { textDocument = { uri = vim.uri_from_bufnr(buf) } })
    local sym = syms[1].children[1].children[1]
    eq("name", sym.name)
    eq({ line = 13, character = 11 }, sym.selectionRange.start)
    eq({ line = 13, character = 15 }, sym.selectionRange["end"])
  end)

  it("finds workspace symbols across files", function()
    local buf = open(main)
    local syms = request(buf, "workspace/symbol", { query = "else" })
    eq(1, #syms)
    eq("Elsewhere", syms[1].name)
    eq(vim.uri_from_fname(other), syms[1].location.uri)
    syms = request(buf, "workspace/symbol", { query = "work report" })
    eq(
      { "Write report" },
      vim.tbl_map(function(s)
        return s.name
      end, syms)
    )
    syms = request(buf, "workspace/symbol", { query = "details" })
    eq("main.org › Write report", syms[1].containerName)
  end)

  it("sees an org file written after the first request", function()
    local buf = open(main)
    eq({}, request(buf, "workspace/symbol", { query = "brandnew" }))
    local path = dir .. "/new.org"
    -- :hide, for a modified buffer another spec left current
    vim.cmd("hide edit " .. vim.fn.fnameescape(path))
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "* Brandnew heading" })
    vim.cmd("silent write")
    vim.cmd("bwipeout")
    local syms = request(buf, "workspace/symbol", { query = "brandnew" })
    eq(1, #syms)
    vim.fn.delete(path)
  end)

  it("preloads the workspace files in the background", function()
    local buf = open(main)
    client_of(buf)
    local server = require("org.extensions.lsp.server")
    ok(vim.wait(3000, function()
      return server.last and server.last.preloaded ~= nil
    end, 10))
    eq(#require("org.extensions.lsp.util").workspace_files(), server.last.preloaded)
  end)

  describe("hover", function()
    local function hover(buf, lnum, col)
      local r = request(buf, "textDocument/hover", tdp(buf, lnum, col))
      return r and r.contents and r.contents.value
    end

    it("explains timestamps", function()
      local buf = open(main)
      local text = hover(buf, 3, 16)
      ok(text:find("SCHEDULED", 1, true), text)
      ok(text:find("in 3 days, " .. date.DAY_NAMES_LONG[today:add(3, "d"):weekday()], 1, true), text)
      ok(text:find("Repeats every 1 week", 1, true), text)
    end)

    it("describes relative dates", function()
      local hover_mod = require("org.extensions.lsp.hover")
      eq("today", hover_mod.relative(today, today))
      ok(hover_mod.relative(today:add(1, "d"), today):match("^tomorrow, "))
      ok(hover_mod.relative(today:add(-1, "d"), today):match("^yesterday, "))
      ok(hover_mod.relative(today:add(-5, "d"), today):match("^5 days ago, "))
      ok(hover_mod.relative(today:add(21, "d"), today):match("^in 3 weeks, "))
    end)

    it("shows clock durations", function()
      local buf = open(main)
      local text = hover(buf, 10, 5)
      ok(text:find("Clocked 1:30", 1, true), text)
    end)

    it("previews link targets", function()
      local buf = open(other)
      local text = hover(buf, 2, 12)
      ok(text:find("main.org", 1, true), text)
      ok(text:find("* TODO [#A] Write report :work:", 1, true), text)
      text = hover(buf, 3, 10)
      ok(text:find("Write report", 1, true), text)
    end)

    it("shows footnote definitions", function()
      local buf = open(main)
      local text = hover(buf, 13, 37)
      ok(text:find("The footnote text.", 1, true), text)
    end)

    it("counts backlinks of a headline with an ID", function()
      local buf = open(main)
      local text = hover(buf, 2, 20)
      ok(text:find("6 backlinks from 2 files", 1, true), text)
    end)
  end)

  describe("definition", function()
    local function def(buf, lnum, col)
      local r = request(buf, "textDocument/definition", tdp(buf, lnum, col))
      if r == vim.NIL then
        return nil
      end
      if r and r.uri then
        return vim.fs.normalize(vim.uri_to_fname(r.uri)), r.range.start.line + 1
      end
      if r and r[1] then
        return vim.fs.normalize(vim.uri_to_fname(r[1].uri)), r[1].range.start.line + 1
      end
    end

    it("follows internal links", function()
      local buf = open(main)
      eq({ main, 2 }, { def(buf, 8, 10) })
      eq({ main, 2 }, { def(buf, 8, 40) })
      eq({ main, 13 }, { def(buf, 22, 13) })
      eq({ main, 12 }, { def(buf, 22, 30) })
    end)

    it("follows file and id links to other files", function()
      local buf = open(other)
      eq({ main, 2 }, { def(buf, 2, 12) })
      eq({ main, 2 }, { def(buf, 3, 10) })
      eq({ main, 2 }, { def(buf, 4, 10) })
    end)

    it("goes to footnote definitions", function()
      local buf = open(main)
      eq({ main, 25 }, { def(buf, 13, 37) })
    end)

    it("returns nothing for broken links", function()
      local buf = open(main)
      eq(nil, def(buf, 23, 12))
    end)

    it("follows links to other files without parsing them as Org", function()
      local script = dir .. "/script.py"
      utils.writefile(script, { "import os", "", "def helper():", "    return 1" })
      local ob = open(other)
      vim.api.nvim_buf_set_lines(ob, -1, -1, false, { "  [[file:script.py::3]] and [[file:pic.png]]" })
      local last = #buf_lines(ob)
      local files = require("org.files")
      local get = files.get
      local parsed = {}
      files.get = function(p)
        parsed[#parsed + 1] = p
        return get(p)
      end
      local okd, res = pcall(function()
        local out = { def(ob, last, 5) }
        local r = request(ob, "textDocument/hover", tdp(ob, last, 5))
        out[#out + 1] = r and r.contents.value
        request(ob, "textDocument/documentLink", { textDocument = { uri = vim.uri_from_bufnr(ob) } })
        return out
      end)
      files.get = get
      ok(okd, res)
      eq({ script, 3 }, { res[1], res[2] })
      ok(res[3]:find("```python\ndef helper():", 1, true), res[3])
      for _, p in ipairs(parsed) do
        ok(p:match("%.org$"), "parsed " .. p)
      end
      vim.fn.delete(script)
    end)

    it("follows code: links of the code extension", function()
      local script = dir .. "/script.py"
      utils.writefile(script, { "import os", "", "def helper():", "    return 1" })
      setup({ extensions = { code = {} } })
      local ob = open(other)
      vim.api.nvim_buf_set_lines(ob, -1, -1, false, { "  [[code:script.py::helper]] [[code:nope.py::x]]" })
      local last = #buf_lines(ob)
      eq({ script, 3 }, { def(ob, last, 8) })
      eq(nil, def(ob, last, 35))
      vim.fn.delete(script)
    end)
  end)

  describe("references", function()
    local function refs(buf, lnum, col, decl)
      local r = request(buf, "textDocument/references", {
        textDocument = { uri = vim.uri_from_bufnr(buf) },
        position = { line = lnum - 1, character = col - 1 },
        context = { includeDeclaration = decl or false },
      })
      local out = {}
      for _, l in ipairs(r or {}) do
        out[#out + 1] = vim.fs.basename(vim.fs.normalize(vim.uri_to_fname(l.uri))) .. ":" .. (l.range.start.line + 1)
      end
      table.sort(out)
      return out
    end

    it("finds every link to a headline across files", function()
      local buf = open(main)
      eq({ "main.org:8", "main.org:8", "other.org:2", "other.org:3", "other.org:3", "other.org:4" }, refs(buf, 2, 20))
    end)

    it("works from a link and includes the declaration", function()
      local buf = open(other)
      local r = refs(buf, 2, 12, true)
      eq(7, #r)
      ok(vim.tbl_contains(r, "main.org:5"))
    end)

    it("finds links to a target", function()
      local buf = open(main)
      eq({ "main.org:22" }, refs(buf, 13, 8))
    end)

    it("finds radio links", function()
      local buf = open(main)
      vim.api.nvim_buf_set_lines(buf, 23, 24, false, { "  The <<<magic word>>> and a Magic  word again." })
      eq({ "main.org:24" }, refs(buf, 24, 12))
      local r = request(buf, "textDocument/definition", tdp(buf, 24, 35))
      eq(23, (r.range or r[1].range).start.line)
    end)

    it("finds footnote references", function()
      local buf = open(main)
      eq({ "main.org:13" }, refs(buf, 25, 3))
    end)
  end)

  describe("rename", function()
    local function rename(buf, lnum, col, new)
      local res, err = request(buf, "textDocument/rename", {
        textDocument = { uri = vim.uri_from_bufnr(buf) },
        position = { line = lnum - 1, character = col - 1 },
        newName = new,
      })
      if res then
        vim.lsp.util.apply_workspace_edit(res, "utf-8")
      end
      return res, err
    end

    it("prepares with the current name", function()
      local buf = open(main)
      local r = request(buf, "textDocument/prepareRename", tdp(buf, 5, 18))
      eq("report", r.placeholder)
      eq({ line = 4, character = 14 }, r.range.start)
      r = request(buf, "textDocument/prepareRename", tdp(buf, 2, 20))
      eq("Write report", r.placeholder)
      eq(vim.NIL, request(buf, "textDocument/prepareRename", tdp(buf, 24, 1)) or vim.NIL)
    end)

    it("renames a CUSTOM_ID and every link to it", function()
      local buf = open(main)
      ok(rename(buf, 5, 18, "summary"))
      local lines = buf_lines(buf)
      eq("  :CUSTOM_ID: summary", lines[5])
      eq("  See [[#summary][the report]] and [[*Write report]].", lines[8])
      local ob = utils.find_buffer(other)
      ok(ob, "other file loaded")
      eq("  Link [[file:main.org::#summary][the report]]", buf_lines(ob)[2])
      -- untouched: id links and the block
      eq(OTHER[3], buf_lines(ob)[3])
      eq(OTHER[6], buf_lines(ob)[6])
    end)

    it("renames a headline title and the links spelling it", function()
      local buf = open(main)
      ok(rename(buf, 2, 20, "Write the summary"))
      local lines = buf_lines(buf)
      eq("* TODO [#A] Write the summary :work:", lines[2])
      eq("  See [[#report][the report]] and [[*Write the summary]].", lines[8])
      local ob = utils.find_buffer(other)
      eq(
        "  And [[id:1111-aaaa][by id]] and [[file:main.org::*Write the summary][Write the summary]].",
        buf_lines(ob)[3]
      )
    end)

    it("renames from a link", function()
      local buf = open(other)
      ok(rename(buf, 2, 12, "rep"))
      eq("  Link [[file:main.org::#rep][the report]]", buf_lines(buf)[2])
      eq("  :CUSTOM_ID: rep", buf_lines(utils.find_buffer(main))[5])
    end)

    it("renames targets, footnotes and ids", function()
      local buf = open(main)
      ok(rename(buf, 13, 8, "spot"))
      eq("   A <<spot>> here and a footnote[fn:1].", buf_lines(buf)[13])
      eq("  Back to [[spot]] and [[Details]].", buf_lines(buf)[22])
      ok(rename(buf, 25, 3, "note"))
      eq("   A <<spot>> here and a footnote[fn:note].", buf_lines(buf)[13])
      eq("[fn:note] The footnote text.", buf_lines(buf)[25])
      ok(rename(buf, 6, 10, "2222-bbbb"))
      eq("  :ID: 2222-bbbb", buf_lines(buf)[6])
      local ob = utils.find_buffer(other)
      eq("  And [[id:2222-bbbb][by id]] and [[file:main.org::*Write report][Write report]].", buf_lines(ob)[3])
      eq("  Plain id:2222-bbbb here.", buf_lines(ob)[4])
    end)

    it("renames a #+NAME: whose value also spells the keyword", function()
      local buf = open(main)
      vim.api.nvim_buf_set_lines(buf, 13, 14, false, { "   #+name: name" })
      vim.api.nvim_buf_set_lines(buf, 21, 22, false, { "  Back to [[name]] and [[Details]]." })
      ok(rename(buf, 14, 14, "numbers"))
      eq("   #+name: numbers", buf_lines(buf)[14])
      eq("  Back to [[numbers]] and [[Details]].", buf_lines(buf)[22])
    end)

    it("renames a headline reached by a fuzzy link", function()
      local buf = open(main)
      ok(rename(buf, 22, 30, "Particulars"))
      eq("** Particulars", buf_lines(buf)[12])
      eq("  Back to [[anchor]] and [[Particulars]].", buf_lines(buf)[22])
    end)

    it("refuses a title that makes links ambiguous", function()
      local buf = open(main)
      local res, err = rename(buf, 12, 5, "Finished")
      eq(nil, res)
      ok(err.message:find("ambiguous"), err.message)
    end)

    it("edits a buffer opened through a symlink, not a second one", function()
      local link = vim.fs.dirname(dir) .. "/alias-" .. vim.fn.getpid() .. ".org"
      ok(vim.uv.fs_symlink(other, link))
      local ob = open(link)
      eq(link, vim.fs.normalize(vim.api.nvim_buf_get_name(ob)))
      local buf = open(main)
      ok(rename(buf, 5, 18, "summary"))
      eq("  Link [[file:main.org::#summary][the report]]", buf_lines(ob)[2])
      local same = 0
      for _, b in ipairs(vim.api.nvim_list_bufs()) do
        local name = vim.api.nvim_buf_get_name(b)
        if name ~= "" and require("org.utils").realpath(name) == other then
          same = same + 1
        end
      end
      eq(1, same)
      vim.api.nvim_buf_delete(ob, { force = true })
      vim.uv.fs_unlink(link)
    end)

    it("sees unsaved changes in other buffers", function()
      local ob = open(other)
      vim.api.nvim_buf_set_lines(ob, -1, -1, false, { "  New [[file:main.org::#report]]" })
      local buf = open(main)
      ok(rename(buf, 5, 18, "sum"))
      eq("  New [[file:main.org::#sum]]", buf_lines(ob)[#buf_lines(ob)])
    end)

    it("writes the files it had to load, and only those", function()
      local buf = open(main)
      eq(nil, utils.find_buffer(other))
      ok(rename(buf, 5, 18, "summary"))
      local ob = utils.find_buffer(other)
      -- (the save is asynchronous: a busy Windows runner took over a second)
      ok(vim.wait(10000, function()
        return not vim.bo[ob].modified
      end, 10))
      eq("  Link [[file:main.org::#summary][the report]]", vim.fn.readfile(other)[2])
      -- the renamed buffer itself is left to the user
      ok(vim.bo[buf].modified)
      eq(MAIN[5], vim.fn.readfile(main)[5])
    end)

    it("leaves them modified with write_unloaded = false", function()
      setup({ extensions = { lsp = { rename = { write_unloaded = false } } } })
      local buf = open(main)
      ok(rename(buf, 5, 18, "summary"))
      vim.wait(100)
      ok(vim.bo[utils.find_buffer(other)].modified)
      eq(OTHER, vim.fn.readfile(other))
    end)

    it("updates the ID database when renaming an ID", function()
      local id = require("org.id")
      id.register("1111-aaaa", main)
      local buf = open(main)
      ok(rename(buf, 6, 10, "2222-bbbb"))
      local known = id.known_ids()
      ok(vim.tbl_contains(known, "2222-bbbb"), vim.inspect(known))
      ok(not vim.tbl_contains(known, "1111-aaaa"), vim.inspect(known))
    end)

    it("updates id link descriptions that spell a renamed title", function()
      local ob = open(other)
      vim.api.nvim_buf_set_lines(ob, -1, -1, false, { "  Node [[id:1111-aaaa][Write report]]." })
      local buf = open(main)
      ok(rename(buf, 2, 20, "Write the summary"))
      eq("  Node [[id:1111-aaaa][Write the summary]].", buf_lines(ob)[#buf_lines(ob)])
      -- other descriptions are kept
      eq(OTHER[3]:gsub("%*Write report%]%[Write report", "*Write the summary][Write the summary"), buf_lines(ob)[3])
    end)

    it("renames a file-level ID (an org-roam file node)", function()
      local node = dir .. "/node.org"
      utils.writefile(node, { ":PROPERTIES:", ":ID: node-1", ":END:", "#+title: Node", "Text." })
      local ob = open(other)
      vim.api.nvim_buf_set_lines(ob, -1, -1, false, { "  See [[id:node-1][Node]]." })
      local last = #buf_lines(ob)
      local r = request(ob, "textDocument/definition", tdp(ob, last, 12))
      eq(node, vim.fs.normalize(vim.uri_to_fname((r.uri and r or r[1]).uri)))
      local list = request(ob, "textDocument/references", {
        textDocument = { uri = vim.uri_from_bufnr(ob) },
        position = { line = last - 1, character = 11 },
        context = { includeDeclaration = true },
      })
      eq(2, #list)
      ok(rename(ob, last, 12, "node-2"))
      eq("  See [[id:node-2][Node]].", buf_lines(ob)[last])
      local nb = utils.find_buffer(node)
      eq(":ID: node-2", buf_lines(nb)[2])
      vim.api.nvim_buf_delete(nb, { force = true })
      vim.fn.delete(node)
    end)

    it("refuses names that would clash", function()
      local buf = open(main)
      local res, err = rename(buf, 13, 8, "Details")
      eq(nil, res)
      ok(err and err.message:find("already has that name"), vim.inspect(err))
      res, err = rename(buf, 5, 18, "has space")
      eq(nil, res)
      ok(err.message:find("blanks"))
      eq(MAIN, buf_lines(buf))
    end)
  end)

  describe("diagnostics", function()
    it("publishes org-lint reports", function()
      local buf = open(main)
      client_of(buf)
      local diags
      vim.wait(3000, function()
        diags = vim.diagnostic.get(buf)
        return #diags > 0
      end, 10)
      local found
      for _, d in ipairs(diags) do
        if d.code == "invalid-custom-id-link" then
          found = d
        end
      end
      ok(found, vim.inspect(diags))
      eq(22, found.lnum)
      eq(vim.diagnostic.severity.ERROR, found.severity)
      eq("org-lint", found.source)
    end)

    it("updates after a change", function()
      local buf = open(main)
      client_of(buf)
      vim.wait(3000, function()
        return #vim.diagnostic.get(buf) > 0
      end, 10)
      vim.api.nvim_buf_set_lines(buf, 22, 23, false, { "  Fixed [[#report]] link." })
      local gone = vim.wait(3000, function()
        for _, d in ipairs(vim.diagnostic.get(buf)) do
          if d.code == "invalid-custom-id-link" then
            return false
          end
        end
        return true
      end, 10)
      ok(gone, vim.inspect(vim.diagnostic.get(buf)))
    end)

    it("honours severity and exclude options", function()
      setup({ extensions = { lsp = { diagnostics = { exclude = { "invalid-custom-id-link" } } } } })
      local diags = require("org.extensions.lsp.diagnostics").compute(open(main))
      for _, d in ipairs(diags) do
        ok(d.code ~= "invalid-custom-id-link")
      end
      setup({
        extensions = { lsp = { diagnostics = { severity = { checkers = { ["invalid-custom-id-link"] = "Hint" } } } } },
      })
      diags = require("org.extensions.lsp.diagnostics").compute(open(main))
      local hint
      for _, d in ipairs(diags) do
        if d.code == "invalid-custom-id-link" then
          hint = d.severity
        end
      end
      eq(4, hint)
    end)
  end)

  describe("code actions", function()
    local function actions(buf, lnum, col, diags)
      local pos = { line = lnum - 1, character = col - 1 }
      return request(buf, "textDocument/codeAction", {
        textDocument = { uri = vim.uri_from_bufnr(buf) },
        range = { start = pos, ["end"] = pos },
        context = { diagnostics = diags or {} },
      })
    end
    local function titled(list, title)
      for _, a in ipairs(list) do
        if a.title == title then
          return a
        end
      end
    end
    local function fix_for(buf, code)
      for _, d in ipairs(require("org.extensions.lsp.diagnostics").compute(buf)) do
        if d.code == code then
          return actions(buf, d.range.start.line + 1, 1, { d })[1]
        end
      end
    end

    it("offers entry commands", function()
      local buf = open(main)
      local list = actions(buf, 3, 1)
      ok(titled(list, "Schedule…"))
      ok(titled(list, "Archive subtree"))
      ok(titled(list, "Cycle TODO state"))
      eq(nil, titled(actions(buf, 1, 1), "Schedule…"))
    end)

    it("runs an entry command", function()
      local buf = open(main)
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      local a = titled(actions(buf, 21, 1), "Cycle TODO state")
      request(buf, "workspace/executeCommand", a.command)
      vim.wait(1000, function()
        return buf_lines(buf)[21] == "* Finished"
      end, 10)
      eq("* Finished", buf_lines(buf)[21])
      eq({ 21, 0 }, vim.api.nvim_win_get_cursor(0))
    end)

    it("converts a line to a checkbox item", function()
      local buf = open(main)
      local a = titled(actions(buf, 23, 3), "Convert line to checkbox item")
      vim.lsp.util.apply_workspace_edit(a.edit, "utf-8")
      eq("  - [ ] Broken [[#nope]] link.", buf_lines(buf)[23])
      a = titled(actions(buf, 23, 3), "Convert line to checkbox item")
      eq(nil, a)
    end)

    it("suggests a fix for a broken link", function()
      local buf = open(main)
      vim.api.nvim_buf_set_lines(buf, 22, 23, false, { "  Broken [[#reprt]] link." })
      local fix = fix_for(buf, "invalid-custom-id-link")
      ok(fix, "a fix")
      eq("Change link to #report", fix.title)
      eq("quickfix", fix.kind)
      vim.lsp.util.apply_workspace_edit(fix.edit, "utf-8")
      eq("  Broken [[#report]] link.", buf_lines(buf)[23])
    end)

    it("fixes more org-lint reports", function()
      local buf = open(main)
      local n = #buf_lines(buf)
      vim.api.nvim_buf_set_lines(buf, n, n, false, {
        "#+BEGIN_HTML",
        "<b>x</b>",
        "#+END_HTML",
        "  %%(diary-float t 4 2)",
        "#+AUTHOR Me",
        '#+INCLUDE: "other.org" html',
        "A [[file:a%20b%5B1%5D.org]] link.",
        "1. one",
        "3. three",
      })
      local function apply(code)
        local a = fix_for(buf, code)
        ok(a and a.kind == "quickfix" and a.edit, code .. ": " .. vim.inspect(a))
        vim.lsp.util.apply_workspace_edit(a.edit, "utf-8")
      end
      apply("deprecated-export-blocks")
      apply("indented-diary-sexp")
      apply("invalid-keyword-syntax")
      apply("obsolete-include-markup")
      apply("percent-encoding-link-escape")
      apply("item-number")
      eq({
        "#+BEGIN_EXPORT html",
        "<b>x</b>",
        "#+END_EXPORT",
        "%%(diary-float t 4 2)",
        "#+AUTHOR: Me",
        '#+INCLUDE: "other.org" export html',
        "A [[file:a b\\[1\\].org]] link.",
        "1. one",
        "3. [@3] three",
      }, vim.list_slice(buf_lines(buf), n + 1))
    end)

    it("removes a special property from a properties drawer", function()
      local buf = open(main)
      vim.api.nvim_buf_set_lines(buf, 5, 5, false, { "  :TODO: DONE" })
      local a = fix_for(buf, "special-property-in-properties-drawer")
      ok(a, "a fix")
      eq("Remove the TODO property", a.title)
      vim.lsp.util.apply_workspace_edit(a.edit, "utf-8")
      eq(MAIN, buf_lines(buf))
    end)

    it("fixes spurious colons and inactive planning", function()
      local buf = open(main)
      vim.api.nvim_buf_set_lines(buf, 1, 3, false, {
        "* TODO [#A] Write report ::work::",
        "  SCHEDULED: [2026-01-05 Mon]",
      })
      local a = fix_for(buf, "spurious-colons")
      ok(a and a.kind == "quickfix", vim.inspect(a))
      vim.lsp.util.apply_workspace_edit(a.edit, "utf-8")
      eq("* TODO [#A] Write report :work:", buf_lines(buf)[2])
      a = fix_for(buf, "planning-inactive")
      ok(a and a.kind == "quickfix", vim.inspect(a))
      vim.lsp.util.apply_workspace_edit(a.edit, "utf-8")
      eq("  SCHEDULED: <2026-01-05 Mon>", buf_lines(buf)[3])
    end)
  end)

  it("computes folding ranges and document links", function()
    local buf = open(main)
    local folds = request(buf, "textDocument/foldingRange", { textDocument = { uri = vim.uri_from_bufnr(buf) } })
    eq({ startLine = 1, endLine = 19, kind = "region" }, folds[1])
    local found_block = false
    for _, f in ipairs(folds) do
      if f.startLine == 17 and f.endLine == 19 then
        found_block = true
      end
    end
    ok(found_block, vim.inspect(folds))
    local dl = request(buf, "textDocument/documentLink", { textDocument = { uri = vim.uri_from_bufnr(buf) } })
    ok(#dl >= 3)
    eq(vim.uri_from_fname(main) .. "#L2", dl[1].target)
  end)

  it("stops and restarts", function()
    local buf = open(main)
    local c = client_of(buf)
    require("org.extensions.lsp").stop()
    vim.wait(2000, function()
      return c:is_stopped()
    end, 10)
    ok(c:is_stopped())
    eq(0, #require("org.extensions.lsp").clients())
    require("org.extensions.lsp").restart()
    local new = vim.wait(2000, function()
      local list = vim.lsp.get_clients({ bufnr = buf, name = "org" })
      return #list == 1 and list[1].id ~= c.id and #require("org.extensions.lsp").clients() == 1
    end, 10)
    ok(new, "a new client attached")
  end)

  it("answers on an empty file", function()
    local empty = dir .. "/empty.org"
    utils.writefile(empty, {})
    local buf = open(empty)
    local td = { textDocument = { uri = vim.uri_from_bufnr(buf) } }
    eq({}, request(buf, "textDocument/documentSymbol", td))
    eq({}, request(buf, "textDocument/foldingRange", td))
    eq({}, request(buf, "textDocument/documentLink", td))
    eq(vim.NIL, request(buf, "textDocument/hover", tdp(buf, 1, 1)) or vim.NIL)
    eq({}, require("org.extensions.lsp.diagnostics").compute(buf))
    wipe(empty)
    vim.fn.delete(empty)
  end)

  it("renames titles with multibyte characters (byte columns)", function()
    local ob = open(other)
    vim.api.nvim_buf_set_lines(ob, -1, -1, false, { "  Voir [[file:main.org::*Détails]] ici — [[*Elsewhere]]." })
    local buf = open(main)
    vim.api.nvim_buf_set_lines(buf, 11, 12, false, { "** Détails" })
    local edit = request(buf, "textDocument/rename", {
      textDocument = { uri = vim.uri_from_bufnr(buf) },
      position = { line = 11, character = 4 },
      newName = "Détails complets",
    })
    vim.lsp.util.apply_workspace_edit(edit, "utf-8")
    eq("** Détails complets", buf_lines(buf)[12])
    eq("  Voir [[file:main.org::*Détails complets]] ici — [[*Elsewhere]].", buf_lines(ob)[#buf_lines(ob)])
  end)

  it("reports a failing notification handler or filter once", function()
    local u = require("org.utils")
    local err = u.error
    local errors = {}
    u.error = function(msg)
      errors[#errors + 1] = msg
    end
    local server = require("org.extensions.lsp.server")
    local handler = server.notifications["textDocument/didChange"]
    server.notifications["textDocument/didChange"] = function()
      error("boom")
    end
    local okr, res = pcall(function()
      local buf = open(main)
      client_of(buf)
      for i = 1, 3 do
        vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "x" .. i })
        -- past the client's didChange debounce
        vim.wait(250)
      end
      server.notifications["textDocument/didChange"] = handler
      local n = #errors
      setup({
        extensions = {
          lsp = {
            filter = function()
              error("bad filter")
            end,
          },
        },
      })
      open(other)
      wipe(main)
      open(main)
      return n
    end)
    server.notifications["textDocument/didChange"] = handler
    u.error = err
    ok(okr, res)
    eq(1, res)
    eq(2, #errors)
    ok(errors[2]:find("bad filter", 1, true), errors[2])
  end)

  it("does not autostart when asked not to", function()
    setup({ extensions = { lsp = { autostart = false } } })
    local buf = open(main)
    vim.wait(100)
    eq(0, #vim.lsp.get_clients({ bufnr = buf, name = "org" }))
    require("org.actions").run("lsp_start")
    ok(client_of(buf))
  end)

  it("is inert when the extension is off", function()
    local buf = open(main)
    local c = client_of(buf)
    require("org").setup({ org_directory = dir, agenda_files = { main, other } })
    vim.wait(2000, function()
      return c:is_stopped()
    end, 10)
    ok(c:is_stopped())
    eq(nil, require("org.actions").list.lsp_start)
    wipe(main)
    buf = open(main)
    vim.wait(100)
    eq(0, #vim.lsp.get_clients({ bufnr = buf, name = "org" }))
  end)

  describe("links spanning lines", function()
    local SPAN = { "  A [[file:main.org::*Write", "  report][the", "  report]] spans lines." }

    it("finds, follows and renames them", function()
      local ob = open(other)
      vim.api.nvim_buf_set_lines(ob, -1, -1, false, SPAN)
      local r = request(ob, "textDocument/definition", tdp(ob, 9, 3))
      local loc = r.uri and r or r[1]
      eq({ main, 2 }, { vim.fs.normalize(vim.uri_to_fname(loc.uri)), loc.range.start.line + 1 })
      local buf = open(main)
      local list = request(buf, "textDocument/references", {
        textDocument = { uri = vim.uri_from_bufnr(buf) },
        position = { line = 1, character = 19 },
        context = { includeDeclaration = false },
      })
      local spanning
      for _, l in ipairs(list) do
        if l.range.start.line == 7 then
          spanning = l.range
        end
      end
      eq({ start = { line = 7, character = 4 }, ["end"] = { line = 9, character = 10 } }, spanning)
      local edit = request(buf, "textDocument/rename", {
        textDocument = { uri = vim.uri_from_bufnr(buf) },
        position = { line = 1, character = 19 },
        newName = "Write the summary",
      })
      vim.lsp.util.apply_workspace_edit(edit, "utf-8")
      local lines = buf_lines(ob)
      eq({ "  A [[file:main.org::*Write the summary][the", "  report]] spans lines." }, vim.list_slice(lines, 8))
    end)

    it("hovers them from any of their lines", function()
      local ob = open(other)
      vim.api.nvim_buf_set_lines(ob, -1, -1, false, SPAN)
      local r = request(ob, "textDocument/hover", tdp(ob, 10, 4))
      ok(r and r.contents.value:find("Write report", 1, true), vim.inspect(r))
      eq({ line = 7, character = 4 }, r.range.start)
    end)
  end)

  describe("diagnostics scheduling", function()
    local D = require("org.extensions.lsp.diagnostics")

    it("does not lint a buffer again at the same changedtick", function()
      local buf = open(main)
      local n = 0
      local sch = D.scheduler(function()
        n = n + 1
      end)
      sch.run(buf, true)
      sch.run(buf, true)
      eq(1, n)
      vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "" })
      sch.run(buf, true)
      eq(2, n)
      sch.clear(buf)
      eq(3, n)
      sch.run(buf, true)
      eq(4, n)
      sch.stop()
    end)

    it("lints in slices and starts over after a change", function()
      local buf = open(main)
      local got = {}
      local sch = D.scheduler(function(_, diags)
        got[#got + 1] = diags
      end)
      local slice = D.SLICE_MS
      D.SLICE_MS = 0
      local okr, res = pcall(function()
        sch.run(buf)
        -- one checker per tick: nothing yet
        eq(0, #got)
        vim.api.nvim_buf_set_lines(buf, 22, 23, false, { "  Fixed [[#report]] link." })
        vim.wait(200)
        -- abandoned: the text changed
        eq(0, #got)
        sch.run(buf)
        ok(vim.wait(3000, function()
          return #got == 1
        end, 5))
        return got[1]
      end)
      D.SLICE_MS = slice
      sch.stop()
      ok(okr, res)
      eq(D.compute(buf), res)
    end)

    it("lints large buffers only when opened and written", function()
      setup({ extensions = { lsp = { diagnostics = { max_lines = 10 } } } })
      local buf = open(main)
      local n = 0
      local sch = D.scheduler(function()
        n = n + 1
      end)
      sch.schedule(buf, 0, true)
      vim.wait(50)
      eq(0, n)
      sch.schedule(buf, 0)
      vim.wait(1000, function()
        return n == 1
      end, 5)
      eq(1, n)
      sch.stop()
    end)
  end)

  describe("with transclusion", function()
    local src = dir .. "/src.org"

    before_each(function()
      wipe(src)
      utils.writefile(src, {
        "* Borrowed",
        "  :PROPERTIES:",
        "  :CUSTOM_ID: report",
        "  :END:",
        "  Its [[#nowhere]] link and [[*Write report]].",
      })
      setup({ extensions = { transclusion = { mode = "materialized", watch = false } } })
    end)
    after_each(function()
      wipe(src)
      vim.fn.delete(src)
    end)

    local function transcluding()
      local buf = open(main)
      vim.api.nvim_buf_set_lines(buf, 20, 20, false, { "#+transclude: [[file:src.org::*Borrowed]]" })
      require("org.extensions.transclusion").add_all(buf)
      local regs = require("org.extensions.transclusion").regions(buf)
      eq(1, #regs)
      -- the property drawer is left out: lines 22-23
      eq({ "* Borrowed", "  Its [[#nowhere]] link and [[*Write report]]." }, vim.list_slice(buf_lines(buf), 22, 23))
      return buf
    end

    it("leaves the inserted text out of diagnostics", function()
      local buf = transcluding()
      for _, d in ipairs(require("org.extensions.lsp.diagnostics").compute(buf)) do
        ok(d.range.start.line + 1 < 22 or d.range.start.line + 1 > 23, vim.inspect(d))
        -- the copy of CUSTOM_ID "report" is no duplicate
        ok(d.code ~= "duplicate-custom-id", vim.inspect(d))
      end
    end)

    it("leaves it out of symbols, references and rename", function()
      local buf = transcluding()
      local syms = request(buf, "textDocument/documentSymbol", { textDocument = { uri = vim.uri_from_bufnr(buf) } })
      for _, sym in ipairs(syms) do
        ok(sym.name ~= "Borrowed", vim.inspect(syms))
      end
      local list = request(buf, "textDocument/references", {
        textDocument = { uri = vim.uri_from_bufnr(buf) },
        position = { line = 1, character = 19 },
        context = { includeDeclaration = false },
      })
      for _, l in ipairs(list) do
        ok(not (l.uri == vim.uri_from_bufnr(buf) and l.range.start.line == 22), vim.inspect(l))
      end
      local _, err = request(buf, "textDocument/rename", {
        textDocument = { uri = vim.uri_from_bufnr(buf) },
        position = { line = 21, character = 4 },
        newName = "Other",
      })
      ok(err and err.message:find("transcluded"), vim.inspect(err))
    end)
  end)
end)
