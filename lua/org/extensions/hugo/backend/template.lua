---@mod org.extensions.hugo.backend.template Hugo templates and filters
---
--- The table of contents, the footnotes section, and the options and
--- body filters (inherited options, directories, copied resources and
--- the front matter put before the body). Part of
--- org.extensions.hugo.backend, which loads it.

local ox = require("org.export.ox")
local html = require("org.export.html")
local fm = require("org.extensions.hugo.front_matter")
local shared = require("org.extensions.hugo.backend.shared")

local M = require("org.extensions.hugo.backend")

local T = M.transcoders
local fmt = shared.fmt
local nw = shared.nw
local trim = shared.trim
local TRIM_PRE = shared.TRIM_PRE
local TRIM_POST = shared.TRIM_POST
local opts = shared.opts
local truthy = shared.truthy
local todo_html = shared.todo_html
local heading_number = shared.heading_number
local copy_if_newer = shared.copy_if_newer

---------------------------------------------------------------------------
-- Templates
---------------------------------------------------------------------------

--- Table of contents (org-hugo--build-toc).
function M.build_toc(info, n, scope, localp)
  local current
  local items = {}
  for _, h in ipairs(ox.collect_headlines(info, n, scope)) do
    local raw = ox.get_relative_level(h, info)
    local level = raw
    if scope then
      current = current or raw
      level = raw - current + 1
    end
    local indent = string.rep(" ", 4 * (level - 1))
    local todo = info.with_todo_keywords and h.todo_keyword
    local todo_s = todo and (todo_html(todo, info) .. " ") or ""
    local number = heading_number(h, info, true) or ""
    local entry = fmt(
      "[%s%s](#%s)",
      todo_s,
      ox.data_with_backend(ox.get_alt_title(h), ox.toc_entry_backend("hugo"), info),
      M.anchor(h, info)
    )
    local tags = ""
    if info.with_tags and info.with_tags ~= "not-in-toc" then
      local tl = ox.get_tags(h, info)
      if #tl > 0 then
        tags = ":" .. table.concat(tl, ":") .. ":"
      end
    end
    items[#items + 1] = indent .. "- " .. number .. entry .. tags
  end
  if #items == 0 then
    return nil
  end
  local list = table.concat(items, "\n")
  local classes = { "ox-hugo-toc", "toc" }
  if list:match('^%s*%- <span class="section%-num"') or list:match('\n%s*%- <span class="section%-num"') then
    classes[#classes + 1] = "has-section-numbers"
  end
  if localp then
    classes[#classes + 1] = "local"
  end
  local heading = localp and ""
    or fmt('\n<div class="heading">%s</div>\n', ox.translate("Table of Contents", "html", info))
  return fmt('<div class="%s">\n%s\n%s\n\n</div>\n<!--endtoc-->\n', table.concat(classes, " "), heading, list)
end

--- Footnote definitions (org-blackfriday-footnote-section, Goldmark).
local function footnote_section(info)
  local defs = ox.collect_footnote_definitions(info)
  if #defs == 0 then
    return ""
  end
  local out = {}
  for _, d in ipairs(defs) do
    local def = trim(ox.data(d[3], info)):gsub("\n", "\n    ")
    out[#out + 1] = fmt("[^fn:%d]: %s", d[1], def)
  end
  return table.concat(out, "\n")
end

T.inner_template = function(contents, info)
  local level = info.with_toc
  if level and type(level) ~= "number" then
    level = info.headline_levels
  end
  local toc = ""
  if type(level) == "number" and level > 0 then
    toc = (M.build_toc(info, level) or "") .. "\n"
  end
  local c = contents or ""
  -- special blocks inside quote blocks
  local n
  repeat
    -- lint: allow gsub: TRIM_PRE is an HTML comment without %
    c, n = c:gsub("\n%s*>%s?" .. vim.pesc(TRIM_PRE), TRIM_PRE)
  until n == 0
  c = c:gsub("[%s]*" .. vim.pesc(TRIM_PRE), "\n")
  c = c:gsub(vim.pesc(TRIM_POST) .. "[%s>]+([^-#`])", " %1")
  c = c:gsub(vim.pesc(TRIM_POST), "")
  local s = toc .. c .. "\n" .. footnote_section(info)
  return (s:gsub("^%s+", ""))
end

T.template = function(contents)
  return contents
end

---------------------------------------------------------------------------
-- Filters
---------------------------------------------------------------------------

--- The options of a subtree post that it inherits from its parents (and
--- the post's own, with `PROP+` values joined), which the generic
--- environment does not see: `info.hugo_ctx.props` from the driver.
local function inherit_options(info)
  local ctx = info.hugo_ctx
  if not (ctx and ctx.props) then
    return info
  end
  local options = vim.list_extend(vim.deepcopy(ox.all_options(M.backend)), ox.global_options())
  local inherited_options = ctx.props.EXPORT_OPTIONS
  if inherited_options then
    local parsed = ox.parse_option_line(inherited_options)
    for _, o in ipairs(options) do
      if o[3] and parsed[o[3]] ~= nil then
        info[o[1]] = parsed[o[3]]
      end
    end
  end
  local seen = {}
  for _, o in ipairs(options) do
    local key = o[2]
    if key and not seen[o[1]] and o[5] ~= "parse" then
      seen[o[1]] = true
      local v = ctx.props["EXPORT_" .. key]
      if v ~= nil then
        if o[5] == "split" then
          v = vim.split(v, "%s+", { trimempty = true })
        end
        info[o[1]] = v
      end
    end
  end
  return info
end

--- Resolve the post's directories (org-hugo--get-pub-dir): it is an
--- error not to have a base dir.
local function directories(info)
  local ctx = info.hugo_ctx or {}
  local base = nw(info.hugo_base_dir)
  if not base and ctx.to_buffer then
    return info
  end
  if not base then
    error("It is mandatory to set the HUGO_BASE_DIR property or the `extensions.hugo.base_dir' option", 0)
  end
  local src_dir = info.input_file and vim.fn.fnamemodify(info.input_file, ":p:h") or vim.fn.getcwd()
  base = require("org.utils").expand(base, src_dir):gsub("/+$", "")
  info.hugo_base_dir_abs = base
  info.hugo_content_folder = nw(info.hugo_content_folder) or opts().content_folder or "content"
  local section = info.hugo_section
  if type(section) ~= "string" then
    error("It is mandatory to set the HUGO_SECTION property", 0)
  end
  -- an empty section (or "/") is the content directory itself
  section = vim.trim(section):gsub("^/+", ""):gsub("/+$", "")
  if ctx.section_frag then
    section = section .. "/" .. ctx.section_frag:gsub("^/+", ""):gsub("/+$", "")
  end
  local bundle = ctx.bundle or nw(info.hugo_bundle)
  local dir = base .. "/" .. info.hugo_content_folder .. (section ~= "" and ("/" .. section) or "")
  if bundle then
    dir = dir .. "/" .. bundle:gsub("/+$", "")
    info.hugo_bundle_dir = dir
  end
  info.hugo_pub_dir = dir
  info.hugo_section_path = section
  if not ctx.to_buffer then
    -- like ox-hugo, the post's directory exists before the body is written
    -- (files linked from it are copied into a bundle)
    vim.fn.mkdir(dir, "p")
  end
  return info
end

local function options_filter(info)
  info = inherit_options(info)
  info.hugo_index = info.hugo_ctx and info.hugo_ctx.index or nil
  return directories(info)
end

--- Copy the files of HUGO_RESOURCES `:src` into the bundle
--- (org-hugo--copy-resources-maybe).
local function copy_resources(info)
  local bundle = info.hugo_bundle_dir
  if not bundle or not nw(info.hugo_resources) then
    return
  end
  local src_dir = info.input_file and vim.fn.fnamemodify(info.input_file, ":p:h") or vim.fn.getcwd()
  for _, kv in ipairs(fm.parse_arguments(info.hugo_resources)) do
    if kv[1] == "src" and type(kv[2]) == "string" then
      -- (document text: utils.glob, never vim.fn.glob(), which runs `backticks`)
      for _, f in ipairs(require("org.utils").glob(src_dir .. "/" .. kv[2])) do
        local ext = vim.fn.fnamemodify(f, ":e"):lower()
        if vim.tbl_contains(opts().copy_extensions or {}, ext) then
          local rel = f:sub(#src_dir + 2)
          copy_if_newer(f, bundle .. "/" .. rel)
        end
      end
    end
  end
end

local function body_filter(body, _, info)
  copy_resources(info)
  if truthy(info.hugo_delete_trailing_ws) and not info.preserve_breaks then
    body = body:gsub("[ \t]+\n", "\n"):gsub("[ \t]+$", ""):gsub("\n+$", "\n")
  end
  local front = require("org.extensions.hugo.export").front_matter(info)
  local extra = info.hugo_fm_extra
  if nw(extra) then
    front = front:gsub("(%+%+%+\n*)$", function(m)
      return extra .. m
    end, 1)
    if not front:find(vim.pesc(extra), 1, true) then
      front = front:gsub("(%-%-%-\n*)$", function(m)
        return extra .. m
      end, 1)
    end
  end
  local footer = opts().footer or ""
  body = nw(body) and ("\n" .. body:gsub("\n+$", "") .. "\n") or ""
  return front .. body .. footer
end

shared.body_filter = body_filter
shared.options_filter = options_filter
