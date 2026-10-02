local root = vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))
local utils = require("org.utils")

local dir
local saved = {}

local function write(rel, lines)
  local path = dir .. "/" .. rel
  utils.writefile(path, lines)
  return path
end

local function read(path)
  return utils.readfile(path) or {}
end

local function setup(roam)
  require("org").setup({
    org_directory = root .. "/tests/fixtures",
    agenda_files = { root .. "/tests/fixtures/*.org" },
    extensions = {
      roam = vim.tbl_extend("force", { directory = dir, index_file = dir .. "/../roam-index.json" }, roam or {}),
    },
  })
end

local function db()
  return require("org.extensions.roam.db")
end

local function stub(mod, name, fn)
  saved[#saved + 1] = { mod, name, mod[name] }
  mod[name] = fn
end

--- Choose the candidate whose formatted text starts with `text`.
local function choose(text)
  stub(utils, "select", function(items, o)
    for _, it in ipairs(items) do
      if o.format_item(it):find(text, 1, true) == 1 then
        return it
      end
    end
    error("no candidate " .. text)
  end)
end

local function bump(path)
  local st = vim.uv.fs_stat(path)
  vim.uv.fs_utime(path, st.atime.sec, st.mtime.sec + 5)
end

describe("roam extension", function()
  before_each(function()
    dir = vim.fn.tempname() .. "/roam"
    vim.fn.mkdir(dir, "p")
    dir = require("org.utils").realpath(dir)
    setup()
    db().reset()
  end)
  after_each(function()
    for i = #saved, 1, -1 do
      local s = saved[i]
      s[1][s[2]] = s[3]
    end
    saved = {}
    vim.cmd("silent! %bwipeout!")
    require("org.extensions.roam.buffer").close()
    vim.fn.delete(vim.fs.dirname(dir), "rf")
    require("org").setup({
      org_directory = root .. "/tests/fixtures",
      agenda_files = { root .. "/tests/fixtures/*.org" },
    })
  end)

  describe("helpers", function()
    it("makes slugs like org-roam-node-slug", function()
      local slug = require("org.extensions.roam.capture").slug
      eq("hello_world", slug("Hello, World!"))
      eq("cafe_creme", slug("Café  Crème"))
      eq("a_b", slug("__a -- b__"))
      eq("日本語", slug("日本語"))
      -- only the marks org-roam strips go: ł has none, ą's ogonek stays
      eq("łodz_ąę", slug("Łódź ąę"))
      eq("tieng_viet", slug("Tiếng Việt"))
      eq("straße", slug("Straße"))
      -- symbols and emoji are not alphanumeric
      eq("5_off_deal", slug("5€ off 😀 deal"))
      eq("ǫ", slug("ǭ"))
    end)

    it("strips decomposed marks and keeps letter numbers in slugs, as org-roam does", function()
      local slug = require("org.extensions.roam.capture").slug
      -- e + U+0301, e + U+0323 + U+0301, q + U+0323 (NFD input)
      eq("ecole", slug("e\204\129cole"))
      eq("e_dot", slug("e\204\163\204\129 dot"))
      eq("q_dot_below", slug("q\204\163 dot below"))
      -- a mark org-roam keeps stays with its letter
      eq("e\204\133_overline", slug("e\204\133 overline"))
      -- Ⅻ is a letter number ([:alnum:] in Emacs); ½ and ² are not
      eq("ⅻ_roman", slug("Ⅻ roman"))
      eq("half_x", slug("½ half x²"))
    end)

    it("splits and joins quoted property values", function()
      eq({ "one", "two words", 'q"x' }, db().split_quoted('one "two words" "q\\"x"'))
      eq('one "two words"', db().join_quoted({ "one", "two words" }))
    end)

    it("reads refs as links and citation keys", function()
      eq({ { type = "cite", path = "doe2020" } }, db().parse_ref("@doe2020"))
      eq({ { type = "cite", path = "a" }, { type = "cite", path = "b" } }, db().parse_ref("[cite:@a;@b]"))
      eq({ { type = "https", path = "//example.com/x" } }, db().parse_ref("https://example.com/x"))
      eq({ { type = "https", path = "//e.org" } }, db().parse_ref("[[https://e.org][E]]"))
    end)
  end)

  describe("index", function()
    local a, b
    before_each(function()
      a = write("a.org", {
        ":PROPERTIES:",
        ":ID:       file-a",
        ':ROAM_ALIASES: Alpha "The A"',
        ":ROAM_REFS: https://example.com @doe2020",
        ":END:",
        "#+title: Note [[https://x.org][A]]",
        "#+filetags: :topic:",
        "",
        "* Parent :p:",
        "** Child :c:",
        ":PROPERTIES:",
        ":ID:       child-a",
        ":END:",
        "Links to [[id:file-b][B]].",
        "* Hidden",
        ":PROPERTIES:",
        ":ID:       hidden-a",
        ":ROAM_EXCLUDE: t",
        ":END:",
      })
      b = write("sub/b.org", {
        ":PROPERTIES:",
        ":ID:       file-b",
        ":END:",
        "See [[id:file-a][the A]] and [[id:child-a]].",
        "#+begin_src org",
        "[[id:file-a]]",
        "#+end_src",
        "Source: https://example.com and [cite:@doe2020].",
      })
      write("nofile.org", { "* No ID here" })
      write("data/x.org", { ":PROPERTIES:", ":ID: excluded", ":END:" })
      write(".hidden/y.org", { ":PROPERTIES:", ":ID: hidden-dir", ":END:" })
    end)

    it("indexes file and headline nodes with titles, aliases, refs, tags and olp", function()
      db().sync()
      local fa = db().node("file-a")
      eq("Note A", fa.title)
      eq(0, fa.level)
      eq({ "Alpha", "The A" }, fa.aliases)
      eq({ "https://example.com", "@doe2020" }, fa.refs)
      eq({ "topic" }, fa.tags)
      local child = db().node("child-a")
      eq("Child", child.title)
      eq(2, child.level)
      eq({ "Parent" }, child.olp)
      eq({ "topic", "p", "c" }, child.tags)
      eq("sub/b.org", db().relative(b))
      -- no #+title: the path relative to the directory
      eq("sub/b", db().node("file-b").title)
      eq(nil, db().node("hidden-a"))
      eq(nil, db().node("excluded"))
      eq(nil, db().node("hidden-dir"))
      eq(3, #db().nodes())
      eq(a, db().by_title("The A").file)
    end)

    it("finds backlinks, skipping verbatim blocks, and reflinks", function()
      db().sync()
      local back = db().backlinks("file-a")
      eq(1, #back)
      eq("file-b", back[1].source.id)
      eq(4, back[1].link.lnum)
      eq("child-a", db().backlinks("file-b")[1].source.id)
      local refs = db().reflinks(db().node("file-a"))
      eq(2, #refs)
      eq("file-b", refs[1].source.id)
    end)

    it("puts a citation at its key, where the backlinks buffer jumps to", function()
      db().sync()
      local cite = db().reflinks(db().node("file-a"))[2].link
      eq("cite", cite.type)
      eq(8, cite.lnum)
      -- "Source: https://example.com and [cite:@doe2020]."
      eq(39, cite.col)
      eq("@doe2020", read(b)[8]:sub(cite.col, cite.col + 7))
    end)

    it("re-parses only changed files and drops deleted ones", function()
      local parsed = db().sync()
      eq(3, parsed)
      eq(0, (db().sync()))
      write("sub/b.org", { ":PROPERTIES:", ":ID:       file-b", ":END:", "#+title: Bee" })
      bump(b)
      eq(1, (db().sync()))
      eq("Bee", db().node("file-b").title)
      eq(0, #db().backlinks("file-a"))
      os.remove(b)
      local _, removed = db().sync()
      eq(1, removed)
      eq(nil, db().node("file-b"))
    end)

    it("keeps the index on disk", function()
      db().sync()
      db().reset()
      eq(0, (db().sync()))
      eq("Note A", db().node("file-a").title)
    end)

    it("makes id: links into roam files resolve", function()
      db().sync()
      require("org.id")._reset()
      local loc = require("org.id").find("child-a")
      ok(loc, "found")
      eq(a, loc.filename)
    end)

    it("re-indexes a roam file when it is written", function()
      db().sync()
      vim.cmd("edit " .. vim.fn.fnameescape(b))
      vim.api.nvim_buf_set_lines(0, 3, 4, false, { "Now nothing links." })
      vim.cmd("silent write")
      eq(0, #db().backlinks("file-a"))
    end)
  end)

  describe("nodes", function()
    before_each(function()
      write("a.org", { ":PROPERTIES:", ":ID:       file-a", ":END:", "#+title: Apple", "", "* Seed", "Body" })
      write("b.org", { ":PROPERTIES:", ":ID:       file-b", ":END:", "#+title: Banana" })
      setup({
        capture_templates = {
          d = {
            description = "default",
            type = "plain",
            template = "Body of ${title}",
            target = "%<%Y>-${slug}.org",
            head = "#+title: ${title}\n",
            immediate_finish = true,
          },
        },
      })
    end)

    it("finds an existing node", function()
      choose("Banana")
      require("org.utils").run(require("org.extensions.roam.node").find)
      eq(dir .. "/b.org", vim.api.nvim_buf_get_name(0))
    end)

    it("finds a node by title or alias from the command", function()
      require("org.utils").run(require("org.extensions.roam.node").find, "Apple")
      eq(dir .. "/a.org", vim.api.nvim_buf_get_name(0))
    end)

    it("creates a new node from the capture template", function()
      choose("+ New node")
      stub(utils, "input", function()
        return "My New Note"
      end)
      require("org.utils").run(require("org.extensions.roam.node").find)
      local path = dir .. "/" .. os.date("%Y") .. "-my_new_note.org"
      local lines = read(path)
      eq(":PROPERTIES:", lines[1])
      local id = lines[2]:match("^:ID:%s+(%S+)")
      ok(id, vim.inspect(lines))
      eq(":END:", lines[3])
      eq("#+title: My New Note", lines[4])
      ok(vim.tbl_contains(lines, "Body of My New Note"), vim.inspect(lines))
      eq("My New Note", db().node(id).title)
    end)

    it("inserts a link to an existing node", function()
      org_buffer({ "Text" }, { 1, 3 })
      choose("Banana")
      require("org.utils").run(require("org.extensions.roam.node").insert)
      eq({ "Text[[id:file-b][Banana]]" }, buf_lines())
    end)

    it("creates a node and inserts a link to it", function()
      org_buffer({ "See " }, { 1, 3 })
      choose("+ New node")
      stub(utils, "input", function()
        return "Cherry"
      end)
      require("org.utils").run(require("org.extensions.roam.node").insert)
      local id = buf_lines()[1]:match("^See %[%[id:([^%]]+)%]%[Cherry%]%]$")
      ok(id, vim.inspect(buf_lines()))
      eq("Cherry", db().node(id).title)
      -- on the link's last bracket, as for an existing node
      eq({ 1, #buf_lines()[1] - 1 }, vim.api.nvim_win_get_cursor(0))
    end)

    it("inserts a link from Insert mode and goes on typing after it", function()
      org_buffer({ "See  now" }, { 1, 0 })
      choose("Banana")
      vim.keymap.set("i", "<F9>", function()
        require("org.utils").run(require("org.extensions.roam.node").insert)
      end, { buffer = true })
      vim.api.nvim_feedkeys(vim.keycode("5|i<F9>!<Esc>"), "xt", false)
      eq({ "See [[id:file-b][Banana]]! now" }, buf_lines())
      vim.api.nvim_feedkeys(vim.keycode("A<F9>.<Esc>"), "xt", false)
      eq({ "See [[id:file-b][Banana]]! now[[id:file-b][Banana]]." }, buf_lines())
    end)

    it("goes back to Insert mode after the link when the picker left it", function()
      org_buffer({ "See  now" }, { 1, 0 })
      local node = require("org.extensions.roam.node")
      -- a picker window (snacks) ends Insert mode before the link goes in;
      -- <Cmd><CR> lets the main loop start the Insert mode asked for
      vim.api.nvim_buf_set_text(0, 0, 4, 0, 4, { "[[id:x][X]]" })
      node.cursor_after_link(0, 15, true)
      vim.api.nvim_feedkeys(vim.keycode("<Cmd><CR>!<Esc>"), "xt", false)
      eq({ "See [[id:x][X]]! now" }, buf_lines())
      -- at the end of the line
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "See [[id:x][X]]" })
      node.cursor_after_link(0, 15, true)
      vim.api.nvim_feedkeys(vim.keycode("<Cmd><CR>!<Esc>"), "xt", false)
      eq({ "See [[id:x][X]]!" }, buf_lines())
    end)

    it("fills ${key=default} by asking once", function()
      local asked = 0
      stub(utils, "input", function(o)
        asked = asked + 1
        eq("where: ", o.prompt)
        eq("home", o.default)
        return "office"
      end)
      local fill = require("org.extensions.roam.capture").fill
      eq("office/office", fill("${where=home}/${where=home}", {}, {}))
      eq(1, asked)
    end)

    it("adds and removes aliases, refs and tags on the file node", function()
      vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/a.org"))
      local node = require("org.extensions.roam.node")
      node.alias_add("Red fruit")
      node.alias_add("Pomme")
      eq(':ROAM_ALIASES: Pomme "Red fruit"', buf_lines()[3])
      node.alias_remove("Pomme")
      eq(':ROAM_ALIASES: "Red fruit"', buf_lines()[3])
      node.ref_add("@apple2024")
      ok(vim.tbl_contains(buf_lines(), ":ROAM_REFS: @apple2024"), vim.inspect(buf_lines()))
      node.tag_add("fruit red")
      ok(vim.tbl_contains(buf_lines(), "#+filetags: :fruit:red:"), vim.inspect(buf_lines()))
      node.tag_remove("red")
      ok(vim.tbl_contains(buf_lines(), "#+filetags: :fruit:"), vim.inspect(buf_lines()))
    end)

    it("edits a headline node's tags and properties", function()
      vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/a.org"))
      vim.api.nvim_buf_set_lines(0, 5, 6, false, { "* Seed", ":PROPERTIES:", ":ID:       seed", ":END:" })
      vim.api.nvim_win_set_cursor(0, { 9, 0 })
      local node = require("org.extensions.roam.node")
      eq("seed", node.at_point().id)
      node.tag_add({ "plant" })
      ok(buf_lines()[6]:match("^%* Seed%s+:plant:$"), buf_lines()[6])
      node.alias_add("Pip")
      ok(vim.tbl_contains(buf_lines(), ":ROAM_ALIASES: Pip"), vim.inspect(buf_lines()))
    end)

    it("extracts a subtree into its own file node", function()
      vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/a.org"))
      vim.api.nvim_buf_set_lines(0, 5, -1, false, { "* Seed :s:", "Body", "** Kid", "text" })
      vim.api.nvim_win_set_cursor(0, { 6, 0 })
      require("org.extensions.roam.node").extract_subtree("seed.org")
      local lines = read(dir .. "/seed.org")
      eq(":PROPERTIES:", lines[1])
      local id = lines[2]:match("^:ID:%s+(%S+)")
      ok(id, vim.inspect(lines))
      eq({ ":END:", "#+title: Seed", "#+filetags: :s:", "Body", "* Kid", "text" }, vim.list_slice(lines, 3))
      eq({ ":PROPERTIES:", ":ID:       file-a", ":END:", "#+title: Apple", "" }, buf_lines())
      eq("Seed", db().node(id).title)
    end)

    it("refiles the subtree at point under a node", function()
      vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/a.org"))
      vim.api.nvim_win_set_cursor(0, { 6, 0 })
      choose("Banana")
      require("org.utils").run(require("org.extensions.roam.node").refile)
      eq({ ":PROPERTIES:", ":ID:       file-a", ":END:", "#+title: Apple", "" }, buf_lines())
      local bbuf = utils.find_buffer(dir .. "/b.org")
      eq({ ":PROPERTIES:", ":ID:       file-b", ":END:", "#+title: Banana", "* Seed", "Body" }, buf_lines(bbuf))
    end)

    it("follows roam: links by title", function()
      local lt = require("org.links").link_type("roam")
      ok(lt and lt.follow)
      lt.follow("Banana")
      eq(dir .. "/b.org", vim.api.nvim_buf_get_name(0))
    end)
  end)

  describe("capture with the default template", function()
    local function start(title)
      choose("+ New node")
      stub(utils, "input", function()
        return title
      end)
      require("org.utils").run(require("org.extensions.roam.node").find)
      local sessions = require("org.capture").sessions
      local buf = next(sessions)
      ok(buf, "a capture is open")
      return buf
    end

    it("writes the node when the capture is finished", function()
      local buf = start("Plum")
      local path = vim.fs.normalize(vim.api.nvim_buf_get_name(buf))
      ok(path:match("/%d+%-plum%.org$"), path)
      require("org.capture").finalize(buf)
      local lines = read(path)
      eq(":PROPERTIES:", lines[1])
      eq("#+title: Plum", lines[4])
      local id = lines[2]:match("^:ID:%s+(%S+)")
      eq("Plum", db().node(id).title)
    end)

    it("leaves no file behind when the capture is aborted", function()
      local buf = start("Pear")
      local path = vim.fs.normalize(vim.api.nvim_buf_get_name(buf))
      require("org.capture").kill(buf)
      ok(not utils.exists(path))
      ok(not utils.find_buffer(path))
    end)
  end)

  describe("backlinks buffer", function()
    it("lists backlinks of the node at point with a preview", function()
      write("a.org", { ":PROPERTIES:", ":ID:       file-a", ":END:", "#+title: Apple" })
      write("b.org", {
        ":PROPERTIES:",
        ":ID:       file-b",
        ":END:",
        "#+title: Banana",
        "* Notes",
        "Apples are [[id:file-a][good]].",
        "Really.",
      })
      vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/a.org"))
      local buffer = require("org.extensions.roam.buffer")
      buffer.toggle()
      ok(buffer.is_open())
      eq({
        "Apple",
        "",
        "Backlinks (1)",
        "  Banana",
        "    Notes",
        "      Apples are good.",
        "      Really.",
        "",
        "Reflinks (0)",
        "",
      }, buffer.lines())
      buffer.toggle()
      ok(not buffer.is_open())
    end)

    it("doesn't index the text the transclusion extension inserted", function()
      require("org").setup({
        org_directory = root .. "/tests/fixtures",
        agenda_files = { root .. "/tests/fixtures/*.org" },
        extensions = {
          roam = { directory = dir, index_file = dir .. "/../roam-index.json" },
          transclusion = {},
        },
      })
      write("a.org", { ":PROPERTIES:", ":ID:       file-a", ":END:", "#+title: Apple" })
      local other = vim.fs.dirname(dir) .. "/other.org"
      utils.writefile(other, { "* Borrowed", "See [[id:file-a][Apple]]." })
      local b = write("b.org", {
        ":PROPERTIES:",
        ":ID:       file-b",
        ":END:",
        "#+title: Banana",
        "#+transclude: [[file:" .. other .. "::*Borrowed]]",
      })
      db().sync(true)
      eq(0, #db().backlinks("file-a"))
      vim.cmd("edit " .. vim.fn.fnameescape(b))
      vim.api.nvim_win_set_cursor(0, { 5, 0 })
      require("org.extensions.transclusion").add()
      ok(table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"):find("[[id:file-a][Apple]]", 1, true))
      db().update_file(b)
      eq(0, #db().backlinks("file-a"))
      eq(
        {},
        vim.tbl_map(
          function(n)
            return n.title
          end,
          vim.tbl_filter(function(n)
            return n.title == "Borrowed"
          end, db().nodes())
        )
      )
    end)

    it("closes with <Esc>, not q", function()
      write("a.org", { ":PROPERTIES:", ":ID:       file-a", ":END:", "#+title: Apple" })
      vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/a.org"))
      local buffer = require("org.extensions.roam.buffer")
      buffer.toggle()
      local win = vim.fn.bufwinid("org-roam")
      ok(win ~= -1)
      vim.api.nvim_set_current_win(win)
      eq("", vim.fn.maparg("q", "n", false, false))
      vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "x", false)
      ok(not buffer.is_open())
    end)

    it("opens a link beside it when it is the only window, keeping its options to itself", function()
      write("a.org", { ":PROPERTIES:", ":ID:       file-a", ":END:", "#+title: Apple" })
      write("b.org", { ":PROPERTIES:", ":ID:       file-b", ":END:", "#+title: Banana", "See [[id:file-a][A]]." })
      vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/a.org"))
      vim.wo.signcolumn = "yes"
      local usual = { vim.wo.foldenable, vim.wo.signcolumn }
      local buffer = require("org.extensions.roam.buffer")
      buffer.toggle()
      -- the paragraph only, not the #+title before it
      eq(
        { "Apple", "", "Backlinks (1)", "  Banana", "    Top", "      See A.", "" },
        vim.list_slice(buffer.lines(), 1, 7)
      )
      vim.cmd("wincmd l")
      local roam_win = vim.api.nvim_get_current_win()
      ok(vim.wo.winfixwidth)
      ok(not vim.wo.foldenable)
      eq("no", vim.wo.signcolumn)
      vim.cmd("only")
      vim.api.nvim_win_set_cursor(0, { 6, 0 })
      vim.api.nvim_feedkeys(vim.keycode("<CR>"), "xt", false)
      eq(2, #vim.api.nvim_tabpage_list_wins(0))
      ok(buffer.is_open())
      eq(dir .. "/b.org", vim.api.nvim_buf_get_name(0))
      eq({ 5, 4 }, vim.api.nvim_win_get_cursor(0))
      -- the note's window has the options of a normal window
      ok(vim.api.nvim_get_current_win() ~= roam_win)
      eq(usual, { vim.wo.foldenable, vim.wo.signcolumn })
      ok(not vim.wo.winfixwidth)
      -- and so does a file opened in the roam window
      vim.api.nvim_set_current_win(roam_win)
      vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/a.org"))
      eq(usual, { vim.wo.foldenable, vim.wo.signcolumn })
      vim.cmd("only")
      vim.wo.signcolumn = "auto"
    end)

    it("keeps the height of a bottom window", function()
      setup({ buffer = { position = "bottom", height = 7 } })
      write("a.org", { ":PROPERTIES:", ":ID:       file-a", ":END:", "#+title: Apple" })
      vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/a.org"))
      local buffer = require("org.extensions.roam.buffer")
      buffer.toggle()
      vim.cmd("wincmd j")
      eq(7, vim.api.nvim_win_get_height(0))
      ok(vim.wo.winfixheight)
      ok(not vim.wo.winfixwidth)
    end)

    it("closes the window and deletes its buffer when the extension is turned off", function()
      write("a.org", { ":PROPERTIES:", ":ID:       file-a", ":END:", "#+title: Apple" })
      vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/a.org"))
      local buffer = require("org.extensions.roam.buffer")
      buffer.toggle()
      ok(buffer.is_open())
      require("org").setup({ org_directory = root .. "/tests/fixtures" })
      ok(not buffer.is_open())
      eq(-1, vim.fn.bufnr("^org-roam$"))
      eq({}, vim.api.nvim_get_autocmds({ group = "org.roam" }))
      eq({}, vim.api.nvim_get_autocmds({ group = "org.roam.buffer" }))
    end)
  end)

  describe("dailies", function()
    local today = os.date("%Y-%m-%d")

    it("opens today's note, creating it from the head", function()
      require("org.utils").run(require("org.extensions.roam.dailies").goto_today)
      local path = dir .. "/daily/" .. today .. ".org"
      eq(path, vim.api.nvim_buf_get_name(0))
      local lines = buf_lines()
      eq(":PROPERTIES:", lines[1])
      ok(lines[2]:match("^:ID:%s+%S+"))
      eq("#+title: " .. today, lines[4])
    end)

    it("captures into a day's note", function()
      setup({
        dailies = {
          capture_templates = {
            d = {
              type = "entry",
              template = "* Entry",
              target = "%<%Y-%m-%d>.org",
              head = "#+title: %<%Y-%m-%d>\n",
              immediate_finish = true,
            },
          },
        },
      })
      require("org.utils").run(require("org.extensions.roam.dailies").capture_yesterday)
      local y = os.date("%Y-%m-%d", os.time() - 86400)
      local lines = read(dir .. "/daily/" .. y .. ".org")
      eq("#+title: " .. y, lines[4])
      eq("* Entry", lines[#lines])
    end)

    it("steps between daily notes", function()
      for _, d in ipairs({ "2026-01-01", "2026-01-03", "2026-01-05" }) do
        write("daily/" .. d .. ".org", { "#+title: " .. d })
      end
      local dailies = require("org.extensions.roam.dailies")
      vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/daily/2026-01-03.org"))
      dailies.goto_next_note()
      eq(dir .. "/daily/2026-01-05.org", vim.api.nvim_buf_get_name(0))
      dailies.goto_previous_note(2)
      eq(dir .. "/daily/2026-01-01.org", vim.api.nvim_buf_get_name(0))
      vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/daily/2026-01-04.org"))
      dailies.goto_previous_note()
      eq(dir .. "/daily/2026-01-03.org", vim.api.nvim_buf_get_name(0))
    end)
  end)

  describe("index edge cases", function()
    it("keeps the first node of a duplicated id and reports the others", function()
      local a = write("a.org", { ":PROPERTIES:", ":ID: same", ":END:", "#+title: First" })
      write("b.org", { ":PROPERTIES:", ":ID: same", ":END:", "#+title: Second" })
      db().sync()
      eq("First", db().node("same").title)
      eq(1, #db().nodes())
      local dups = db().duplicates().same
      eq(2, #dups)
      eq("Second", dups[2].title)
      require("org.id")._reset()
      eq(a, require("org.id").find("same").filename)
    end)

    it("excludes files by Emacs regexp or function", function()
      setup({
        exclude = {
          "\\.draft\\.org\\'",
          function(rel)
            return rel:find("^attic/") ~= nil
          end,
        },
      })
      write("keep.org", { ":PROPERTIES:", ":ID: keep", ":END:" })
      write("x.draft.org", { ":PROPERTIES:", ":ID: draft", ":END:" })
      write("attic/old.org", { ":PROPERTIES:", ":ID: old", ":END:" })
      db().sync()
      eq(
        { "keep" },
        vim.tbl_map(function(n)
          return n.id
        end, db().nodes())
      )
    end)

    it("finds a directory created after setup", function()
      local later = dir .. "/later"
      setup({ directory = later })
      eq(0, (db().sync()))
      vim.fn.mkdir(later, "p")
      utils.writefile(later .. "/n.org", { ":PROPERTIES:", ":ID: late", ":END:" })
      eq(1, (db().sync()))
      ok(db().node("late"))
    end)

    it("skips links in comments, fixed-width lines and #+transclude, like org-roam", function()
      write("a.org", { ":PROPERTIES:", ":ID: a", ":END:", "#+title: Alpha" })
      write("b.org", {
        ":PROPERTIES:",
        ":ID: b",
        ":END:",
        "# a comment [[id:a][A]]",
        "#",
        ": fixed [[id:a][A]] [cite:@key]",
        "#+transclude: [[id:a]]",
        "#+TRANSCLUDE: [[id:a]]",
        "#+caption: kept [[id:a][A]]",
        "Text [[id:a][A]].",
      })
      db().sync()
      eq(
        { 9, 10 },
        vim.tbl_map(function(b)
          return b.link.lnum
        end, db().backlinks("a"))
      )
      eq(0, #vim.tbl_filter(function(l)
        return l.type == "cite"
      end, db().links()))
    end)

    it("indexes without keeping every note in org.files' cache", function()
      write("a.org", { ":PROPERTIES:", ":ID: a", ":END:", "#+title: Alpha" })
      stub(require("org.files"), "get", function()
        error("org.files.get used")
      end)
      eq(1, (db().sync()))
      ok(db().node("a"))
    end)

    it("writes the index a moment after a save, and at once on flush or teardown", function()
      local a = write("a.org", { ":PROPERTIES:", ":ID: a", ":END:", "#+title: Alpha" })
      db().sync()
      local path = dir .. "/../roam-index.json"
      local function on_disk()
        local data = utils.read_json(path)
        local e = data.files[a]
        return e and e.nodes[1] and e.nodes[1].title
      end
      eq("Alpha", on_disk())
      write("a.org", { ":PROPERTIES:", ":ID: a", ":END:", "#+title: Beta" })
      bump(a)
      db().update_file(a)
      eq("Beta", db().node("a").title)
      eq("Alpha", on_disk())
      db().flush()
      eq("Beta", on_disk())
      write("a.org", { ":PROPERTIES:", ":ID: a", ":END:", "#+title: Gamma" })
      bump(a)
      db().update_file(a)
      vim.wait(3000, function()
        return on_disk() == "Gamma"
      end)
      eq("Gamma", on_disk())
      write("a.org", { ":PROPERTIES:", ":ID: a", ":END:", "#+title: Delta" })
      bump(a)
      db().update_file(a)
      require("org").setup({ org_directory = root .. "/tests/fixtures" })
      eq("Delta", on_disk())
    end)

    it("has no node at point in a file with ROAM_EXCLUDE", function()
      local a = write("a.org", { ":PROPERTIES:", ":ID: a", ":ROAM_EXCLUDE: t", ":END:", "#+title: Alpha" })
      vim.cmd("edit " .. vim.fn.fnameescape(a))
      eq(nil, require("org.extensions.roam.node").at_point())
    end)

    it("lists unlinked references outside links and the node's own file", function()
      write("a.org", { ":PROPERTIES:", ":ID: a", ":ROAM_ALIASES: Alef", ":END:", "#+title: Alpha", "Alpha itself." })
      write("b.org", {
        ":PROPERTIES:",
        ":ID: b",
        ":END:",
        "alpha and ALEF, [[id:a][Alpha]], alphabet, [Alpha] and Alpha.",
      })
      db().sync()
      local refs = db().unlinked_references(db().node("a"))
      eq(
        { "alpha", "ALEF", "Alpha" },
        vim.tbl_map(function(r)
          return r.match
        end, refs)
      )
      eq(
        { 1, 11, 56 },
        vim.tbl_map(function(r)
          return r.col
        end, refs)
      )
    end)

    it("finds unlinked references in the unsaved text of a buffer", function()
      write("a.org", { ":PROPERTIES:", ":ID: a", ":END:", "#+title: Alpha" })
      local b = write("b.org", { ":PROPERTIES:", ":ID: b", ":END:", "Nothing yet." })
      db().sync()
      eq({}, db().unlinked_references(db().node("a")))
      vim.cmd("edit " .. vim.fn.fnameescape(b))
      vim.api.nvim_buf_set_lines(0, 3, 4, false, { "Now about alpha." })
      local refs = db().unlinked_references(db().node("a"))
      eq(1, #refs)
      eq({ 4, 11, "alpha" }, { refs[1].lnum, refs[1].col, refs[1].match })
      -- saved again, the file's own text counts
      vim.cmd("silent edit!")
      eq({}, db().unlinked_references(db().node("a")))
    end)
  end)

  describe("capture targets", function()
    before_each(function()
      write("a.org", { ":PROPERTIES:", ":ID: file-a", ":END:", "#+title: Apple" })
      setup({
        capture_templates = {
          o = {
            type = "entry",
            template = "* Note",
            target = { "file+head+olp", "proj.org", "#+title: Projects", { "Active", "${title}" } },
            immediate_finish = true,
          },
          t = {
            type = "entry",
            template = "* Logged",
            target = { "file+datetree", "journal.org", "month" },
            immediate_finish = true,
          },
          n = { type = "entry", template = "* About ${title}", target = { "node", "Apple" }, immediate_finish = true },
          h = { type = "plain", template = "text", target = { "file+head", "${slug}.org", "#+title: ${title}" } },
        },
      })
    end)

    local function capture(key, title)
      require("org.utils").run(require("org.extensions.roam.capture").capture, { keys = key, node = { title = title } })
    end

    it("makes a file+head+olp target and gives the last heading the id", function()
      capture("o", "Rocket")
      local lines = read(dir .. "/proj.org")
      eq({ "#+title: Projects", "* Active", "** Rocket", ":PROPERTIES:" }, vim.list_slice(lines, 1, 4))
      local id = lines[5]:match("^:ID:%s+(%S+)")
      ok(id, vim.inspect(lines))
      eq("*** Note", lines[#lines])
      eq("Rocket", db().node(id).title)
    end)

    it("makes a file+datetree target whose entry is the node", function()
      capture("t", "")
      local lines = read(dir .. "/journal.org")
      local month = os.date("%Y-%m %B")
      local at = vim.fn.index(lines, "** " .. month) + 1
      ok(at > 0, vim.inspect(lines))
      ok(lines[at + 2]:match("^:ID:"), vim.inspect(lines))
      eq("*** Logged", lines[#lines])
      local id = lines[at + 2]:match("^:ID:%s+(%S+)")
      eq(month, db().node(id).title)
    end)

    it("captures under an existing node by title", function()
      capture("n", "Apple")
      eq({ ":PROPERTIES:", ":ID: file-a", ":END:", "#+title: Apple", "* About Apple" }, read(dir .. "/a.org"))
    end)

    it("reads the parts of every target form", function()
      local parts = require("org.extensions.roam.capture").target_parts
      eq({ file = "x.org" }, parts({ target = "x.org" }, {}))
      eq("h", parts({ target = { "file+head", "x.org", "h" } }, {}).head)
      eq({ "A" }, parts({ target = { "file+olp", "x.org", { "A" } } }, {}).olp)
      eq("week", parts({ target = { "file+datetree", "x.org", "week" } }, {}).tree_type)
      eq({ node = "Apple" }, parts({ target = { "node", "Apple" } }, {}))
      local _, err = parts({ target = { "nope", "x" } }, {})
      ok(err and err:find("unknown"), err)
    end)
  end)

  describe("org-protocol", function()
    it("captures a roam-ref into a new node with the ref, then into that node", function()
      require("org.protocol").handle(
        "org-protocol://roam-ref?template=r&ref=https%3A%2F%2Fexample.com%2Fpost&title=Example%20Post&body=hi"
      )
      local buf = next(require("org.capture").sessions)
      ok(buf, "a capture is open")
      local path = vim.fs.normalize(vim.api.nvim_buf_get_name(buf))
      eq(dir .. "/example_post.org", path)
      require("org.capture").finalize(buf)
      local lines = read(path)
      ok(vim.tbl_contains(lines, ":ROAM_REFS: https://example.com/post"), vim.inspect(lines))
      eq("#+title: Example Post", lines[5])
      eq("Example Post", db().by_ref("https://example.com/post").title)
      -- the same ref again: capture to the existing node
      require("org.protocol").handle("org-protocol://roam-ref?template=r&ref=https%3A%2F%2Fexample.com%2Fpost&title=X")
      buf = next(require("org.capture").sessions)
      eq(path, vim.fs.normalize(vim.api.nvim_buf_get_name(buf)))
      require("org.capture").kill(buf)
      eq(1, #vim.fn.glob(dir .. "/*.org", false, true))
    end)

    it("visits a roam-node, and stops handling both when turned off", function()
      write("b.org", { ":PROPERTIES:", ":ID: file-b", ":END:", "#+title: Banana" })
      require("org.protocol").handle("org-protocol://roam-node?node=file-b")
      eq(dir .. "/b.org", vim.api.nvim_buf_get_name(0))
      require("org").setup({ org_directory = root .. "/tests/fixtures" })
      eq({}, require("org.protocol").extension_handlers)
    end)
  end)

  describe("roam: links", function()
    it("are replaced with id: links on save, outside verbatim blocks", function()
      write("a.org", { ":PROPERTIES:", ":ID: file-a", ":ROAM_ALIASES: Pomme", ":END:", "#+title: Apple" })
      local b = write("b.org", {
        ":PROPERTIES:",
        ":ID: file-b",
        ":END:",
        "See [[roam:Apple]], [[roam:Pomme][the fruit]] and [[roam:Nothing]].",
        "#+begin_src org",
        "[[roam:Apple]]",
        "#+end_src",
      })
      db().sync()
      vim.cmd("edit " .. vim.fn.fnameescape(b))
      vim.cmd("silent write")
      eq("See [[id:file-a][Apple]], [[id:file-a][the fruit]] and [[roam:Nothing]].", buf_lines()[4])
      eq("[[roam:Apple]]", buf_lines()[6])
      -- one backlink per link, as in org-roam
      eq(2, #db().backlinks("file-a"))
    end)

    it("are left alone with link_auto_replace off", function()
      setup({ link_auto_replace = false })
      write("a.org", { ":PROPERTIES:", ":ID: file-a", ":END:", "#+title: Apple" })
      local b = write("b.org", { "[[roam:Apple]]" })
      db().sync()
      vim.cmd("edit " .. vim.fn.fnameescape(b))
      vim.cmd("silent write")
      eq({ "[[roam:Apple]]" }, buf_lines())
    end)
  end)

  describe("refile and pickers", function()
    before_each(function()
      write("a.org", { ":PROPERTIES:", ":ID: file-a", ":END:", "#+title: Apple" })
    end)

    it("deletes a source file that the refile left empty", function()
      local solo = write("solo.org", { "* Only", "text" })
      db().sync()
      vim.cmd("edit " .. vim.fn.fnameescape(solo))
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      choose("Apple")
      require("org.utils").run(require("org.extensions.roam.node").refile)
      ok(not utils.exists(solo))
      ok(not utils.find_buffer(solo))
      local abuf = utils.find_buffer(dir .. "/a.org")
      eq("* Only", buf_lines(abuf)[5])
    end)

    it("creates a node from the text typed in the input picker", function()
      setup({ picker = "input" })
      local node = require("org.extensions.roam.node")
      stub(vim.fn, "input", function(o)
        eq({ "Apple" }, node._complete("", "app"))
        return "Apple"
      end)
      local c
      require("org.utils").run(function()
        c = node.read({})
      end)
      eq("file-a", c.node.id)
      stub(vim.fn, "input", function()
        return "Brand New"
      end)
      require("org.utils").run(function()
        c = node.read({})
      end)
      eq({ title = "Brand New" }, c)
    end)

    it("creates a node from the snacks picker's query when nothing matches", function()
      local query, pick_item
      stub(_G, "Snacks", {
        picker = {
          pick = function(o)
            -- like snacks, closing the picker runs on_close
            local picker = { input = { filter = { pattern = query } } }
            picker.close = function()
              o.on_close(picker)
            end
            o.actions.confirm(picker, pick_item and o.items[1] or nil)
          end,
        },
      })
      eq("snacks", require("org.extensions.roam.node").picker())
      local node = require("org.extensions.roam.node")
      local c
      query, pick_item = "Durian", false
      require("org.utils").run(function()
        c = node.read({})
      end)
      vim.wait(100, function()
        return c ~= nil
      end)
      eq({ title = "Durian" }, c)
      c, query, pick_item = nil, "app", true
      require("org.utils").run(function()
        c = node.read({})
      end)
      vim.wait(100, function()
        return c ~= nil
      end)
      eq("file-a", c.node.id)
    end)
  end)

  describe("graph", function()
    it("writes the nodes and links as Graphviz, around a node with a distance", function()
      write("a.org", { ":PROPERTIES:", ":ID: a", ":END:", "#+title: Apple", "[[id:b][B]] [[https://x.org][X]]" })
      write("b.org", { ":PROPERTIES:", ":ID: b", ":END:", "#+title: Banana", "[[id:c][C]]" })
      write("c.org", { ":PROPERTIES:", ":ID: c", ":END:", '#+title: Cherry "red"' })
      write("d.org", { ":PROPERTIES:", ":ID: d", ":END:", "#+title: Lonely" })
      local graph = require("org.extensions.roam.graph")
      local dot = graph.dot()
      ok(dot:find('"a" -> "b";', 1, true), dot)
      ok(dot:find('"b" -> "c";', 1, true), dot)
      ok(dot:find('"a" -> "https://x.org";', 1, true), dot)
      ok(dot:find('label="Cherry &quot;red&quot;"', 1, true), dot)
      ok(dot:find("org-protocol://roam-node?node=a", 1, true), dot)
      ok(dot:find('"d" [', 1, true), dot)
      local near = graph.dot({ id = "a", distance = 1 })
      ok(near:find('"a" -> "b";', 1, true), near)
      ok(not near:find('"c"', 1, true), near)
      ok(not near:find('"d"', 1, true), near)
      ok(graph.dot({ id = "a", distance = 0 }):find('"b" -> "c";', 1, true))
    end)
  end)

  it("adds no key that is a prefix of, or the same as, another org key", function()
    local a = write("a.org", { "* A" })
    vim.cmd("edit " .. vim.fn.fnameescape(a))
    local clashes = {}
    for _, mode in ipairs({ "n", "x", "o" }) do
      local keys = {}
      for _, m in ipairs(vim.list_extend(vim.api.nvim_buf_get_keymap(0, mode), vim.api.nvim_get_keymap(mode))) do
        if m.desc and m.desc:match("^org: ") then
          keys[#keys + 1] = { key = vim.keycode(m.lhs), desc = m.desc }
        end
      end
      for _, k in ipairs(keys) do
        for _, o in ipairs(keys) do
          local roam = k.desc:find("roam", 1, true) or o.desc:find("roam", 1, true)
          if roam and k ~= o and o.key:sub(1, #k.key) == k.key and (#k.key < #o.key or k.desc ~= o.desc) then
            clashes[#clashes + 1] = mode .. " " .. k.key .. " (" .. k.desc .. ") / " .. o.key .. " (" .. o.desc .. ")"
          end
        end
      end
    end
    eq({}, clashes)
  end)

  it("labels its key groups for which-key", function()
    local added = {}
    package.loaded["which-key"] = {
      add = function(spec)
        vim.list_extend(added, spec)
      end,
    }
    require("org.mappings").register_which_key()
    package.loaded["which-key"] = nil
    local labels = {}
    for _, g in ipairs(added) do
      labels[g[1]] = g.group
    end
    local config = require("org.config")
    eq("roam", labels[config.lhs_list("<prefix>m")[1]])
    eq("roam dailies", labels[config.lhs_list("<prefix>md")[1]])
  end)

  it("registers its actions and keys, and stays off by default", function()
    ok(require("org.actions").list.roam_node_find)
    eq("<prefix>mf", require("org.config").opts.mappings.global.roam_node_find)
    require("org").setup({ org_directory = root .. "/tests/fixtures" })
    eq(nil, require("org.actions").list.roam_node_find)
    eq(nil, require("org.config").opts.links.types.roam)
  end)
end)
