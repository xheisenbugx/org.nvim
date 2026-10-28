-- extensions.src_lsp: language servers inside src blocks, against a fake
-- in-process "lua" server (no real server needed; tests/helpers/src_lsp.lua).
local S = require("tests.helpers.src_lsp")
local utils = require("org.utils")

local dir, main, MAIN, FAKE = S.dir, S.main, S.MAIN, S.FAKE
local requests = S.requests
local wipe, setup, open, mirror, group = S.wipe, S.setup, S.open, S.mirror, S.group
local fake_client, proxy_ready, request, tdp, src_diags = S.fake_client, S.proxy_ready, S.request, S.tdp, S.src_diags

describe("src_lsp extension", function()
  before_each(function()
    S.reset()
    setup()
  end)
  after_each(function()
    require("org").setup({})
    wipe(main)
  end)

  it("mirrors the blocks of a language at their own lines", function()
    local buf = open(main)
    local g = group(buf)
    ok(g, "a lua group")
    eq(nil, group(buf, "python"))
    local lines = vim.api.nvim_buf_get_lines(g.hidden, 0, -1, false)
    eq(#MAIN, #lines)
    eq("local function greet(name)", lines[3])
    eq("  return 'hi ' .. name", lines[4])
    eq("", lines[2])
    eq("", lines[7])
    -- the common indentation of a block is removed
    eq("local x = greet('a')", lines[10])
    eq(4, g.shift[10])
    -- -i keeps it; the comma escape becomes a space
    eq("   * bad", lines[17])
    eq(0, g.shift[17])
    eq("", lines[14])
    eq("lua", vim.bo[g.hidden].filetype)
    eq("nofile", vim.bo[g.hidden].buftype)
    ok(vim.api.nvim_buf_get_name(g.hidden):match("notes%.org%.src%-lua%.lua$"))
  end)

  it("attaches the language server to the hidden buffer only", function()
    local buf = open(main)
    ok(fake_client(buf), "fake server on the hidden buffer")
    eq(0, #vim.lsp.get_clients({ bufnr = buf, name = "fake_lua" }))
    ok(proxy_ready(buf), "proxy on the org buffer")
  end)

  it("finds the root from the org file's directory", function()
    utils.writefile(dir .. "/.marker", { "" })
    setup({ languages = { lua = { servers = { vim.tbl_extend("force", FAKE, { root_markers = { ".marker" } }) } } } })
    local buf = open(main)
    local c = fake_client(buf)
    ok(c, "client")
    eq(dir, c.root_dir)
    -- a root_dir function sees the hidden buffer as a file buffer
    local seen
    setup({
      languages = {
        lua = {
          servers = {
            vim.tbl_extend("force", FAKE, {
              name = "fake_lua",
              root_dir = function(b, on_dir)
                seen = vim.fs.root(b, { ".marker" })
                on_dir(seen)
              end,
            }),
          },
        },
      },
    })
    buf = open(main)
    ok(fake_client(buf), "client")
    eq(dir, seen)
    os.remove(dir .. "/.marker")
  end)

  it("shows the diagnostics in the block bodies", function()
    local buf = open(main)
    fake_client(buf)
    vim.wait(3000, function()
      return #src_diags(buf) == 2
    end, 5)
    -- line 11 is indented by 4 in the org buffer; line 17 keeps its indentation
    eq({ { 11, 4, 7, "bad thing" }, { 17, 5, 8, "bad thing" } }, src_diags(buf))
  end)

  it("follows edits", function()
    local buf = open(main)
    fake_client(buf)
    vim.wait(3000, function()
      return #src_diags(buf) == 2
    end, 5)
    vim.api.nvim_buf_set_lines(buf, 3, 4, false, { "  return bad" })
    vim.wait(3000, function()
      return #src_diags(buf) == 3
    end, 5)
    eq({ 4, 9, 12, "bad thing" }, src_diags(buf)[1])
    -- a new line above shifts everything down
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "#+TITLE: x" })
    vim.wait(3000, function()
      local d = src_diags(buf)
      return #d == 3 and d[1][1] == 5
    end, 5)
    eq({ 5, 12, 18 }, { src_diags(buf)[1][1], src_diags(buf)[2][1], src_diags(buf)[3][1] })
    eq("local function greet(name)", vim.api.nvim_buf_get_lines(group(buf).hidden, 3, 4, false)[1])
    -- removing a block's language clears its lines
    vim.api.nvim_buf_set_lines(buf, 2, 3, false, { "#+begin_src text" })
    vim.wait(3000, function()
      return vim.api.nvim_buf_get_lines(group(buf).hidden, 3, 4, false)[1] == ""
    end, 5)
    eq("", vim.api.nvim_buf_get_lines(group(buf).hidden, 3, 4, false)[1])
  end)

  it("does not create hidden buffers without a listed language", function()
    setup({ languages = { "rust" } })
    local buf = open(main)
    eq({}, mirror().states[buf].groups)
    eq(0, #vim.lsp.get_clients({ bufnr = buf, name = "org_src" }))
  end)

  it("forwards definition with positions mapped back", function()
    local buf = open(main)
    -- `greet` in the indented second block (line 10, col 15) -> line 3
    local res = request(buf, "textDocument/definition", tdp(buf, 10, 16))
    eq(1, #res)
    eq(vim.uri_from_bufnr(buf), res[1].uri)
    eq({ line = 2, character = 15 }, res[1].range.start)
    eq({ line = 2, character = 20 }, res[1].range["end"])
    -- the server got the hidden buffer's position (indentation removed)
    local last
    for _, r in ipairs(requests) do
      if r.method == "textDocument/definition" then
        last = r.params
      end
    end
    eq(group(buf).uri, last.textDocument.uri)
    eq({ line = 9, character = 11 }, last.position)
  end)

  it("answers nothing outside the blocks", function()
    local buf = open(main)
    local res = request(buf, "textDocument/definition", tdp(buf, 7, 17))
    eq(true, res == nil or res == vim.NIL or (type(res) == "table" and #res == 0))
    res = request(buf, "textDocument/hover", tdp(buf, 14, 1))
    eq(true, res == nil or res == vim.NIL)
  end)

  it("forwards hover and references", function()
    local buf = open(main)
    local res = request(buf, "textDocument/hover", tdp(buf, 10, 16))
    eq("hover:greet", res.contents.value)
    eq({ line = 9, character = 14 }, res.range.start)
    local refs = request(buf, "textDocument/references", {
      textDocument = { uri = vim.uri_from_bufnr(buf) },
      position = { line = 2, character = 16 },
      context = { includeDeclaration = true },
    })
    local got = {}
    for _, r in ipairs(refs) do
      eq(vim.uri_from_bufnr(buf), r.uri)
      got[#got + 1] = { r.range.start.line + 1, r.range.start.character }
    end
    eq({ { 3, 15 }, { 10, 14 } }, got)
  end)

  it("forwards completion with the edit range mapped", function()
    local buf = open(main)
    local res = request(buf, "textDocument/completion", tdp(buf, 10, 18))
    eq(1, #res.items)
    local it = res.items[1]
    eq("greeting", it.label)
    eq({ line = 9, character = 14 }, it.textEdit.range.start)
    eq({ line = 9, character = 17 }, it.textEdit.range["end"])
    eq(group(buf).ft, it.data.org_src.ft)
  end)

  it("jumps with vim.lsp.buf.definition", function()
    local buf = open(main)
    proxy_ready(buf)
    fake_client(buf)
    vim.api.nvim_win_set_cursor(0, { 10, 16 })
    vim.lsp.buf.definition()
    vim.wait(3000, function()
      return vim.api.nvim_win_get_cursor(0)[1] == 3
    end, 5)
    eq({ 3, 15 }, vim.api.nvim_win_get_cursor(0))
    eq(buf, vim.api.nvim_get_current_buf())
  end)

  it("org's omnifunc hands over inside a block", function()
    local buf = open(main)
    proxy_ready(buf)
    vim.api.nvim_win_set_cursor(0, { 10, 16 })
    local called
    local saved = vim.lsp.omnifunc
    vim.lsp.omnifunc = function(findstart)
      called = findstart
      return -2
    end
    local r = require("org.completion").omnifunc(1, "")
    vim.lsp.omnifunc = saved
    eq(-2, r)
    eq(1, called)
    -- outside a block org's own completion answers
    vim.api.nvim_win_set_cursor(0, { 1, 2 })
    eq(nil, require("org.extensions.src_lsp").omnifunc(1, ""))
  end)

  it("removes the hidden buffers with the org buffer and on teardown", function()
    local buf = open(main)
    local hidden = group(buf).hidden
    vim.cmd("bwipeout! " .. buf)
    eq(false, vim.api.nvim_buf_is_valid(hidden))
    eq(nil, mirror().states[buf])
    buf = open(main)
    hidden = group(buf).hidden
    require("org").setup({})
    eq(false, vim.api.nvim_buf_is_valid(hidden))
  end)

  it("wipes an org buffer while its servers are still starting", function()
    -- a server of its own, so no running client is reused
    setup({ languages = { lua = { servers = { vim.tbl_extend("force", FAKE, { name = "fake_lua_new" }) } } } })
    local buf = open(main)
    -- the proxy is ready at once: wiping the buffer can't race its didOpen
    local p = vim.lsp.get_clients({ bufnr = buf, name = "org_src" })[1]
    ok(p and p.initialized, "proxy initialized")
    local hidden = group(buf).hidden
    local fake = vim.lsp.get_clients({ bufnr = hidden, name = "fake_lua_new", _uninitialized = true })[1]
    ok(fake and not fake.initialized, "fake server still starting")
    -- Neovim 0.11.0 failed here in vim.lsp's change tracking
    vim.cmd("bwipeout! " .. buf)
    eq(false, vim.api.nvim_buf_is_valid(hidden))
    vim.wait(3000, function()
      return fake.initialized == true
    end, 5)
    eq(nil, fake.attached_buffers[hidden])
  end)

  it("health lists the servers of each language", function()
    local out = {}
    local h = {}
    for _, k in ipairs({ "start", "ok", "info", "warn", "error" }) do
      h[k] = function(msg)
        out[#out + 1] = k .. ": " .. msg
      end
    end
    local ext = require("org.extensions.src_lsp")
    ext.health(h, require("org.extensions").opts("src_lsp"))
    ok(vim.tbl_contains(out, "ok: src_lsp: lua (filetype lua): fake_lua"), vim.inspect(out))
    out = {}
    setup({ languages = { lua = { servers = { "no_such_server" } } } })
    ext.health(h, require("org.extensions").opts("src_lsp"))
    ok(vim.tbl_contains(out, "warn: src_lsp: lua: no vim.lsp.config for no_such_server"), vim.inspect(out))
    out = {}
    require("org").setup({ extensions = { src_lsp = {} } })
    ext.health(h, require("org.extensions").opts("src_lsp"))
    eq({ "warn: src_lsp: no languages listed" }, out)
  end)
end)
