-- Edge cases of the lsp extension: positions past the end of a line or of
-- the file, unknown documents, headlines with no title, deep and wide
-- outlines, malformed timestamps and links, bad new names for rename.
-- Every request answers (a result or a request error), never with an
-- internal error (a failure of the server's own code).
local utils = require("org.utils")

local dir = vim.fs.normalize(vim.fn.tempname())
vim.fn.mkdir(dir, "p")
dir = vim.fs.normalize(utils.realpath(dir))
local path = dir .. "/edge.org"

local INTERNAL = -32603

local LINES = {
  "*",
  "* ",
  "* TODO",
  "*** Skipped a level",
  "* 日本語の見出し 🎉 :タグ:",
  "  SCHEDULED: <2026-13-45 Foo>",
  "  DEADLINE: <not a date>",
  "  [[#]] [[]] [[file:]] [[id:]] [[*]] [fn:] [fn:missing]",
  "  <<>> <<<>>>",
  "  #+begin_src",
  "  unterminated block",
  "* Last",
}

local function wipe()
  local b = utils.find_buffer(path)
  if b then
    vim.api.nvim_buf_delete(b, { force = true })
  end
end

local function open(lines)
  wipe()
  utils.writefile(path, lines or LINES)
  require("org").setup({
    org_directory = dir,
    agenda_files = { path },
    extensions = { lsp = { diagnostics = { debounce = 10 } } },
  })
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  local buf = vim.api.nvim_get_current_buf()
  vim.wait(2000, function()
    local c = vim.lsp.get_clients({ bufnr = buf, name = "org" })[1]
    return c ~= nil and c.initialized == true
  end, 5)
  return buf
end

--- The result and error of `method`.
local function request(buf, method, params)
  local res = vim.lsp.buf_request_sync(buf, method, params, 3000)
  ok(res, "no response to " .. method)
  for _, r in pairs(res) do
    return r.result, r.err
  end
end

local function td(buf)
  return { uri = vim.uri_from_bufnr(buf) }
end

local function at(buf, line, character)
  return { textDocument = td(buf), position = { line = line, character = character } }
end

--- Ask every positional request at `line`, `character`; the errors of
--- the server's own code.
local function internal_errors(buf, line, character)
  local out = {}
  local p = at(buf, line, character)
  local range = { start = { line = line, character = character }, ["end"] = { line = line, character = character } }
  local asks = {
    { "textDocument/hover", p },
    { "textDocument/definition", p },
    { "textDocument/references", vim.tbl_extend("force", p, { context = { includeDeclaration = true } }) },
    { "textDocument/prepareRename", p },
    { "textDocument/completion", p },
    { "textDocument/codeAction", { textDocument = td(buf), range = range, context = { diagnostics = {} } } },
    { "textDocument/selectionRange", { textDocument = td(buf), positions = { p.position } } },
    { "textDocument/rangeFormatting", { textDocument = td(buf), range = range, options = {} } },
    { "textDocument/inlayHint", { textDocument = td(buf), range = range } },
  }
  for _, a in ipairs(asks) do
    local _, err = request(buf, a[1], a[2])
    if err and err.code == INTERNAL then
      out[#out + 1] = ("%s at %d:%d: %s"):format(a[1], line, character, err.message)
    end
  end
  return out
end

describe("lsp edge cases", function()
  after_each(function()
    wipe()
    require("org").setup({
      org_directory = vim.fn.getcwd() .. "/tests/fixtures",
      agenda_files = { vim.fn.getcwd() .. "/tests/fixtures/*.org" },
    })
  end)

  it("answers at every position of odd lines, and past their ends", function()
    local buf = open()
    local errors = {}
    for line = 0, #LINES - 1 do
      local len = #LINES[line + 1]
      for _, character in ipairs({ 0, math.floor(len / 2), len, len + 5 }) do
        vim.list_extend(errors, internal_errors(buf, line, character))
      end
    end
    eq({}, errors)
  end)

  it("answers past the last line of the file", function()
    local buf = open()
    eq({}, internal_errors(buf, #LINES + 3, 0))
  end)

  it("answers the whole-document requests", function()
    local buf = open()
    for _, m in ipairs({
      "textDocument/documentSymbol",
      "textDocument/foldingRange",
      "textDocument/documentLink",
      "textDocument/formatting",
      "textDocument/codeLens",
    }) do
      local _, err = request(buf, m, { textDocument = td(buf), options = {} })
      ok(not (err and err.code == INTERNAL), m .. ": " .. vim.inspect(err))
    end
  end)

  it("lists headlines with no title and unicode titles as symbols", function()
    local buf = open()
    local syms = request(buf, "textDocument/documentSymbol", { textDocument = td(buf) })
    local names = {}
    local function walk(list)
      for _, s in ipairs(list) do
        names[#names + 1] = s.name
        ok(type(s.name) == "string" and s.name ~= "", vim.inspect(s))
        walk(s.children or {})
      end
    end
    walk(syms)
    ok(vim.tbl_contains(names, "日本語の見出し 🎉"), vim.inspect(names))
  end)

  it("refuses an unknown document with a request error", function()
    local buf = open()
    local _, err = request(buf, "textDocument/hover", {
      textDocument = { uri = vim.uri_from_fname(dir .. "/does-not-exist.org") },
      position = { line = 0, character = 0 },
    })
    ok(err and err.code ~= INTERNAL, vim.inspect(err))
  end)

  it("refuses empty and link-breaking new names", function()
    local buf = open({ "* Target", "  :PROPERTIES:", "  :CUSTOM_ID: target", "  :END:", "* Links [[#target]]" })
    for _, name in ipairs({ "", "   ", "with]]brackets", "new\nline" }) do
      local res, err = request(buf, "textDocument/rename", vim.tbl_extend("force", at(buf, 2, 17), { newName = name }))
      ok(err and err.code ~= INTERNAL, vim.inspect({ name, res, err }))
    end
    eq("  :CUSTOM_ID: target", buf_lines(buf)[3])
  end)

  it("lists a deep and wide outline", function()
    local lines = {}
    for i = 1, 60 do
      lines[#lines + 1] = string.rep("*", i) .. " Level " .. i
    end
    for i = 1, 300 do
      lines[#lines + 1] = "* Sibling " .. i
    end
    local buf = open(lines)
    local syms, err = request(buf, "textDocument/documentSymbol", { textDocument = td(buf) })
    eq(nil, err)
    eq(301, #syms)
    local depth, s = 0, syms[1]
    while s do
      depth = depth + 1
      s = s.children and s.children[1]
    end
    eq(60, depth)
  end)

  it("publishes diagnostics for a file of broken syntax without failing", function()
    local buf = open()
    local got = vim.wait(3000, function()
      return #vim.diagnostic.get(buf) > 0
    end)
    ok(got)
  end)
end)
