-- The fake in-process "lua" language server of the src_lsp specs and the
-- helpers around it (no real server needed).
--
--   local S = require("tests.helpers.src_lsp")
--   S.reset()          -- before each test: forget what the server saw
--   S.setup()          -- write S.MAIN (or the lines given) and enable src_lsp
--   local buf = S.open(S.main)
--   S.request(buf, "textDocument/hover", S.tdp(buf, 10, 16))
local utils = require("org.utils")

local M = {}

local dir = vim.fs.normalize(vim.fn.tempname())
vim.fn.mkdir(dir, "p")
dir = vim.fs.normalize(utils.realpath(dir))
local main = dir .. "/notes.org"

local MAIN = {
  "* Code", --  1
  "#+begin_src lua", --  2
  "local function greet(name)", --  3
  "  return 'hi ' .. name", --  4
  "end", --  5
  "#+end_src", --  6
  "Some text with greet in it.", --  7
  "- item", --  8
  "  #+begin_src lua", --  9
  "    local x = greet('a')", -- 10
  "    bad = 1", -- 11
  "  #+end_src", -- 12
  "#+begin_src python", -- 13
  "bad = 2", -- 14
  "#+end_src", -- 15
  "#+begin_src lua -i", -- 16
  "  ,* bad", -- 17
  "#+end_src", -- 18
}

-- what the fake server saw, by URI, and the requests it got (cleared in
-- place by reset(), so a spec may keep the tables)
local docs = {}
local requests = {}
M.docs, M.requests = docs, requests

function M.reset()
  for k in pairs(docs) do
    docs[k] = nil
  end
  for i = #requests, 1, -1 do
    requests[i] = nil
  end
end

