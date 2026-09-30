local date = require("org.date")
local utils = require("org.utils")

local dir = vim.fs.normalize(vim.fn.tempname())
vim.fn.mkdir(dir, "p")
-- macOS: /var is /private/var; the server reports resolved names
dir = vim.fs.normalize(vim.uv.fs_realpath(dir))
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
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  return vim.api.nvim_get_current_buf()
end

local function client_of(buf)
  local c
  vim.wait(2000, function()
    c = vim.lsp.get_clients({ bufnr = buf, name = "org" })[1]
    return c ~= nil and c.initialized
  end, 5)
  return c
end

local function request(buf, method, params)
  client_of(buf)
  local res = vim.lsp.buf_request_sync(buf, method, params, 3000)
  ok(res, "no response to " .. method)
  for _, r in pairs(res) do
    -- Neovim 0.10 names the field `error`, 0.11+ `err`
    local e = r.err or r.error
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
        return vim.uri_to_fname(r.uri), r.range.start.line + 1
      end
      if r and r[1] then
        return vim.uri_to_fname(r[1].uri), r[1].range.start.line + 1
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
        out[#out + 1] = vim.fs.basename(vim.uri_to_fname(l.uri)) .. ":" .. (l.range.start.line + 1)
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

    it("sees unsaved changes in other buffers", function()
      local ob = open(other)
      vim.api.nvim_buf_set_lines(ob, -1, -1, false, { "  New [[file:main.org::#report]]" })
      local buf = open(main)
      ok(rename(buf, 5, 18, "sum"))
      eq("  New [[file:main.org::#sum]]", buf_lines(ob)[#buf_lines(ob)])
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
end)
