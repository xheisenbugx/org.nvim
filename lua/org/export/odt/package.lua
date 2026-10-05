---@mod org.export.odt.package ODT packaging
---
--- meta.xml, styles.xml, the manifest and the package entries.
---
--- Part of org.export.odt, which loads it.

local ox = require("org.export.ox")
local zip = require("org.export.zip")
local shared = require("org.export.odt.shared")

local M = require("org.export.odt")

local fmt = string.format
local nw = ox.nw
local trim = ox.trim

local read_file = shared.read_file
local state = shared.state
local manifest_entry = shared.manifest_entry
local encode = shared.encode
local strip_tags = shared.strip_tags
local MEDIA = shared.MEDIA
local expand_path = shared.expand_path
local format_timestamp = shared.format_timestamp
local insert_before = shared.insert_before

---------------------------------------------------------------------------
-- Package: meta.xml, styles.xml, manifest, zip
---------------------------------------------------------------------------

local function xml_text(s)
  return encode(strip_tags(s or ""), true)
end

--- meta.xml (written by org-odt-template in Emacs).
function M.meta_xml(info)
  local title = ox.data(info.title, info)
  local subtitle = ox.data(info.subtitle, info)
  local author = info.author and ox.data(info.author, info) or ""
  local out = {
    [[<?xml version="1.0" encoding="UTF-8"?>
     <office:document-meta
         xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
         xmlns:xlink="http://www.w3.org/1999/xlink"
         xmlns:dc="http://purl.org/dc/elements/1.1/"
         xmlns:meta="urn:oasis:names:tc:opendocument:xmlns:meta:1.0"
         xmlns:ooo="http://openoffice.org/2004/office"
         office:version="1.2">
       <office:meta>
]],
    fmt("<dc:creator>%s</dc:creator>\n", xml_text(author)),
    fmt("<meta:initial-creator>%s</meta:initial-creator>\n", xml_text(author)),
  }
  if info.with_date then
    local date = info.date
    local ts = (type(date) == "table" and #date == 1 and date[1].type == "timestamp") and date[1] or nil
    local iso = format_timestamp(ts, nil, true)
    out[#out + 1] = fmt("<dc:date>%s</dc:date>\n", iso)
    out[#out + 1] = fmt("<meta:creation-date>%s</meta:creation-date>\n", iso)
  end
  out[#out + 1] = fmt("<meta:generator>%s</meta:generator>\n", xml_text(info.creator or ""))
  out[#out + 1] = fmt("<meta:keyword>%s</meta:keyword>\n", xml_text(info.keywords_meta or ""))
  out[#out + 1] = fmt("<dc:subject>%s</dc:subject>\n", xml_text(info.description or ""))
  out[#out + 1] = fmt("<dc:title>%s</dc:title>\n", xml_text(title))
  if nw(subtitle) then
    out[#out + 1] = fmt('<meta:user-defined meta:name="subtitle">%s</meta:user-defined>\n', xml_text(subtitle))
  end
  out[#out + 1] = "\n  </office:meta>\n</office:document-meta>"
  return table.concat(out)
end

--- The styles file specification: nil (factory styles), a path to a
--- styles.xml, .odt or .ott file, or { file, { members } }.
local function styles_spec(info)
  local spec = info.odt_styles_file
  if type(spec) == "string" then
    spec = trim(spec)
    if spec == "" then
      return nil
    end
    if spec:match("^%(.*%)$") then
      local v = ox.read_sexp(spec)
      if type(v) ~= "table" or type(v[1]) ~= "string" then
        error("Invalid styles file specification: " .. spec, 0)
      end
      return { v[1], type(v[2]) == "table" and v[2] or {} }
    end
    return (spec:gsub('^"(.*)"$', "%1"))
  end
  return spec
end

--- styles.xml and the extra package members of the styles file.
function M.styles_xml(info)
  local spec = styles_spec(info)
  local styles
  local extra = {}
  if spec == nil or spec == false then
    styles = read_file(M.styles_dir() .. "OrgOdtStyles.xml")
    if not styles then
      error("Missing styles file", 0)
    end
  elseif type(spec) == "table" then
    local archive = expand_path(spec[1], info)
    for _, member in ipairs(spec[2] or {}) do
      local data, err = zip.read(archive, member)
      if not data then
        error(err, 0)
      end
      if member == "styles.xml" then
        styles = data
      else
        extra[#extra + 1] = { name = member, data = data }
        local ext = (member:match("%.([%w]+)$") or ""):lower()
        if vim.tbl_contains({ "png", "jpg", "jpeg", "gif", "svg", "bmp", "tif", "tiff", "webp" }, ext) then
          manifest_entry(info, "image/" .. (MEDIA[ext] or ext), member)
        end
      end
    end
    if not styles then
      error("styles.xml must be one of the members of " .. spec[1], 0)
    end
  else
    local file = expand_path(spec, info)
    if vim.fn.filereadable(file) == 0 then
      error("Invalid specification of styles.xml file: " .. tostring(info.odt_styles_file), 0)
    end
    local ext = (file:match("%.([%w]+)$") or ""):lower()
    if ext == "xml" then
      styles = read_file(file)
    elseif ext == "odt" or ext == "ott" then
      local err
      styles, err = zip.read(file, "styles.xml")
      if not styles then
        error(err, 0)
      end
    else
      error("Invalid specification of styles.xml file: " .. tostring(info.odt_styles_file), 0)
    end
  end
  manifest_entry(info, "text/xml", "styles.xml")
  -- colorized source block styles
  local st = state(info)
  local src = {}
  for _, name in ipairs(st.src_style_order) do
    local s = st.src_styles[name]
    if s and s ~= "" then
      src[#src + 1] = " " .. s .. "\n"
    end
  end
  local add = "\n<!-- Org Htmlfontify Styles -->\n" .. table.concat(src) .. "\n"
  if nw(info.odt_extra_styles) then
    add = add .. "\n<!-- Org Extra Styles -->\n" .. info.odt_extra_styles .. "\n"
  end
  styles = insert_before(styles, "</office:styles>", add)
  -- outline numbering is kept up to the section-number level
  local sec = info.section_numbers
  styles = styles:gsub('<text:outline%-level%-style([^>]*)text:level="([^"]*)"([^>]*)>', function(a, level, b)
    local l = tonumber(level) or 0
    local keep
    if type(sec) == "number" then
      keep = l <= sec
    else
      keep = sec and true or false
    end
    if keep then
      return nil
    end
    return fmt('<text:outline-level-style%stext:level="%s" style:num-format="">', a, level)
  end)
  -- priority styles for the valid priority range
  if info.with_priority then
    local marker = '<style:style style:name="OrgPriority" style:family="text"/>'
    local a, b = styles:find(marker, 1, true)
    if a then
      local c = require("org.config").opts
      local hi, lo = c.priority_highest or "A", c.priority_lowest or "C"
      local items = {}
      local function add_p(p)
        items[#items + 1] = fmt(
          '  <style:style style:name="OrgPriority-%s" style:family="text" style:parent-style-name="OrgPriority"/>\n',
          p
        )
      end
      if type(hi) == "number" and type(lo) == "number" then
        for p = hi, lo do
          add_p(p)
        end
      else
        for p = tostring(hi):byte(), tostring(lo):byte() do
          add_p(string.char(p))
        end
      end
      styles = styles:sub(1, b) .. "\n  <!-- Org Priority Styles -->\n" .. table.concat(items) .. styles:sub(b + 1)
    end
  end
  return styles, extra
end

--- META-INF/manifest.xml (org-odt-write-manifest-file).
function M.manifest_xml(entries)
  local out = {
    [[<?xml version="1.0" encoding="UTF-8"?>
     <manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.2">
]],
  }
  for i = #entries, 1, -1 do
    local e = entries[i]
    out[#out + 1] = fmt(
      '\n<manifest:file-entry manifest:media-type="%s" manifest:full-path="%s"%s/>',
      e[1],
      e[2],
      e[3] and fmt(' manifest:version="%s"', e[3]) or ""
    )
  end
  out[#out + 1] = "\n</manifest:manifest>\n"
  return table.concat(out)
end

--- Package members of an exported document: `content` is the content.xml
--- produced by the export, `info` its communication channel.
---@return { name: string, data?: string }[]
function M.package_entries(content, info)
  local mimetype = "application/vnd.oasis.opendocument.text"
  manifest_entry(info, "text/xml", "meta.xml")
  local meta = M.meta_xml(info)
  local styles, extra = M.styles_xml(info)
  manifest_entry(info, "text/xml", "content.xml")
  manifest_entry(info, mimetype, "/", "1.2")
  local entries = {
    { name = "mimetype", data = mimetype },
    { name = "content.xml", data = content },
    { name = "styles.xml", data = styles },
    { name = "meta.xml", data = meta },
  }
  local seen = { mimetype = true, ["content.xml"] = true, ["styles.xml"] = true, ["meta.xml"] = true }
  local function add(e)
    if not seen[e.name] then
      seen[e.name] = true
      -- parent directories of members of the styles file
      local dir = e.name:match("^(.*/)[^/]+$")
      if dir and not seen[dir] then
        seen[dir] = true
        entries[#entries + 1] = { name = dir }
      end
      entries[#entries + 1] = e
    end
  end
  for _, e in ipairs(extra) do
    add(e)
  end
  for _, e in ipairs(state(info).files) do
    add(e)
  end
  entries[#entries + 1] = { name = "META-INF/" }
  entries[#entries + 1] = { name = "META-INF/manifest.xml", data = M.manifest_xml(state(info).manifest) }
  return entries
end
