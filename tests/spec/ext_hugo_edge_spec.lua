-- Edge cases of the hugo extension: malformed property values, file names
-- that try to leave the section, titles with no letters, quotes and
-- unicode in front matter, empty posts and odd base directories.
local set_tz = require("org.date").set_tz
local fm = require("org.extensions.hugo.front_matter")

local dir, saved_tz

local function setup(opts)
  require("org").setup({ export = { author = false }, extensions = { hugo = opts or true } })
end

local function hugo()
  return require("org.extensions.hugo.export")
end

local function read(path)
  return table.concat(vim.fn.readfile(path), "\n")
end

local function open(name, lines, line)
  local path = dir .. "/" .. name
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile(lines, path)
  vim.cmd("silent edit! " .. vim.fn.fnameescape(path))
  vim.api.nvim_win_set_cursor(0, { line or 1, 0 })
  return path
end

local function messages(fn)
  local utils = require("org.utils")
  local saved = { utils.notify, utils.warn, utils.error }
  local out = {}
  utils.notify = function(m)
    out[#out + 1] = m
  end
  utils.warn = utils.notify
  utils.error = utils.notify
  local okf, err = pcall(fn)
  utils.notify, utils.warn, utils.error = saved[1], saved[2], saved[3]
  if not okf then
    error(err, 0)
  end
  return out
end

describe("hugo edge cases", function()
  describe("front matter values", function()
    it("reads malformed Lisp values without failing", function()
      eq(nil, fm.read_value(""))
      eq(")", fm.read_value(")"))
      eq('"unterminated', fm.read_value('"unterminated'))
      eq({ kind = "list" }, fm.read_value("("))
      eq({ "a", { "b", "c", kind = "list" }, kind = "list" }, fm.read_value("(a (b c)"))
      eq({ 1, 2, kind = "list" }, fm.read_value("'(1 2"))
    end)

    it("reads property arguments with no value, a bare word or an open quote", function()
      eq({}, fm.parse_arguments(""))
      eq({}, fm.parse_arguments(":"))
      eq({ { "a" }, { "b" }, { "c" } }, fm.parse_arguments(":a :b :c"))
      eq({ { "a", '"unterminated' } }, fm.parse_arguments(':a "unterminated'))
      eq({ { "key", "val" } }, fm.parse_arguments(":key\tval"))
    end)

    it("slugs a title with no letters or digits to nothing", function()
      for _, s in ipairs({ "", "   ", "!!!", "---", "😀 🎉" }) do
        eq("", fm.slug(s), s)
      end
      eq("a-b-c", fm.slug("a\tb\nc"))
    end)

    it("quotes strings that look like other YAML values only when they aren't", function()
      eq("true", fm.yaml_scalar("true"))
      eq("123", fm.yaml_scalar("123"))
      eq('"a: b"', fm.yaml_scalar("a: b"))
      eq('"#not a comment"', fm.yaml_scalar("#not a comment"))
      eq('"tab\there"', fm.yaml_scalar("tab\there"))
      eq('""', fm.yaml_scalar(""))
    end)

    it("escapes tabs, quotes and backslashes in TOML", function()
      eq('"a\\tb"', fm.toml_scalar("a\tb"))
      eq('"C:\\\\path"', fm.toml_scalar("C:\\path"))
      eq('"日本語"', fm.toml_scalar("日本語"))
    end)
  end)

  describe("exporting", function()
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

    it("keeps a post's EXPORT_FILE_NAME inside its section", function()
      open("blog.org", {
        "#+hugo_base_dir: site",
        "* Escape attempt",
        ":PROPERTIES:",
        ":EXPORT_FILE_NAME: ../../../outside",
        ":END:",
        "Text.",
      }, 2)
      local out
      messages(function()
        out = hugo().export_wim()
      end)
      eq(dir .. "/site/content/posts/outside.md", out)
      eq(nil, vim.uv.fs_stat(dir .. "/outside.md"))
    end)

    it("doesn't add .md twice to an EXPORT_FILE_NAME ending in .md", function()
      open("blog.org", {
        "#+hugo_base_dir: site",
        "* Post",
        ":PROPERTIES:",
        ":EXPORT_FILE_NAME: post.md",
        ":END:",
        "Text.",
      }, 2)
      local out
      messages(function()
        out = hugo().export_wim()
      end)
      eq(dir .. "/site/content/posts/post.md", out)
    end)

    it("writes quotes, backslashes and unicode in a title as valid TOML and YAML", function()
      open("q.org", {
        '#+title: “Quoted” \\ "straight" — 日本',
        "#+hugo_base_dir: site",
        "",
        "Text.",
      })
      local out
      messages(function()
        out = hugo().export_wim()
      end)
      local text = read(out)
      ok(text:find("日本", 1, true), text)
      -- a double quote in TOML: a multi-line string, its backslash doubled
      ok(text:find('"""', 1, true), text)
      ok(text:find("\\\\", 1, true), text)
      open("y.org", {
        '#+title: “Quoted” \\ "straight" — 日本',
        "#+hugo_base_dir: site",
        "#+hugo_front_matter_format: yaml",
        "",
        "Text.",
      })
      messages(function()
        out = hugo().export_wim()
      end)
      text = read(out)
      ok(text:find('title: "“Quoted” \\\\ \\"straight\\" — 日本"', 1, true), text)
    end)

    it("exports a post with only a title", function()
      open("empty.org", { "#+title: Nothing here", "#+hugo_base_dir: site" })
      local out
      messages(function()
        out = hugo().export_wim()
      end)
      local text = read(out)
      ok(text:match("^%+%+%+\n"), text)
      ok(text:find('title = "Nothing here"', 1, true), text)
    end)

    it("refuses a title made only of spaces", function()
      open("blank.org", { "#+title:    ", "#+hugo_base_dir: site", "", "Text." })
      local msgs = messages(function()
        eq(nil, hugo().export_wim())
      end)
      ok(msgs[1] and msgs[1]:find("#+title", 1, true), vim.inspect(msgs))
    end)

    it("writes into a base dir with spaces and unicode in its path", function()
      vim.fn.mkdir(dir .. "/my site ñ", "p")
      open("s.org", { "#+title: T", "#+hugo_base_dir: my site ñ", "", "Text." })
      local out
      messages(function()
        out = hugo().export_wim()
      end)
      eq(dir .. "/my site ñ/content/posts/s.md", out)
      eq(1, vim.fn.filereadable(out))
    end)

    it("reports a link to an image that doesn't exist instead of failing", function()
      open("img.org", { "#+title: T", "#+hugo_base_dir: site", "", "[[file:missing.png]]" })
      local out
      messages(function()
        out = hugo().export_wim()
      end)
      ok(out and vim.fn.filereadable(out) == 1)
    end)

    it("does nothing outside an org buffer", function()
      vim.cmd("enew")
      local msgs = messages(function()
        eq(nil, hugo().export_wim())
      end)
      ok(#msgs >= 1)
    end)

    it("leaves a #+date it can't read as written", function()
      open("d.org", { "#+title: T", "#+hugo_base_dir: site", "#+date: sometime soon", "", "Text." })
      local out
      messages(function()
        out = hugo().export_wim()
      end)
      local text = read(out)
      ok(not text:find("date = 1970", 1, true), text)
    end)
  end)
end)
