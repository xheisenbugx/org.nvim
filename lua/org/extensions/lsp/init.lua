---@mod org.extensions.lsp A language server for Org buffers
---
--- An in-process LSP server (no external program): every LSP-aware
--- feature and plugin works in Org files. Document symbols (the outline),
--- workspace symbols (headlines of the agenda files and `org_directory`),
--- org-lint diagnostics, hover (timestamps, links, clocks, footnotes,
--- headlines), go to definition, references, rename (headline titles,
--- CUSTOM_ID, ID, targets, names, footnotes, with every link updated across
--- files), code actions, folding ranges and document links.
---
--- ```lua
--- require("org").setup({ extensions = { lsp = {} } })
--- ```
---
--- See `:h org-extensions-lsp`.

local M = {}

local MOD = "org.extensions.lsp"

M.defaults = {
  --- Attach to every org buffer (FileType org). With false, `:Org lsp_start`
  --- attaches the current buffer.
  autostart = true,
  --- `fun(bufnr): boolean` choosing the buffers to attach; default: file
  --- buffers (`buftype` "" or "acwrite") with a name.
  ---@type fun(bufnr: integer): boolean|nil
  filter = nil,
  --- `fun(client, bufnr)` called when the server attaches to a buffer.
  ---@type fun(client: table, bufnr: integer)|nil
  on_attach = nil,
  --- Turn single capabilities off.
  features = {
    document_symbols = true,
    workspace_symbols = true,
    diagnostics = true,
    hover = true,
    definition = true,
    references = true,
    rename = true,
    code_actions = true,
    folding = true,
    document_links = true,
  },
  --- org-lint reports as diagnostics.
  diagnostics = {
    --- Milliseconds without changes before a buffer is linted again
    --- (twice the time the last lint took when that is longer).
    debounce = 500,
    --- Buffers with more lines are linted when opened and written, not
    --- while you type; 0 or false: no limit.
    max_lines = 3000,
    --- Checker names (`:Org lint` names); nil: org-lint's default set.
    ---@type string[]|nil
    checkers = nil,
    --- Checkers left out.
    exclude = {},
    --- Severity of "high" and "low" trust reports, and per checker
    --- (`checkers = { ["item-number"] = "Hint" }`): "Error", "Warning",
    --- "Information" or "Hint".
    severity = { high = "Error", low = "Warning", checkers = {} },
  },
  hover = {
    --- Lines of a link's target shown in its hover.
    preview_lines = 8,
    --- Count backlinks in the hover of every headline, not only those
    --- with an ID or CUSTOM_ID.
    backlinks_all_headings = false,
  },
  --- Also list named src blocks and tables in the document symbols.
  document_symbols = { src_blocks = true, tables = true },
  --- LSP symbol kinds (names from `vim.lsp.protocol.SymbolKind`).
  symbol_kinds = {
    heading = "Namespace",
    todo = "Event",
    done = "Constant",
    src_block = "Function",
    table = "Struct",
  },
  --- The files workspace symbols, references and rename look at, besides
  --- the loaded org buffers.
  workspace = {
    agenda_files = true,
    --- The `.org` files under `org_directory`.
    org_directory = true,
    --- Include the subdirectories of `org_directory`.
    recursive = true,
    --- More files, directories or globs.
    extra = {},
    --- A list of files/globs (or a function returning one) replacing all
    --- of the above.
    ---@type string[]|fun(): string[]|nil
    files = nil,
    max_files = 2000,
    --- Parse the workspace files in the background after the server
    --- starts (a few ms at a time), so the first request is quick.
    preload = true,
  },
  workspace_symbol_limit = 1000,
  rename = {
    --- Rewrite a link's description when it equals the old name.
    update_descriptions = true,
    --- Write the files a rename changed that were not loaded (Neovim
    --- loads them to apply the edit and would leave them modified).
    write_unloaded = true,
  },
  code_actions = {
    --- Entry commands (TODO, priority, schedule, deadline, refile,
    --- archive); false or a list of `{ action, title }`.
    entry = true,
    --- "Convert line to heading / checkbox".
    conversions = true,
  },
}

M.actions = {
  lsp_start = { MOD, "start", desc = "Start the org language server for this buffer" },
  lsp_stop = { MOD, "stop", desc = "Stop the org language server", global = true },
  lsp_restart = { MOD, "restart", desc = "Restart the org language server", global = true },
}

local augroup = vim.api.nvim_create_augroup("org.lsp", { clear = true })

--- ids of the clients this setup started (a client still shutting down
--- after a restart is never reused)
local active = {}

local function opts()
  return require("org.extensions").opts("lsp") or M.defaults
end

local function eligible(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].filetype ~= "org" then
    return false
  end
  local f = opts().filter
  if f then
    return f(bufnr) and true or false
  end
  local bt = vim.bo[bufnr].buftype
  return (bt == "" or bt == "acwrite") and vim.api.nvim_buf_get_name(bufnr) ~= ""
