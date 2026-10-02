local odt = require("org.export.odt")
local zip = require("org.export.zip")
local config = require("org.config")

local root = vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h"))
local dir = root .. "/fixtures/export/odt"

local function has(s, sub)
  ok(s:find(sub, 1, true), "missing: " .. sub .. "\n---\n" .. s)
end
local function hasnt(s, sub)
  ok(not s:find(sub, 1, true), "unexpected: " .. sub .. "\n---\n" .. s)
end

local function read(path)
  local f = assert(io.open(path, "rb"))
  local s = f:read("*a")
  f:close()
  return s
end

--- Export `lines` (or the fixture `name`) to a temporary .odt file.
---@return string path, fun(member: string): string?
local function export(lines, filename)
  local out = vim.fn.tempname() .. ".odt"
  local res = odt.export_file(lines, { filename = filename }, { output = out }, filename)
  eq(out, res)
  return out, function(member)
    return (zip.read(out, member))
  end
end

local function export_fixture(name)
  local path = dir .. "/" .. name .. ".org"
  return export(vim.fn.readfile(path), path)
end

--- Emacs generates random references: number them by first occurrence.
local function normalize(s)
  local map, n = {}, 0
  s = s:gsub("org%x%x%x%x%x%x%x", function(r)
    if not map[r] then
      n = n + 1
      map[r] = "ref" .. n
    end
    return map[r]
  end)
  return s
end

local function body(xml)
  return xml:sub((xml:find("<office:body>", 1, true)))
end

