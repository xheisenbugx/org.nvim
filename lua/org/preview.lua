---@mod org.preview Live HTML preview (:Org preview)
---
--- Exports the buffer with the HTML back-end and serves the page from a
--- small HTTP server on vim.uv (lua/org/preview/server.lua). The page
--- listens on an event stream: each write of the buffer (a write hook, so
--- org's own saves count too) or, with `export.preview.on_change = "text"`,
--- each pause in typing exports it again and the page reloads, keeping its
--- scroll position. Moving to another heading scrolls the page to it.
---
--- One server serves every previewed buffer, each under its own random
--- path: /p/<token>/ is the page, /p/<token>/<file> a file below the
--- directory of the Org file (images, attachments, stylesheets), and
--- /p/<token>/.org-preview/events the event stream. The server stops with
--- the last preview.

local server_mod = require("org.preview.server")
local utils = require("org.utils")

local uv = vim.uv

local M = {}

local EVENTS = ".org-preview/events"

---@class org.preview.Preview
---@field bufnr integer
---@field token string
---@field html string|nil the page as served (with the client script)
---@field version integer
---@field streams org.preview.Stream[]
---@field heading string|nil the last heading sent ("key\tn\tindex")
---@field timer uv.uv_timer_t|nil
---@field cursor_timer uv.uv_timer_t|nil
---@field augroup integer

---@type org.preview.Server|nil
M.server = nil
---@type table<integer, org.preview.Preview>
M.previews = {}
---@type table<string, org.preview.Preview>
local by_token = {}

local function cfg()
  local export = require("org.config").opts.export or {}
  return export.preview or {}
end

local function is_loopback(host)
  return host == "127.0.0.1" or host == "::1" or host == "localhost" or (host or ""):match("^127%.") ~= nil
end

local function token()
  local ok, bytes = pcall(uv.random, 16)
  if not ok or type(bytes) ~= "string" then
    bytes = tostring(uv.hrtime()) .. tostring(math.random()) .. tostring(os.time())
    return utils.sha256(bytes):sub(1, 32)
  end
  return (bytes:gsub(".", function(c)
    return ("%02x"):format(c:byte())
  end))
end

--- URL of the page of `p`.
---@param p org.preview.Preview
---@return string
function M.url(p)
  local srv = assert(M.server)
  local host = srv.host
  if host == "0.0.0.0" or host == "::" then
    host = "127.0.0.1"
  end
  if host:find(":", 1, true) then
    host = "[" .. host .. "]"
  end
  return ("http://%s:%d/p/%s/"):format(host, srv.port, p.token)
end

---------------------------------------------------------------------------
-- Files below the directory of the Org file
---------------------------------------------------------------------------

local function norm_path(p)
  p = p:gsub("\\", "/")
  if vim.fn.has("win32") == 1 then
    p = p:lower()
  end
  return p
end

--- The file `rel` (a decoded URL path below the page) below `root`, or
--- nil and an HTTP status. Rejects `..`, `.` and hidden segments,
--- absolute and drive paths, backslashes, NUL bytes, and anything whose
--- real path (symlinks resolved) is not below the real `root`.
---@param root string|nil
---@param rel string
---@return string|nil path, integer|nil status
function M.resolve_file(root, rel)
  if not root or rel == "" then
    return nil, 404
  end
  if rel:find("%z") or rel:find("\\", 1, true) or rel:sub(1, 1) == "/" or rel:match("^%a:") then
    return nil, 403
  end
  for seg in (rel .. "/"):gmatch("([^/]*)/") do
    if seg == "" or seg:sub(1, 1) == "." then
      return nil, 403
    end
  end
  local real_root = uv.fs_realpath(root)
  if not real_root then
    return nil, 404
  end
  local real = uv.fs_realpath(real_root .. "/" .. rel)
  if not real then
    return nil, 404
  end
  local nroot, nreal = norm_path(real_root), norm_path(real)
  if nroot:sub(-1) ~= "/" then
    nroot = nroot .. "/"
  end
  if nreal:sub(1, #nroot) ~= nroot then
    return nil, 403
  end
  local st = uv.fs_stat(real)
  if not st or st.type ~= "file" then
    return nil, 404
  end
  return real
end

local function read_file(path)
  local fd = uv.fs_open(path, "r", 438)
  if not fd then
    return nil
  end
  local st = uv.fs_fstat(fd)
  local data = st and uv.fs_read(fd, st.size, 0)
  uv.fs_close(fd)
  return data
end

local function root_of(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    return nil
  end
  return vim.fn.fnamemodify(name, ":p:h")
end

---------------------------------------------------------------------------
-- The page
---------------------------------------------------------------------------

-- The client: reload on "reload" keeping the scroll position, scroll to
-- a heading on "heading", show export errors in a banner. It reloads
-- when the page it shows is older than the server's (a write between
-- loading the page and connecting).
local CLIENT = [[
<script>
(function () {
  var VERSION = %d;
  var KEY = "org-preview-scroll:" + location.pathname;
  try {
    var y = sessionStorage.getItem(KEY);
    if (y !== null) {
      sessionStorage.removeItem(KEY);
      var go = function () { window.scrollTo(0, +y); };
      go();
      window.addEventListener("load", go);
    }
  } catch (e) {}
  function reload() {
    try { sessionStorage.setItem(KEY, String(window.scrollY)); } catch (e) {}
    location.reload();
  }
  function norm(s) { return (s || "").toLowerCase().replace(/[^a-z0-9]+/g, ""); }
  function headings() {
    var out = [], hs = document.querySelectorAll("h2,h3,h4,h5,h6,h7,h8");
    for (var i = 0; i < hs.length; i++) {
      var p = hs[i].parentNode;
      if (p && /^outline-container-/.test(p.id || "")) out.push(hs[i]);
    }
    return out;
  }
  function title(h) {
    var c = h.cloneNode(true);
    var drop = c.querySelectorAll("[class^=section-number],.todo,.done,.tag,.priority");
    for (var i = 0; i < drop.length; i++) drop[i].remove();
    return norm(c.textContent);
  }
  function heading(d) {
    var hs = headings(), seen = 0, target = null;
    if (d.key) {
      for (var i = 0; i < hs.length; i++) {
        if (title(hs[i]) === d.key && ++seen === d.n) { target = hs[i]; break; }
      }
    }
    if (!target && !d.key) target = hs[d.index - 1] || null;
    if (target) target.scrollIntoView({ behavior: "smooth", block: "start" });
  }
  var banner = null;
  function problem(msg) {
    if (!banner) {
      banner = document.createElement("pre");
      banner.id = "org-preview-problem";
      banner.style.cssText = "position:fixed;left:0;right:0;bottom:0;margin:0;padding:.6em 1em;" +
        "background:#fdd;color:#600;border-top:2px solid #c00;font:13px monospace;z-index:99999;white-space:pre-wrap";
      document.body.appendChild(banner);
    }
    banner.textContent = "Org preview: " + msg;
  }
  var es = new EventSource("]] .. EVENTS .. [[");
  es.addEventListener("hello", function (e) { if (+e.data !== VERSION) reload(); });
  es.addEventListener("reload", reload);
  es.addEventListener("heading", function (e) { try { heading(JSON.parse(e.data)); } catch (x) {} });
  es.addEventListener("problem", function (e) { problem(e.data); });
})();
</script>
]]

local function find_last(text, pat)
  local last
  local init = 1
  while true do
    local s = text:find(pat, init)
    if not s then
      return last
    end
    last, init = s, s + 1
  end
end

local function stylesheet_tag()
  local sheet = cfg().stylesheet
  if type(sheet) ~= "string" or sheet == "" then
    return ""
  end
  if sheet:match("^%a[%w+.-]*://") then
    local href = sheet:gsub('"', "&quot;")
    return ('<link rel="stylesheet" type="text/css" href="%s" />\n'):format(href)
  end
  local path = utils.expand(sheet)
  local css = read_file(path)
  if not css then
    utils.warn("org preview: cannot read the stylesheet " .. path)
    return ""
  end
  return "<style>\n" .. css:gsub("</[Ss][Tt][Yy][Ll][Ee]", "<\\/style") .. "\n</style>\n"
end

--- Add the stylesheet before </head> and the client before </body>.
---@param html string
---@param version integer
---@return string
function M.inject(html, version)
  local style = stylesheet_tag()
  if style ~= "" then
    local h = find_last(html, "</[Hh][Ee][Aa][Dd]>")
    html = h and (html:sub(1, h - 1) .. style .. html:sub(h)) or (style .. html)
  end
  local client = CLIENT:format(version)
  local b = find_last(html, "</[Bb][Oo][Dd][Yy]>")
  if b then
    return html:sub(1, b - 1) .. client .. html:sub(b)
  end
  return html .. client
end

local function broadcast(p, event, data)
  local live = {}
  for _, s in ipairs(p.streams) do
    if s:event(event, data) then
      live[#live + 1] = s
    end
  end
  p.streams = live
end

--- Export the buffer of `p` again and tell the page.
---@param p org.preview.Preview
---@return boolean ok
function M.refresh(p)
  if not vim.api.nvim_buf_is_valid(p.bufnr) then
    return false
  end
  local name = vim.api.nvim_buf_get_name(p.bufnr)
  local ok, html = pcall(function()
    return require("org.export.ox").export_as("html", vim.api.nvim_buf_get_lines(p.bufnr, 0, -1, false), {
      filename = name ~= "" and name or nil,
      bufnr = p.bufnr,
      no_babel_eval = not cfg().evaluate_babel,
    })
  end)
  if not ok or type(html) ~= "string" then
    local msg = tostring(html):gsub("\n", " ")
    broadcast(p, "problem", "export failed: " .. msg)
    if not p.html then
      p.html = M.inject("<!DOCTYPE html><html><head><title>Org preview</title></head><body></body></html>", p.version)
    end
    return false
  end
  p.version = p.version + 1
  p.html = M.inject(html, p.version)
  broadcast(p, "reload", tostring(p.version))
  return true
end

---------------------------------------------------------------------------
-- The heading under the cursor
---------------------------------------------------------------------------

--- Letters and digits of a headline title, without its link targets,
--- the way the page compares heading texts.
---@param title string
---@return string
function M.heading_key(title)
  title = title:gsub("%[%[[^%]]*%]%[([^%]]*)%]%]", "%1"):gsub("%[%[([^%]]*)%]%]", "%1")
  return (title:lower():gsub("[^%w]", ""))
end

--- What the page needs to find the heading at `lnum`: { key, n, index }
--- (the n-th exported heading with that key; `index` among all headings
--- for titles without letters or digits). nil before the first heading.
---@param bufnr integer
---@param lnum integer
---@return { key: string, n: integer, index: integer }|nil
function M.heading_at(bufnr, lnum)
  local file = require("org.files").get_buffer(bufnr)
  local hl = file:headline_at(lnum)
  if not hl then
    return nil
  end
  local key = M.heading_key(hl.title or "")
  local n = 0
  for i = 1, hl.index do
    local h = file.headlines[i]
    if not h.inlinetask and M.heading_key(h.title or "") == key then
      n = n + 1
    end
  end
  return { key = key, n = n, index = hl.index }
end

local function sync_cursor(p)
  if #p.streams == 0 or not vim.api.nvim_buf_is_valid(p.bufnr) or vim.api.nvim_get_current_buf() ~= p.bufnr then
    return
  end
  local ok, h = pcall(M.heading_at, p.bufnr, vim.api.nvim_win_get_cursor(0)[1])
  if not ok or not h then
    return
  end
  local sig = ("%s\t%d\t%d"):format(h.key, h.n, h.index)
  if sig == p.heading then
    return
  end
  p.heading = sig
  broadcast(p, "heading", vim.json.encode(h))
end

---------------------------------------------------------------------------
-- The server
---------------------------------------------------------------------------

local function allowed_host(req)
  local srv = assert(M.server)
  if not is_loopback(srv.host) and srv.host ~= "0.0.0.0" and srv.host ~= "::" then
    return true -- served on purpose to other machines: any Host
  end
  local host = (req.headers.host or ""):lower()
  local port = tostring(srv.port)
  for _, h in ipairs({ "127.0.0.1", "localhost", "[::1]", srv.host }) do
    if host == h .. ":" .. port then
      return true
    end
  end
  -- 0.0.0.0 on purpose: the machine's own names and addresses too
  return srv.host == "0.0.0.0" or srv.host == "::"
end

---@param req table
---@param res org.preview.Response
local function handle(req, res)
  if req.method ~= "GET" and req.method ~= "HEAD" then
    return res:send(405, { Allow = "GET, HEAD" }, "Method Not Allowed\n")
  end
  -- a page on another site resolving its name to this machine (DNS
  -- rebinding) sends its own Host
  if not allowed_host(req) then
    return res:fail(421)
  end
  local tok, rest = req.path:match("^/p/(%x+)(.*)$")
  local p = tok and by_token[tok]
  if not p then
    return res:fail(404)
  end
  if rest == "" then
    return res:send(301, { Location = "/p/" .. tok .. "/" }, "")
  end
  rest = rest:sub(2)
  if rest == "" then
    return res:send(200, { ["Content-Type"] = "text/html; charset=utf-8" }, p.html or "")
  end
  if rest == EVENTS then
    if res.head_only then
      return res:send(200, { ["Content-Type"] = "text/event-stream" }, "")
    end
    local s = res:stream()
    s:write("retry: 1000\n\n")
    s:event("hello", tostring(p.version))
    p.streams[#p.streams + 1] = s
    p.heading = nil
    s.on_close = function()
      p.streams = vim.tbl_filter(function(x)
        return x ~= s
      end, p.streams)
    end
    return
  end
  local path, status = M.resolve_file(root_of(p.bufnr), rest)
  if not path then
    return res:fail(status or 404)
  end
  local data = read_file(path)
  if not data then
    return res:fail(404)
  end
  res:send(200, { ["Content-Type"] = server_mod.mime(path) }, data)
end

local function ensure_server()
  if M.server and M.server:is_running() then
    return M.server
  end
  local c = cfg()
  local host = c.host or "127.0.0.1"
  if not is_loopback(host) then
    utils.warn(("org preview: serving on %s, reachable from other machines"):format(host))
  end
  local srv, err = server_mod.start({ host = host, port = c.port or 0 }, handle)
  if not srv then
    utils.error("org preview: " .. tostring(err))
    return nil
  end
  M.server = srv
  return srv
end

local function stop_server()
  if M.server then
    M.server:close()
    M.server = nil
  end
  require("org.write_hooks").unregister("org.preview")
  pcall(vim.api.nvim_del_augroup_by_name, "org.preview")
end

---------------------------------------------------------------------------
-- Starting and stopping
---------------------------------------------------------------------------

local function open_browser(url)
  local how = cfg().open_browser
  if how == false or how == nil then
    utils.notify("Org preview: " .. url)
    return
  end
  if type(how) == "function" then
    return how(url)
  end
  if type(how) == "string" or type(how) == "table" then
    local cmd = type(how) == "string" and vim.split(how, "%s+", { trimempty = true }) or vim.list_extend({}, how)
    cmd[#cmd + 1] = url
    local ok, err = pcall(vim.system, cmd, { detach = true })
    if not ok then
      utils.error("org preview: " .. tostring(err))
    end
  else
    local _, err = vim.ui.open(url)
    if err then
      utils.error("org preview: " .. tostring(err))
    end
  end
  utils.notify("Org preview: " .. url)
end

local function schedule_refresh(p, delay)
  if not p.timer then
    p.timer = uv.new_timer()
  end
  if not p.timer then
    return
  end
  p.timer:stop()
  p.timer:start(
    delay,
    0,
    vim.schedule_wrap(function()
      if M.previews[p.bufnr] == p then
        M.refresh(p)
      end
    end)
  )
end

local function global_hooks()
  require("org.write_hooks").register("org.preview", {
    order = 90,
    filetype = "org",
    post = function(bufnr, ctx)
      local p = M.previews[bufnr]
      if p and ctx.ok then
        schedule_refresh(p, 0)
      end
    end,
  })
  local group = vim.api.nvim_create_augroup("org.preview", { clear = true })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      M.stop_all()
    end,
  })
end

--- Start the preview of `bufnr` (or show it again).
---@param bufnr? integer
---@return org.preview.Preview|nil
function M.start(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local p = M.previews[bufnr]
  if p then
    return p
  end
  if not ensure_server() then
    return nil
  end
  p = {
    bufnr = bufnr,
    token = token(),
    version = 0,
    streams = {},
    augroup = vim.api.nvim_create_augroup("org.preview." .. bufnr, { clear = true }),
  }
  M.previews[bufnr] = p
  by_token[p.token] = p
  global_hooks()
  local c = cfg()
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = p.augroup,
    buffer = bufnr,
    callback = function()
      M.stop(bufnr)
    end,
  })
  if c.on_change == "text" then
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
      group = p.augroup,
      buffer = bufnr,
      callback = function()
        schedule_refresh(p, c.debounce or 300)
      end,
    })
  end
  if c.sync_cursor ~= false then
    vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
      group = p.augroup,
      buffer = bufnr,
      callback = function()
        if not p.cursor_timer then
          p.cursor_timer = uv.new_timer()
        end
        if not p.cursor_timer then
          return
        end
        p.cursor_timer:stop()
        p.cursor_timer:start(
          100,
          0,
          vim.schedule_wrap(function()
            if M.previews[bufnr] == p then
              sync_cursor(p)
            end
          end)
        )
      end,
    })
  end
  M.refresh(p)
  return p
