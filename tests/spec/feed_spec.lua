-- RSS/Atom feeds (org-feed.el). Expected texts and hashes come from Emacs
-- 9.8 org-feed-update on the same fixtures.
local config = require("org.config")
local feed = require("org.feed")
local utils = require("org.utils")

local root = vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h"))
local fixtures = root .. "/fixtures/feed/"

local function quiet(fn)
  local n, w = utils.notify, utils.warn
  local messages = {}
  utils.notify = function(msg)
    messages[#messages + 1] = msg
  end
  utils.warn = utils.notify
  local ok, res = pcall(fn)
  utils.notify, utils.warn = n, w
  if not ok then
    error(res, 0)
  end
  return res, messages
end

local function inbox_file(lines)
  local path = vim.fn.tempname() .. ".org"
  utils.writefile(path, lines or { "#+TITLE: t", "", "* Other", "text" })
  return path
end

local function file_lines(path)
  local b = utils.find_buffer(path)
  local lines = b and vim.api.nvim_buf_get_lines(b, 0, -1, false) or utils.readfile(path)
  -- the current time is not reproducible
  return vim.tbl_map(function(l)
    return (l:gsub("%[(%d+)%-%d+%-%d+ %a+ %d+:%d+%]", function(y)
      return y ~= "2003" and "[NOW]" or nil
    end))
  end, lines)
end

local function with_feeds(feeds)
  local saved
  before_each(function()
    saved = vim.deepcopy(config.opts.feed)
    config.opts.feed.feeds = feeds()
  end)
  after_each(function()
    config.opts.feed = saved
  end)
end

describe("org-feed XML", function()
  it("decodes entities, character references and CDATA", function()
    eq(
      "a & <b> \"c\" 'd' A é &nbsp;",
      feed.decode("a &amp; &lt;b&gt; &quot;c&quot; &apos;d&apos; &#65; &#xe9; &nbsp;")
    )
    eq("<p>x &amp; y</p> & z", feed.decode("<![CDATA[<p>x &amp; y</p>]]> &amp; z"))
  end)

  it("parses elements, attributes and text leniently", function()
    local doc = feed.parse_xml(
      '<?xml version="1.0"?><!DOCTYPE x [<!ENTITY a "b">]><!-- c --><r b="2" a=\'1\'>t&amp;<e/>'
        .. "<![CDATA[<raw>]]>x<u>unclosed</r>"
    )
    local r = doc.children[1]
    eq("r", r.tag)
    eq({ "b", "a" }, r.attr_order)
    eq("1", r.attrs.a)
    eq("t&", r.children[1])
    eq("e", r.children[2].tag)
    -- a CDATA section starts a new string, like xml.el
    eq("<raw>x", r.children[3])
    eq("t&<raw>xunclosed", feed.xml_text(r))
    eq('(r ((b . "2") (a . "1")) "t&" (e nil) "<raw>x" (u nil "unclosed"))', feed.xml_lisp_form(r))
  end)

  it("reads and writes the status drawer as Lisp", function()
    local status = feed.parse_status('(("a \\"q\\"" t "h1")\n ("b"\n  nil "h2") (nil t "h3"))')
    eq({
      { guid = 'a "q"', handled = true, hash = "h1" },
      { guid = "b", handled = false, hash = "h2" },
      { handled = true, hash = "h3" },
    }, status)
    eq({ '(("a \\"q\\"" t "h1")', ' ("b" nil "h2")', ' (nil t "h3"))' }, feed.format_status(status))
    eq({}, feed.parse_status("nil"))
    eq(nil, (feed.parse_status("((")))
  end)
end)

describe("org-feed parsing", function()
  it("splits RSS items and reads their fields", function()
    local text = table.concat(utils.readfile(fixtures .. "rss.xml"), "\n")
    local entries = feed.parse_rss_feed(text)
    eq(2, #entries)
    eq("id-1", entries[1].guid)
    eq("https://example.com/2", entries[2].guid)
    local e = feed.parse_rss_entry(entries[1])
    eq("First & best", e.title)
    eq("https://example.com/1", e.link)
    eq("Tue, 10 Jun 2003 04:00:00 GMT", e.pubDate)
    eq("Line one\nLine two", e.description)
    eq(nil, e.guid_permalink)
    local e2 = feed.parse_rss_entry(entries[2])
    eq(true, e2.guid_permalink)
    eq("<p>Hi</p>", e2.description)
  end)

  it("reads Atom entries", function()
    local text = table.concat(utils.readfile(fixtures .. "atom.xml"), "\n")
    local entries = feed.parse_atom_feed(text)
    eq({ "urn:uuid:one", "urn:uuid:two" }, { entries[1].guid, entries[2].guid })
    local e = feed.parse_atom_entry(entries[1])
    eq("Atom <one>", e.title)
    eq("https://example.org/one", e.link)
    eq("Plain & simple", e.description)
    eq("2024-05-01T10:20:30Z", e.updated)
    local e2 = feed.parse_atom_entry(entries[2])
    eq("Two & more", e2.title)
    eq('<div xmlns="http://www.w3.org/1999/xhtml"><p>Rich <b>text</b></p></div>', e2.description)
  end)
end)

describe("org-feed templates", function()
  it("expands the default template like Emacs", function()
    local e = {
      title = "T",
      pubDate = "Tue, 10 Jun 2003 04:00:00 GMT",
      description = "one\ntwo",
      guid = "g",
      link = "https://l",
    }
    eq("\n* T\n  [2003-06-10 Tue 04:00]\n  one\n  two\n  [[https://l]]\n\n", feed.format_entry(e))
    e.guid_permalink = true
    eq("[[g]]\n", feed.format_entry(e, "%a"))
  end)

  it("expands the special escapes, fields, \\% and Lua expressions", function()
    local e = { description = "\nfirst line\nsecond", pubDate = "2024-05-01T10:20:30Z", category = "news" }
    eq("first line", feed.format_entry(e, "%h"))
    eq(
      "<2024-05-01 Wed> <2024-05-01 Wed 10:20> [2024-05-01 Wed] [2024-05-01 Wed 10:20]",
      feed.format_entry(e, "%t %T %u %U")
    )
    eq("news %category  NEWS", feed.format_entry(e, '%category \\%category %missing %(string.upper("%category"))'))
    eq("6", feed.format_entry(e, "%(#entry.category + 2)"))
    eq(
      "x",
      feed.format_entry(e, "", function()
        return "x"
      end)
    )
    -- a date without a time gets the current time
    ok(feed.format_entry({ pubDate = "01 May 2024" }, "%T"):match("^<2024%-05%-01 Wed %d%d:%d%d>$"))
  end)
end)

describe("org-feed update", function()
  local target
  with_feeds(function()
    target = inbox_file()
    return {
      { name = "Ex", url = "file://" .. fixtures .. "rss.xml", file = target, headline = "Feed Inbox" },
      { "Atom", fixtures .. "atom.xml", target, "Atom Inbox" },
    }
  end)

  it("adds new RSS items under a new inbox and records them", function()
    local n, msgs = quiet(function()
      return feed.update("Ex")
    end)
    eq(2, n)
    eq("Added 2 new items from feed Ex to file " .. vim.fn.fnamemodify(target, ":t") .. ", heading Feed Inbox", msgs[1])
    eq({
      "#+TITLE: t",
      "",
      "* Other",
      "text",
      "",
      "",
      "* Feed Inbox",
      "",
      "",
      "  :FEEDSTATUS:",
      '(("id-1" t "2520fee970384fa208d24ea9aa92215f27179a93")',
      ' ("https://example.com/2" t "a3151ce492bcfb66f93d78f5cf2d74e67a990b82"))',
      "  :END:",
      "** Second",
      "  [NOW]",
      "  <p>Hi</p>",
      "  [[https://example.com/2]]",
      "",
      "",
      "** First & best",
      "  [2003-06-10 Tue 04:00]",
      "  Line one",
      "  Line two",
      "  [[https://example.com/1]]",
      "",
    }, file_lines(target))
    -- saved (feed.save_after_adding)
    eq(false, vim.bo[utils.find_buffer(target)].modified)
    local again, msgs2 = quiet(function()
      return feed.update("Ex")
    end)
    eq(0, again)
    eq("No new items in feed Ex", msgs2[1])
  end)

  it("hashes Atom entries like Emacs and appends to an existing inbox", function()
    quiet(function()
      eq(2, feed.update("Ex"))
      eq(2, feed.update("Atom"))
    end)
    local lines = file_lines(target)
    local text = table.concat(lines, "\n")
    ok(text:find('(("urn:uuid:one" t "d66ca214b5269384fcf077293bb8be452636631a")', 1, true), text)
    ok(text:find(' ("urn:uuid:two" t "4cba13c6af5285f62838a588da68da8a5cfe51b2"))', 1, true), text)
    ok(text:find("** Atom <one>\n  [NOW]\n  Plain & simple\n  [[https://example.org/one]]", 1, true), text)
  end)

  it("uses an Emacs-written status drawer and adds only unknown items", function()
    utils.writefile(target, {
      "* Feed Inbox",
      "  :FEEDSTATUS:",
      '(("id-1" t',
      '  "2520fee970384fa208d24ea9aa92215f27179a93"))',
      "  :END:",
      "** Old item",
      "* Next",
    })
    quiet(function()
      eq(1, feed.update("Ex"))
    end)
    eq({
      "* Feed Inbox",
      "  :FEEDSTATUS:",
      '(("id-1" t "2520fee970384fa208d24ea9aa92215f27179a93")',
      ' ("https://example.com/2" t "a3151ce492bcfb66f93d78f5cf2d74e67a990b82"))',
      "  :END:",
      "** Old item",
      "",
      "** Second",
      "  [NOW]",
      "  <p>Hi</p>",
      "  [[https://example.com/2]]",
      "",
      "* Next",
    }, file_lines(target))
  end)

  it("refuses an unterminated status drawer instead of deleting what follows", function()
    local before = {
      "* Feed Inbox",
      "  :FEEDSTATUS:",
      '(("id-1" t "x"))',
      "* Next",
      "  :PROPERTIES:",
      "  :ID: keep",
      "  :END:",
      "* Last",
    }
    utils.writefile(target, before)
    local okc, err = pcall(quiet, function()
      return feed.update("Ex")
    end)
    eq(false, okc)
    ok(tostring(err):find("FEEDSTATUS", 1, true), err)
    eq(before, file_lines(target))
  end)
end)

describe("org-feed handlers", function()
  local target, src
  local new_seen, changed_seen
  local function write_feed(desc)
    utils.writefile(src, {
      "<rss><channel>",
      "<item><title>A</title><guid>ga</guid><description>" .. desc .. "</description></item>",
      "<item><title>B</title><guid>gb</guid><description>b</description></item>",
      "</channel></rss>",
    })
  end
  with_feeds(function()
    target = inbox_file({ "* Inbox" })
    src = vim.fn.tempname() .. ".xml"
    write_feed("a")
    new_seen, changed_seen = {}, {}
    return {
      {
        name = "H",
        url = "file://" .. src,
        file = target,
        headline = "Inbox",
        drawer = "MYFEED",
        filter = function(e)
          return e.title ~= "B" and e
        end,
        new_handler = function(entries, ctx)
          eq(ctx.lnum, vim.api.nvim_win_get_cursor(0)[1])
          vim.list_extend(new_seen, entries)
        end,
        changed_handler = function(entries)
          vim.list_extend(changed_seen, entries)
        end,
      },
    }
  end)

  it("passes new and changed items to the handlers", function()
    quiet(function()
      eq(1, feed.update("H"))
    end)
    eq(
      { "A" },
      vim.tbl_map(function(e)
        return e.title
      end, new_seen)
    )
    local text = table.concat(file_lines(target), "\n")
    -- the filtered-out item is not marked as handled
    ok(text:find(':MYFEED:\n%(%("ga" t "%x+"%)\n %("gb" nil "%x+"%)%)\n  :END:'), text)
    ok(not text:find("** A", 1, true), "a new handler replaces the insertion")
    write_feed("changed")
    quiet(function()
      eq(0, feed.update("H"))
    end)
    eq(1, #new_seen)
    eq(
      { "ga" },
      vim.tbl_map(function(e)
        return e.guid
      end, changed_seen)
    )
    eq("changed", changed_seen[1].description)
    eq(true, changed_seen[1].handled)
  end)
end)

describe("org-feed commands", function()
  local target
  with_feeds(function()
    target = inbox_file({ "* A" })
    return {
      {
        name = "Fn",
        url = "mem://x",
        file = target,
        headline = "Inbox",
        retrieve_method = function(url)
          eq("mem://x", url)
          return "<rss><item><title>X</title><guid>x</guid></item></rss>"
        end,
      },
      { name = "Missing", url = "file:///nonexistent/feed.xml", file = target, headline = "Inbox" },
    }
  end)

  it("updates all feeds and counts unavailable ones", function()
    local res, msgs = quiet(function()
      return { feed.update_all() }
    end)
    eq({ 1, 1 }, res)
    eq("1 new entry from 2 feeds (unavailable feeds: 1)", msgs[#msgs])
    ok(table.concat(file_lines(target), "\n"):find("** X", 1, true))
  end)

  it("goes to the inbox, creating it", function()
    quiet(function()
      feed.goto_inbox("Fn")
    end)
    eq(require("org.utils").realpath(target), require("org.utils").realpath(vim.api.nvim_buf_get_name(0)))
    eq("* Inbox", vim.api.nvim_get_current_line())
    eq({ "* A", "", "", "* Inbox", "" }, buf_lines())
  end)

  it("has :Org subcommands, completion and the Emacs keys", function()
    local commands = require("org.commands")
    eq({ "Fn" }, commands.complete("F", "Org feed_update F"))
    ok(vim.tbl_contains(commands.complete("feed", "Org feed"), "feed_update_all"))
    eq("<C-c><C-x>g", config.opts.mappings.emacs.feed_update_all)
    eq("<C-c><C-x>G", config.opts.mappings.emacs.feed_goto_inbox)
    ok(require("org.actions").list.feed_update_all)
  end)
end)
