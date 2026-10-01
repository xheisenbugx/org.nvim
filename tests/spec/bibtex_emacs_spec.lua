-- ol-bibtex: BibTeX entries as headlines. Expected text comes from Emacs
-- Org 9.8.10 probes (emacs -Q --batch, ol-bibtex loaded; for the keys,
-- after (bibtex-set-dialect 'BibTeX), which ol-bibtex needs in -Q).

local bibtex = require("org.bibtex")
local config = require("org.config")

local function tmpdir()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  return dir
end

local saved
local function set(o)
  for k, v in pairs(o) do
    config.opts.bibtex[k] = v
  end
end

--- Answer the prompts of vim.fn.input in turn; returns the prompts seen.
local function answering(answers, fn)
  local prompts = {}
  local input = vim.fn.input
  vim.fn.input = function(o)
    prompts[#prompts + 1] = type(o) == "table" and o.prompt or o
    return table.remove(answers, 1) or ""
  end
  local ok_, err = pcall(fn)
  vim.fn.input = input
  if not ok_ then
    error(err, 0)
  end
  return prompts
end

local function messages(fn)
  local out = {}
  local notify = vim.notify
  vim.notify = function(m)
    out[#out + 1] = m
  end
  local ok_, err = pcall(fn)
  vim.notify = notify
  if not ok_ then
    error(err, 0)
  end
  return out
end

local BIB = {
  '@String{jt = "J. Things"}',
  "",
  "@Article{doe2020,",
  "  author =       {Doe, John and",
  "                  Roe, Jane},",
  "  title =        {The {Big} Title},",
  "  journal =      jt,",
  "  year =         2020,",
  "  month =        jan,",
  "  keywords =     {Machine learning, graphs, a:b},",
  '  note =         "A " # "note",',
  "}",
  "",
  "@book{bk99,",
  '  title = "Book",',
  "  author = {A. Author},",
  "  publisher = {Pub},",
  "  year = {1999}",
  "}",
}

describe("ol-bibtex", function()
  before_each(function()
    saved = vim.deepcopy(config.opts.bibtex)
    bibtex.entries = {}
  end)
  after_each(function()
    config.opts.bibtex = saved
  end)

  describe("headline -> BibTeX (org-bibtex-headline)", function()
    local lines = {
      "* The Title of It                                         :tagA:tagB:",
      ":PROPERTIES:",
      ":TITLE:    Real Title",
      ":BTYPE:    article",
      ":CUSTOM_ID: key2020",
      ":AUTHOR:   Doe, John and Roe, Jane",
      ":JOURNAL:  J. Things",
      ":YEAR:     2020",
      ":PAGES:    1--10",
      ":KEYWORDS: kw1, kw2",
      ":CATEGORY: xx",
      ":END:",
      "* No type",
      "* Book no title",
      ":PROPERTIES:",
      ":BTYPE: book",
      ":CUSTOM_ID: bk",
      ":AUTHOR: A",
      ":VOLUME: 3",
      ":NUMBER: 4",
      ":END:",
    }
    local function entry(lnum)
      local buf = org_buffer(lines)
      return bibtex.headline_entry(require("org.files").get_buffer(buf):headline_at(lnum))
    end

    it("exports the fields of the type in order", function()
      eq(
        "@article{key2020,\n  author={Doe, John and Roe, Jane},\n  title={Real Title},\n  journal={J. Things},\n"
          .. "  year={2020},\n  pages={1--10}\n}\n",
        entry(1)
      )
      eq("@book{bk,\n  author={A},\n  title={Book no title},\n  volume={3},\n  number={4}\n}\n", entry(14))
      eq(nil, entry(13))
    end)

    it("tags_are_keywords and no_export_tags", function()
      set({ tags_are_keywords = true })
      eq(
        "@article{key2020,\n  keywords={tagA, tagB},\n  author={Doe, John and Roe, Jane},\n  title={Real Title},\n"
          .. "  journal={J. Things},\n  year={2020},\n  pages={1--10}\n}\n",
        entry(1)
      )
      set({ no_export_tags = { "tagB" } })
      ok(entry(1):find("  keywords={tagA},\n", 1, true))
    end)

    it("prefix, export_arbitrary_fields, key_property and type_property_name", function()
      local buf = org_buffer({
        "* T",
        ":PROPERTIES:",
        ":BIB_BTYPE: misc",
        ":CUSTOM_ID: t1",
        ":BIB_TITLE: TT",
        ":BIB_FOO: bar",
        ":OTHER: o",
        ":END:",
      })
      local hl = require("org.files").get_buffer(buf):headline_at(1)
      set({ prefix = "BIB_" })
      eq("@misc{t1,\n  title={TT}\n}\n", bibtex.headline_entry(hl))
      set({ export_arbitrary_fields = true })
      eq("@misc{t1,\n  foo={bar},\n  title={TT}\n}\n", bibtex.headline_entry(hl))
      buf = org_buffer({
        "* T",
        ":PROPERTIES:",
        ":BIB_BTYPE: misc",
        ":CUSTOM_ID: t1",
        ":BIB_ZED: z",
        ":bib_alpha: a",
        ":BIB_MID: m",
        ":END:",
      })
      hl = require("org.files").get_buffer(buf):headline_at(1)
      eq("@misc{t1,\n  mid={m},\n  alpha={a},\n  zed={z}\n}\n", bibtex.headline_entry(hl))
      set({ prefix = nil, export_arbitrary_fields = false, type_property_name = "TYPE", key_property = "ID" })
      buf = org_buffer({ "* T", ":PROPERTIES:", ":TYPE: misc", ":ID: t1", ":END:" })
      hl = require("org.files").get_buffer(buf):headline_at(1)
      eq("@misc{t1,\n  title={T}\n}\n", bibtex.headline_entry(hl))
    end)

    it("inherit_tags exports inherited tags too", function()
      set({ tags_are_keywords = true, inherit_tags = true })
      local buf = org_buffer({ "* P :par:", "** T :own:", ":PROPERTIES:", ":BTYPE: misc", ":CUSTOM_ID: t1", ":END:" })
      local hl = require("org.files").get_buffer(buf):headline_at(2)
      eq("@misc{t1,\n  keywords={par, own},\n  title={T}\n}\n", bibtex.headline_entry(hl))
    end)

    it("exports every entry of the file (org-bibtex)", function()
      local dir = tmpdir()
      local buf = org_buffer({
        "* A",
        ":PROPERTIES:",
        ":BTYPE: misc",
        ":CUSTOM_ID: a1",
        ":END:",
        "* B",
        "** C",
        ":PROPERTIES:",
        ":BTYPE: misc",
        ":CUSTOM_ID: c1",
        ":NOTE: n",
        ":END:",
      })
      vim.api.nvim_buf_set_name(buf, dir .. "/x.org")
      local msgs = messages(function()
        answering({ "x.bib" }, function()
          bibtex.export()
        end)
      end)
      vim.bo[buf].modified = false
      eq(
        { "@misc{a1,", "  title={A}", "}", "", "@misc{c1,", "  title={C},", "  note={n}", "}" },
        vim.fn.readfile(dir .. "/x.bib")
      )
      ok(msgs[#msgs]:match("^Successfully exported 2 BibTeX entries to .*/x%.bib$"), msgs[#msgs])
    end)

    it("export_to_kill_ring copies the entry", function()
      org_buffer(lines, { 14, 0 })
      bibtex.export_to_kill_ring()
      eq("@book{bk,\n  author={A},\n  title={Book no title},\n  volume={3},\n  number={4}\n}\n", vim.fn.getreg('"'))
    end)
  end)

  describe("BibTeX -> headlines", function()
    local function read_all()
      local bib = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bib, 0, -1, false, BIB)
      local msgs = messages(function()
        eq(2, bibtex.read_buffer(bib))
      end)
      eq("Parsed 2 entries", msgs[1])
    end

    it("reads entries like org-bibtex-read", function()
      read_all()
      eq({
        {
          { "type", "Article" },
          { "key", "doe2020" },
          { "author", "Doe, John and Roe, Jane" },
          { "title", "The {Big} Title" },
          { "journal", "jt" },
          { "year", "2020" },
          { "month", "jan" },
          { "keywords", "Machine learning, graphs, a:b" },
          { "note", 'A " # "note' },
        },
        {
          { "type", "book" },
          { "key", "bk99" },
          { "title", "Book" },
          { "author", "A. Author" },
          { "publisher", "Pub" },
          { "year", "1999" },
        },
      }, bibtex.entries)
    end)

    it("reads the entry at the cursor", function()
      local bib = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(
        bib,
        0,
        -1,
        false,
        { "@misc{a, title={A}}", "", "@misc{b,", "  title = {B},", "  year = 2000", "}" }
      )
      bibtex.read(bib, 5)
      eq({ { { "type", "misc" }, { "key", "b" }, { "title", "B" }, { "year", "2000" } } }, bibtex.entries)
    end)

    it("headline_format_function makes the headline text", function()
      set({
        headline_format_function = function(f)
          return string.format("%s (%s)", f.title, f.year)
        end,
      })
      bibtex.entries = { { { "type", "misc" }, { "key", "k" }, { "title", "Tt" }, { "year", "1999" } } }
      local buf = org_buffer({ "" }, { 1, 0 })
      bibtex.write()
      eq({
        "* Tt (1999)",
        ":PROPERTIES:",
        ":TITLE:    Tt",
        ":BTYPE:    misc",
        ":CUSTOM_ID: k",
        ":YEAR:     1999",
        ":END:",
      }, buf_lines(buf))
    end)

    it("writes headlines, aligned unless noindent", function()
      read_all()
      local buf = org_buffer({ "* Existing", "" }, { 2, 0 })
      bibtex.write()
      vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "" })
      vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(buf), 0 })
      bibtex.write(true)
      eq({
        "* Existing",
        "* The {Big} Title",
        ":PROPERTIES:",
        ":TITLE:    The {Big} Title",
        ":BTYPE:    article",
        ":CUSTOM_ID: doe2020",
        ":AUTHOR:   Doe, John and Roe, Jane",
        ":JOURNAL:  jt",
        ":YEAR:     2020",
        ":MONTH:    jan",
        ":KEYWORDS: Machine learning, graphs, a:b",
        ':NOTE:     A " # "note',
        ":END:",
        "* Book",
        ":PROPERTIES:",
        ":TITLE: Book",
        ":BTYPE: book",
        ":CUSTOM_ID: bk99",
        ":AUTHOR: A. Author",
        ":PUBLISHER: Pub",
        ":YEAR: 1999",
        ":END:",
      }, buf_lines(buf))
      local msgs = messages(function()
        bibtex.write()
      end)
      eq({ "No entries in ‘org-bibtex-entries’" }, msgs)
    end)

    it("imports a file with tags, prefix and key property", function()
      local dir = tmpdir()
      vim.fn.writefile(BIB, dir .. "/x.bib")
      set({ tags_are_keywords = true, tags = { "bib" }, key_property = "ID", prefix = "B_" })
      local buf = org_buffer({ "* Top", "" }, { 2, 0 })
      messages(function()
        bibtex.import_from_file(dir .. "/x.bib")
      end)
      local lines = buf_lines(buf)
      while lines[#lines] == "" do
        table.remove(lines)
      end
      eq({
        "* Top",
        "* The {Big} Title                            :Machine_learning:graphs:ab:bib:",
        ":PROPERTIES:",
        ":B_TITLE:  The {Big} Title",
        ":B_BTYPE:  article",
        ":ID:       doe2020",
        ":B_AUTHOR: Doe, John and Roe, Jane",
        ":B_JOURNAL: jt",
        ":B_YEAR:   2020",
        ":B_MONTH:  jan",
        ':B_NOTE:   A " # "note',
        ":END:",
        "* Book                                                                  :bib:",
        ":PROPERTIES:",
        ":B_TITLE:  Book",
        ":B_BTYPE:  book",
        ":ID:       bk99",
        ":B_AUTHOR: A. Author",
        ":B_PUBLISHER: Pub",
        ":B_YEAR:   1999",
        ":END:",
      }, lines)
    end)

    it("yanks an entry as a new headline or into the headline", function()
      local buf = org_buffer({ "* Top", "" }, { 2, 0 })
      vim.fn.setreg('"', "@misc{m1, title={Yanked}, howpublished={web}}")
      bibtex.yank(false)
      eq({
        "* Top",
        "* Yanked",
        ":PROPERTIES:",
        ":TITLE:    Yanked",
        ":BTYPE:    misc",
        ":CUSTOM_ID: m1",
        ":HOWPUBLISHED: web",
        ":END:",
      }, buf_lines(buf))
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      vim.fn.setreg('"', "@misc{m2, title={Upd}, year={2001}}")
      bibtex.yank(true)
      eq({
        "* Top",
        ":PROPERTIES:",
        ":TITLE:    Upd",
        ":BTYPE:    misc",
        ":CUSTOM_ID: m2",
        ":YEAR:     2001",
        ":END:",
        "* Yanked",
      }, vim.list_slice(buf_lines(buf), 1, 8))
      vim.fn.setreg('"', "no entry here")
      eq(
        { "Yanked text does not appear to contain a BibTeX entry" },
        messages(function()
          bibtex.yank(false)
        end)
      )
    end)
  end)

  describe("keys and checks", function()
    local function key(text)
      local ok_, k = pcall(bibtex.autokey, bibtex.parse_text(text)[1])
      return ok_ and k or ("ERR " .. k)
    end

    it("generates keys like bibtex-generate-autokey", function()
      eq(
        "doe20:_big_title_every_else_here_now",
        key(
          "@article{x,\n  author={Doe, John and Roe, Jane},\n  title={The {Big} Title of Everything Else Here Now},\n  year={2020}\n}\n"
        )
      )
      eq(
        "mueller99:_ueber_graph",
        key('@article{x,\n  author={M\\"uller, Hans},\n  title={\\"Uber Graphs: a study},\n  year={1999}\n}\n')
      )
      eq(
        "fontaine84:_fables",
        key(
          "@book{x,\n  editor={Jean de la Fontaine and Bob Smith and Carl Jones},\n  title={Fables},\n  year={(about 1984)}\n}\n"
        )
      )
      eq("ERR Year or date field `' invalid", key("@misc{x,\n  title={No Year}\n}\n"))
      eq(
        "knuth74:_struc_progr_statem",
        key(
          "@misc{x,\n  author={Knuth, Donald E.},\n  title={Structured Programming with go to Statements},\n  year={1974}\n}\n"
        )
      )
      eq("author01:_short", key("@misc{x,\n  author={A. Author},\n  title={Short},\n  year={2001}\n}\n"))
    end)

    it("check asks for the missing required fields and the key", function()
      local buf = org_buffer(
        { "* A Paper", ":PROPERTIES:", ":BTYPE: article", ":AUTHOR: X, Y", ":END:", "** Child" },
        { 1, 0 }
      )
      local prompts = answering({ "J. Foo", "", "mykey" }, function()
        bibtex.check(false)
      end)
      eq({ "journal: ", "year: ", "id: " }, prompts)
      eq({
        "* A Paper",
        ":PROPERTIES:",
        ":BTYPE: article",
        ":AUTHOR: X, Y",
        ":JOURNAL:  J. Foo",
        ":CUSTOM_ID: mykey",
        ":END:",
        "** Child",
      }, buf_lines(buf))
    end)

    it("check with optional fields and choices between fields", function()
      local buf = org_buffer({ "* A Paper", ":PROPERTIES:", ":BTYPE: misc", ":CUSTOM_ID: k", ":END:" }, { 1, 0 })
      local prompts = answering({ "au", "", "", "", "2020", "", "", "" }, function()
        bibtex.check(true)
      end)
      eq({ "author: ", "title: ", "howpublished: ", "month: ", "year: ", "note: ", "doi: ", "url: " }, prompts)
      eq(
        { "* A Paper", ":PROPERTIES:", ":BTYPE: misc", ":CUSTOM_ID: k", ":AUTHOR:   au", ":YEAR:     2020", ":END:" },
        buf_lines(buf)
      )
      buf = org_buffer({ "* B", ":PROPERTIES:", ":BTYPE: book", ":CUSTOM_ID: k", ":END:" }, { 1, 0 })
      prompts = answering({ "editor", "Ed", "Pub", "1999" }, function()
        bibtex.check(false)
      end)
      eq({ "Field: ", "editor: ", "publisher: ", "year: " }, prompts)
      eq({
        "* B",
        ":PROPERTIES:",
        ":BTYPE: book",
        ":CUSTOM_ID: k",
        ":EDITOR:   Ed",
        ":PUBLISHER: Pub",
        ":YEAR:     1999",
        ":END:",
      }, buf_lines(buf))
    end)

    it("check_all checks every headline; treat_headline_as_title = false asks for the title", function()
      set({ treat_headline_as_title = false })
      local buf = org_buffer({
        "* One",
        ":PROPERTIES:",
        ":BTYPE: misc",
        ":END:",
        "* Two",
        "* Three",
        ":PROPERTIES:",
        ":BTYPE: unpublished",
        ":CUSTOM_ID: t3",
        ":AUTHOR: A",
        ":END:",
      }, { 1, 0 })
      local prompts = answering({ "k1", "T3", "N3" }, function()
        bibtex.check_all(false)
      end)
      eq({ "id: ", "title: ", "note: " }, prompts)
      eq({
        "* One",
        ":PROPERTIES:",
        ":BTYPE: misc",
        ":CUSTOM_ID: k1",
        ":END:",
        "* Two",
        "* Three",
        ":PROPERTIES:",
        ":BTYPE: unpublished",
        ":CUSTOM_ID: t3",
        ":AUTHOR: A",
        ":TITLE:    T3",
        ":NOTE:     N3",
        ":END:",
      }, buf_lines(buf))
    end)

    it("autogen_keys generates the key", function()
      set({ autogen_keys = true })
      local buf = org_buffer({
        "* The Great Adventure",
        ":PROPERTIES:",
        ":BTYPE: misc",
        ":AUTHOR: Smith, Anna",
        ":YEAR: 2011",
        ":END:",
      }, { 1, 0 })
      bibtex.check(false)
      eq(":CUSTOM_ID: smith11:_great_adven", buf_lines(buf)[6])
    end)

    it("creates entries", function()
      set({ tags = { "bib" } })
      local buf = org_buffer({ "* Top", "body" }, { 2, 0 })
      local prompts = answering({ "misc", "My Title", "k1" }, function()
        bibtex.create(false)
      end)
      eq({ "Type: ", "title: ", "id: " }, prompts)
      eq({
        "* Top",
        "body",
        "* My Title                                                              :bib:",
        ":PROPERTIES:",
        ":TITLE:    My Title",
        ":BTYPE:    misc",
        ":CUSTOM_ID: k1",
        ":END:",
      }, buf_lines(buf))
      set({ tags = {} })
      buf = org_buffer({ "* Existing heading", "text" }, { 2, 0 })
      prompts = answering({ "techreport", "Au", "TR title", "Inst", "2000", "k2" }, function()
        bibtex.create_in_current_entry(false)
      end)
      eq({ "Type: ", "author: ", "title: ", "institution: ", "year: ", "id: " }, prompts)
      eq({
        "* Existing heading",
        ":PROPERTIES:",
        ":BTYPE:    techreport",
        ":AUTHOR:   Au",
        ":TITLE:    TR title",
        ":INSTITUTION: Inst",
        ":YEAR:     2000",
        ":CUSTOM_ID: k2",
        ":END:",
        "text",
      }, buf_lines(buf))
      org_buffer({ "* X" }, { 1, 0 })
      local msgs = messages(function()
        answering({ "nope" }, function()
          bibtex.create(false)
        end)
      end)
      eq({ "Type::nope is not known" }, msgs)
    end)
  end)

  describe("links", function()
    it("stores a link to the entry at the cursor of a .bib file", function()
      local dir = tmpdir()
      local path = dir .. "/refs.bib"
      vim.fn.writefile({
        "@Article{doe2020,",
        "  author = {Doe, John and Roe, Jane},",
        "  title = {The {Big} Title},",
        "  year = 2020",
        "}",
        "",
        "@misc{solo,",
        "  author = {Solo, Han and Chewie, W. and Leia, P.},",
        "  title = {A New Hope: Episode IV},",
        "  year = {1977}",
        "}",
      }, path)
      vim.cmd("edit! " .. path)
      local links = require("org.links")
      vim.api.nvim_win_set_cursor(0, { 3, 0 })
      local l = links.link_to_location({})
      local display = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":~")
      eq({ "file:" .. display .. "::doe2020", "Doe & Roe 2020: Big Title" }, { l.link, l.desc })
      vim.api.nvim_win_set_cursor(0, { 9, 0 })
      l = links.link_to_location({})
      eq({ "file:" .. display .. "::solo", "Solo et al. 1977: New Hope" }, { l.link, l.desc })
      eq("[no doi]", l.extra.doi)
      -- following it goes to the entry
      local src = org_buffer({ "[[bibtex:" .. path .. "::solo]]" }, { 1, 3 })
      vim.bo[src].modified = false
      vim.bo[src].bufhidden = "hide"
      vim.cmd("silent! only!")
      links.open_at_point()
      eq(require("org.utils").realpath(path), require("org.utils").realpath(vim.api.nvim_buf_get_name(0)))
      eq(7, vim.api.nvim_win_get_cursor(0)[1])
      vim.cmd("silent! only!")
    end)

    it("searches entries in the agenda files", function()
      local agenda = require("org.agenda")
      local open = agenda.open
      local spec
      agenda.open = function(s)
        spec = s
      end
      bibtex.search("graphs")
      agenda.open = open
      eq({
        type = "search",
        match = "graphs +{:btype:}",
        header = "Bib search results:",
        search_view_always_boolean = true,
      }, spec)
    end)
  end)
end)
