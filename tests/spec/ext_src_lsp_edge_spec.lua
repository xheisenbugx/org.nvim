-- Edge cases of the src_lsp extension (fake server: tests/helpers/src_lsp.lua):
-- empty and unterminated blocks, upper-case keywords and header arguments,
-- tabs, multibyte text before a symbol, escapes, positions outside the
-- blocks or the file, a buffer emptied, and a long block.
local S = require("tests.helpers.src_lsp")

local function hidden_lines(buf)
  return vim.api.nvim_buf_get_lines(S.group(buf).hidden, 0, -1, false)
end

local function nothing(res)
  return res == nil or res == vim.NIL or (type(res) == "table" and #res == 0 and next(res) == nil)
end

describe("src_lsp edge cases", function()
  before_each(function()
    S.reset()
  end)
  after_each(function()
    require("org").setup({})
    S.wipe(S.main)
  end)

  it("mirrors a block with no body and one with only blank lines", function()
    S.setup(nil, {
      "#+begin_src lua",
      "#+end_src",
      "#+begin_src lua",
      "",
      "   ",
      "#+end_src",
      "#+begin_src lua",
      "x = 1",
      "#+end_src",
    })
    local buf = S.open(S.main)
    eq({ "", "", "", "", "", "", "", "x = 1", "" }, hidden_lines(buf))
  end)

  it("leaves an unterminated block out", function()
    S.setup(nil, { "#+begin_src lua", "x = 1", "#+begin_src lua", "bad = 1", "no end" })
    local buf = S.open(S.main)
    local g = S.group(buf)
    if g then
      eq({ "", "", "", "", "" }, hidden_lines(buf))
    end
  end)

  it("reads upper-case keywords, header arguments and switches", function()
    S.setup(nil, {
      "#+BEGIN_SRC lua :results silent :exports none",
      "a = 1",
      "#+END_SRC",
      "#+begin_src lua -n -r :tangle no",
      "b = 2",
      "#+end_src",
    })
    local buf = S.open(S.main)
    eq({ "", "a = 1", "", "", "b = 2", "" }, hidden_lines(buf))
  end)

  it("removes tab indentation common to a block and maps columns back", function()
    S.setup(nil, { "#+begin_src lua", "\tlocal function greet(n)", "\t\treturn bad", "\tend", "#+end_src" })
    local buf = S.open(S.main)
    eq({ "", "local function greet(n)", "\treturn bad", "end", "" }, hidden_lines(buf))
    S.fake_client(buf)
    vim.wait(3000, function()
      return #S.src_diags(buf) == 1
    end, 5)
    -- "bad" after two tabs and "return "
    eq({ { 3, 9, 12, "bad thing" } }, S.src_diags(buf))
  end)

  it("maps positions after multibyte text, for UTF-16 and UTF-8 servers", function()
    local org_line = "    local s = '日本語 é' .. greet('a')"
    local lines =
      { "- item", "  #+begin_src lua", "  local function greet(name) return name end", org_line, "  #+end_src" }
    local byte = org_line:find("greet", 1, true) - 1
    -- the org buffer's proxy speaks UTF-16, like Neovim's default
    local u16 = vim.str_utfindex(org_line, "utf-16", byte, false)
    for _, enc in ipairs({ "utf-16", "utf-8" }) do
      S.reset()
      S.position_encoding = enc ~= "utf-16" and enc or nil
      -- a server of its own per encoding, so no running client is reused
      S.setup({
        languages = {
          lua = { servers = { vim.tbl_extend("force", S.FAKE, { name = "fake_" .. enc:gsub("%-", "") }) } },
        },
      }, lines)
      local buf = S.open(S.main)
      local res, server_enc
      vim.wait(3000, function()
        local p = vim.lsp.get_clients({ bufnr = S.group(buf).hidden, name = "fake_" .. enc:gsub("%-", "") })[1]
        if not (p and p.initialized) then
          return false
        end
        server_enc = p.offset_encoding
        local r = vim.lsp.buf_request_sync(buf, "textDocument/hover", S.tdp(buf, 4, u16 + 2), 3000)
        local proxy = vim.lsp.get_clients({ bufnr = buf, name = "org_src" })[1]
        res = r and proxy and r[proxy.id] and r[proxy.id].result
        return res ~= nil
      end, 10)
      S.position_encoding = nil
      ok(res, enc)
      eq(enc, server_enc)
      eq("hover:greet", res.contents.value, enc)
      eq({ line = 3, character = u16 }, res.range.start, enc)
      eq({ line = 3, character = u16 + 5 }, res.range["end"], enc)
    end
  end)

  it("unescapes comma-escaped lines without moving columns", function()
    S.setup(nil, { "#+begin_src lua", ",#+end_src = 1", ",* bad", ",,* twice", "#+end_src" })
    local buf = S.open(S.main)
    eq({ "", " #+end_src = 1", " * bad", " ,* twice", "" }, hidden_lines(buf))
  end)

  it("answers nothing on the block's delimiters and past the end of the file", function()
    local buf = S.open((function()
      S.setup()
      return S.main
    end)())
    for _, pos in ipairs({ { 2, 1 }, { 6, 3 }, { #S.MAIN + 5, 1 }, { 3, 500 } }) do
      local res, err = S.request(buf, "textDocument/hover", S.tdp(buf, pos[1], pos[2]))
      ok(err == nil or err.code ~= -32603, vim.inspect({ pos, err }))
      if pos[1] ~= 3 then
        ok(nothing(res), vim.inspect({ pos, res }))
      end
    end
  end)

  it("blanks the mirror and the diagnostics when the buffer is emptied", function()
    S.setup()
    local buf = S.open(S.main)
    S.fake_client(buf)
    vim.wait(3000, function()
      return #S.src_diags(buf) == 2
    end, 5)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
    vim.wait(3000, function()
      return #S.src_diags(buf) == 0
    end, 5)
    eq({}, S.src_diags(buf))
    eq({ "" }, hidden_lines(buf))
  end)

  it("keeps a long block's lines in step", function()
    local lines = { "#+begin_src lua" }
    for i = 1, 2000 do
      lines[#lines + 1] = "local v" .. i .. " = " .. i
    end
    lines[#lines + 1] = "bad = 0"
    lines[#lines + 1] = "#+end_src"
    S.setup(nil, lines)
    local buf = S.open(S.main)
    local h = hidden_lines(buf)
    eq(#lines, #h)
    eq("local v2000 = 2000", h[2001])
    S.fake_client(buf)
    vim.wait(3000, function()
      return #S.src_diags(buf) == 1
    end, 5)
    eq({ { 2002, 0, 3, "bad thing" } }, S.src_diags(buf))
  end)

  it("mirrors only the configured language among several", function()
    S.setup({ languages = { lua = { servers = { S.FAKE } }, rust = {} } }, {
      "#+begin_src rust",
      "fn main() {}",
      "#+end_src",
      "#+begin_src lua",
      "y = 1",
      "#+end_src",
    })
    local buf = S.open(S.main)
    eq({ "", "", "", "", "y = 1", "" }, hidden_lines(buf))
  end)

  it("ignores a #+call and inline src blocks", function()
    S.setup(nil, { "#+call: thing()", "Inline src_lua{bad = 1} here.", "#+begin_src lua", "ok = 1", "#+end_src" })
    local buf = S.open(S.main)
    eq({ "", "", "", "ok = 1", "" }, hidden_lines(buf))
  end)
end)
