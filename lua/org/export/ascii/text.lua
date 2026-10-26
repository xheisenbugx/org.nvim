---@mod org.export.ascii.text Plain text links, paragraphs and blocks
---
--- From link to superscript: links, paragraphs, lists, plain text
--- (org-ascii-plain-text), planning, sections and blocks.
---
--- Part of org.export.ascii, which loads it.

local ox = require("org.export.ox")
local element = require("org.export.element")
local shared = require("org.export.ascii.shared")

local M = require("org.export.ascii")

local fmt = string.format
local nw = ox.nw

local T = shared.T
local box_string = shared.box_string
local build_caption = shared.build_caption
local describe_datum = shared.describe_datum
local describe_links = shared.describe_links
local has_caption = shared.has_caption
local indent_string = shared.indent_string
local unique_links = shared.unique_links
local utf8p = shared.utf8p

T.link = function(el, desc, info)
  local t = el.link_type
  local custom = ox.custom_protocol_maybe(el, desc, "ascii", info)
  if custom then
    return custom
  end
  if t == "coderef" then
    local ref = el.path
    local f = ox.get_coderef_format(ref, desc)
    local r = ox.resolve_coderef(ref, info)
    return (f:gsub("%%s", function()
      return tostring(r)
    end))
  elseif t == "radio" then
    return desc
  elseif t == "custom-id" or t == "fuzzy" or t == "id" then
    local dest = t == "fuzzy" and ox.resolve_fuzzy_link(el, info) or ox.resolve_id_link(el, info)
    if desc then
      if info.ascii_links_to_notes then
        return fmt("[%s]", desc)
      end
      return fmt("[%s] (%s)", desc, describe_datum(dest, info))
    end
    if dest.type == "plain-text" then
      return dest.value
    elseif dest.type == "headline" then
      if ox.numbered_headline_p(dest, info) then
        local parts = {}
        for i, x in ipairs(ox.get_headline_number(dest, info) or {}) do
          parts[i] = tostring(x)
        end
        return table.concat(parts, ".")
      end
      return ox.data(dest.title, info)
    end
    local number = ox.get_ordinal(dest, info, nil, has_caption)
    if number then
      if type(number) == "number" then
        return tostring(number)
      end
      local parts = {}
      for i, x in ipairs(number) do
        parts[i] = tostring(x)
      end
      return table.concat(parts, ".")
    end
    return "???"
  end
  local path = el.raw_link
  if not nw(desc) then
    return fmt("<%s>", path)
  end
  return fmt("[%s]", desc) .. ((not info.ascii_links_to_notes) and fmt(" (<%s>)", path) or "")
end

T["node-property"] = function(el)
  return fmt("%s:%s", el.key, el.value and (" " .. el.value) or "")
end

T.paragraph = function(el, contents, info)
  -- org-remove-blank-lines: a line break is a (hard) newline too, so one
  -- on a line of its own makes a blank line, which goes with its hardness
  contents = (contents or ""):gsub("[\n\1][ \t\n\1]*[\n\1]", "\n")
  local ilw = info.ascii_indented_line_width
  if type(ilw) == "number" and ilw >= 0 then
    local first_in_section = not ox.get_previous_element(el, info) and el.parent and el.parent.type == "section"
    contents = (first_in_section and "" or string.rep(" ", ilw)) .. contents:gsub("^[ \t]+", "")
  end
  return M.justify_element(contents, el, info)
end

T["plain-list"] = function(el, contents, info)
  local margin = info.ascii_list_margin
  if margin < 1 or (el.parent and el.parent.type == "item") then
    return contents
  end
  return indent_string(contents, margin)
end

function M.plain_text(text, info, node)
  local u = utf8p(info)
  if u and info.with_smart_quotes and node then
    text = ox.activate_smart_quotes(text, "utf-8", info, node)
  end
  if not info.with_special_strings then
    return text
  end
  text = text:gsub("\\%-", "")
  if not u then
    return text
  end
  return (text:gsub("%-%-%-", "—"):gsub("%-%-", "–"):gsub("%.%.%.", "…"))
end

T["plain-text"] = function(text, info, node)
  return M.plain_text(text, info, node)
end

T.planning = function(el, _, info)
  local parts = {}
  if el.closed then
    parts[#parts + 1] = "CLOSED: " .. ox.timestamp_translate(el.closed)
  end
  if el.deadline then
    parts[#parts + 1] = "DEADLINE: " .. ox.timestamp_translate(el.deadline)
  end
  if el.scheduled then
    parts[#parts + 1] = "SCHEDULED: " .. ox.timestamp_translate(el.scheduled)
  end
  return M.justify_element(table.concat(parts, " "), el, info)
end

T["property-drawer"] = function(el, contents, info)
  if nw(contents) then
    return M.justify_element(contents, el, info)
  end
end

T["quote-block"] = function(_, contents, info)
  return indent_string(contents, info.ascii_quote_margin)
end

T["radio-target"] = function(_, contents)
  return contents
end

T.section = function(el, contents, info)
  local headline = element.lineage(el, "headline")
  local links
  if info.ascii_links_to_notes and not headline then
    links = describe_links(unique_links(el, info), M.current_text_width(el, info), info)
  end
  local s = contents
  if nw(links) then
    s = ox.normalize_string(contents or "") .. "\n\n" .. links
  end
  local margin = (not headline or ox.low_level_p(headline, info)) and 0 or info.ascii_inner_margin
  return indent_string(s, margin)
end

T["special-block"] = function(_, contents)
  return contents
end

T["src-block"] = function(el, _, info)
  local caption = build_caption(el, info)
  local above = info.ascii_caption_above
  local code = ox.format_code_default(el, info)
  if code == "" then
    return ""
  end
  return M.justify_element(
    ((caption and above) and (caption .. "\n") or "")
      .. box_string(code, info)
      .. ((caption and not above) and ("\n" .. caption) or ""),
    el,
    info
  )
end

T["statistics-cookie"] = function(el)
  return el.value
end

T.subscript = function(el, contents)
  return el.use_brackets and fmt("_{%s}", contents or "") or fmt("_%s", contents or "")
end

T.superscript = function(el, contents)
  return el.use_brackets and fmt("^{%s}", contents or "") or fmt("^%s", contents or "")
end