describe("export odt", function()
  posix_shell()
  local saved
  before_each(function()
    saved = saved or vim.deepcopy(config.opts.export.odt)
    config.opts.export.odt = vim.deepcopy(saved)
    config.opts.export.odt.fontify_srcblocks = false
    -- keep the MathML cache (org-latex-mathml-directory) out of the fixtures
    config.opts.export.odt.latex_mathml_directory = vim.fn.tempname() .. "/"
    config.opts.babel.evaluate_on_export = false
    config.opts.export.author = "Tester"
  end)
  after_each(function()
    config.opts.export.odt = vim.deepcopy(saved)
    config.opts.export.author = nil
  end)

  describe("zip writer", function()
    it("computes CRC-32", function()
      eq(0x414fa339, zip.crc32("The quick brown fox jumps over the lazy dog"))
      eq(0, zip.crc32(""))
    end)

    it("writes stored entries that read back", function()
      local path = vim.fn.tempname() .. ".zip"
      ok(zip.write(path, {
        { name = "mimetype", data = "application/vnd.oasis.opendocument.text" },
        { name = "d/" },
        { name = "d/x.bin", data = "\0\1\2\255" .. string.rep("é", 100) },
      }))
      local list = zip.list(path)
      eq(
        { "mimetype", "d/", "d/x.bin" },
        vim.tbl_map(function(e)
          return e.name
        end, list)
      )
      eq(0, list[1].method)
      eq("\0\1\2\255" .. string.rep("é", 100), zip.read(path, "d/x.bin"))
      if vim.fn.executable("unzip") == 1 then
        eq(0, vim.system({ "unzip", "-tq", path }):wait().code)
      end
    end)
  end)

  describe("package", function()
    it("has mimetype first and uncompressed, and a manifest of every part", function()
      local path, get = export_fixture("basic")
      local s = read(path)
      -- local header of the first entry: stored "mimetype" then its data
      eq("PK\3\4", s:sub(1, 4))
      eq(0, s:byte(9) + s:byte(10) * 256)
      eq("mimetypeapplication/vnd.oasis.opendocument.text", s:sub(31, 38 + 39))
      local names = vim.tbl_map(function(e)
        return e.name
      end, zip.list(path))
      eq({
        "mimetype",
        "content.xml",
        "styles.xml",
        "meta.xml",
        "Images/",
        "Images/0001.png",
        "META-INF/",
        "META-INF/manifest.xml",
      }, names)
      eq(read(dir .. "/img.png"), get("Images/0001.png"))
      local manifest = get("META-INF/manifest.xml")
      has(
        manifest,
        'manifest:media-type="application/vnd.oasis.opendocument.text" manifest:full-path="/" manifest:version="1.2"/>'
      )
      for _, p in ipairs({ "content.xml", "styles.xml", "meta.xml" }) do
        has(manifest, 'manifest:media-type="text/xml" manifest:full-path="' .. p .. '"/>')
      end
      has(manifest, 'manifest:media-type="image/png" manifest:full-path="Images/0001.png"/>')
      if vim.fn.executable("unzip") == 1 then
        eq(0, vim.system({ "unzip", "-tq", path }):wait().code)
      end
    end)

    it("writes the metadata", function()
      local _, get = export({
        "#+TITLE: A *bold* title",
        "#+SUBTITLE: Sub",
        "#+AUTHOR: Jane Doe",
        "#+DATE: <2024-01-15 Mon>",
        "#+KEYWORDS: k1 k2",
        "#+DESCRIPTION: About",
        "Text",
      })
      local meta = get("meta.xml")
      has(meta, "<dc:creator>Jane Doe</dc:creator>")
      has(meta, "<meta:initial-creator>Jane Doe</meta:initial-creator>")
      has(meta, "<dc:date>2024-01-15</dc:date>")
      has(meta, "<meta:keyword>k1 k2</meta:keyword>")
      has(meta, "<dc:subject>About</dc:subject>")
      -- markup is dropped: meta.xml does not declare the text namespace
      has(meta, "<dc:title>A bold title</dc:title>")
      has(meta, '<meta:user-defined meta:name="subtitle">Sub</meta:user-defined>')
      local content = get("content.xml")
      has(content, '<text:title>A <text:span text:style-name="Bold">bold</text:span> title</text:title>')
      has(content, "<text:initial-creator>Jane Doe</text:initial-creator>")
    end)
  end)

  describe("matches Emacs (ox-odt) content.xml", function()
    for _, name in ipairs({ "basic", "features", "images" }) do
      it("for " .. name .. ".org", function()
        local _, get = export_fixture(name)
        eq(normalize(read(dir .. "/" .. name .. ".emacs.xml")), normalize(body(get("content.xml"))))
      end)
    end

    it("for LaTeX converted to MathML (math.org)", function()
      config.opts.export.odt.latex_to_mathml_convert_command = "sh " .. dir .. "/fakemml.sh %I %o"
      local path, get = export_fixture("math")
      eq(normalize(read(dir .. "/math.emacs.xml")), normalize(body(get("content.xml"))))
      local mathml = get("Formula-0001/content.xml")
      eq(
        '<?xml version="1.0" encoding="UTF-8"?>\n<math xmlns="http://www.w3.org/1998/Math/MathML"><mtext>a+b</mtext></math>',
        mathml
      )
      has(
        get("META-INF/manifest.xml"),
        'manifest:media-type="application/vnd.oasis.opendocument.formula" manifest:full-path="Formula-0001/" manifest:version="1.2"/>'
      )
      ok(zip.read(path, "Formula-0004/content.xml"))
    end)

    it("keeps the styles of Emacs (outline numbering, priorities)", function()
      local _, get = export_fixture("features")
      local styles = get("styles.xml")
      -- H:2 num:t: all levels keep their numbering; pri:t adds priority styles
      has(styles, '<style:style style:name="OrgPriority-A" style:family="text" style:parent-style-name="OrgPriority"/>')
      has(styles, "<!-- Org Htmlfontify Styles -->")
      local _, get2 = export({ "#+OPTIONS: num:1", "* A" })
      local s2 = get2("styles.xml")
      has(s2, '<text:outline-level-style text:level="2" style:num-format="">')
      ok(s2:find('<text:outline%-level%-style text:level="1" style:num%-suffix'), "level 1 keeps numbering")
    end)
  end)

  describe("content", function()
    it("exports headings, emphasis and paragraphs", function()
      local _, get = export({
        "#+OPTIONS: toc:nil num:nil",
        "* Heading",
        "Some *b* /i/ _u_ +s+ =v= ~c~ text.",
      })
      local c = get("content.xml")
      ok(
        c:find(
          '<text:h text:style%-name="Heading_20_1_unnumbered" text:outline%-level="1" text:is%-list%-header="true">'
        ),
        c
      )
      has(c, '<text:span text:style-name="Bold">b</text:span>')
      has(c, '<text:span text:style-name="Emphasis">i</text:span>')
      has(c, '<text:span text:style-name="Underline">u</text:span>')
      has(c, '<text:span text:style-name="Strikethrough">s</text:span>')
      has(c, '<text:span text:style-name="OrgCode">v</text:span>')
      hasnt(c, "<text:table-of-content")
    end)

    it("exports dates as fields with use_date_fields", function()
      config.opts.export.odt.use_date_fields = true
      local _, get = export_fixture("dates")
      local c = get("content.xml")
      has(
        c,
        '<text:date text:date-value="2024-01-15" style:data-style-name="OrgDate1" text:fixed="true">01/15/24 Mon</text:date> +1w&gt;'
      )
      has(c, '<text:date text:date-value="2024-01-15T09:00:00" style:data-style-name="OrgDate2" text:fixed="true">')
      has(c, '<number:date-style style:name="OrgDate1"  number:automatic-order="true" number:format-source="fixed">')
      has(c, "<office:annotation>\n<dc:creator>Tester</dc:creator><dc:date>2024-05-06T10:30:00</dc:date>")
    end)

    it("colorizes source blocks with tree-sitter", function()
      config.opts.export.odt.fontify_srcblocks = true
      local lib = vim.fn.fnamemodify(vim.env.VIMRUNTIME, ":h:h:h") .. "/lib/nvim"
      if vim.fn.isdirectory(lib .. "/parser") == 1 then
        vim.opt.rtp:append(lib)
      end
      if not pcall(vim.treesitter.language.add, "lua") then
        return
      end
      local _, get = export({ "#+begin_src lua", 'local x = "a"', "#+end_src" })
      local c = get("content.xml")
      has(
        c,
        '<text:p text:style-name="OrgSrcBlockLastLine"><text:span text:style-name="OrgSrcKeyword">local</text:span><text:s/>'
      )
      has(
        get("styles.xml"),
        '<style:style style:name="OrgSrcBlock" style:family="paragraph" style:parent-style-name="Preformatted_20_Text">'
      )
    end)

    it("renders LaTeX to pictures with a preview process (tex:dvipng...)", function()
      local ui = config.opts.ui.latex_preview
      local saved_processes = ui.processes
      ui.processes = {
        fakeimg = {
          programs = { "sh" },
          image_input_type = "tex",
          image_output_type = "png",
          latex_compiler = {},
          image_converter = { "cp " .. vim.fn.shellescape(dir .. "/img.png") .. " %O" },
        },
      }
      local ok_run, err = pcall(function()
        local path, get = export({
          "#+OPTIONS: tex:fakeimg",
          "Inline $x$ here.",
          "",
          "#+CAPTION: Energy",
          "#+NAME: eq:e",
          "\\begin{equation}",
          "E = mc^2",
          "\\end{equation}",
        })
        local c = get("content.xml")
        has(c, 'draw:style-name="OrgInlineImage" svg:width="2.54cm" svg:height="1.27cm" text:anchor-type="as-char"')
        has(c, "<svg:title>Latex-Fragment</svg:title><svg:desc>$x$</svg:desc>")
        has(c, '<text:p text:style-name="OrgFormula">')
        has(c, 'text:name="Equation" text:formula="ooow:Equation+1" style:num-format="1">1</text:sequence>: Energy')
        eq(read(dir .. "/img.png"), zip.read(path, "Images/0002.png"))
      end)
      ui.processes = saved_processes
      ok(ok_run, err)
    end)

    it("falls back to verbatim LaTeX without a converter", function()
      local _, get = export({ "#+OPTIONS: tex:dvipng-missing", "Math $x$ here." })
      has(get("content.xml"), '<text:span text:style-name="OrgCode">$x$</text:span>')
    end)

    it("honours #+ATTR_ODT on images (size, scale, anchor)", function()
      local _, get = export({
        "#+ATTR_ODT: :width 4 :height 1",
        "[[file:img.png]]",
        "",
        "#+ATTR_ODT: :scale 0.5 :anchor as-char",
        "[[file:img.png]]",
      }, dir .. "/x.org")
      local c = get("content.xml")
      -- 96x48 pixels at 96 dpi = 2.54 x 1.27 cm
      has(c, 'draw:style-name="OrgDisplayImage" svg:width="4.00cm" svg:height="1.00cm" text:anchor-type="paragraph"')
      has(c, 'draw:style-name="OrgDisplayImage" svg:width="1.27cm" svg:height="0.64cm" text:anchor-type="as-char"')
    end)

    it("uses #+ODT_STYLES_FILE and #+ODT_EXTRA_STYLES", function()
      local tmp = vim.fn.tempname()
      vim.fn.mkdir(tmp, "p")
      local styles =
        '<office:document-styles><office:styles><style:style style:name="Mine"/></office:styles></office:document-styles>'
      vim.fn.writefile({ styles }, tmp .. "/my-styles.xml")
      local _, get = export({
        '#+ODT_STYLES_FILE: "my-styles.xml"',
        '#+ODT_EXTRA_STYLES: <style:style style:name="Extra"/>',
        "Text",
      }, tmp .. "/doc.org")
      local s = get("styles.xml")
      has(s, '<style:style style:name="Mine"/>')
      has(s, '<style:style style:name="Extra"/>')
      -- members of an .ott file
      ok(zip.write(tmp .. "/t.ott", {
        { name = "mimetype", data = "application/vnd.oasis.opendocument.text-template" },
        { name = "styles.xml", data = styles },
        { name = "Pictures/logo.png", data = read(dir .. "/img.png") },
      }))
      local path, get2 =
        export({ '#+ODT_STYLES_FILE: ("t.ott" ("styles.xml" "Pictures/logo.png"))', "Text" }, tmp .. "/doc.org")
      has(get2("styles.xml"), '<style:style style:name="Mine"/>')
      eq(read(dir .. "/img.png"), get2("Pictures/logo.png"))
      has(get2("META-INF/manifest.xml"), 'manifest:media-type="image/png" manifest:full-path="Pictures/logo.png"/>')
      ok(vim.tbl_contains(
        vim.tbl_map(function(e)
          return e.name
        end, zip.list(path)),
        "Pictures/"
      ))
      -- a plain .ott: its styles.xml
      local _, get3 = export({ '#+ODT_STYLES_FILE: "t.ott"', "Text" }, tmp .. "/doc.org")
      has(get3("styles.xml"), '<style:style style:name="Mine"/>')
    end)

    it("replaces forbidden XML characters", function()
      local _, get = export({ "Bell\7 here" })
      has(get("content.xml"), "Bell here")
      config.opts.export.odt.with_forbidden_chars = "?"
      local _, get2 = export({ "Bell\7 here" })
      has(get2("content.xml"), "Bell? here")
    end)

    it("converts to the preferred output format", function()
      local tmp = vim.fn.tempname()
      vim.fn.mkdir(tmp, "p")
      config.opts.export.odt.preferred_output_format = "docx"
      config.opts.export.odt.convert_process = "fake"
      config.opts.export.odt.convert_processes = { { "fake", "cp %i %d/converted.%f" } }
      local out = tmp .. "/doc.odt"
      local res = odt.export_file({ "Text" }, {}, { output = out })
      -- the fake converter wrote converted.docx, not doc.docx: failure keeps the odt
      eq(out, res)
      config.opts.export.odt.convert_processes = { { "fake", "cp %i %o" } }
      res = odt.export_file({ "Text" }, {}, { output = out })
      eq(tmp .. "/doc.docx", res)
      eq(read(out), read(res))
      eq({ "pdf", "odt", "rtf", "ott", "doc", "docx", "html" }, odt.reachable_formats("odt"))
    end)

    it("is reachable from the export dispatcher", function()
      local tmp = vim.fn.tempname()
      vim.fn.mkdir(tmp, "p")
      local buf = org_buffer({ "* Hello", "World" })
      vim.api.nvim_buf_set_name(buf, tmp .. "/hello.org")
      local res = require("org.export").export("odt", {})
      eq(vim.fs.normalize(vim.fn.resolve(tmp .. "/hello.odt")), vim.fs.normalize(vim.fn.resolve(res)))
      has(zip.read(res, "content.xml"), "World")
      vim.bo[buf].modified = false
      vim.cmd("bwipe! " .. buf)
      local xml = require("org.export").to_string("odt", { lines = { "Hi" }, body_only = true })
      has(xml, '<text:p text:style-name="Text_20_body">Hi</text:p>')
    end)
  end)

  it("escapes quotes and angle brackets in link targets", function()
    local _, member = export({ '[[https://e.com/?a=1&b="2"<x>][link]]' })
    has(member("content.xml"), 'xlink:href="https://e.com/?a=1&amp;b=&quot;2&quot;&lt;x&gt;">link</text:a>')
  end)

  it("quotes shell arguments for sh whatever 'shell' is", function()
    if vim.fn.has("win32") == 1 then
      return
    end
    local saved = vim.o.shell
    vim.o.shell = "/usr/bin/fish"
    local arg = odt.shellescape("\\frac{a}{b} it's !x")
    vim.o.shell = saved
    eq("\\frac{a}{b} it's !x", odt.shell_command_to_string("printf %s " .. arg))
  end)
end)
