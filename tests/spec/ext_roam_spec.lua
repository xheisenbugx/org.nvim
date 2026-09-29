local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
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
    dir = vim.uv.fs_realpath(dir)
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

  it("registers its actions and keys, and stays off by default", function()
    ok(require("org.actions").list.roam_node_find)
    eq("<prefix>mf", require("org.config").opts.mappings.global.roam_node_find)
    require("org").setup({ org_directory = root .. "/tests/fixtures" })
    eq(nil, require("org.actions").list.roam_node_find)
    eq(nil, require("org.config").opts.links.types.roam)
  end)
end)