--- A fake lua server: full sync, a diagnostic on every `bad`, definition
--- of `local function <word>`, hover, references and completion.
local function fake_cmd(dispatchers)
  local closing = false
  local srv = {}
  -- positions in the client's encoding (utf-16 unless M.position_encoding
  -- is set when the server starts), turned into and from byte columns
  local enc = M.position_encoding or "utf-16"
  local function to_char(l, byte)
    return vim.str_utfindex(l, enc, math.min(byte, #l), false)
  end
  local function to_byte(l, char)
    local okb, b = pcall(vim.str_byteindex, l, enc, char, false)
    return okb and b or math.min(char, #l)
  end
  local function publish(uri)
    local diags = {}
    for i, l in ipairs(docs[uri] or {}) do
      local s = l:find("bad", 1, true)
      if s then
        diags[#diags + 1] = {
          range = {
            start = { line = i - 1, character = to_char(l, s - 1) },
            ["end"] = { line = i - 1, character = to_char(l, s + 2) },
          },
          message = "bad thing",
          severity = 1,
          source = "fake",
        }
      end
    end
    dispatchers.notification("textDocument/publishDiagnostics", { uri = uri, diagnostics = diags })
  end
  local function word_at(uri, pos)
    local l = (docs[uri] or {})[pos.line + 1] or ""
    local col = to_byte(l, pos.character) + 1
    local s = col
    while s > 1 and l:sub(s - 1, s - 1):match("[%w_]") do
      s = s - 1
    end
    local e = col
    while l:sub(e, e):match("[%w_]") do
      e = e + 1
    end
    return l:sub(s, e - 1), to_char(l, s - 1), to_char(l, e - 1)
  end
  local handlers = {
    initialize = function()
      return {
        capabilities = {
          positionEncoding = M.position_encoding,
          textDocumentSync = 1,
          definitionProvider = true,
          hoverProvider = true,
          referencesProvider = true,
          completionProvider = { triggerCharacters = { "." } },
        },
      }
    end,
    shutdown = function()
      return vim.NIL
    end,
    ["textDocument/definition"] = function(p)
      local w = word_at(p.textDocument.uri, p.position)
      for i, l in ipairs(docs[p.textDocument.uri] or {}) do
        local s = l:find("local function " .. w .. "(", 1, true)
        if s then
          local c = s + #"local function " - 1
          return {
            uri = p.textDocument.uri,
            range = { start = { line = i - 1, character = c }, ["end"] = { line = i - 1, character = c + #w } },
          }
        end
      end
      return vim.NIL
    end,
    ["textDocument/hover"] = function(p)
      local w, s, e = word_at(p.textDocument.uri, p.position)
      return {
        contents = { kind = "plaintext", value = "hover:" .. w },
        range = {
          start = { line = p.position.line, character = s },
          ["end"] = { line = p.position.line, character = e },
        },
      }
    end,
    ["textDocument/references"] = function(p)
      local w = word_at(p.textDocument.uri, p.position)
      local out = {}
      for i, l in ipairs(docs[p.textDocument.uri] or {}) do
        local s = l:find(w, 1, true)
        if s then
          out[#out + 1] = {
            uri = p.textDocument.uri,
            range = { start = { line = i - 1, character = s - 1 }, ["end"] = { line = i - 1, character = s - 1 + #w } },
          }
        end
      end
      return out
    end,
    ["textDocument/completion"] = function(p)
      local _, s = word_at(p.textDocument.uri, p.position)
      return {
        isIncomplete = false,
        items = {
          {
            label = "greeting",
            textEdit = {
              newText = "greeting",
              range = { start = { line = p.position.line, character = s }, ["end"] = p.position },
            },
          },
        },
      }
    end,
  }
  function srv.request(method, params, callback)
    requests[#requests + 1] = { method = method, params = params }
    vim.schedule(function()
      local h = handlers[method]
      if h then
        callback(nil, h(params))
      else
        callback({ code = -32601, message = "nope" }, nil)
      end
    end)
    return true, #requests
  end
  function srv.notify(method, params)
    if method == "textDocument/didOpen" then
      docs[params.textDocument.uri] = vim.split(params.textDocument.text, "\n", { plain = true })
      vim.schedule(function()
        publish(params.textDocument.uri)
      end)
    elseif method == "textDocument/didChange" then
      local changes = params.contentChanges
      docs[params.textDocument.uri] = vim.split(changes[#changes].text, "\n", { plain = true })
      vim.schedule(function()
        publish(params.textDocument.uri)
      end)
    elseif method == "exit" then
      closing = true
    end
    return true
  end
  function srv.is_closing()
    return closing
  end
  function srv.terminate()
    closing = true
  end
  return srv
end

local FAKE = { name = "fake_lua", cmd = fake_cmd, filetypes = { "lua" } }

local function wipe(path)
  local b = utils.find_buffer(path)
  if b then
    vim.api.nvim_buf_delete(b, { force = true })
  end
end

--- Write `lines` (default MAIN) to `main` and enable src_lsp with the fake
--- server for lua, `extra` merged over its options.
local function setup(extra, lines)
  wipe(main)
  utils.writefile(main, lines or MAIN)
  require("org").setup({
    extensions = {
      src_lsp = vim.tbl_deep_extend("force", {
        languages = { lua = { servers = { FAKE } } },
        debounce = 10,
      }, extra or {}),
    },
  })
end

local function open(path)
  if vim.bo.bufhidden == "wipe" then
    vim.bo.modified = false
  end
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  return vim.api.nvim_get_current_buf()
end

local function mirror()
  return require("org.extensions.src_lsp.mirror")
end

local function group(buf, ft)
  local st = mirror().states[buf]
  return st and st.groups[ft or "lua"]
end

local function fake_client(buf)
  local c
  vim.wait(3000, function()
    local g = group(buf)
    c = g and vim.lsp.get_clients({ bufnr = g.hidden, name = "fake_lua" })[1]
    return c ~= nil and c.initialized == true
  end, 5)
  return c
end

local function proxy_ready(buf)
  local c
  vim.wait(3000, function()
    c = vim.lsp.get_clients({ bufnr = buf, name = "org_src" })[1]
    return c ~= nil and c.initialized == true
  end, 5)
  return c
end

local function request(buf, method, params)
  local p = proxy_ready(buf)
  ok(p, "proxy attached")
  fake_client(buf)
  local res = vim.lsp.buf_request_sync(buf, method, params, 3000)
  ok(res, "no response to " .. method)
  local r = res[p.id]
  ok(r, "proxy answered")
  return r.result, r.err
end

local function tdp(buf, lnum, col)
  return {
    textDocument = { uri = vim.uri_from_bufnr(buf) },
    position = { line = lnum - 1, character = col - 1 },
  }
end

local function src_diags(buf)
  local out = {}
  for _, d in ipairs(vim.diagnostic.get(buf, { namespace = mirror().ns })) do
    out[#out + 1] = { d.lnum + 1, d.col, d.end_col, d.message }
  end
  table.sort(out, function(a, b)
    return a[1] < b[1]
  end)
  return out
end

M.dir, M.main, M.MAIN, M.FAKE = dir, main, MAIN, FAKE
M.fake_cmd, M.wipe, M.setup, M.open, M.mirror, M.group = fake_cmd, wipe, setup, open, mirror, group
M.fake_client, M.proxy_ready, M.request, M.tdp, M.src_diags = fake_client, proxy_ready, request, tdp, src_diags

return M
