-- Build the documentation website into a directory (default: site/).
--
--   nvim --headless --clean -l scripts/site/build.lua [outdir]
--
-- (`make site` runs it with a throwaway XDG_DATA_HOME.) Sources, never
-- copied by hand:
--   doc/org.txt          → manual/<chapter tag>.html (vimdoc → HTML)
--   README.md            → index.html
--   examples/*.org       → examples/<name>.html, exported by org.nvim's own
--                          HTML exporter (body only, no Babel evaluation)
--   docs/parity-review.md, docs/parity/inventory.tsv → parity/
--   tutor/org/*.org, docs/playground/*.cast → playground.html, the tutor
--                          lessons' recordings (scripts/site/playground.lua)
-- plus a search index (search-index.js) and scripts/site/assets/. Every
-- internal link and #anchor of the result is checked; a broken one fails
-- the build.
--
-- The output directory (relative to the checkout) is emptied first, so it
-- must be new, empty or one a build made; anything else, the checkout
-- above all, is refused before a file is touched (scripts/site/outdir.lua).
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
package.path = root .. "/scripts/?.lua;" .. package.path
vim.opt.rtp:prepend(root)

local html = require("site.html")
local vimdoc = require("site.vimdoc")
local markdown = require("site.markdown")
local site_dir = require("site.outdir")

local REPO = "xheisenbugx/org.nvim"
local GITHUB = "https://github.com/" .. REPO
-- the ref links to repository files point at: releases deploy from main
local REF = vim.env.ORG_SITE_REF or "main"
local NVIM_HELP = "https://neovim.io/doc/user/helptag.html?tag="
local LOGO = "https://raw.githubusercontent.com/" .. REPO .. "/media/logo.png"

--- Stop the build: the output directory can't be used.
local function refuse(why)
  io.stderr:write("site: " .. why .. "\n")
  os.exit(2)
end

-- (checked before the build, which takes a while, and again before the
-- directory is emptied)
local outdir_arg = _G.arg and _G.arg[1]
if outdir_arg == nil then
  outdir_arg = "site"
end
local outdir, why = site_dir.check(outdir_arg, root)
if not outdir then
  return refuse(why)
end

local errors = {}
local function err(fmt, ...)
  errors[#errors + 1] = string.format(fmt, ...)
end

local function read(path)
  return vim.fn.readfile(root .. "/" .. path)
end

local function exists(path)
  return vim.uv.fs_stat(root .. "/" .. path) ~= nil
end

local function blob(path, frag)
  return GITHUB .. "/blob/" .. REF .. "/" .. path .. (frag or "")
end

--- `to` (a site path) relative to the directory of the site page `from`.
local function rel(from, to)
  local depth = select(2, from:gsub("/", ""))
  return string.rep("../", depth) .. to
end

--- Normalise "a/b/../c" and "./x".
local function normpath(p)
  local parts = {}
  for seg in p:gmatch("[^/]+") do
    if seg == ".." then
      parts[#parts] = nil
    elseif seg ~= "." then
      parts[#parts + 1] = seg
    end
  end
  return table.concat(parts, "/")
end

-- Pages -----------------------------------------------------------------------

local pages = {} -- { path, title, body, section, source }
local by_path = {}
local search = {}

local function add_page(p)
  pages[#pages + 1] = p
  by_path[p.path] = p
  return p
end

local function add_search(title, url, section, kind)
  search[#search + 1] = { t = title, u = url, s = section, k = kind }
end

-- The manual ------------------------------------------------------------------

local manual_lines = read("doc/org.txt")
local chapters = vimdoc.split(manual_lines)
local tag_page = {}
local all_tags = {}
for _, ch in ipairs(chapters) do
  for _, t in ipairs(vimdoc.tags(ch.lines)) do
    tag_page[t] = ch.name
    all_tags[t] = true
  end
end

local vim_tags = {}
for _, line in ipairs(vim.fn.readfile(vim.env.VIMRUNTIME .. "/doc/tags")) do
  local t = line:match("^([^\t]+)\t")
  if t then
    vim_tags[t] = true
  end
end

-- first line of each chapter in doc/org.txt, for "view source" links
do
  local k = 1
  for lnum, line in ipairs(manual_lines) do
    local ch = chapters[k + 1]
    if ch and line:find("*" .. ch.name .. "*", 1, true) and manual_lines[lnum - 1]:match("^[=-]+$") then
      ch.lnum = lnum - 1
      k = k + 1
    end
  end
  chapters[1].lnum = 1
end

for _, ch in ipairs(chapters) do
  local path = "manual/" .. ch.name .. ".html"
  local section = ch.name == "index" and "Manual" or ch.title
  local body = vimdoc.render(ch.lines, {
    title = ch.name == "index" and "org.nvim manual" or ch.title,
    header = ch.name ~= "index",
    tags = all_tags,
    slugs = {},
    link = function(tag)
      local page = tag_page[tag]
      if page then
        if page == ch.name and tag ~= ch.name then
          return "#" .. html.urlencode(tag)
        end
        return page .. ".html" .. (tag == page and "" or ("#" .. html.urlencode(tag)))
      elseif vim_tags[tag] then
        return NVIM_HELP .. html.urlencode(tag)
      end
      err("doc/org.txt: |%s| (in %s) is neither an org.nvim nor a Neovim help tag", tag, ch.name)
    end,
    on_tag = function(tag, heading)
      add_search(tag, path .. (tag == ch.name and "" or ("#" .. html.urlencode(tag))), heading or section, "tag")
    end,
    on_heading = function(id, text)
      if ch.name ~= "index" then
        add_search(text, path .. "#" .. id, section, "heading")
      end
    end,
  })
  if ch.name ~= "index" then
    add_search(ch.title, path, ch.parent and "Manual: Extensions" or "Manual", "page")
  end
  if ch.name == "org-config" then
    -- the option tables: an anchor and a search entry per option
    local seen = {}
    body = body:gsub("([\n>])  ([%a][%w_]*)(%s%s+)", function(before, opt, gap)
      if seen[opt] or all_tags[opt] then
        return nil
      end
      seen[opt] = true
      add_search(opt, path .. "#opt-" .. opt, "Configuration reference", "option")
      return before .. '  <span class="opt" id="opt-' .. opt .. '">' .. opt .. "</span>" .. gap
    end)
  end
  if ch.name == "index" then
    -- a contents page instead of the help file's title lines: keep their
    -- tags as anchors
    local b = {}
    for _, t in ipairs(vimdoc.tags(ch.lines)) do
      b[#b + 1] = '<span id="' .. html.escape(t) .. '"></span>'
    end
    b[#b + 1] = "<h1>org.nvim manual</h1>"
    b[#b + 1] = '<p class="lead">The user manual, also available in Neovim as <code>:h org</code>. '
      .. "Press <kbd>/</kbd> to search every help tag and heading.</p>"
    b[#b + 1] = '<ol class="contents">'
    for k = 2, #chapters do
      local c = chapters[k]
      if not c.parent then
        local subs = {}
        for _, sub in ipairs(chapters) do
          if sub.parent == c.name then
            subs[#subs + 1] = '<li><a href="' .. sub.name .. '.html">' .. html.escape(sub.title) .. "</a></li>"
          end
        end
        b[#b + 1] = '<li><a href="'
          .. c.name
          .. '.html">'
          .. html.escape(c.title)
          .. "</a>"
          .. (#subs > 0 and ("<ul>" .. table.concat(subs) .. "</ul>") or "")
          .. "</li>"
      end
    end
    b[#b + 1] = "</ol>"
    body = table.concat(b, "\n")
  end
  add_page({
    path = path,
    title = ch.name == "index" and "Manual" or ch.title,
    body = body,
    group = "manual",
    parent = ch.parent,
    source = blob("doc/org.txt", "#L" .. (ch.lnum or 1)),
  })
end

-- Markdown sources --------------------------------------------------------------

-- repository file → site page
local SITE_MAP = {
  ["README.md"] = "index.html",
  ["doc/org.txt"] = "manual/index.html",
  ["docs/parity-review.md"] = "parity/review.html",
  ["docs/parity/inventory.tsv"] = "parity/index.html",
}
for _, f in ipairs(vim.fn.glob(root .. "/examples/*.org", false, true)) do
  local name = vim.fn.fnamemodify(f, ":t:r")
  SITE_MAP["examples/" .. name .. ".org"] = "examples/" .. name .. ".html"
end

--- Rewrite a link found in the repository file `src` for the site page `page`.
local function rewrite_link(href, src, page)
  -- a link to the website itself (README.md) stays on the site
  local site_path = href:match("^https://org%-nvim%.com/(.*)$")
  if site_path then
    local p, frag = site_path:match("^([^#]*)(#?.*)$")
    return rel(page, p == "" and "index.html" or p) .. frag
  end
  if href:match("^%a[%w+.-]*:") or href:match("^#") or href:match("^//") or href == "" then
    return href
  end
  local path, frag = href:match("^([^#]*)(#?.*)$")
  local target = normpath(vim.fn.fnamemodify(src, ":h") .. "/" .. path)
  if vim.fn.fnamemodify(src, ":h") == "." then
    target = normpath(path)
  end
  if SITE_MAP[target] then
    return rel(page, SITE_MAP[target]) .. frag
  end
  if not exists(target) then
    err("%s: link to %s, which doesn't exist", src, href)
  end
  return blob(target, frag)
end

--- Rewrite the href and src attributes of an HTML tag.
local function rewrite_attrs(tag, src, page)
  for _, attr in ipairs({ "href", "src" }) do
    tag = tag:gsub("(%s" .. attr .. '=")([^"]*)(")', function(a, v, b)
      return a .. html.escape(rewrite_link(html.unescape(v), src, page)) .. b
    end)
  end
  return tag
end

local function markdown_page(src, path, title, group)
  local section = title
  local body = markdown.render(read(src), {
    link = function(href)
      return rewrite_link(href, src, path)
    end,
    rewrite_html = function(tag)
      return rewrite_attrs(tag, src, path)
    end,
    -- `:h org-agenda` links to the manual
    code = function(text)
      local tag = text:match("^:h%s+(%S+)$")
      if tag and tag_page[tag] then
        local href = "manual/" .. tag_page[tag] .. ".html"
        if tag ~= tag_page[tag] then
          href = href .. "#" .. html.urlencode(tag)
        end
        return '<a href="' .. rel(path, href) .. '"><code>' .. html.escape(text) .. "</code></a>"
      end
    end,
    on_heading = function(id, text, level)
      if level > 1 then
        add_search(text, path .. "#" .. id, section, "heading")
      end
    end,
  })
  return add_page({ path = path, title = title, body = body, group = group, source = blob(src) })
end

markdown_page("README.md", "index.html", "Home", "home")
markdown_page("docs/parity-review.md", "parity/review.html", "Parity reviews", "parity")

-- Parity scorecard ----------------------------------------------------------------

-- The areas and formula of docs/parity/score.sh.
local function parity_area(f)
  if f == "org-agenda" or f == "org-habit" then
    return "Agenda"
  elseif f == "org-table" or f == "org-plot" then
    return "Tables"
  elseif f == "org-colview" then
    return "Column view"
  elseif f == "org-list" then
    return "Lists"
  elseif f == "org-clock" or f == "org-timer" then
    return "Clocking"
  elseif f == "org-capture" or f == "org-datetree" then
    return "Capture"
  elseif f == "org-refile" or f == "org-archive" then
    return "Refile/archive"
  elseif
    f:match("^org%-attach")
    or vim.tbl_contains({ "org-id", "org-crypt", "org-footnote", "org-lint", "org-ctags", "org-protocol" }, f)
  then
    return "Attach/ID/misc"
  elseif f == "org-mobile" or f == "org-feed" then
    return "Feeds/MobileOrg"
  elseif f:match("^ol") then
    return "Links"
  elseif f:match("^ob") or f == "org-src" then
    return "Babel/src"
  elseif f:match("^oc") then
    return "Citations"
  elseif f:match("^ox") then
    return "Export"
  end
  return "Core"
end

local function score(file)
  local areas, all, rows = {}, { n = 0 }, {}
  for _, line in ipairs(read(file)) do
    local f = vim.split(line, "\t", { plain = true })
    if #f >= 4 then
      local a = parity_area(f[1])
      areas[a] = areas[a] or { n = 0 }
      for _, t in ipairs({ areas[a], all }) do
        t.n = t.n + 1
        t[f[4]] = (t[f[4]] or 0) + 1
      end
      rows[#rows + 1] = { area = a, lib = f[1], sym = f[2], kind = f[3], status = f[4], note = f[6] or "" }
    end
  end
  return areas, all, rows
end

local function pct(t, strict)
  local s = (t.done or 0) + (t.vim or 0) + 0.5 * (t.partial or 0)
  local d = t.n - (t.na or 0) - (strict and 0 or (t["emacs-only"] or 0))
  return d > 0 and string.format("%.1f%%", 100 * s / d) or "–"
end

do
  local areas, all, rows = score("docs/parity/inventory.tsv")
  local names = vim.tbl_keys(areas)
  table.sort(names)
  local cols = { "done", "vim", "partial", "missing", "emacs-only", "na" }
  local function row(name, t, tag)
    local cells = { "<" .. tag .. ">" .. html.escape(name) .. "</" .. tag .. ">", "<td>" .. t.n .. "</td>" }
    for _, c in ipairs(cols) do
      cells[#cells + 1] = "<td>" .. (t[c] or 0) .. "</td>"
    end
    cells[#cells + 1] = "<td><strong>" .. pct(t) .. "</strong></td><td>" .. pct(t, true) .. "</td>"
    return "<tr>" .. table.concat(cells) .. "</tr>"
  end
  local b = {
    "<h1>Parity with Emacs Org 9.8.10</h1>",
    '<p class="lead">Every interactive command and user option of Org 9.8.10 is listed in '
      .. '<a href="'
      .. blob("docs/parity/inventory.tsv")
      .. '"><code>docs/parity/inventory.tsv</code></a> with its status in org.nvim. '
      .. "This page is generated from that file with the formula of "
      .. '<a href="'
      .. blob("docs/parity/score.sh")
      .. '"><code>docs/parity/score.sh</code></a>.</p>',
    '<div class="scorecard"><div class="big">'
      .. pct(all)
      .. '</div><div>overall parity<br><span class="muted">'
      .. pct(all, true)
      .. " counting Emacs-only features</span></div></div>",
    "<ul>",
    "<li><strong>done</strong>: implemented; <strong>vim</strong>: stock Neovim covers it; "
      .. "<strong>partial</strong> counts half; <strong>missing</strong>: not there yet.</li>",
    "<li><strong>emacs-only</strong>: only makes sense inside Emacs (left out of the overall score, "
      .. "counted in the strict one); <strong>na</strong>: Emacs internals, not counted.</li>",
    "</ul>",
    '<div class="table-wrap"><table class="numeric">',
    "<thead><tr><th>Area</th><th>Total</th><th>Done</th><th>Vim</th><th>Partial</th><th>Missing</th>"
      .. "<th>Emacs-only</th><th>N/A</th><th>Overall</th><th>Strict</th></tr></thead><tbody>",
  }
  for _, a in ipairs(names) do
    b[#b + 1] = row(a, areas[a], "td")
  end
  b[#b + 1] = "</tbody><tfoot>" .. row("All", all, "th") .. "</tfoot></table></div>"
  for _, status in ipairs({ "missing", "partial", "emacs-only" }) do
    local list = vim.tbl_filter(function(r)
      return r.status == status
    end, rows)
    if #list > 0 then
      local id = "status-" .. status
      b[#b + 1] = '<h2 id="' .. id .. '">' .. status:gsub("^%l", string.upper) .. " (" .. #list .. ")</h2>"
      add_search(
        status:gsub("^%l", string.upper) .. " commands and options",
        "parity/index.html#" .. id,
        "Parity",
        "heading"
      )
      b[#b + 1] =
        '<div class="table-wrap"><table><thead><tr><th>Symbol</th><th>Kind</th><th>Area</th><th>Note</th></tr></thead><tbody>'
      for _, r in ipairs(list) do
        b[#b + 1] = "<tr><td><code>"
          .. html.escape(r.sym)
          .. "</code></td><td>"
          .. (r.kind == "cmd" and "command" or "option")
          .. "</td><td>"
          .. html.escape(r.area)
          .. "</td><td>"
          .. html.escape(r.note)
          .. "</td></tr>"
      end
      b[#b + 1] = "</tbody></table></div>"
    end
  end
  b[#b + 1] = '<p>See also the <a href="review.html">parity reviews</a>, and '
    .. '<a href="../manual/org-differences.html">Differences from Emacs</a> in the manual.</p>'
  add_page({
    path = "parity/index.html",
    title = "Parity scorecard",
    body = table.concat(b, "\n"),
    group = "parity",
    source = blob("docs/parity/inventory.tsv"),
  })
end

-- Examples (exported with org.nvim) -------------------------------------------------

require("org").setup({
  export = { with_broken_links = "mark", with_sub_superscripts = "{}" },
})
require("org.config").opts.babel.evaluate_on_export = false
local ox = require("org.export.ox")

--- Export an example to HTML. Exercises leave some footnotes undefined on
--- purpose: those get a placeholder definition rather than failing.
local function export_example(file)
  local lines = read(file)
  -- quiet: "Reference ... cannot be resolved without publishing"
  local utils = require("org.utils")
  local notify = utils.notify
  utils.notify = function() end
  local ok, res = pcall(function()
    for _ = 1, 20 do
      local done, out = pcall(ox.export_as, "html", lines, { filename = root .. "/" .. file, body_only = true })
      if done then
        return out
      end
      local label = tostring(out):match("^Definition not found for footnote (%S+)")
      if not label then
        error(file .. ": " .. tostring(out), 0)
      end
      lines =
        vim.list_extend(vim.deepcopy(lines), { "", "[fn:" .. label .. "] (Defined in an exercise of this file.)" })
    end
    error(file .. ": too many undefined footnotes", 0)
  end)
  utils.notify = notify
  if not ok then
    error(res, 0)
  end
  return res
end

local example_files = vim.fn.glob(root .. "/examples/*.org", false, true)
table.sort(example_files, function(a, b)
  -- the tour first, then the numbered files
  local ta, tb = a:match("tutorial%.org$"), b:match("tutorial%.org$")
  if ta or tb then
    return ta ~= nil and tb == nil
  end
  return a < b
end)

for _, abs in ipairs(example_files) do
  local name = vim.fn.fnamemodify(abs, ":t:r")
  local src = "examples/" .. name .. ".org"
  local path = "examples/" .. name .. ".html"
  local title = name
  for _, l in ipairs(read(src)) do
    local t = l:match("^#%+[Tt][Ii][Tt][Ll][Ee]:%s*(.-)%s*$")
    if t then
      title = t
      break
    end
  end
  local body = export_example(src)
  -- highlight source blocks
  body = body:gsub('<pre class="src src%-([%w_%-]+)"><code>(.-)</code></pre>', function(lang, code)
    if code:find("<", 1, true) then
      return nil -- holds markup already (coderef anchors)
    end
    return '<pre class="src src-' .. lang .. '"><code>' .. html.highlight(html.unescape(code), lang) .. "</code></pre>"
  end)
  -- links: other examples stay on the site, other files go to GitHub
  body = body:gsub("(<[%a][^<>]*>)", function(tag)
    if not tag:find("href=", 1, true) and not tag:find("src=", 1, true) then
      return tag
    end
    for _, attr in ipairs({ "href", "src" }) do
      tag = tag:gsub("(%s" .. attr .. '=")([^"]*)(")', function(a, v, b)
        v = html.unescape(v)
        if v:match("^%a[%w+.-]*:") or v:match("^#") or v == "" then
          return a .. html.escape(v) .. b
        end
        local p, frag = v:match("^([^#]*)(#?.*)$")
        local target = normpath("examples/" .. p)
        if by_path[target] or (target:match("%.html$") and SITE_MAP[target:gsub("%.html$", ".org")]) then
          -- a heading the exporter couldn't find in another file (it
          -- resolves those only when publishing): link to the page
          if frag == "#MissingReference" then
            v = p ~= "" and p or "#"
          end
          return a .. html.escape(v) .. b
        end
        if SITE_MAP[target] then
          return a .. html.escape(rel(path, SITE_MAP[target]) .. frag) .. b
        end
        if exists(target) then
          local url = attr == "src" and ("https://raw.githubusercontent.com/" .. REPO .. "/" .. REF .. "/" .. target)
            or blob(target, frag)
          return a .. html.escape(url) .. b
        end
        -- a file an exercise creates (or a deliberately broken link): not
        -- part of the site
        return a .. "#" .. b .. ' data-missing="' .. html.escape(v) .. '"'
      end)
    end
    return tag
  end)
  -- the h1 and the search entries
  body = "<h1>" .. html.escape(title) .. "</h1>\n" .. body
  add_search(title, path, "Examples", "page")
  for id, text in body:gmatch('<h[2-6] id="([^"]+)">(.-)</h[2-6]>') do
    text = html.unescape(text:gsub("<[^>]+>", ""):gsub("^[%d.]+%s+", ""))
    add_search(text, path .. "#" .. id, title, "heading")
  end
  add_page({ path = path, title = title, body = body, group = "examples", source = blob(src) })
end

-- Playground (the tutor lessons' recordings) ---------------------------------------

local playground_files
do
  local pg = require("site.playground").build(root, { err = err, blob = blob })
  playground_files = pg.files
  add_page({
    path = "playground.html",
    title = "Playground",
    body = pg.body,
    group = "playground",
    source = blob("scripts/playground/record.lua"),
    scripts = { "assets/playground.js" },
  })
  add_search("Playground", "playground.html", "Try org.nvim in your browser", "page")
  add_search("Try the syntax", "playground.html#try-the-syntax", "Playground", "heading")
end

-- Navigation ------------------------------------------------------------------------

local function nav_html(page)
  local function item(p, label, cls)
    local current = p.path == page.path and ' aria-current="page"' or ""
    return '<li class="'
      .. (cls or "")
      .. '"><a href="'
      .. rel(page.path, p.path)
      .. '"'
      .. current
      .. ">"
      .. html.escape(label or p.title)
      .. "</a></li>"
  end
  local out = { "<ul>", item(by_path["index.html"], "Home"), item(by_path["playground.html"], "Playground") }
  local function group(title, key, filter)
    local open = page.group == key and " open" or ""
    out[#out + 1] = '<li><details class="group"' .. open .. "><summary>" .. title .. "</summary><ul>"
    for _, p in ipairs(pages) do
      if p.group == key and (not filter or filter(p)) then
        out[#out + 1] = item(p, p.path:match("/index%.html$") and "Contents" or nil, p.parent and "sub" or nil)
      end
    end
    out[#out + 1] = "</ul></details></li>"
  end
  group("Manual", "manual")
  group("Examples", "examples")
  group("Parity", "parity")
  out[#out + 1] = '<li><a href="' .. GITHUB .. '">GitHub</a></li>'
  out[#out + 1] = '<li><a href="' .. GITHUB .. '/releases">Releases</a></li>'
  out[#out + 1] = "</ul>"
  return table.concat(out, "\n")
end

local function pager(page)
  local seq = vim.tbl_filter(function(p)
    return p.group == page.group
  end, pages)
  for k, p in ipairs(seq) do
    if p == page then
      local out = {}
      if seq[k - 1] then
        out[#out + 1] = '<a class="prev" href="'
          .. rel(page.path, seq[k - 1].path)
          .. '"><span>Previous</span>'
          .. html.escape(seq[k - 1].title)
          .. "</a>"
      end
      if seq[k + 1] then
        out[#out + 1] = '<a class="next" href="'
          .. rel(page.path, seq[k + 1].path)
          .. '"><span>Next</span>'
          .. html.escape(seq[k + 1].title)
          .. "</a>"
      end
      return #out > 0 and ('<nav class="pager">' .. table.concat(out) .. "</nav>") or ""
    end
  end
  return ""
end

local ICONS = {
  github = '<svg viewBox="0 0 16 16" width="20" height="20" aria-hidden="true"><path fill="currentColor" d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z"/></svg>',
  theme = '<svg viewBox="0 0 24 24" width="20" height="20" aria-hidden="true"><path fill="currentColor" d="M12 3a9 9 0 1 0 0 18V3z"/><circle cx="12" cy="12" r="8.25" fill="none" stroke="currentColor" stroke-width="1.5"/></svg>',
  menu = '<svg viewBox="0 0 24 24" width="22" height="22" aria-hidden="true"><path fill="currentColor" d="M3 6h18v2H3zm0 5h18v2H3zm0 5h18v2H3z"/></svg>',
}

local function render_page(page)
  local r = rel(page.path, "")
  return table.concat({
    "<!doctype html>",
    '<html lang="en">',
    "<head>",
    '<meta charset="utf-8">',
    '<meta name="viewport" content="width=device-width, initial-scale=1">',
    "<title>"
      .. (page.path == "index.html" and "org.nvim: Emacs Org mode for Neovim" or (html.escape(page.title) .. " · org.nvim"))
      .. "</title>",
    '<meta name="description" content="org.nvim: Emacs Org mode for Neovim, in pure Lua.">',
    '<link rel="icon" href="' .. LOGO .. '">',
    '<link rel="stylesheet" href="' .. r .. 'assets/site.css">',
    "<script>try{var t=localStorage.getItem('org-theme');if(t)document.documentElement.dataset.theme=t}catch(e){}</script>",
    '<script src="' .. r .. 'assets/site.js" defer></script>',
    table.concat(
      vim.tbl_map(function(src)
        return '<script src="' .. r .. src .. '" defer></script>'
      end, page.scripts or {}),
      "\n"
    ),
    "</head>",
    '<body data-root="' .. r .. '">',
    '<a class="skip" href="#content">Skip to content</a>',
    '<header class="topbar">',
    '<button class="icon menu" type="button" aria-label="Menu" aria-controls="sidebar" aria-expanded="false">'
      .. ICONS.menu
      .. "</button>",
    '<a class="brand" href="'
      .. r
      .. 'index.html"><img src="'
      .. LOGO
      .. '" alt="" width="28" height="28">org.nvim</a>',
    '<div class="search" role="search"><input id="search" type="search" placeholder="Search the docs  ( / )" '
      .. 'autocomplete="off" spellcheck="false" aria-label="Search" aria-controls="search-results">'
      .. '<ul id="search-results" role="listbox" hidden></ul></div>',
    '<button class="icon theme" type="button" aria-label="Toggle dark mode" title="Toggle dark mode">'
      .. ICONS.theme
      .. "</button>",
    '<a class="icon" href="' .. GITHUB .. '" aria-label="org.nvim on GitHub" title="GitHub">' .. ICONS.github .. "</a>",
    "</header>",
    '<div class="layout">',
    '<nav class="sidebar" id="sidebar" aria-label="Site">' .. nav_html(page) .. "</nav>",
    '<main id="content" class="content ' .. page.group .. '">',
    "<article>",
    page.body,
    "</article>",
    pager(page),
    '<footer><a href="' .. page.source .. '">View source on GitHub</a> · org.nvim is MIT licensed.</footer>',
    "</main>",
    "</div>",
    "</body>",
    "</html>",
    "",
  }, "\n")
end

-- Write -----------------------------------------------------------------------------

outdir, why = site_dir.prepare(outdir, root)
if not outdir then
  return refuse(why)
end
local written = {}
local function write(path, text)
  local full = outdir .. "/" .. path
  vim.fn.mkdir(vim.fn.fnamemodify(full, ":h"), "p")
  local f = assert(io.open(full, "wb"))
  f:write(text)
  f:close()
  written[path] = text
end

for _, p in ipairs(pages) do
  write(p.path, render_page(p))
end
for _, f in ipairs(vim.fn.glob(root .. "/scripts/site/assets/*", false, true)) do
  local name = vim.fn.fnamemodify(f, ":t")
  local fh = assert(io.open(f, "rb"))
  write("assets/" .. name, fh:read("*a"))
  fh:close()
end
for path, text in pairs(playground_files) do
  write(path, text)
end
write("search-index.js", "window.ORG_SEARCH=" .. vim.json.encode(search) .. ";\n")
write(".nojekyll", "")

-- Check links -------------------------------------------------------------------------

local ids = {}
for path, text in pairs(written) do
  if path:match("%.html$") then
    local set = {}
    for id in text:gmatch('%sid="([^"]*)"') do
      set[html.unescape(id)] = true
    end
    for id in text:gmatch('%sname="([^"]*)"') do
      set[html.unescape(id)] = true
    end
    ids[path] = set
  end
end
local checked = 0
for path, text in pairs(written) do
  if path:match("%.html$") then
    for v in text:gmatch('%shref="([^"]*)"') do
      v = html.unescape(v)
      if not v:match("^%a[%w+.-]*:") and not v:match("^//") then
        checked = checked + 1
        local p, frag = v:match("^([^#]*)#?(.*)$")
        local target = p == "" and path or normpath(vim.fn.fnamemodify(path, ":h") .. "/" .. p)
        if vim.fn.fnamemodify(path, ":h") == "." and p ~= "" then
          target = normpath(p)
        end
        if not written[target] then
          err("%s: broken link %s", path, v)
        elseif frag ~= "" and target:match("%.html$") and not ids[target][html.urldecode(frag)] then
          err("%s: link %s: no #%s in %s", path, v, html.urldecode(frag), target)
        end
      end
    end
    for v in text:gmatch('%ssrc="([^"]*)"') do
      if not v:match("^%a[%w+.-]*:") and not v:match("^//") then
        local target = normpath(vim.fn.fnamemodify(path, ":h") .. "/" .. html.unescape(v))
        if not written[target] then
          err("%s: missing file %s", path, v)
        end
      end
    end
  end
end

for _, e in ipairs(search) do
  local p, frag = e.u:match("^([^#]*)#?(.*)$")
  if not written[p] or (frag ~= "" and not ids[p][html.urldecode(frag)]) then
    err("search index: %s (%s) points nowhere", e.u, e.t)
  end
end

local npages = #pages
print(
  string.format(
    "site: %d pages, %d search entries, %d internal links checked → %s",
    npages,
    #search,
    checked,
    vim.fn.fnamemodify(outdir, ":~:.")
  )
)
if #errors > 0 then
  io.stderr:write(table.concat(errors, "\n") .. "\n")
  io.stderr:write(#errors .. " problem(s)\n")
  os.exit(1)
end