end

--- Stop the preview of `bufnr`; the server stops with the last one.
---@param bufnr? integer
---@return boolean stopped
function M.stop(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local p = M.previews[bufnr]
  if not p then
    return false
  end
  M.previews[bufnr] = nil
  by_token[p.token] = nil
  for _, s in ipairs(p.streams) do
    s:close()
  end
  p.streams = {}
  for _, k in ipairs({ "timer", "cursor_timer" }) do
    local t = p[k]
    if t and not t:is_closing() then
      t:stop()
      t:close()
    end
    p[k] = nil
  end
  pcall(vim.api.nvim_del_augroup_by_id, p.augroup)
  if next(M.previews) == nil then
    stop_server()
  end
  return true
end

--- Stop every preview and the server.
function M.stop_all()
  for bufnr in pairs(M.previews) do
    M.stop(bufnr)
  end
  stop_server()
end

---------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------

--- :Org preview: start the preview of the buffer and open it.
function M.preview()
  local p = M.start()
  if p then
    open_browser(M.url(p))
  end
end

--- :Org preview_toggle: start or stop the preview of the buffer.
---@return boolean on
function M.toggle()
  if M.previews[vim.api.nvim_get_current_buf()] then
    M.stop()
    utils.notify("Org preview stopped")
    return false
  end
  M.preview()
  return M.previews[vim.api.nvim_get_current_buf()] ~= nil
end

--- :Org preview_stop: stop the preview of the buffer (all previews
--- when it has none).
function M.stop_command()
  if not M.stop() then
    if next(M.previews) == nil then
      utils.notify("No Org preview is running")
      return
    end
    M.stop_all()
  end
  utils.notify("Org preview stopped")
end

return M
