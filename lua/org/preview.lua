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
--- directory of the Org file that the page refers to (images,
--- attachments, stylesheets), and /p/<token>/.org-preview/events the
--- event stream. The server stops with the last preview.

local server_mod = require("org.preview.server")
local utils = require("org.utils")

local uv = vim.uv

local M = {}

local EVENTS = ".org-preview/events"

-- The page may hold raw HTML from the document: it can't send what it
-- reads anywhere but back to this server, nor submit forms elsewhere.
-- Scripts and styles stay allowed (the client below, MathJax, #+HTML_HEAD).
local CSP = "connect-src 'self'; form-action 'self'"

-- Stylesheets the page links are read for the files they refer to
-- (fonts, images) up to this size.
local MAX_CSS = 2 * 1024 * 1024

---@class org.preview.Preview
---@field bufnr integer
---@field token string
---@field html string|nil the page as served (with the client script)
---@field version integer
---@field streams org.preview.Stream[]
---@field heading string|nil the last heading sent ("key\tn\tindex")
---@field files table<string, true> files below the Org file's directory the page refers to (decoded paths)
---@field problem string|nil why the last export failed (nil after a good one)
---@field export table|nil options of the last export that decide which headings the page shows
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

local function decode_entities(s)
  local named = { amp = "&", quot = '"', apos = "'", lt = "<", gt = ">" }
  return (
    s:gsub("&(#?[xX]?%w+);", function(e)
      local n = e:match("^#[xX](%x+)$")
      n = n and tonumber(n, 16) or tonumber(e:match("^#(%d+)$") or "")
      if n then
        return n < 128 and string.char(n) or nil
      end
      return named[e]
    end)
  )
end

--- The path below the page that the URL `ref` names, decoded, `base`
--- being the directory it is relative to ("" or "dir/"); nil for URLs
--- with a scheme, absolute paths and paths above the page.
---@param ref string
---@param base string
---@return string|nil
local function local_ref(ref, base)
  ref = vim.trim(ref):gsub("[#?].*$", "")
  if ref == "" or ref:match("^%a[%w+.-]*:") or ref:sub(1, 1) == "/" or ref:find("\\", 1, true) then
    return nil
  end
  local dec = server_mod.url_decode(ref)
  if not dec then
    return nil
  end
  local parts = {}
  for seg in (base .. dec):gmatch("[^/]+") do
    if seg == ".." then
      if #parts == 0 then
        return nil
      end
      parts[#parts] = nil
    elseif seg ~= "." then
      parts[#parts + 1] = seg
    end
  end
  return #parts > 0 and table.concat(parts, "/") or nil
end

local REF_ATTRS = { src = true, href = true, data = true, poster = true, ["xlink:href"] = true }

--- The files below the page that the HTML or CSS `text` refers to
--- (src, href, data, poster, srcset attributes, CSS url() and @import),
--- added to `out`. `base`: the directory of `text` below the page.
---@param text string
---@param base? string
---@param out? table<string, true>
---@return table<string, true>
function M.references(text, base, out)
  out = out or {}
  base = base or ""
  local function add(v)
    local r = local_ref(decode_entities(v), base)
    if r then
      out[r] = true
    end
  end
  for name, _, v in text:gmatch("([%w:_-]+)%s*=%s*([\"'])(.-)%2") do
    name = name:lower()
    if REF_ATTRS[name] then
      add(v)
    elseif name == "srcset" then
      for cand in v:gmatch("[^,]+") do
        add(vim.trim(cand):match("^(%S*)"))
      end
    end
  end
  for v in text:gmatch("[Uu][Rr][Ll]%(%s*([^)]-)%s*%)") do
    add((v:gsub("^([\"'])(.*)%1$", "%2")))
  end
  for _, v in text:gmatch("@import%s+([\"'])(.-)%1") do
    add(v)
  end
  return out
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

--- The files the page `html` of the buffer `bufnr` refers to, with the
--- ones the stylesheets among them refer to.
---@param bufnr integer
---@param html string
---@return table<string, true>
local function page_files(bufnr, html)
  local files = M.references(html)
  local root = root_of(bufnr)
  local queue, seen = vim.tbl_keys(files), {}
  while #queue > 0 do
    local rel = table.remove(queue)
    if not seen[rel] and rel:lower():match("%.css$") then
      seen[rel] = true
      local path = M.resolve_file(root, rel)
      local st = path and uv.fs_stat(path)
      local css = st and st.size <= MAX_CSS and read_file(path)
      if css then
        local found = M.references(css, rel:match("^(.*/)") or "")
        for f in pairs(found) do
          if not files[f] then
            files[f] = true
            queue[#queue + 1] = f
          end
        end
      end
    end
  end
  return files
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
  -- without evaluate_babel no code from the document runs: neither
  -- source blocks nor (eval ...) macros, nor Lisp header values in Emacs
  local evaluate = cfg().evaluate_babel == true
  local elisp = require("org.babel.elisp")
  if not evaluate then
    elisp.no_external = elisp.no_external + 1
  end
  local ok, html, info = pcall(function()
    return require("org.export.ox").export_as("html", vim.api.nvim_buf_get_lines(p.bufnr, 0, -1, false), {
      filename = name ~= "" and name or nil,
      bufnr = p.bufnr,
      no_babel_eval = not evaluate,
      no_eval_macros = not evaluate,
    })
  end)
  if not evaluate then
    elisp.no_external = elisp.no_external - 1
  end
  if not ok or type(html) ~= "string" then
    local msg = "export failed: " .. tostring(html):gsub("\n", " ")
    if not p.problem then
      utils.warn("org preview: " .. msg)
    end
    p.problem = msg
    broadcast(p, "problem", msg)
    if not p.html then
      p.html = M.inject("<!DOCTYPE html><html><head><title>Org preview</title></head><body></body></html>", p.version)
      p.files = {}
    end
    return false
  end
  p.problem = nil
  if type(info) == "table" then
    p.export = {
      exclude_tags = info.exclude_tags,
      select_tags = info.select_tags,
      filetags = info.filetags,
      with_archived_trees = info.with_archived_trees,
      with_tasks = info.with_tasks,
      headline_levels = info.headline_levels,
    }
  end
  p.version = p.version + 1
  p.html = M.inject(html, p.version)
  p.files = page_files(p.bufnr, p.html)
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

local function set_of(list)
  local out = {}
  for _, x in ipairs(list or {}) do
    out[x] = true
  end
  return out
end

--- Export options deciding which headings the page shows: those of the
--- last export of the preview of `bufnr`, else the configured ones.
local function heading_options(bufnr)
  local p = M.previews[bufnr]
  if p and p.export then
    return p.export
  end
  local c = require("org.config").opts.export or {}
  local arch = c.with_archived_trees
  return {
    exclude_tags = c.exclude_tags or { "noexport" },
    select_tags = c.select_tags or { "export" },
    filetags = {},
    with_archived_trees = arch == nil and "headline" or arch,
    with_tasks = c.with_tasks == nil and true or c.with_tasks,
    headline_levels = c.headline_levels or 3,
  }
end

--- The headings of `file` that the export keeps, the way it prunes the
--- tree (org-export--prune-tree): COMMENT ones, those with an exclude
--- tag, outside the selected trees, archived (with `arch:nil`) or
--- tasks left out by `tasks:` go with their subtrees; an archived one
--- with `arch:headline` keeps its heading only. Returns the headings the
--- page shows as headings (not deeper than `H:`, not inline tasks), in
--- order, and the set of every kept headline.
---@param file org.File
---@param o table
---@return org.Headline[] page, table<org.Headline, boolean> kept
local function exported_headings(file, o)
  local hls = file.headlines
  local exclude, select = set_of(o.exclude_tags), set_of(o.select_tags)
  for _, t in ipairs(o.filetags or {}) do
    if exclude[t] then
      return {}, {}
    end
  end
  local all_selected = false
  for _, t in ipairs(o.filetags or {}) do
    if select[t] then
      all_selected = true
    end
  end
  local selected
  if not all_selected and next(select) then
    for _, h in ipairs(hls) do
      if not h.inlinetask and (not selected or not selected[h]) then
        for _, t in ipairs(h.tags or {}) do
          if select[t] then
            selected = selected or {}
            local a = h
            while a do
              selected[a] = true
              a = a.parent
            end
            local i = h.index + 1
            while hls[i] and hls[i].line <= h.end_line do
              selected[hls[i]] = true
              i = i + 1
            end
            break
          end
        end
      end
    end
  end
  local footnotes = (require("org.config").opts.export or {}).footnote_section
    or require("org.config").opts.footnote_section
  local todo = file.settings and file.settings.todo
  local tasks = o.with_tasks
  -- kept[h]: true = with its contents, false = its heading only
  local kept = {}
  for _, h in ipairs(hls) do
    if not h.inlinetask then
      local drop = h.parent ~= nil and kept[h.parent] ~= true
      drop = drop or h.commented or (selected ~= nil and not selected[h])
      drop = drop or (footnotes ~= nil and h.title == footnotes)
      local archived = false
      for _, t in ipairs(h.tags or {}) do
        if exclude[t] then
          drop = true
        end
        archived = archived or t == "ARCHIVE"
      end
      drop = drop or (archived and not o.with_archived_trees)
      if not drop and h.todo then
        local done = todo and todo.is_done and todo:is_done(h.todo)
        if not tasks then
          drop = true
        elseif tasks == "todo" or tasks == "done" then
          drop = (tasks == "done") ~= (done and true or false)
        elseif type(tasks) == "table" then
          drop = not vim.tbl_contains(tasks, h.todo)
        end
      end
      if not drop then
        kept[h] = not (archived and o.with_archived_trees == "headline")
      end
    end
  end
  -- levels are relative to the topmost exported headings
  -- (org-export-get-relative-level)
  local min
  for _, h in ipairs(hls) do
    if kept[h] ~= nil and h.parent == nil then
      min = math.min(min or h.level, h.level)
    end
  end
  local limit = o.headline_levels
  local page = {}
  for _, h in ipairs(hls) do
    if kept[h] ~= nil then
      local rel = h.level - (min or 1) + 1
      if type(limit) ~= "number" or limit < 0 or rel <= limit then
        page[#page + 1] = h
      end
    end
  end
  return page, kept
end

--- What the page needs to find the heading at `lnum`: { key, n, index }
--- (the n-th heading of the page with that key; `index` among all its
--- headings, for titles without letters or digits). Headings the export
--- leaves out don't count; for one deeper than `H:` (a list item on the
--- page) it is its heading on the page. nil before the first heading
--- and in a subtree the export leaves out.
---@param bufnr integer
---@param lnum integer
---@return { key: string, n: integer, index: integer }|nil
function M.heading_at(bufnr, lnum)
  local file = require("org.files").get_buffer(bufnr)
  local hl = file:headline_at(lnum)
  if not hl then
    return nil
  end
  local page, kept = exported_headings(file, heading_options(bufnr))
  local index_of = {}
  for i, h in ipairs(page) do
    index_of[h] = i
  end
  while hl and not index_of[hl] and (hl.inlinetask or kept[hl] ~= nil) do
    hl = hl.parent
  end
  local index = hl and index_of[hl]
  if not index then
    return nil
  end
  local key = M.heading_key(hl.title or "")
  local n = 0
  for i = 1, index do
    if M.heading_key(page[i].title or "") == key then
      n = n + 1
    end
  end
  return { key = key, n = n, index = index }
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
local function send_file(req, res, p, rest)
  local path, status = M.resolve_file(root_of(p.bufnr), rest)
  if not path then
    return res:fail(status or 404)
  end
  -- only what the page refers to: a document opened from a big directory
  -- (the home directory) doesn't show the rest of it
  if not (p.files and p.files[rest]) then
    return res:fail(404)
  end
  local st = uv.fs_stat(path)
  if not st then
    return res:fail(404)
  end
  local headers = {
    ["Content-Type"] = server_mod.mime(path),
    ["Accept-Ranges"] = "bytes",
    ["Content-Security-Policy"] = CSP,
  }
  local first, length = server_mod.parse_range(req.headers.range, st.size)
  if first == false then
    headers["Content-Range"] = "bytes */" .. st.size
    headers["Content-Type"] = nil
    return res:send(416, headers, "")
  end
  local code = 200
  if first then
    code = 206
    headers["Content-Range"] = ("bytes %d-%d/%d"):format(first, first + length - 1, st.size)
  else
    first, length = 0, st.size
  end
  if not res:send_file(code, headers, path, first, length) then
    res:fail(404)
  end
end

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
    return res:send(
      200,
      { ["Content-Type"] = "text/html; charset=utf-8", ["Content-Security-Policy"] = CSP },
      p.html or ""
    )
  end
  if rest == EVENTS then
    if res.head_only then
      return res:send(200, { ["Content-Type"] = "text/event-stream" }, "")
    end
    local s = res:stream()
    s:write("retry: 1000\n\n")
    s:event("hello", tostring(p.version))
    if p.problem then
      s:event("problem", p.problem)
    end
    p.streams[#p.streams + 1] = s
    p.heading = nil
    s.on_close = function()
      p.streams = vim.tbl_filter(function(x)
        return x ~= s
      end, p.streams)
    end
    return
  end
  send_file(req, res, p, rest)
end

--- The address to listen on for the `host` option: "localhost" is
--- 127.0.0.1, other names are looked up. nil when that fails.
---@param host string
---@return string|nil
function M.listen_address(host)
  if host == "localhost" then
    return "127.0.0.1"
  end
  if host:match("^[%d.]+$") or host:find(":", 1, true) then
    return host
  end
  local ok, addrs = pcall(uv.getaddrinfo, host)
  if ok and type(addrs) == "table" and addrs[1] and addrs[1].addr then
    return addrs[1].addr
  end
  return nil
end

local function ensure_server()
  if M.server and M.server:is_running() then
    return M.server
  end
  local c = cfg()
  local host = M.listen_address(c.host or "127.0.0.1")
  if not host then
    utils.error(("org preview: cannot find the address of the host %q (export.preview.host)"):format(c.host))
    return nil
  end
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
    local cmd
    if type(how) == "table" then
      cmd = vim.list_extend({}, how)
    elseif vim.fn.executable(how) == 1 then
      -- a path to a program, maybe with spaces in it
      cmd = { how }
    else
      cmd = vim.split(how, "%s+", { trimempty = true })
    end
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
