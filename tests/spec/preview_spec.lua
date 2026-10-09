-- :Org preview: the HTML page, its files and its event stream, fetched
-- over a vim.uv TCP connection from the server on a free port.
local preview = require("org.preview")

local uv = vim.uv

--- Send `request` to the preview server and collect the reply. With
--- `until_pat` the connection is left open: the reply so far is returned
--- once it matches, with the handle (for streams).
local function raw(request, until_pat)
  local tcp = assert(uv.new_tcp())
  local out, done = {}, false
  tcp:connect("127.0.0.1", preview.server.port, function(err)
    assert(not err, err)
    tcp:write(request)
    tcp:read_start(function(rerr, data)
      if rerr or not data then
        done = true
        tcp:close()
      else
        out[#out + 1] = data
      end
    end)
  end)
  local got = vim.wait(5000, function()
    return done or (until_pat ~= nil and table.concat(out):find(until_pat) ~= nil)
  end, 10)
  ok(got, "no reply to " .. request:match("^[^\r]*"))
  return table.concat(out), tcp, out
end

local function get(path, host)
  host = host or ("127.0.0.1:" .. preview.server.port)
  local reply = raw(("GET %s HTTP/1.1\r\nHost: %s\r\n\r\n"):format(path, host))
  local status = tonumber(reply:match("^HTTP/1%.1 (%d+)"))
  local head, body = reply:match("^(.-)\r\n\r\n(.*)$")
  return status, body, head
end

local dir

local function write(path, text)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end

local function open_org(lines)
  local path = dir .. "/notes/doc.org"
  write(path, table.concat(lines, "\n") .. "\n")
  vim.cmd.edit(vim.fn.fnameescape(path))
  return vim.api.nvim_get_current_buf()
end

local function base(p)
  return "/p/" .. p.token .. "/"
end

local DOC = {
  "#+TITLE: Preview",
  "* First heading",
  "Some text [[file:img/pic.png]]",
  "* Second heading",
  "More text",
}

describe("org.preview", function()
  local saved
  before_each(function()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir .. "/notes/img", "p")
    write(dir .. "/notes/img/pic.png", "\137PNG fake")
    write(dir .. "/secret.txt", "outside")
    local export = require("org.config").opts.export
    saved = export.preview
    export.preview = vim.tbl_extend("force", vim.deepcopy(saved), { open_browser = false, port = 0 })
  end)
  after_each(function()
    preview.stop_all()
    require("org.config").opts.export.preview = saved
    vim.cmd("silent! %bwipeout!")
    vim.fn.delete(dir, "rf")
  end)

  it("serves the exported page with the client script", function()
    open_org(DOC)
    local p = assert(preview.start())
    ok(preview.server.port > 0)
    local status, body, head = get(base(p))
    eq(200, status)
    ok(head:find("Content-Type: text/html", 1, true))
    ok(body:find("First heading", 1, true))
    ok(body:find('<img src="img/pic.png"', 1, true))
    ok(body:find('EventSource(".org-preview/events")', 1, true))
    -- the client sits inside the body
    ok(body:find("EventSource", 1, true) < body:find("</body>", 1, true))
    eq(301, (get("/p/" .. p.token)))
    eq(preview.url(p), ("http://127.0.0.1:%d/p/%s/"):format(preview.server.port, p.token))
  end)

  it("serves files relative to the Org file", function()
    open_org(DOC)
    local p = assert(preview.start())
    local status, body, head = get(base(p) .. "img/pic.png")
    eq(200, status)
    eq("\137PNG fake", body)
    ok(head:find("Content-Type: image/png", 1, true))
    eq(200, (get(base(p) .. "img%2Fpic.png")))
    eq(404, (get(base(p) .. "img/missing.png")))
    eq(404, (get(base(p) .. "img")))
  end)

  it("rejects paths outside the directory of the Org file", function()
    open_org(DOC)
    local p = assert(preview.start())
    local b = base(p)
    eq(403, (get(b .. "../secret.txt")))
    eq(403, (get(b .. "%2e%2e/secret.txt")))
    eq(403, (get(b .. "img/..%2F..%2Fsecret.txt")))
    eq(403, (get(b .. "..%5Csecret.txt")))
    eq(403, (get(b .. "/" .. dir .. "/secret.txt")))
    eq(403, (get(b .. "%2F" .. dir:gsub("^/", "") .. "/secret.txt")))
    eq(403, (get(b .. "C:/x.txt")))
    eq(403, (get(b .. "img%00.png")))
    eq(403, (get(b .. ".hidden")))
    eq(400, (get(b .. "bad%zzescape")))
    eq(404, (get("/p/0123456789abcdef/img/pic.png")))
    eq(404, (get("/")))
    if vim.fn.has("win32") == 0 then
      -- a symlink below the directory pointing out of it
      assert(uv.fs_symlink(dir .. "/secret.txt", dir .. "/notes/link.txt"))
      assert(uv.fs_symlink(dir, dir .. "/notes/up"))
      eq(403, (get(b .. "link.txt")))
      eq(403, (get(b .. "up/secret.txt")))
    end
  end)

  it("resolve_file checks paths without a server", function()
    local root = dir .. "/notes"
    eq(uv.fs_realpath(root .. "/img/pic.png"), (preview.resolve_file(root, "img/pic.png")))
    eq({ nil, 403 }, { preview.resolve_file(root, "../secret.txt") })
    eq({ nil, 403 }, { preview.resolve_file(root, "img//pic.png") })
    eq({ nil, 403 }, { preview.resolve_file(root, "./img/pic.png") })
    eq({ nil, 404 }, { preview.resolve_file(nil, "img/pic.png") })
  end)

  it("answers only requests for its own host name", function()
    open_org(DOC)
    local p = assert(preview.start())
    eq(421, (get(base(p), "evil.example:" .. preview.server.port)))
    eq(421, (get(base(p), "127.0.0.1:1")))
    eq(200, (get(base(p), "localhost:" .. preview.server.port)))
    local reply = raw(("POST %s HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n\r\n"):format(base(p), preview.server.port))
    ok(reply:match("^HTTP/1%.1 405"))
  end)

  it("pushes a reload on the event stream after a write", function()
    local buf = open_org(DOC)
    local p = assert(preview.start())
    local req = ("GET %s.org-preview/events HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n\r\n"):format(
      base(p),
      preview.server.port
    )
    local reply, tcp, out = raw(req, "event: hello\ndata: 1\n\n")
    ok(reply:find("Content-Type: text/event-stream", 1, true))
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "* Renamed heading" })
    -- not before the write (on_change = "write")
    vim.wait(100)
    ok(not table.concat(out):find("event: reload", 1, true))
    vim.cmd("silent write")
    ok(vim.wait(3000, function()
      return table.concat(out):find("event: reload\ndata: 2", 1, true) ~= nil
    end, 10))
    local _, body = get(base(p))
    ok(body:find("Renamed heading", 1, true))
    tcp:close()
  end)

  it("reloads on org's own saves too (write hook)", function()
    local buf = open_org(DOC)
    local p = assert(preview.start())
    vim.api.nvim_buf_set_lines(buf, 3, 4, false, { "* Saved by org" })
    require("org.utils").save_buffer(buf)
    ok(vim.wait(2000, function()
      return p.version == 2
    end, 10))
    ok(p.html:find("Saved by org", 1, true))
  end)

  it("exports while typing with on_change = text", function()
    require("org.config").opts.export.preview.on_change = "text"
    require("org.config").opts.export.preview.debounce = 20
    local buf = open_org(DOC)
    local p = assert(preview.start())
    vim.api.nvim_buf_set_lines(buf, 4, 5, false, { "Typed text" })
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
    ok(vim.wait(2000, function()
      return p.html:find("Typed text", 1, true) ~= nil
    end, 10))
    eq(true, vim.bo[buf].modified)
  end)

  it("sends the heading under the cursor", function()
    open_org({ "* Intro", "a", "* [[https://x.org][Linked]] title :tag:", "b", "* Intro", "c" })
    local p = assert(preview.start())
    local req = ("GET %s.org-preview/events HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n\r\n"):format(
      base(p),
      preview.server.port
    )
    local _, tcp, out = raw(req, "event: hello")
    vim.api.nvim_win_set_cursor(0, { 6, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = p.bufnr })
    ok(vim.wait(2000, function()
      return table.concat(out):find("event: heading", 1, true) ~= nil
    end, 10))
    local data = table.concat(out):match("event: heading\ndata: ([^\n]+)")
    eq({ key = "intro", n = 2, index = 3 }, vim.json.decode(data))
    eq({ key = "linkedtitle", n = 1, index = 2 }, preview.heading_at(p.bufnr, 4))
    tcp:close()
  end)

  it("keeps the results in the buffer instead of evaluating blocks", function()
    open_org({
      "#+begin_src lua :exports results",
      "return 6 * 7",
      "#+end_src",
      "",
      "#+RESULTS:",
      ": old result",
    })
    local p = assert(preview.start())
    ok(p.html:find("old result", 1, true))
    ok(not p.html:find("return 6", 1, true))
  end)

  it("adds the configured stylesheet", function()
    write(dir .. "/style.css", "body { color: rebeccapurple; }")
    require("org.config").opts.export.preview.stylesheet = dir .. "/style.css"
    open_org(DOC)
    local p = assert(preview.start())
    local s = p.html:find("rebeccapurple", 1, true)
    ok(s and s < p.html:find("</head>", 1, true))
  end)

  it("serves several buffers from one server and stops with the last", function()
    local a = open_org(DOC)
    local pa = assert(preview.start())
    local other = dir .. "/notes/other.org"
    write(other, "* Other file\n")
    vim.cmd.edit(vim.fn.fnameescape(other))
    local b = vim.api.nvim_get_current_buf()
    local pb = assert(preview.start())
    local port = preview.server.port
    ok(pa.token ~= pb.token)
    local _, body = get(base(pb))
    ok(body:find("Other file", 1, true))
    vim.api.nvim_buf_delete(b, { force = true })
    eq(nil, preview.previews[b])
    eq(404, (get(base(pb))))
    eq(port, preview.server.port)
    preview.stop(a)
    eq(nil, preview.server)
    ok(not vim.tbl_contains(require("org.write_hooks").list(), "org.preview"))
  end)

  it("toggles through the actions", function()
    open_org(DOC)
    eq(true, preview.toggle())
    ok(preview.server ~= nil)
    eq(false, preview.toggle())
    eq(nil, preview.server)
  end)

  it("matches heading titles the way the page does", function()
    eq("hllowrld", preview.heading_key("Héllo, *wörld*"))
    eq("descr", preview.heading_key("[[https://a.b][Descr]]"))
  end)
end)
