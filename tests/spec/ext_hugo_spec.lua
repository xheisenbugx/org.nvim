-- The hugo extension (port of ox-hugo): front matter in TOML and YAML,
-- the per-file and per-subtree flows, inheritance, drafts and dates, tags
-- and categories, bundles, figures, relrefs and where the files go.
-- Expected outputs follow ox-hugo's test site (test/site/content).
local set_tz = require("org.date").set_tz

local dir, saved_tz

-- no default author (the system user's name) in the front matter
local function setup(opts, extra)
  require("org").setup(vim.tbl_extend("force", {
    export = { author = false },
    extensions = { hugo = opts or true },
  }, extra or {}))
end

local function hugo()
  return require("org.extensions.hugo.export")
end

local function read(path)
  return table.concat(vim.fn.readfile(path), "\n")
end

--- Write `lines` to <dir>/<name>, open it with the cursor on `line`.
local function open(name, lines, line)
  local path = dir .. "/" .. name
  vim.fn.writefile(lines, path)
  vim.cmd("silent edit! " .. vim.fn.fnameescape(path))
  vim.api.nvim_win_set_cursor(0, { line or 1, 0 })
  return path
end

--- Messages given through org.utils while `fn` runs.
local function messages(fn)
  local utils = require("org.utils")
  local saved = { utils.notify, utils.warn, utils.error }
  local out = {}
  utils.notify = function(m)
    out[#out + 1] = m
  end
  utils.warn = utils.notify
  utils.error = utils.notify
  local ok, err = pcall(fn)
  utils.notify, utils.warn, utils.error = saved[1], saved[2], saved[3]
  if not ok then
    error(err, 0)
  end
  return out
end

local function site(p)
  return dir .. "/site/" .. p
end

describe("hugo extension", function()
  before_each(function()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir .. "/site/static", "p")
    dir = vim.uv.fs_realpath(dir)
    saved_tz = vim.env.TZ
    set_tz(tz("UTC"))
    setup()
  end)

  after_each(function()
    vim.cmd("silent! %bwipeout!")
    set_tz(saved_tz)
    vim.fn.delete(dir, "rf")
    require("org").setup({})
  end)

  describe("per-file flow", function()
    it("writes TOML front matter and the body to content/<section>/<file>.md", function()
      open("post-toml.org", {
        "#+title: Single Post with TOML front matter",
        "#+author:",
        "#+date: 2017-07-20",
        "#+filetags: single toml cross-link @cat1 @cat2",
        "#+hugo_base_dir: site",
        "#+hugo_section: singles",
        "#+hugo_menu: :menu foo :weight 10 :parent main :identifier single-toml",
        "#+description: Some description for this post.",
        "",
        "This is a single post.",
        "",
        "* First heading in this post",
        "This is a under first heading.",
      })
      local out
      messages(function()
        out = hugo().export_wim()
      end)
      eq(site("content/singles/post-toml.md"), out)
      eq(
        table.concat({
          "+++",
          'title = "Single Post with TOML front matter"',
          'description = "Some description for this post."',
          "date = 2017-07-20",
          'tags = ["single", "toml", "cross-link"]',
          'categories = ["cat1", "cat2"]',
          "draft = false",
          "[menu]",
          "  [menu.foo]",
          '    parent = "main"',
          "    weight = 10",
          '    identifier = "single-toml"',
          "+++",
          "",
          "This is a single post.",
          "",
          "",
          "## First heading in this post {#first-heading-in-this-post}",
          "",
          "This is a under first heading.",
        }, "\n"),
        read(out)
      )
    end)

    it("writes YAML front matter with #+hugo_front_matter_format", function()
      open("post-yaml.org", {
        "#+title: Single Post with YAML front matter",
        "#+author: Jane Doe, John Roe",
        "#+date: <2017-07-20 Thu 10:30>",
        "#+hugo_base_dir: site",
        "#+hugo_front_matter_format: yaml",
        '#+hugo_tags: alpha "two words"',
        "#+hugo_categories: misc",
        "#+hugo_aliases: old-name /elsewhere/x",
        "#+hugo_slug: my-slug",
        "",
        "Body.",
      })
      local out
      messages(function()
        out = hugo().export_file()
      end)
      eq(site("content/posts/post-yaml.md"), out)
      eq(
        table.concat({
          "---",
          'title: "Single Post with YAML front matter"',
          'author: ["Jane Doe", "John Roe"]',
          "date: 2017-07-20T10:30:00+00:00",
          'aliases: ["/posts/old-name", "/elsewhere/x"]',
          'slug: "my-slug"',
          'tags: ["alpha", "two words"]',
          'categories: ["misc"]',
          "draft: false",
          "---",
          "",
          "Body.",
        }, "\n"),
        read(out)
      )
    end)

    it("uses #+export_file_name and #+hugo_bundle for a page bundle", function()
      open("bundle.org", {
        "#+title: Page Bundle (File-based Flow)",
        "#+author:",
        "#+hugo_base_dir: site",
        "#+hugo_section: singles",
        "#+hugo_bundle: page-bundle-file-based-flow",
        "#+export_file_name: index",
        "#+begin_description",
        "Post organized as a /Page Bundle/  exported using /file-based flow/.",
        "#+end_description",
        "",
        "Text.",
      })
      local out
      messages(function()
        out = hugo().export_file()
      end)
      eq(site("content/singles/page-bundle-file-based-flow/index.md"), out)
      ok(
        read(out):find('description = "Post organized as a _Page Bundle_  exported using _file-based flow_."', 1, true)
      )
    end)

    it("needs a #+title, and a base dir", function()
      open("no-title.org", { "#+hugo_base_dir: site", "", "Text." })
      local msgs = messages(function()
        eq(nil, hugo().export_wim())
      end)
      ok(msgs[1]:find("missing the #+title keyword", 1, true), msgs[1])
      open("no-base.org", { "#+title: T", "", "Text." })
      msgs = messages(function()
        eq(nil, hugo().export_wim())
      end)
      ok(msgs[1]:find("HUGO_BASE_DIR", 1, true), msgs[1])
    end)

    it("takes the base dir from the options", function()
      setup({ base_dir = dir .. "/site", section = "notes" })
      open("opt.org", { "#+title: T", "#+author:", "", "Text." })
      messages(function()
        eq(site("content/notes/opt.md"), hugo().export_file())
      end)
    end)

    it("skips a file whose #+hugo_tags has an exclude tag", function()
      open("ex.org", { "#+title: T", "#+hugo_base_dir: site", "#+hugo_tags: a noexport", "", "Text." })
      local msgs = messages(function()
        eq(nil, hugo().export_wim())
      end)
      ok(msgs[1]:find("exclude tag `noexport'", 1, true), msgs[1])
    end)
  end)

  describe("per-subtree flow", function()
    local BLOG = {
      "#+hugo_base_dir: site",
      "#+author: Jane Doe",
      "#+filetags: @tech",
      "",
      "* Blog                                                        :emacs:",
      ":PROPERTIES:",
      ":EXPORT_HUGO_SECTION: blog",
      ":EXPORT_HUGO_CUSTOM_FRONT_MATTER: :foo bar :num 3",
      ":END:",
      "** DONE First post                                 :org_mode:hello__world:",
      "CLOSED: [2024-03-05 Tue 10:30]",
      ":PROPERTIES:",
      ":EXPORT_FILE_NAME: first-post",
      ":END:",
      "Hello /world/, see [[*Second post]] and [[#sub-x][sub]].",
      "*** Sub heading (with parens)",
      ":PROPERTIES:",
      ":CUSTOM_ID: sub-x",
      ":END:",
      "Sub text.",
      "** TODO Second post",
      ":PROPERTIES:",
      ":EXPORT_FILE_NAME: second",
      ":EXPORT_HUGO_FRONT_MATTER_FORMAT: yaml",
      ":EXPORT_DATE: 2024-04-01",
      ":END:",
      "Back to [[*First post][first]] and [[*Sub heading (with parens)]].",
      "* Not a post",
      "Nothing.",
    }

    it("exports the post at the cursor, with what it inherits", function()
      open("blog.org", BLOG, 15)
      local out
      messages(function()
        out = hugo().export_wim()
      end)
      eq(site("content/blog/first-post.md"), out)
      eq(
        table.concat({
          "+++",
          'title = "First post"',
          'author = ["Jane Doe"]',
          "date = 2024-03-05T10:30:00+00:00",
          'tags = ["emacs", "org-mode", "hello world"]',
          'categories = ["tech"]',
          "draft = false",
          'foo = "bar"',
          "num = 3",
          "+++",
          "",
          'Hello _world_, see [Second post]({{< relref "second" >}}) and [sub](#sub-x).',
          "",
          "",
          "## Sub heading (with parens) {#sub-x}",
          "",
          "Sub text.",
        }, "\n"),
        read(out)
      )
    end)

    it("exports a TODO post as a draft, in YAML, with relrefs to headings of other posts", function()
      open("blog.org", BLOG, 27)
      local out
      messages(function()
        out = hugo().export_wim()
      end)
      eq(site("content/blog/second.md"), out)
      eq(
        table.concat({
          "---",
          'title: "Second post"',
          'author: ["Jane Doe"]',
          "date: 2024-04-01",
          'tags: ["emacs"]',
          'categories: ["tech"]',
          "draft: true",
          'foo: "bar"',
          "num: 3",
          "---",
          "",
          'Back to [first]({{< relref "first-post" >}}) and [Sub heading (with parens)]({{< relref "first-post#sub-x" >}}).',
        }, "\n"),
        read(out)
      )
    end)

    it("exports all posts, and warns outside of one", function()
      open("blog.org", BLOG, 29)
      local msgs = messages(function()
        eq(nil, hugo().export_wim())
      end)
      ok(msgs[1]:find("not in a valid Hugo post subtree", 1, true))
      local paths
      messages(function()
        paths = hugo().export_wim({ all = true })
      end)
      eq({ site("content/blog/first-post.md"), site("content/blog/second.md") }, paths)
    end)

    it("joins EXPORT_HUGO_SECTION_FRAG and EXPORT_HUGO_BUNDLE of parents", function()
      open("frag.org", {
        "#+hugo_base_dir: site",
        "#+author:",
        "* Docs",
        ":PROPERTIES:",
        ":EXPORT_HUGO_SECTION: docs",
        ":EXPORT_HUGO_SECTION_FRAG: guide",
        ":END:",
        "** Part",
        ":PROPERTIES:",
        ":EXPORT_HUGO_SECTION_FRAG: part-1",
        ":EXPORT_HUGO_BUNDLE: chapter",
        ":END:",
        "*** Landing",
        ":PROPERTIES:",
        ":EXPORT_FILE_NAME: index",
        ":END:",
        "Text.",
      }, 17)
      local out
      messages(function()
        out = hugo().export_wim()
      end)
      eq(site("content/docs/guide/part-1/chapter/index.md"), out)
    end)

    it("skips commented posts and posts with an exclude tag", function()
      open("skip.org", {
        "#+hugo_base_dir: site",
        "* COMMENT Hidden",
        ":PROPERTIES:",
        ":EXPORT_FILE_NAME: hidden",
        ":END:",
        "* Private                                                  :noexport:",
        ":PROPERTIES:",
        ":EXPORT_FILE_NAME: private",
        ":END:",
      })
      local paths
      local msgs = messages(function()
        paths = hugo().export_wim({ all = true })
      end)
      eq({}, paths)
      ok(msgs[1]:find("commented out", 1, true))
      ok(msgs[2]:find("exclude tag `noexport'", 1, true))
    end)
  end)

  describe("front matter", function()
    local function export(lines, line)
      open("fm.org", lines, line or #lines)
      local out
      messages(function()
        out = hugo().export_wim()
      end)
      return out and read(out)
    end

    it("sets draft from the TODO state, then from HUGO_DRAFT", function()
      local text = export({
        "#+hugo_base_dir: site",
        "#+todo: TODO DRAFT | DONE",
        "* DRAFT Pre-draft",
        ":PROPERTIES:",
        ":EXPORT_FILE_NAME: d",
        ":EXPORT_HUGO_DRAFT: false",
        ":END:",
        "x",
      })
      ok(text:find("\ndraft = true\n", 1, true), text)
      text = export({
        "#+hugo_base_dir: site",
        "* Not a TODO",
        ":PROPERTIES:",
        ":EXPORT_FILE_NAME: d",
        ":EXPORT_HUGO_DRAFT: t",
        ":END:",
        "x",
      })
      ok(text:find("\ndraft = true\n", 1, true), text)
    end)

    it("takes publishDate from SCHEDULED, and lastmod, expiryDate, slug and url", function()
      local text = export({
        "#+hugo_base_dir: site",
        "* Post",
        "SCHEDULED: <2024-05-01 Wed>",
        ":PROPERTIES:",
        ":EXPORT_FILE_NAME: p",
        ":EXPORT_HUGO_LASTMOD: <2024-05-03 Fri 08:00>",
        ":EXPORT_HUGO_EXPIRYDATE: 2025-01-01",
        ":EXPORT_HUGO_URL: /x/y",
        ":EXPORT_HUGO_TYPE: page",
        ":END:",
        "x",
      })
      ok(text:find("publishDate = 2024-05-01T00:00:00+00:00\nexpiryDate = 2025-01-01\n", 1, true), text)
      ok(text:find("lastmod = 2024-05-03T08:00:00+00:00\n", 1, true), text)
      ok(text:find('type = "page"\nurl = "/x/y"\n', 1, true), text)
    end)

    it("uses date_format and auto_set_lastmod", function()
      setup({ date_format = "%Y-%m-%d", auto_set_lastmod = true })
      local text = export({
        "#+hugo_base_dir: site",
        "* Post",
        ":PROPERTIES:",
        ":EXPORT_FILE_NAME: p",
        ":EXPORT_DATE: <2024-05-03 Fri 08:00>",
        ":END:",
        "x",
      })
      ok(text:find("date = 2024-05-03\n", 1, true), text)
      ok(text:find("lastmod = " .. os.date("%Y-%m-%d") .. "\n", 1, true), text)
    end)

    it("escapes strings: quotes, backslashes and multi-line descriptions", function()
      local lines = {
        "#+hugo_base_dir: site",
        '* A "quoted" title --- with ... dashes',
        ":PROPERTIES:",
        ":EXPORT_FILE_NAME: e",
        ":END:",
        "#+begin_description",
        "Backslashes in =\\|= and",
        "=\\\\= are escaped.",
        "#+end_description",
        "x",
      }
      local text = export(lines)
      -- tomelr writes strings with double quotes as multi-line strings
      ok(text:find('title = """\n  A "quoted" title — with … dashes\n  """', 1, true), text)
      ok(text:find('description = """\n  Backslashes in `\\\\|` and\n  `\\\\\\\\` are escaped.\n  """', 1, true), text)
      table.insert(lines, 5, ":EXPORT_HUGO_FRONT_MATTER_FORMAT: yaml")
      text = export(lines)
      ok(text:find('title: "A \\"quoted\\" title — with … dashes"', 1, true), text)
      ok(text:find("description: >\n  Backslashes in `\\|` and\n  `\\\\` are escaped.\n", 1, true), text)
    end)

    it("writes auto and taxonomy weights and menus", function()
      local text = export({
        "#+hugo_base_dir: site",
        "* Parent",
        "** Post one",
        ":PROPERTIES:",
        ":EXPORT_FILE_NAME: one",
        ":END:",
        "** Post two",
        ":PROPERTIES:",
        ":EXPORT_FILE_NAME: two",
        ":EXPORT_HUGO_WEIGHT: auto :tags 111 :categories auto",
        ':EXPORT_HUGO_MENU: :menu "auto weight"',
        ":END:",
        "x",
      })
      ok(
        text:find(
          'categories_weight = 2002\ntags_weight = 111\nweight = 2002\n[menu]\n  [menu."auto weight"]\n    weight = 2002\n    identifier = "post-two"\n',
          1,
          true
        ),
        text
      )
      text = export({
        "#+hugo_base_dir: site",
        "#+hugo_front_matter_format: yaml",
        "* Post",
        ":PROPERTIES:",
        ":EXPORT_FILE_NAME: m",
        ':EXPORT_HUGO_MENU: :menu "something here" :weight 25 :parent posts',
        ":EXPORT_HUGO_MENU_OVERRIDE: :identifier ov",
        ":END:",
        "x",
      })
      ok(
        text:find('menu:\n  "something here":\n    parent: "posts"\n    weight: 25\n    identifier: "ov"\n', 1, true),
        text
      )
    end)

    it("writes custom front matter with lists and nested maps", function()
      local lines = {
        "#+hugo_base_dir: site",
        "* Post",
        ":PROPERTIES:",
        ":EXPORT_FILE_NAME: c",
        ':EXPORT_HUGO_CUSTOM_FRONT_MATTER: :animals \'(dog cat "mountain gorilla") :small "234" :big "10040216507682529280"',
        ":EXPORT_HUGO_CUSTOM_FRONT_MATTER+: :dog '((legs . 4) (friends . (poo boo)))",
        ":END:",
        "x",
      }
      local text = export(lines)
      ok(
        text:find(
          'animals = ["dog", "cat", "mountain gorilla"]\nsmall = 234\nbig = "10040216507682529280"\n[dog]\n  legs = 4\n  friends = ["poo", "boo"]\n+++',
          1,
          true
        ),
        text
      )
      table.insert(lines, 5, ":EXPORT_HUGO_FRONT_MATTER_FORMAT: yaml")
      text = export(lines)
      ok(text:find('animals: ["dog", "cat", "mountain gorilla"]\nsmall: 234\n', 1, true), text)
      ok(text:find('dog:\n  legs: 4\n  friends: ["poo", "boo"]\n---', 1, true), text)
    end)

    it("writes resources, and renames or drops keys with HUGO_FRONT_MATTER_KEY_REPLACE", function()
      local text = export({
        "#+hugo_base_dir: site",
        "* Post",
        ":PROPERTIES:",
        ":EXPORT_FILE_NAME: r",
        ':EXPORT_HUGO_RESOURCES: :src "img.png" :title "An image" :credit me',
        ":EXPORT_HUGO_FRONT_MATTER_KEY_REPLACE: draft>nil title>linkTitle",
        ":END:",
        "x",
      })
      eq(
        table.concat({
          "+++",
          'linkTitle = "Post"',
          "[[resources]]",
          '  src = "img.png"',
          '  title = "An image"',
          "  [resources.params]",
          '    credit = "me"',
          "+++",
        }, "\n"),
        text:match("^(%+%+%+.-%+%+%+)")
      )
    end)

    it("processes tags: spaces, hyphens, @categories, HUGO_TAGS overriding", function()
      local text = export({
        "#+hugo_base_dir: site",
        "* Post                              :a_b:c__d:e___f:@my_cat:",
        ":PROPERTIES:",
        ":EXPORT_FILE_NAME: t",
        ":END:",
        "x",
      })
      ok(text:find('tags = ["a-b", "c d", "e_f"]\ncategories = ["my-cat"]\n', 1, true), text)
      setup({ prefer_hyphen_in_tags = false, allow_spaces_in_tags = false })
      text = export({
        "#+hugo_base_dir: site",
        "* Post                              :a_b:c__d:",
        ":PROPERTIES:",
        ":EXPORT_FILE_NAME: t",
        ":EXPORT_HUGO_CATEGORIES: x y",
        ":END:",
        "x",
      })
      ok(text:find('tags = ["a_b", "c__d"]\ncategories = ["x", "y"]\n', 1, true), text)
    end)
  end)

  describe("body", function()
    local function export(lines, line)
      open("body.org", lines, line or #lines)
      local out
      messages(function()
        out = hugo().export_wim()
      end)
      return out and read(out)
    end

    it("copies images to static/ and writes figure shortcodes", function()
      vim.fn.mkdir(dir .. "/img", "p")
      vim.fn.writefile({ "png" }, dir .. "/img/cat.png")
      vim.fn.mkdir(dir .. "/site/static/images", "p")
      vim.fn.writefile({ "png" }, dir .. "/site/static/images/logo.png")
      local text = export({
        "#+title: Figures",
        "#+hugo_base_dir: site",
        "",
        '#+caption: A unicorn! "Quoted"',
        "[[file:img/cat.png]]",
        "",
        "#+attr_html: :class inset :width 50",
        "[[file:site/static/images/logo.png]]",
        "",
        "Inline [[file:img/cat.png]] image.",
      })
      ok(
        text:find(
          '{{< figure src="/ox-hugo/cat.png" caption="<span class=\\"figure-number\\">Figure 1: </span>A unicorn! \\"Quoted\\"" >}}',
          1,
          true
        ),
        text
      )
      ok(text:find('{{< figure src="/images/logo.png" class="inset" width="50" >}}', 1, true), text)
      ok(text:find("Inline ![](/ox-hugo/cat.png) image.", 1, true), text)
      eq(1, vim.fn.filereadable(site("static/ox-hugo/cat.png")))
    end)

    it("copies images into a page bundle", function()
      vim.fn.mkdir(dir .. "/img", "p")
      vim.fn.writefile({ "png" }, dir .. "/img/cat.png")
      local text = export({
        "#+hugo_base_dir: site",
        "* Post",
        ":PROPERTIES:",
        ":EXPORT_FILE_NAME: index",
        ":EXPORT_HUGO_BUNDLE: my-bundle",
        ":END:",
        "[[file:img/cat.png]]",
      })
      ok(text:find('{{< figure src="img/cat.png" >}}', 1, true), text)
      eq(1, vim.fn.filereadable(site("content/posts/my-bundle/img/cat.png")))
    end)

    it("links to other Org files with relref", function()
      vim.fn.writefile({ "* Heading", ":PROPERTIES:", ":CUSTOM_ID: first-heading", ":END:" }, dir .. "/post-yaml.org")
      local text = export({
        "#+title: Links",
        "#+hugo_base_dir: site",
        "",
        "See [[file:post-yaml.org]], [[file:post-yaml.org][Post with YAML]],",
        "[[./post-yaml.org::#first-heading]] and [[https://example.com][a site]].",
      })
      ok(
        text:find(
          'See [{{< relref "post-yaml" >}}]({{< relref "post-yaml" >}}), [Post with YAML]({{< relref "post-yaml" >}}),\n'
            .. '[{{< relref "post-yaml#first-heading" >}}]({{< relref "post-yaml#first-heading" >}}) and [a site](https://example.com).',
          1,
          true
        ),
        text
      )
    end)

    it("writes code fences with hl_lines and linenos, or highlight shortcodes", function()
      local lines = {
        "#+title: Code",
        "#+hugo_base_dir: site",
        "",
        "#+begin_src emacs-lisp -n :hl_lines 1,3-4",
        "(a)",
        "(b)",
        "#+end_src",
      }
      local text = export(lines)
      ok(text:find('```emacs-lisp { linenos=true, linenostart=1, hl_lines=["1","3-4"] }\n(a)\n(b)\n```', 1, true), text)
      table.insert(lines, 3, "#+hugo_code_fence:")
      text = export(lines)
      ok(
        text:find(
          '{{< highlight emacs-lisp "linenos=true, linenostart=1, hl_lines=1 3-4" >}}\n(a)\n(b)\n{{< /highlight >}}',
          1,
          true
        ),
        text
      )
    end)

    it("writes details, paired shortcodes, the summary splitter and footnotes", function()
      local text = export({
        "#+title: Blocks",
        "#+hugo_base_dir: site",
        "#+hugo_paired_shortcodes: %alert mark-me",
        "",
        "Summary[fn:1].",
        "",
        "#+hugo: more",
        "",
        "#+begin_details",
        "#+begin_summary",
        "Why?",
        "#+end_summary",
        "Because.",
        "#+end_details",
        "",
        "#+attr_shortcode: :type warning",
        "#+begin_alert",
        "Careful *here*.",
        "#+end_alert",
        "",
        "#+begin_mark-me",
        "Plain",
        "#+end_mark-me",
        "",
        "[fn:1] A note.",
      })
      ok(
        text:find(
          table.concat({
            "Summary[^fn:1].",
            "",
            "<!--more-->",
            "",
            "<details>",
            "<summary>Why?</summary>",
            '<div class="details">',
            "",
            "Because.",
            "</div>",
            "</details>",
            "",
            '{{% alert type="warning" %}}',
            "Careful **here**.",
            "{{% /alert %}}",
            "",
            "{{< mark-me >}}",
            "Plain",
            "{{< /mark-me >}}",
            "",
            "[^fn:1]: A note.",
          }, "\n"),
          1,
          true
        ),
        text
      )
    end)

    it("offsets headings, keeps TODO keywords and turns deep ones into lists", function()
      local text = export({
        "#+title: Levels",
        "#+hugo_base_dir: site",
        "#+options: H:2",
        "",
        "* TODO One",
        "** Two",
        "*** Three",
        "Deep.",
      })
      ok(
        text:find(
          table.concat({
            '## <span class="org-todo todo TODO">TODO</span> One {#one}',
            "",
            "",
            "### Two {#two}",
            "",
            "<!--list-separator-->",
            "",
            "-  Three",
            "",
            "    Deep.",
          }, "\n"),
          1,
          true
        ),
        text
      )
    end)

    it("exports to a temporary buffer without a base dir", function()
      open("buf.org", { "#+title: Buffer", "#+author:", "", "Text *here*." })
      -- (the markdown ftplugin needs a treesitter parser the test runtime lacks)
      vim.cmd("filetype plugin off")
      local buf = hugo().export_as_buffer({ hidden = true })
      vim.cmd("filetype plugin on")
      eq("markdown", vim.bo[buf].filetype)
      eq({ "+++", 'title = "Buffer"', "draft = false", "+++", "", "Text **here**." }, buf_lines(buf))
    end)
  end)

  describe("front matter encoding", function()
    local fm = require("org.extensions.hugo.front_matter")

    it("slugs like org-hugo-slug", function()
      eq("my-first-post", fm.slug("My First Post"))
      eq("closed-details-disclosure--default", fm.slug("Closed details disclosure (default)", true))
      eq("summary-plus-details", fm.slug("Summary + Details"))
      eq("setting-class-parameter", fm.slug("Setting `class` parameter"))
      eq("link-desc", fm.slug("[Link desc](https://example.com)"))
      eq("version-1-dot-0-and-more", fm.slug("Version 1.0 & more"))
    end)

    it("reads property arguments", function()
      eq(
        { { "foo", "bar" }, { "baz", 1 }, { "zoo", "two words" } },
        fm.parse_arguments(':foo bar :baz 1 :zoo "two words"')
      )
      eq({ { "auto", nil }, { "tags", 3 } }, fm.parse_arguments("auto :tags 3"))
    end)
  end)

  describe("dispatcher and setup", function()
    it("adds H to the export dispatcher, and removes it with the extension", function()
      local export = require("org.export")
      local function keys()
        local out = {}
        for _, e in ipairs(export.menu_entries) do
          out[#out + 1] = e.key
        end
        return out
      end
      eq({ "H" }, keys())
      local labels = {}
      for _, it in ipairs(export.menu_entries[1].items) do
        labels[#labels + 1] = it.key
      end
      eq({ "H", "h", "O", "o", "A", "t" }, labels)
      require("org").setup({})
      eq({}, keys())
    end)

    it("runs H H from the dispatcher", function()
      open("dispatch.org", { "#+title: D", "#+author:", "#+hugo_base_dir: site", "", "Text." })
      local ui = require("org.ui")
      local saved = ui.menu
      ui.menu = function(o)
        for _, it in ipairs(o.items) do
          if it.key == "H" and it.items then
            return it.items[1].value
          end
        end
      end
      local ok_, err = pcall(function()
        messages(function()
          require("org.export").prompt()
        end)
      end)
      ui.menu = saved
      assert(ok_, err)
      eq(1, vim.fn.filereadable(site("content/posts/dispatch.md")))
    end)

    it("exports on save with auto_export", function()
      setup({ auto_export = true })
      open("auto.org", { "#+title: Auto", "#+author:", "#+hugo_base_dir: site", "", "Text." })
      messages(function()
        vim.cmd("silent write")
      end)
      eq(1, vim.fn.filereadable(site("content/posts/auto.md")))
    end)
  end)
end)
