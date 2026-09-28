-- HTML source highlighting (org-html-htmlize-output-type, -font-prefix,
-- org-html-htmlize-generate-css) with tree-sitter, and htmlized Org
-- sources when publishing (org-org-htmlized-css-url).
local export = require("org.export")
local config = require("org.config")

local function has_lua_parser()
  local lib = vim.fn.fnamemodify(vim.env.VIMRUNTIME, ":h:h:h") .. "/lib/nvim"
  if vim.fn.isdirectory(lib .. "/parser") == 1 and not vim.o.rtp:find(lib, 1, true) then
    vim.opt.rtp:append(lib)
  end
  return pcall(vim.treesitter.language.add, "lua")
end

local SRC = { "#+begin_src lua", 'local x = "s"', "#+end_src", "and src_lua{return 1}" }

describe("html source highlighting", function()
  local html = config.opts.export.html
  local saved
  before_each(function()
    config.opts.babel.evaluate_on_export = false
    saved = { html.htmlize_output_type, html.htmlize_font_prefix }
  end)
  after_each(function()
    html.htmlize_output_type, html.htmlize_font_prefix = saved[1], saved[2]
    config.opts.babel.evaluate_on_export = true
  end)

  it("writes htmlize classes with output type css", function()
    if not has_lua_parser() then
      return
    end
    html.htmlize_output_type = "css"
    local out = export.to_string("html", { lines = SRC, body_only = true })
    ok(out:find('<code><span class="org-keyword">local</span> x <span class="org-operator">=</span> <span class="org-string">"s"</span>\n</code>', 1, true), out)
    ok(out:find('<code class="src src-lua"><span class="org-keyword">return</span> <span class="org-number">1</span></code>', 1, true), out)
    html.htmlize_font_prefix = "my-"
    out = export.to_string("html", { lines = SRC, body_only = true })
    ok(out:find('<span class="my-keyword">local</span>', 1, true), out)
  end)

  it("inlines the colour scheme's styles with inline-css", function()
    if not has_lua_parser() then
      return
    end
    html.htmlize_output_type = "inline-css"
    local hl = vim.api.nvim_get_hl(0, { name = "@keyword", link = false })
    local out = export.to_string("html", { lines = SRC, body_only = true })
    local specs = require("org.export.fontify").css_specs(hl)
    ok(#specs > 0)
    ok(out:find('<span style="' .. table.concat(specs, " ") .. '">local</span>', 1, true), out)
  end)

  it("leaves code plain with output type false or without a parser", function()
    html.htmlize_output_type = false
    local out = export.to_string("html", { lines = SRC, body_only = true })
    ok(out:find('<code>local x = "s"\n</code>', 1, true), out)
    html.htmlize_output_type = "css"
    out = export.to_string("html", { lines = { "#+begin_src nosuchlang", "a < b", "#+end_src" }, body_only = true })
    ok(out:find("<code>a &lt; b\n</code>", 1, true), out)
  end)

  it("prefers a user fontify function", function()
    html.fontify = function(code)
      return "[" .. code .. "]"
    end
    local out = export.to_string("html", { lines = SRC, body_only = true })
    html.fontify = nil
    ok(out:find('<code>[local x = "s"\n]</code>', 1, true) or out:find('[local x = "s"', 1, true), out)
  end)

  it("generates the stylesheet of the classes in a *html* buffer", function()
    html.htmlize_font_prefix = "org-"
    local buf = require("org.export.html").htmlize_generate_css()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    eq('<style type="text/css">', lines[1])
    eq("    <!--", lines[2])
    eq("      body {", lines[3])
    eq("</style>", lines[#lines])
    local text = table.concat(lines, "\n")
    ok(text:find("      .org-keyword {\n        /* @keyword */\n", 1, true), text)
    eq("*html*", vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":t"))
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)

describe("htmlized Org sources", function()
  it("publishes FILE.org.html, linking org-org-htmlized-css-url", function()
    local ok_tohtml = pcall(require, "tohtml") or (pcall(vim.cmd.packadd, "nvim.tohtml") and pcall(require, "tohtml"))
    if not ok_tohtml then
      return
    end
    local dir = vim.fn.tempname()
    local src, pub = dir .. "/src", dir .. "/pub"
    vim.fn.mkdir(src, "p")
    vim.fn.writefile({ "* Heading", "Some text." }, src .. "/a.org")
    local publish = require("org.export.publish")
    local org_cfg = config.opts.export.org
    org_cfg.htmlized_css_url = "style.css"
    local notify = require("org.utils").notify
    require("org.utils").notify = function() end
    local okp, err = pcall(publish.htmlize_source, { htmlized_source = true }, src .. "/a.org", pub)
    require("org.utils").notify = notify
    org_cfg.htmlized_css_url = nil
    assert(okp, err)
    local html = table.concat(vim.fn.readfile(pub .. "/a.org.html"), "\n")
    ok(html:find('<link rel="stylesheet" type="text/css" href="style.css">', 1, true), html)
    ok(not html:find("<style>", 1, true), html)
    ok(html:find("Heading", 1, true), html)
  end)
end)