end

local function root_dir()
  local utils = require("org.utils")
  local dir = utils.expand(require("org.config").opts.org_directory, vim.fn.getcwd())
  if dir and utils.is_dir(dir) then
    return dir
  end
  return vim.fs.normalize(vim.fn.getcwd())
end

--- Clients of this server that are running.
---@return table[]
function M.clients()
  local out = {}
  for _, c in ipairs(vim.lsp.get_clients({ name = "org" })) do
    if active[c.id] then
      out[#out + 1] = c
    end
  end
  return out
end

--- Attach the server to a buffer (starting it if needed).
---@param bufnr? integer
---@return integer|nil client id
function M.attach(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  if not eligible(bufnr) then
    return nil
  end
  local user_attach = opts().on_attach
  local id = vim.lsp.start({
    name = "org",
    cmd = require(MOD .. ".server").cmd,
    root_dir = root_dir(),
    offset_encoding = "utf-8",
    on_attach = user_attach and function(client, b)
      local ok, err = pcall(user_attach, client, b)
      if not ok then
        require("org.utils").error("lsp: on_attach failed: " .. tostring(err))
      end
    end or nil,
  }, {
    bufnr = bufnr,
    reuse_client = function(client, config)
      return active[client.id] == true and client.name == config.name
    end,
  })
  if id then
    active[id] = true
  end
  return id
end

--- `lsp_start`: attach the server to the current buffer.
function M.start()
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.bo[bufnr].filetype ~= "org" then
    require("org.utils").warn("Not in an Org buffer")
    return false
  end
  local id = M.attach(bufnr)
  if not id then
    require("org.utils").warn("lsp: this buffer is not a file the server can attach to")
  end
  return id ~= nil
end

--- `lsp_stop`: stop the server (every buffer is detached).
function M.stop()
  for _, c in ipairs(M.clients()) do
    active[c.id] = nil
    c:stop(true)
  end
  active = {}
end

--- `lsp_restart`: stop the server and attach every org buffer again.
function M.restart()
  M.stop()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) then
      M.attach(b)
    end
  end
end

function M.setup(o)
  vim.api.nvim_clear_autocmds({ group = augroup })
  local util = require(MOD .. ".util")
  util.invalidate()
  -- a new org file on disk: list the workspace files again
  vim.api.nvim_create_autocmd({ "BufWritePost", "BufFilePost" }, {
    group = augroup,
    pattern = "*.org",
    callback = function()
      util.invalidate()
    end,
  })
  vim.api.nvim_create_autocmd({ "BufAdd", "BufReadPost", "BufFilePost", "BufUnload", "BufWipeout" }, {
    group = augroup,
    callback = function()
      util.reset_scope()
    end,
  })
  if o.autostart == false then
    return
  end
  local reported = false
  local function attach(b)
    local ok, err = pcall(M.attach, b)
    if not ok and not reported then
      -- once, not for every org buffer opened
      reported = true
      require("org.utils").error("lsp: could not start the server: " .. tostring(err))
    end
  end
  vim.api.nvim_create_autocmd("FileType", {
    group = augroup,
    pattern = "org",
    callback = function(ev)
      attach(ev.buf)
    end,
  })
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].filetype == "org" then
      attach(b)
    end
  end
end

--- Turned off (or set up again): stop the server, remove the autocmds.
function M.teardown()
  vim.api.nvim_clear_autocmds({ group = augroup })
  require(MOD .. ".rename").reset()
  M.stop()
end

function M.health(h, o)
  local clients = M.clients()
  if #clients == 0 then
    h.info(
      "lsp: not running (" .. (o.autostart == false and "autostart is off: :Org lsp_start" or "no org buffer") .. ")"
    )
  else
    for _, c in ipairs(clients) do
      local n = vim.tbl_count(c.attached_buffers or {})
      h.ok(string.format("lsp: client %d running, attached to %d buffer%s", c.id, n, n == 1 and "" or "s"))
    end
  end
  local off = {}
  for name, v in pairs(o.features or {}) do
    if v == false then
      off[#off + 1] = name
    end
  end
  table.sort(off)
  if #off > 0 then
    h.info("lsp: features turned off: " .. table.concat(off, ", "))
  end
  local ok, list = pcall(require(MOD .. ".util").workspace_files)
  if ok then
    h.ok(string.format("lsp: %d workspace files (references, rename, workspace symbols)", #list))
  else
    h.warn("lsp: listing the workspace files failed: " .. tostring(list))
  end
  if (o.features or {}).diagnostics ~= false then
    h.info(string.format("lsp: %d org-lint checkers run as diagnostics", #require(MOD .. ".diagnostics").checkers()))
  end
end

return M
