-- Hyperlinks: Emacs Org 9.8 parity (org-link-search, org-store-link,
-- org-insert-link, org-link-make-string, org-open-at-point, org-id links).
local links = require("org.links")
local config = require("org.config")
local utils = require("org.utils")

local root = vim.fn.getcwd()
local ZWSP = "\226\128\139"

local saved = {}
local function stub(t, k, v)
  saved[#saved + 1] = { t, k, t[k] }
  t[k] = v
end
local function restore()
  for i = #saved, 1, -1 do
    local s = saved[i]
    s[1][s[2]] = s[3]
  end
  saved = {}
end

local function reset(extra)
  config.setup(vim.tbl_deep_extend("force", {
    org_directory = root .. "/tests/fixtures",
    agenda_files = { root .. "/tests/fixtures/*.org" },
  }, extra or {}))
end

local function tmpdir()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  return vim.uv.fs_realpath(dir)
end

local function write(dir, name, lines)
  local p = dir .. "/" .. name
  vim.fn.mkdir(vim.fn.fnamemodify(p, ":h"), "p")
  vim.fn.writefile(lines, p)
  return p
end

local function edit(p, cursor)
  vim.cmd("silent! only")
  vim.cmd("edit! " .. vim.fn.fnameescape(p))
  if cursor then
    vim.api.nvim_win_set_cursor(0, cursor)
  end
  return vim.api.nvim_get_current_buf()
end

local function cursor()
  return vim.api.nvim_win_get_cursor(0)
end

local function real(p)
  return vim.uv.fs_realpath(p) or p
end

--- Answer vim.fn.input prompts from a table (prompt prefix -> answer; a
--- function receives the options).
local function answer(map)
  stub(vim.fn, "input", function(o)
    o = type(o) == "table" and o or { prompt = o }
    for prefix, v in pairs(map) do
      if o.prompt:sub(1, #prefix) == prefix then
        if type(v) == "function" then
          return v(o)
        end
        return v
      end
    end
    error("unexpected prompt " .. o.prompt)
  end)
end

describe("links parity", function()
  before_each(function()
    restore()
    vim.cmd("silent! only")
    links.stored = {}
    links._search_failed = nil
    reset()
  end)

  describe("fuzzy links (org-link-search)", function()
    it("offers to create a missing heading instead of matching the link itself", function()
      org_buffer({ "* A", "See [[nonexistent thing]] here", "* B" }, { 2, 8 })
      local asked
      stub(utils, "confirm", function(msg)
        asked = msg
        return true
      end)
      links.open_at_point(0)
      eq("No match - create this as a new heading?", asked)
      eq({ "* A", "See [[nonexistent thing]] here", "* B", "* nonexistent thing" }, buf_lines())
      eq({ 4, 0 }, cursor())
    end)

    it("puts a blank line before the new heading like org-blank-before-new-entry", function()
      org_buffer({ "* A", "", "text [[New thing]] x", "", "* B", "", "body b" }, { 3, 8 })
      stub(utils, "confirm", function()
        return true
      end)
      links.open_at_point(0)
      eq({ "* A", "", "text [[New thing]] x", "", "* B", "", "body b", "", "* New thing" }, buf_lines())
    end)

    it("reports a missing match when declined, or with must-match t, without moving", function()
      org_buffer({ "* A", "See [[line]] and the line here", "* B" }, { 2, 6 })
      stub(utils, "confirm", function()
        return false
      end)
      eq(nil, links.open_at_point(0))
      eq({ 2, 6 }, cursor())
      config.opts.links.search_must_match_exact_headline = true
      stub(utils, "confirm", function()
        error("must not ask")
      end)
      eq(nil, links.open_at_point(0))
      eq({ 2, 6 }, cursor())
    end)

    it("falls back to a text search that skips the link itself when must-match is nil", function()
      config.opts.links.search_must_match_exact_headline = false
      org_buffer({ "* A", "See [[line]] and the line", "here" }, { 2, 6 })
      links.open_at_point(0)
      eq({ 2, 21 }, cursor())
      -- a starred search never falls back to text
      org_buffer({ "* A", "See [[*line]] and the line" }, { 2, 6 })
      eq(nil, links.open_at_point(0))
    end)

    it("normalises whitespace and case in headline, target and CUSTOM_ID searches", function()
      org_buffer({
        "* TODO [#A] Head one [1/2] :tag:",
        "text",
        "* Head   Spaced   Out",
        ":PROPERTIES:",
        ":CUSTOM_ID: cid1",
        ":END:",
        "a <<my   target>> b",
        "#+NAME: Tbl   One",
        "| x |",
      }, { 2, 0 })
      ok(links.search_in_buffer("head   ONE"))
      eq(1, cursor()[1])
      ok(links.search_in_buffer("Head Spaced Out"))
      eq(3, cursor()[1])
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      ok(links.search_in_buffer("*head spaced out"))
      eq(3, cursor()[1])
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      ok(links.search_in_buffer("#CID1"))
      eq(3, cursor()[1])
      ok(links.search_in_buffer("My Target"))
      eq({ 7, 2 }, cursor())
      ok(links.search_in_buffer("tbl one"))
      eq(8, cursor()[1])
      local found, err = links.search_in_buffer("#nope")
      eq(false, found)
      eq("No match for custom ID: nope", err)
    end)

    it("searches text across line breaks in non-Org files", function()
      vim.cmd("enew!")
      vim.bo.bufhidden = "wipe"
      local text = { "first", "text across", "  line break", "  indented   text   here" }
      vim.api.nvim_buf_set_lines(0, 0, -1, false, text)
      ok(links.search_in_buffer("across line"))
      eq({ 2, 5 }, cursor())
      ok(links.search_in_buffer("indented text here"))
      eq({ 4, 2 }, cursor())
    end)

    it("finds coderefs of file links, with the block's -l format", function()
      local dir = tmpdir()
      local p = write(dir, "t.org", {
        "* Code",
        "#+begin_src sh -n :results output",
        "echo hi (ref:lbl)",
        "#+end_src",
        '#+begin_example -l "<%s>"',
        "echo two <lbl2>",
        "#+end_example",
      })
      org_buffer({ "x" }, { 1, 0 })
      vim.bo.modified = false
      config.opts.links.frame_setup = { file = "current" }
      links.open("file:" .. p .. "::(lbl)")
      eq(real(p), real(vim.api.nvim_buf_get_name(0)))
      eq({ 3, 8 }, cursor())
      links.open("file:" .. p .. "::(lbl2)")
      eq({ 6, 9 }, cursor())
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      links.open("(lbl)")
      eq({ 3, 8 }, cursor())
    end)

    it("makes a sparse tree for ::/regexp/ in Org files and a location list elsewhere", function()
      org_buffer({ "* A", "foo x", "* B", "FOOO x" }, { 1, 0 })
      ok(links.search_in_buffer("/fo+ x/"))
      eq(2, #vim.fn.getloclist(0))
      eq(2, cursor()[1])
      require("org.agenda.sparse").clear()
      eq("\\ca\\+b\\=", links.emacs_regexp_to_vim("a+b?"))
      eq("\\c\\(foo\\|bar\\)\\%(x\\)", links.emacs_regexp_to_vim("\\(foo\\|bar\\)\\(?:x\\)"))
      eq("\\cx\\{2,3}.\\{-}", links.emacs_regexp_to_vim("x\\{2,3\\}.*?"))
      eq("\\c[^\\\\a]\\%(\\<\\|\\>\\)", links.emacs_regexp_to_vim("[^\\a]\\b"))
    end)
  end)

  describe("parsing", function()
    it("keeps balanced parentheses in plain links and trims punctuation", function()
      local wp = "https://en.wikipedia.org/wiki/Foo_(bar)"
      eq(wp, links.parse_links("see " .. wp .. " now")[1].target)
      eq("https://x.org/a", links.parse_links("(see https://x.org/a)")[1].target)
      eq("https://x.org/a", links.parse_links("at https://x.org/a.")[1].target)
      eq("https://x.org/a/", links.parse_links("at https://x.org/a/, ok")[1].target)
      eq("https://x.org/f(a(b))", links.parse_links("https://x.org/f(a(b)) z")[1].target)
    end)

    it("escapes and unescapes like org-link-escape / org-link-unescape", function()
      eq("a\\[b\\]c", links.escape("a[b]c"))
      eq("foo\\\\\\]", links.escape("foo\\]"))
      eq("C:\\\\dir\\file\\\\", links.escape("C:\\\\dir\\file\\"))
      eq("a\\b", links.escape("a\\b"))
      eq("a\\\\b", links.unescape("a\\\\b"))
      eq("a[b]", links.unescape("a\\[b\\]"))
      eq("a\\]", links.unescape("a\\\\\\]"))
      eq("\\\\server\\share", links.parse_links("[[\\\\server\\share]]")[1].target)
    end)

    it("adds a zero width space to descriptions with ]] or a final ]", function()
      eq("[[x][b]" .. ZWSP .. "]c]]", links.format("x", "b]]c"))
      eq("[[x][end]" .. ZWSP .. "]]", links.format("x", "end]"))
      eq("[[x][x]]", links.format("x", "x"))
      eq("[[x]]", links.format("x", "  "))
      local l = links.parse_links(links.format("x", "Fix [bug]"))[1]
      eq("x", l.target)
      eq("Fix [bug]" .. ZWSP, l.desc)
    end)

    it("expands name::tag and bare abbreviations, also from indented #+LINK", function()
      org_buffer({ "  #+LINK: wp https://wp/", "[[wp::Foo]] [[wp]]" }, { 2, 3 })
      eq("https://wp/Foo", links.expand_abbrev("wp::Foo"))
      eq("https://wp/", links.expand_abbrev("wp"))
      eq("https://wp/Foo", links.expand_abbrev("wp:Foo"))
      eq("up:x", links.expand_abbrev("up:x"))
      local opened = {}
      stub(vim.ui, "open", function(u)
        opened[#opened + 1] = u
      end)
      links.open_at_point(0)
      vim.api.nvim_win_set_cursor(0, { 2, 14 })
      links.open_at_point(0)
      eq({ "https://wp/Foo", "https://wp/" }, opened)
    end)

    it("follows bracket links spanning lines", function()
      org_buffer({ "see [[multi", "  line target]] end", "* multi line target" }, { 2, 4 })
      local l = links.link_at_cursor()
      eq("multi line target", l.target)
      eq({ 1, 5, 2, 15 }, { l.lnum, l.start_col, l.end_lnum, l.end_col })
      links.open_at_point(0)
      eq(3, cursor()[1])
    end)

    it("matches radio links on word boundaries and across lines", function()
      org_buffer({ "<<<Foo Bar>>>", "and xfoo bar and Foo", "  Bar end" }, { 2, 5 })
      eq(nil, links.link_at_cursor())
      vim.api.nvim_win_set_cursor(0, { 3, 3 })
      local l = links.link_at_cursor()
      eq("radio", l.type)
      eq({ 2, 18, 3, 5 }, { l.lnum, l.start_col, l.end_lnum, l.end_col })
      links.open_at_point(0)
      eq({ 1, 0 }, cursor())
    end)

    it("highlights radio links and custom link faces", function()
      config.opts.links.types = { jira = { follow = function() end, face = "ErrorMsg" } }
      org_buffer({ "<<<my radio>>>", "a My Radio b", "[[jira:X-1]] jira:Y-2" }, { 1, 0 })
      local function names(l, c)
        return vim.tbl_map(function(id)
          return vim.fn.synIDattr(id, "name")
        end, vim.fn.synstack(l, c))
      end
      ok(vim.tbl_contains(names(2, 4), "orgRadioLink"), vim.inspect(names(2, 4)))
      eq({}, names(2, 1))
      ok(vim.tbl_contains(names(3, 4), "orgLinkType_jira"), vim.inspect(names(3, 4)))
      ok(vim.tbl_contains(names(3, 16), "orgLinkType_jira"), vim.inspect(names(3, 16)))
      -- toggling the display only changes link concealing
      org_buffer({ "[[https://x][desc]] *b*" }, { 1, 0 })
      eq(1, vim.fn.synconcealed(1, 1)[1])
      links.toggle_link_display()
      eq(0, vim.fn.synconcealed(1, 1)[1])
      links.toggle_link_display()
      eq(1, vim.fn.synconcealed(1, 1)[1])
    end)
  end)

  describe("next / previous link", function()
    it("skips links in src blocks and verbatim, and wraps on a repeated search", function()
      org_buffer({
        "a [[x]]",
        "#+begin_src sh",
        "echo [[y]]",
        "#+end_src",
        "=[[z]]= and ~https://q.org~",
        "b https://w.org",
      }, { 1, 0 })
      links.next_link()
      eq({ 1, 2 }, cursor())
      links.next_link()
      eq({ 6, 2 }, cursor())
      links.next_link()
      eq({ 6, 2 }, cursor())
      links.next_link()
      eq({ 1, 2 }, cursor())
      links.prev_link()
      eq({ 1, 2 }, cursor())
      links.prev_link()
      eq({ 6, 2 }, cursor())
    end)
  end)

  describe("storing (org-store-link)", function()
    it("stores Emacs context strings", function()
      local dir = tmpdir()
      local p = write(dir, "s.org", {
        "#+TITLE: Store test",
        "",
        "third [line] with (brackets)",
        "  indented   text   here",
        "* Heading with [[https://y][Link Desc]] in   title [1/2] :tag:",
        "body",
        "See <<my target>> here.",
      })
      local buf = edit(p)
      local path = "file:" .. vim.fn.fnamemodify(p, ":~")
      local function at(lnum, extra)
        return links.link_to_location(vim.tbl_extend("force", { bufnr = buf, lnum = lnum }, extra or {}))
      end
      eq(path .. "::+TITLE: Store test", at(1).link)
      eq({ link = path }, at(2))
      eq(path .. "::third [line] with (brackets)", at(3).link)
      eq(path .. "::indented text here", at(4).link)
      local h = at(6)
      eq(path .. "::*Heading with [[https://y][Link Desc]] in title", h.link)
      eq("Heading with Link Desc in title", h.desc)
      eq(path .. "::my target", at(7, { col = 8 }).link)
      eq(path .. "::*Heading with [[https://y][Link Desc]] in title", at(7, { col = 1 }).link)
      -- C-u negates org-link-context-for-files
      eq({ link = path }, at(6, { negate_context = true }))
      -- a region is the search string (first N lines with a number)
      eq(path .. "::third [line] with (brackets)\n indented text here", at(3, { region = { 3, 1, 4, 24 } }).link)
      config.opts.links.context_for_files = 1
      eq(path .. "::third [line] with (brackets)", at(3, { region = { 3, 1, 4, 24 } }).link)
      -- inserting such a link escapes the brackets and reads back
      local text = links.format(at(3).link)
      eq(path .. "::third [line] with (brackets)", links.parse_links(text)[1].target)
    end)

    it("stores links in plain files without line numbers", function()
      local dir = tmpdir()
      local p = write(dir, "plain.txt", { "first line", "", "  (second   line)" })
      local buf = edit(p)
      local path = "file:" .. vim.fn.fnamemodify(p, ":~")
      eq(path .. "::first line", links.link_to_location({ bufnr = buf, lnum = 1 }).link)
      eq(path, links.link_to_location({ bufnr = buf, lnum = 2 }).link)
      eq(path .. "::second line", links.link_to_location({ bufnr = buf, lnum = 3 }).link)
    end)

    it("does not create IDs by default and stores CUSTOM_ID links", function()
      local dir = tmpdir()
      config.opts.id.locations_file = dir .. "/ids.json"
      local p = write(dir, "c.org", { "* H", ":PROPERTIES:", ":CUSTOM_ID: cc", ":END:", "* Plain" })
      edit(p, { 5, 0 })
      local l = links.store_link(0)
      eq("file:" .. vim.fn.fnamemodify(p, ":~") .. "::*Plain", l.link)
      eq({ "* H", ":PROPERTIES:", ":CUSTOM_ID: cc", ":END:", "* Plain" }, buf_lines())
      -- with IDs: the id: link and then the CUSTOM_ID link (most recent)
      config.opts.links.use_id = true
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      l = links.store_link(0)
      eq("file:" .. vim.fn.fnamemodify(p, ":~") .. "::#cc", l.link)
      eq("H", l.desc)
      ok(links.stored[2].link:match("^id:"), links.stored[2].link)
      -- create-if-interactive-and-no-custom-id
      links.stored = {}
      vim.bo.modified = false
      edit(p, { 1, 0 })
      config.opts.links.use_id = "create-if-interactive-and-no-custom-id"
      l = links.store_link(0)
      eq("file:" .. vim.fn.fnamemodify(p, ":~") .. "::#cc", l.link)
      eq(1, #links.stored)
      vim.bo.modified = false
    end)

    it("adds a search string to id links (org-id-link-use-context)", function()
      local dir = tmpdir()
      config.opts.id.locations_file = dir .. "/ids.json"
      require("org.id")._reset()
      local p = write(dir, "i.org", {
        "* Head [1/2] :tag:",
        ":PROPERTIES:",
        ":ID: abc",
        ":END:",
        "#+NAME: tbl1",
        "| a |",
        "** Child 1",
        ":PROPERTIES:",
        ":CUSTOM_ID: c1",
        ":END:",
      })
      local buf = edit(p)
      config.opts.links.use_id = "use-existing"
      local function at(lnum)
        return links.link_to_location({ bufnr = buf, lnum = lnum, interactive = true })
      end
      eq({ link = "id:abc", desc = "Head [1/2]", id = true }, at(1))
      eq({ link = "id:abc::tbl1", desc = "tbl1", id = true }, at(6))
      eq("file:" .. vim.fn.fnamemodify(p, ":~") .. "::#c1", at(7).link)
      config.opts.id.link_consider_parent_id = true
      eq({ link = "id:abc::#c1", desc = "Child 1", id = true }, at(7))
      config.opts.id.link_use_context = false
      eq({ link = "id:abc", desc = "Head [1/2]", id = true }, at(6))
      eq(links.format("id:abc", "Head [1/2]"), "[[id:abc][Head [1/2]" .. ZWSP .. "]]")
    end)

    it("stores links from help and man buffers and directories", function()
      vim.cmd("enew!")
      vim.bo.bufhidden = "wipe"
      vim.bo.buftype = "help"
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "*my-tag*  *other*", "body" })
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      local l = links.link_to_location({})
      eq("help:my-tag", l.link)
      local dir = tmpdir()
      write(dir, "f.txt", { "x" })
      vim.cmd("enew!")
      vim.bo.bufhidden = "wipe"
      vim.api.nvim_buf_set_name(0, dir)
      l = links.link_to_location({})
      eq("file:" .. vim.fn.fnamemodify(dir, ":~") .. "/", l.link)
    end)

    it("uses the store functions of custom link types first", function()
      config.opts.links.types = {
        tick = {
          follow = function() end,
          store = function(interactive)
            if vim.b.tick then
              return { link = "tick:42", desc = interactive and "Ticket" or nil }
            end
          end,
        },
      }
      org_buffer({ "* H" }, { 1, 0 })
      vim.b.tick = true
      local l = links.store_link(0)
      eq({ link = "tick:42", desc = "Ticket" }, l)
      -- C-u C-u skips them
      eq(nil, links.link_to_location({ skip_custom = true }))
    end)
  end)

  describe("inserting (org-insert-link)", function()
    it("writes file paths per links.file_path_type", function()
      local home = vim.fs.normalize(vim.env.HOME)
      eq("plain.txt", links.normalize_file_path("/W/plain.txt", "adaptive", "/W"))
      eq("sub/x.org", links.normalize_file_path("/W/sub/x.org", nil, "/W"))
      eq("/etc/hosts", links.normalize_file_path("/etc/hosts", "adaptive", "/W"))
      eq("~/foo.org", links.normalize_file_path(home .. "/foo.org", "adaptive", "/W"))
      eq("../X/y", links.normalize_file_path("/W/X/y", "relative", "/W/Z"))
      eq("~/foo.org", links.normalize_file_path(home .. "/foo.org", "absolute", home))
      eq(home .. "/foo.org", links.normalize_file_path("~/foo.org", "noabbrev", "/W"))
      eq("F:/a", links.normalize_file_path("/a", function(p)
        return "F:" .. p
      end, "/W"))
    end)

    it("formats stored links for the buffer and forgets them after insertion", function()
      local dir = tmpdir()
      write(dir, "plain.txt", { "first line" })
      local p = write(dir, "s.org", { "* Has ID", "" })
      edit(p, { 2, 0 })
      links.store("file:" .. dir .. "/plain.txt::first line", nil)
      links.store("file:" .. p .. "::*Has ID", "Has ID")
      answer({
        ["Insert link"] = "",
        ["Description: "] = function(o)
          return o.default
        end,
      })
      links.insert_link(0)
      eq("[[*Has ID][Has ID]]", buf_lines()[2])
      eq(1, #links.stored)
      vim.api.nvim_buf_set_lines(0, 1, 2, false, { "" })
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      config.opts.links.keep_stored_after_insertion = true
      links.insert_link(0)
      eq("[[file:plain.txt::first line]]", buf_lines()[2])
      eq(1, #links.stored)
      -- C-u C-u C-u negates the option
      vim.api.nvim_buf_set_lines(0, 1, 2, false, { "" })
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      links.insert_link(64)
      eq(0, #links.stored)
      vim.bo.modified = false
    end)

    it("selects a stored link by its description and edits links at point", function()
      org_buffer({ "a", "see <https://old.example> x", "[[https://z][Zed]]" }, { 1, 0 })
      links.store("https://d.example", "Dee")
      answer({
        ["Insert link"] = "Dee",
        ["Description: "] = function(o)
          return o.default
        end,
      })
      links.insert_link(0)
      eq("a[[https://d.example][Dee]]", buf_lines()[1])
      answer({
        ["Link: "] = function(o)
          return o.default .. "/new"
        end,
        ["Description: "] = function(o)
          return o.default
        end,
      })
      vim.api.nvim_win_set_cursor(0, { 2, 7 })
      links.insert_link(0)
      eq("see [[https://old.example/new]] x", buf_lines()[2])
      vim.api.nvim_win_set_cursor(0, { 3, 3 })
      links.insert_link(0)
      eq("[[https://z/new][Zed]]", buf_lines()[3])
    end)

    it("inserts file links with C-u (relative) and C-u C-u (absolute)", function()
      local dir = tmpdir()
      write(dir, "sub/x.org", { "* X" })
      local p = write(dir, "s.org", { "" })
      edit(p, { 1, 0 })
      answer({
        ["File: "] = "sub/x.org",
        ["Description: "] = "",
      })
      links.insert_link(4)
      eq("[[file:sub/x.org]]", buf_lines()[1])
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "" })
      links.insert_link(16)
      eq("[[file:" .. vim.fn.fnamemodify(dir .. "/sub/x.org", ":~") .. "]]", buf_lines()[1])
      -- file completion is relative to the buffer's directory, not the cwd
      local cwd = vim.fn.getcwd()
      vim.cmd("cd /")
      links._complete_bufnr = vim.api.nvim_get_current_buf()
      local ok1, res = pcall(links._complete, "file:su")
      local ok2, res2 = pcall(links._complete_file, "sub/")
      links._complete_bufnr = nil
      vim.cmd("cd " .. vim.fn.fnameescape(cwd))
      ok(ok1 and ok2)
      eq({ "file:sub/" }, res)
      eq({ "sub/x.org" }, res2)
      vim.bo.modified = false
    end)

    it("uses custom type completion, descriptions and export", function()
      config.opts.links.types = {
        jira = {
          follow = function() end,
          complete = function()
            return "jira:ABC-1"
          end,
          insert_description = function(link)
            return "Ticket " .. link:sub(6)
          end,
          export = function(path, desc, backend)
            return backend .. ":" .. path .. ":" .. tostring(desc)
          end,
        },
      }
      org_buffer({ "" }, { 1, 0 })
      answer({
        ["Insert link"] = "jira:",
        ["Description: "] = function(o)
          return o.default
        end,
      })
      links.insert_link(0)
      eq("[[jira:ABC-1][Ticket ABC-1]]", buf_lines()[1])
      eq("html:ABC-1:d", links.export_link("jira:ABC-1", "d", "html"))
      eq(nil, links.export_link("https://x", "d", "html"))
      config.opts.links.make_description = function(link)
        return "D:" .. link
      end
      eq("[[https://a][D:https://a]]", links.format_for_buffer("https://a", nil))
    end)
  end)

  describe("opening", function()
    it("opens file links in another window, internal links there with a count", function()
      local dir = tmpdir()
      local t = write(dir, "t.org", { "* A", "* Target" })
      local s = write(dir, "s.org", { "[[file:t.org::*Target]]", "[[*Here]]", "* Here" })
      local sbuf = edit(s, { 1, 3 })
      local swin = vim.api.nvim_get_current_win()
      links.open_at_point(0)
      eq(2, #vim.api.nvim_tabpage_list_wins(0))
      eq(real(t), real(vim.api.nvim_buf_get_name(0)))
      eq(2, cursor()[1])
      vim.api.nvim_set_current_win(swin)
      links.open_at_point(0)
      eq(2, #vim.api.nvim_tabpage_list_wins(0))
      -- C-u C-c C-o on an internal link: shown in another window
      vim.api.nvim_set_current_win(swin)
      vim.api.nvim_win_set_cursor(0, { 2, 3 })
      links.open_at_point(4)
      ok(vim.api.nvim_get_current_win() ~= swin)
      eq(sbuf, vim.api.nvim_get_current_buf())
      eq(3, cursor()[1])
      -- frame_setup "current"
      vim.cmd("only")
      config.opts.links.frame_setup = { file = "current" }
      edit(s, { 1, 3 })
      links.open_at_point(0)
      eq(1, #vim.api.nvim_tabpage_list_wins(0))
      eq(real(t), real(vim.api.nvim_buf_get_name(0)))
    end)

    it("follows id:ID::search inside the entry's subtree", function()
      local dir = tmpdir()
      config.opts.id.locations_file = dir .. "/ids.json"
      require("org.id")._reset()
      local p = write(dir, "i.org", {
        "* Other",
        "** Child 1",
        "* Parent",
        ":PROPERTIES:",
        ":ID: pid",
        ":END:",
        "** Child 1",
        "* Odd",
        ":PROPERTIES:",
        ":ID: a::b",
        ":END:",
      })
      edit(p, { 1, 0 })
      links.open("id:pid::*Child 1")
      eq(7, cursor()[1])
      links.open("id:a::b")
      eq(8, cursor()[1])
      stub(utils, "confirm", function()
        return true
      end)
      links.open("id:pid::*New child")
      eq("** New child", buf_lines()[8])
      eq(8, cursor()[1])
      vim.bo.modified = false
    end)

    it("runs shell links literally in the file's directory", function()
      local dir = tmpdir()
      local p = write(dir, "s.org", { "[[shell:echo '50% #1' && pwd]]", "[[shell:echo skipped]]" })
      edit(p, { 1, 3 })
      local asked
      stub(utils, "confirm", function(msg)
        asked = msg
        return true
      end)
      links.open_at_point(0)
      eq("Execute echo '50% #1' && pwd in shell?", asked)
      local term = vim.api.nvim_get_current_buf()
      local function text()
        return table.concat(vim.api.nvim_buf_get_lines(term, 0, -1, false), "")
      end
      vim.wait(5000, function()
        return text():find(dir, 1, true) ~= nil
      end)
      ok(text():find("50% #1", 1, true), vim.inspect(vim.api.nvim_buf_get_lines(term, 0, -1, false)))
      ok(text():find(dir, 1, true), text())
      vim.cmd("bwipeout!")
      -- org-link-shell-skip-confirm-regexp
      config.opts.links.shell_skip_confirm_regexp = "^echo skip"
      stub(utils, "confirm", function()
        error("must not ask")
      end)
      edit(p, { 2, 3 })
      links.open_at_point(0)
      local t2 = vim.api.nvim_get_current_buf()
      ok(t2 ~= vim.fn.bufnr(p))
      vim.wait(5000, function()
        return table.concat(vim.api.nvim_buf_get_lines(t2, 0, -1, false), ""):find("skipped") ~= nil
      end)
      vim.cmd("bwipeout!")
    end)

    it("uses the DOI server, translation function, file apps and counts", function()
      local opened = {}
      stub(vim.ui, "open", function(u)
        opened[#opened + 1] = u
      end)
      config.opts.links.doi_server_url = "https://doi.example/"
      links.open("doi:10.1/x")
      config.opts.links.translation_function = function(t, p)
        if t == "http" then
          return "https", p
        end
      end
      links.open("http://x.example")
      local dir = tmpdir()
      local pdf = write(dir, "a.pdf", { "x" })
      local txt = write(dir, "a.txt", { "x" })
      org_buffer({ "" }, { 1, 0 })
      vim.bo.modified = false
      links.open("file:" .. pdf)
      links.open("file:" .. txt, { arg = 16 })
      eq({ "https://doi.example/10.1/x", "https://x.example", pdf, txt }, opened)
      -- C-u: in Neovim even when an external app applies
      config.opts.links.frame_setup = { file = "current" }
      links.open("file:" .. pdf, { arg = 4 })
      eq(real(pdf), real(vim.api.nvim_buf_get_name(0)))
      -- search functions come first
      local got
      config.opts.links.search_functions = {
        function(s)
          got = s
          return s == "magic"
        end,
      }
      ok(links.search_in_buffer("magic"))
      eq("magic", got)
      eq(false, links.open("elisp:(message 1)"))
    end)

    it("offers every entry link, including 'open all', and opens tag searches", function()
      org_buffer({ "* E :work:home:", "[[*A]] and [[*B]] and [[*A]]", "* A", "* B" }, { 1, 0 })
      local labels
      stub(utils, "select", function(items)
        labels = items
        return items[#items], #items
      end)
      links.open_at_point_or_entry()
      eq({ "*A", "*B", "Open all links" }, labels)
      eq(4, cursor()[1])
      local tag
      stub(require("org.agenda"), "open_tags", function(t, todo)
        tag = { t, todo }
      end)
      vim.api.nvim_win_set_cursor(0, { 1, 13 })
      links.open_at_point_or_entry()
      eq({ "home", false }, tag)
    end)

    it("visits #+INCLUDE and #+SETUPFILE files with C-c '", function()
      local dir = tmpdir()
      local inc = write(dir, "inc.org", { "* Included" })
      local p = write(dir, "m.org", { '#+INCLUDE: "inc.org" :minlevel 2', "#+SETUPFILE: inc.org" })
      config.opts.links.frame_setup = { file = "current" }
      edit(p, { 1, 0 })
      require("org.context").edit_special()
      eq(real(inc), real(vim.api.nvim_buf_get_name(0)))
      edit(p, { 2, 0 })
      require("org.context").edit_special()
      eq(real(inc), real(vim.api.nvim_buf_get_name(0)))
    end)
  end)
end)
