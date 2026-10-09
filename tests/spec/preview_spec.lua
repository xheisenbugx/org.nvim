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

local function get(path, host, extra)
  host = host or ("127.0.0.1:" .. preview.server.port)
  local reply = raw(("GET %s HTTP/1.1\r\nHost: %s\r\n%s\r\n"):format(path, host, extra or ""))
  local status = tonumber(reply:match("^HTTP/1%.1 (%d+)"))
  local head, body = reply:match("^(.-)\r\n\r\n(.*)$")
  return status, body, head
end

--- Collect the notifications sent while `fn` runs.
local function notes(fn)
  local got, orig = {}, vim.notify
  vim.notify = function(msg, level)
    got[#got + 1] = { msg = msg, level = level }
  end
  local ok, err = pcall(fn)
  vim.notify = orig
  assert(ok, err)
  return got
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

  it("doesn't run (eval) macros or send Lisp header values to Emacs", function()
    local elisp = require("org.babel.elisp")
    local marker = dir .. "/ran"
    local orig_eval, orig_ext, orig_cmd = elisp.eval, elisp.eval_external, elisp.command
    local function touch()
      write(marker, "x")
    end
    elisp.eval_external = function()
      touch()
      return '"/tmp"'
    end
    elisp.command = function()
      return { "emacs" }
    end
    local lines = {
      '#+MACRO: boom (eval (progn (shell-command "touch ran") "BOOM"))',
      "* Head {{{boom}}}",
      "#+begin_src sh :dir (my-dir) :exports code",
      "echo hi",
      "#+end_src",
    }
    local ok_run, err = pcall(function()
      open_org(lines)
      local p = assert(preview.start())
      eq(0, vim.fn.filereadable(marker))
      ok(p.html:find("[macro boom not evaluated in the preview]", 1, true))
      ok(not p.html:find("BOOM", 1, true))
      eq(0, elisp.no_external)
      -- an ordinary export still runs them
      require("org.export.ox").export_as("html", lines, { filename = dir .. "/notes/doc.org" })
      eq(1, vim.fn.filereadable(marker))
      vim.fn.delete(marker)
      -- and the preview does with evaluate_babel
      preview.stop()
      require("org.config").opts.export.preview.evaluate_babel = true
      local p2 = assert(preview.start())
      ok(not p2.html:find("not evaluated in the preview", 1, true))
      eq(1, vim.fn.filereadable(marker))
    end)
    elisp.eval, elisp.eval_external, elisp.command = orig_eval, orig_ext, orig_cmd
    assert(ok_run, err)
  end)

  it("serves only the files the page refers to", function()
    write(dir .. "/notes/private.txt", "private")
    write(dir .. "/notes/img/unlinked.png", "png")
    write(dir .. "/notes/css/site.css", "@font-face { src: url('../fonts/a.woff2'); } body { background: url(bg.png) }")
    write(dir .. "/notes/fonts/a.woff2", "font")
    write(dir .. "/notes/css/bg.png", "bg")
    write(dir .. "/notes/my pic.png", "spaced")
    open_org({
      '#+HTML_HEAD: <link rel="stylesheet" href="css/site.css">',
      "* Files",
      "[[file:img/pic.png]] [[file:my pic.png]] [[file:../secret.txt]]",
    })
    local p = assert(preview.start())
    local b = base(p)
    eq(200, (get(b .. "img/pic.png")))
    eq(200, (get(b .. "css/site.css")))
    eq(200, (get(b .. "fonts/a.woff2")))
    eq(200, (get(b .. "css/bg.png")))
    eq(200, (get(b .. "my%20pic.png")))
    eq(404, (get(b .. "private.txt")))
    eq(404, (get(b .. "img/unlinked.png")))
    eq(404, (get(b .. "doc.org")))
    eq(403, (get(b .. "../secret.txt")))
    -- the page may only connect and post back to the server
    local _, _, head = get(b)
    ok(head:find("Content-Security-Policy: connect-src 'self'; form-action 'self'", 1, true))
    local _, _, fhead = get(b .. "img/pic.png")
    ok(fhead:find("Content-Security-Policy:", 1, true))
    ok(fhead:find("Accept-Ranges: bytes", 1, true))
    -- a link added later is served after the next export
    vim.api.nvim_buf_set_lines(p.bufnr, -1, -1, false, { "[[file:private.txt]]" })
    preview.refresh(p)
    eq(200, (get(b .. "private.txt")))
  end)

  it("collects the references of HTML and CSS", function()
    local refs = preview.references(table.concat({
      '<img src="a.png" srcset="b.png 1x, c%20d.png 2x">',
      "<a href='sub/./e.pdf#page=2'>x</a> <a href=\"https://x.org/f.png\">y</a>",
      '<a href="/abs.png">z</a> <a href="../up.png">u</a> <video poster="v.jpg"></video>',
      '<object data="g.svg"></object> <a href="h.png?x=1&amp;y=2">h</a>',
      "<style>div { background: url( 'i.png' ) } @import \"j.css\";</style>",
    }, "\n"))
    eq({
      ["a.png"] = true,
      ["b.png"] = true,
      ["c d.png"] = true,
      ["sub/e.pdf"] = true,
      ["v.jpg"] = true,
      ["g.svg"] = true,
      ["h.png"] = true,
      ["i.png"] = true,
      ["j.css"] = true,
    }, refs)
    eq({ ["css/x.woff"] = true, ["y.png"] = true }, preview.references("url(x.woff) url(../y.png)", "css/"))
  end)

  it("answers byte ranges of files, read in chunks", function()
    local big = {}
    for i = 1, 20000 do
      big[i] = ("%09d\n"):format(i)
    end
    big = table.concat(big)
    write(dir .. "/notes/clip.mp4", big)
    open_org({ "* Video", "[[file:clip.mp4]] [[file:img/pic.png]]" })
    local p = assert(preview.start())
    local b = base(p)
    local status, body, head = get(b .. "img/pic.png", nil, "Range: bytes=1-3\r\n")
    eq(206, status)
    eq("PNG", body)
    ok(head:find("Content-Range: bytes 1-3/9", 1, true))
    ok(head:find("Content-Length: 3", 1, true))
    status, body = get(b .. "img/pic.png", nil, "Range: bytes=-4\r\n")
    eq(206, status)
    eq("fake", body)
    status, body, head = get(b .. "img/pic.png", nil, "Range: bytes=50-\r\n")
    eq(416, status)
    ok(head:find("Content-Range: bytes */9", 1, true))
    -- several ranges: the whole file
    status, body = get(b .. "img/pic.png", nil, "Range: bytes=0-1,3-4\r\n")
    eq(200, status)
    eq("\137PNG fake", body)
    -- a file bigger than one chunk, whole and from the middle
    status, body = get(b .. "clip.mp4")
    eq(200, status)
    eq(#big, #body)
    eq(big, body)
    status, body = get(b .. "clip.mp4", nil, "Range: bytes=100000-\r\n")
    eq(206, status)
    eq(big:sub(100001), body)
    -- HEAD: the headers only
    local reply = raw(("HEAD %sclip.mp4 HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n\r\n"):format(b, preview.server.port))
    ok(reply:find("Content-Length: " .. #big, 1, true))
    eq("", reply:match("\r\n\r\n(.*)$"))
  end)

  it("parses Range headers", function()
    local server = require("org.preview.server")
    eq({ 0, 10 }, { server.parse_range("bytes=0-", 10) })
    eq({ 2, 3 }, { server.parse_range("bytes=2-4", 10) })
    eq({ 8, 2 }, { server.parse_range("bytes=8-100", 10) })
    eq({ 7, 3 }, { server.parse_range("bytes=-3", 10) })
    eq({ 0, 10 }, { server.parse_range("bytes=-30", 10) })
    eq(false, server.parse_range("bytes=10-", 10))
    eq(false, server.parse_range("bytes=-0", 10))
    eq(nil, server.parse_range(nil, 10))
    eq(nil, server.parse_range("bytes=0-1,4-5", 10))
    eq(nil, server.parse_range("bytes=5-2", 10))
    eq(nil, server.parse_range("items=0-1", 10))
  end)

  it("closes connections that don't send their request in time", function()
    local server = require("org.preview.server")
    local srv = assert(server.start({ host = "127.0.0.1", port = 0, head_timeout = 100 }, function(_, res)
      res:send(200, nil, "hi")
    end))
    local tcp = assert(uv.new_tcp())
    local out, closed = {}, false
    tcp:connect("127.0.0.1", srv.port, function(err)
      assert(not err, err)
      tcp:write("GET / HTTP/1.1\r\nHost: x\r\n")
      tcp:read_start(function(rerr, data)
        if rerr or not data then
          closed = true
          tcp:close()
        else
          out[#out + 1] = data
        end
      end)
    end)
    ok(vim.wait(3000, function()
      return closed
    end, 10))
    ok(table.concat(out):match("^HTTP/1%.1 408"))
    eq(nil, next(srv.clients))
    srv:close()
  end)

  it("sends event data with CR line ends as separate lines", function()
    local server = require("org.preview.server")
    local stream
    local srv = assert(server.start({ host = "127.0.0.1", port = 0 }, function(_, res)
      stream = res:stream()
      stream:event("problem", "a\r\nb\rc")
    end))
    local tcp = assert(uv.new_tcp())
    local out = {}
    tcp:connect("127.0.0.1", srv.port, function()
      tcp:write("GET / HTTP/1.1\r\nHost: x\r\n\r\n")
      tcp:read_start(function(_, data)
        out[#out + 1] = data
      end)
    end)
    ok(vim.wait(3000, function()
      return table.concat(out):find("data: c\n\n", 1, true) ~= nil
    end, 10))
    ok(table.concat(out):find("event: problem\ndata: a\ndata: b\ndata: c\n\n", 1, true))
    stream:close()
    tcp:close()
    srv:close()
  end)

  it("listens on localhost and reports hosts it can't use", function()
    require("org.config").opts.export.preview.host = "localhost"
    open_org(DOC)
    local p = assert(preview.start())
    eq("127.0.0.1", preview.server.host)
    eq(200, (get(base(p))))
    preview.stop_all()
    require("org.config").opts.export.preview.host = "no-such-host.invalid"
    local got = notes(function()
      eq(nil, preview.start())
    end)
    eq(vim.log.levels.ERROR, got[#got].level)
    ok(got[#got].msg:find("no-such-host.invalid", 1, true))
    eq(nil, preview.server)
    -- the server itself returns an error for a name instead of throwing
    local srv, err = require("org.preview.server").start({ host = "not-an-address", port = 0 }, function() end)
    eq(nil, srv)
    ok(err:find("cannot listen on not-an-address", 1, true))
  end)

  it("shows why the first export failed to pages opened later", function()
    local buf = open_org({ "* Head {{{undefined}}}" })
    local p
    local got = notes(function()
      p = assert(preview.start())
    end)
    ok(p.problem and p.problem:find("Undefined Org macro", 1, true))
    eq(1, #vim.tbl_filter(function(n)
      return n.level == vim.log.levels.WARN and n.msg:find("export failed", 1, true) ~= nil
    end, got))
    local req = ("GET %s.org-preview/events HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n\r\n"):format(
      base(p),
      preview.server.port
    )
    local reply, tcp, out = raw(req, "event: problem\ndata: [^\n]+\n\n")
    ok(reply:find("event: hello\ndata: 0\n\nevent: problem\ndata: export failed: Undefined Org macro", 1, true))
    -- warned once while it keeps failing
    got = notes(function()
      preview.refresh(p)
    end)
    eq(0, #got)
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "* Head" })
    ok(preview.refresh(p))
    eq(nil, p.problem)
    ok(vim.wait(2000, function()
      return table.concat(out):find("event: reload", 1, true) ~= nil
    end, 10))
    tcp:close()
  end)

  it("counts only the headings the page shows", function()
    open_org({
      "* A :noexport:",
      "** A child",
      "* COMMENT A",
      "* B",
      "* DONE A :ARCHIVE:",
      "** A archived child",
      "* A",
      "** Two",
      "*** Three",
      "**** A deep",
    })
    local p = assert(preview.start())
    eq({ key = "a", n = 2, index = 3 }, preview.heading_at(p.bufnr, 7))
    eq({ key = "b", n = 1, index = 1 }, preview.heading_at(p.bufnr, 4))
    eq({ key = "a", n = 1, index = 2 }, preview.heading_at(p.bufnr, 5))
    -- deeper than H:3, a list item on the page: its heading
    eq({ key = "three", n = 1, index = 5 }, preview.heading_at(p.bufnr, 10))
    -- in a subtree the export leaves out
    eq(nil, preview.heading_at(p.bufnr, 2))
    eq(nil, preview.heading_at(p.bufnr, 3))
    eq(nil, preview.heading_at(p.bufnr, 6))
    -- the page agrees
    local _, body = get(base(p))
    ok(not body:find("A child", 1, true))
    ok(body:find("A archived", 1, true) == nil)
  end)

  it("follows #+OPTIONS and select tags when counting headings", function()
    open_org({
      "#+OPTIONS: H:1 tasks:nil arch:nil",
      "#+SELECT_TAGS: pick",
      "* TODO Task :pick:",
      "* A :pick:",
      "** Sub",
      "* Other",
      "* A :ARCHIVE:pick:",
      "* A :pick:",
    })
    local p = assert(preview.start())
    eq(nil, preview.heading_at(p.bufnr, 3))
    eq({ key = "a", n = 1, index = 1 }, preview.heading_at(p.bufnr, 5))
    eq(nil, preview.heading_at(p.bufnr, 6))
    eq({ key = "a", n = 2, index = 2 }, preview.heading_at(p.bufnr, 8))
  end)

  it("runs an open_browser string that names a program as it is", function()
    local calls, orig = {}, vim.system
    vim.system = function(cmd)
      calls[#calls + 1] = cmd
      return {}
    end
    local prog = dir .. "/my browser"
    write(prog, "#!/bin/sh\n")
    vim.fn.setfperm(prog, "rwxr-xr-x")
    local okr, err = pcall(function()
      open_org(DOC)
      require("org.config").opts.export.preview.open_browser = prog
      notes(preview.preview)
      if vim.fn.has("win32") == 0 then
        eq(prog, calls[1][1])
        eq(2, #calls[1])
      end
      preview.stop_all()
      require("org.config").opts.export.preview.open_browser = "firefox --new-tab"
      notes(preview.preview)
      eq({ "firefox", "--new-tab" }, vim.list_slice(calls[#calls], 1, 2))
    end)
    vim.system = orig
    assert(okr, err)
  end)
end)
