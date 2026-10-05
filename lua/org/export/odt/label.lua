---@mod org.export.odt.label ODT labels and captions
---
--- Categories, standalone image and formula links, enumeration and
--- caption labels (org-odt-format-label).
---
--- Part of org.export.odt, which loads it.

local ox = require("org.export.ox")
local element = require("org.export.element")
local shared = require("org.export.odt.shared")

local M = require("org.export.odt")

local fmt = string.format
local nw = ox.nw

local LABEL_STYLES = shared.LABEL_STYLES
local headline_numbers = shared.headline_numbers

---------------------------------------------------------------------------
-- Labels and captions
---------------------------------------------------------------------------

local function category_map(info)
  local user = info.odt_category_map_alist
  local out = {}
  for _, e in ipairs(M.CATEGORY_MAP) do
    out[#out + 1] = e
  end
  if type(user) == "table" then
    for k, v in pairs(user) do
      local entry = type(k) == "string" and { k, v[1], v[2], v[3] } or v
      local replaced = false
      for i, e in ipairs(out) do
        if e[1] == entry[1] then
          out[i] = entry
          replaced = true
        end
      end
      if not replaced then
        out[#out + 1] = entry
      end
    end
  end
  return out
end

local function category_entry(info, handle)
  for _, e in ipairs(category_map(info)) do
    if e[1] == handle then
      return e
    end
  end
end

local function converted(x, kind)
  return x.odt_converted ~= nil and (not kind or x.odt_converted.kind == kind)
end

local function image_link_p(x, info)
  if x.type == "latex-fragment" then
    return converted(x, "image")
  end
  return x.type == "link" and ox.inline_image_p(x, info.odt_inline_image_rules)
end

local function formula_link_p(x, info)
  if x.type == "latex-fragment" then
    return converted(x, "mathml")
  end
  return x.type == "link" and ox.inline_image_p(x, info.odt_inline_formula_rules)
end

--- org-odt--standalone-link-p: a paragraph whose sole content is one link
--- (or converted LaTeX fragment) satisfying `link_pred`.
local function standalone_link_p(el, info, para_pred, link_pred)
  local p
  if el.type == "paragraph" then
    p = el
  elseif el.type == "link" or el.type == "latex-fragment" then
    if not link_pred or link_pred(el, info) then
      p = el.parent
    end
  end
  if not (p and p.type == "paragraph") then
    return false
  end
  if para_pred and not para_pred(p) then
    return false
  end
  local count = 0
  for _, x in ipairs(p.contents) do
    if not info.ignore[x] then
      if x.type == "plain-text" then
        if nw(x.value) then
          return false
        end
      elseif x.type == "link" or (x.type == "latex-fragment" and converted(x)) then
        if link_pred and not link_pred(x, info) then
          return false
        end
        count = count + 1
        if count > 1 then
          return false
        end
      else
        return false
      end
    end
  end
  return true
end
M.standalone_link_p = standalone_link_p

local function labelled(p)
  return p.caption ~= nil or p.name ~= nil
end

local PREDICATES = {
  __Table__ = function(el)
    return labelled(el)
  end,
  __Listing__ = function(el)
    return labelled(el)
  end,
  __Figure__ = function(el, info)
    return el.type == "paragraph" and standalone_link_p(el, info, labelled, image_link_p)
  end,
  __DvipngImage__ = function(el)
    return el.type == "latex-environment" and converted(el, "image") and labelled(el)
  end,
  __MathFormula__ = function(el, info)
    if el.type == "latex-environment" then
      return converted(el, "mathml") and labelled(el)
    end
    return el.type == "paragraph" and standalone_link_p(el, info, labelled, formula_link_p)
  end,
}

local TYPES = {
  __Table__ = { table = true },
  __Listing__ = { ["src-block"] = true },
  __Figure__ = { paragraph = true },
  __DvipngImage__ = { ["latex-environment"] = true },
  __MathFormula__ = { paragraph = true, ["latex-environment"] = true },
}

--- org-odt--enumerate: sequence number of `el` among the elements of
--- `types` satisfying `predicate`, prefixed with the number of the
--- enclosing numbered headline of level <= display outline level.
local function enumerate(el, info, predicate, types)
  local n = info.odt_display_outline_level or 2
  local scope
  local p = el.parent
  while p do
    if p.type == "headline" and ox.get_relative_level(p, info) <= n and ox.numbered_headline_p(p, info) then
      scope = p
      break
    end
    p = p.parent
  end
  local counter = 0
  local ordinal = element.map(scope or info.parse_tree, types or { [el.type] = true }, function(x)
    if not predicate or predicate(x, info) then
      counter = counter + 1
      if x == el then
        return counter
      end
    end
  end, { first_match = true, ignore = info.ignore })
  local prefix = scope and headline_numbers(scope, info)
  return (prefix and (prefix .. ".") or "") .. tostring(ordinal or 0)
end

local function default_category(el, info)
  local t = el.type
  if t == "table" then
    return "__Table__"
  elseif t == "src-block" then
    return "__Listing__"
  elseif t == "latex-environment" then
    if converted(el, "image") then
      return "__DvipngImage__"
    elseif converted(el, "mathml") then
      return "__MathFormula__"
    end
  elseif t == "paragraph" then
    if PREDICATES.__Figure__(el, info) then
      return "__Figure__"
    elseif PREDICATES.__MathFormula__(el, info) then
      return "__MathFormula__"
    end
  end
  error("Don't know how to format label for element type: " .. tostring(t), 0)
end

local function format_spec(s, spec)
  return (
    s:gsub("%%(%a)", function(c)
      local v = spec[c]
      if v == nil then
        return "%" .. c
      end
      return v
    end)
  )
end

--- org-odt-format-label: for "definition", { caption } (nil when `el` has
--- neither caption nor name); for "reference", the sequence reference.
local function format_label(el, info, op, category, label_style)
  local label = el.name and ox.get_reference(el, info)
  local caption = ox.get_caption(el)
  caption = caption and ox.data(caption, info) or nil
  if not (label or caption) then
    return nil
  end
  category = category or default_category(el, info)
  local entry = category_entry(info, category)
  local counter, cat = entry[2], entry[4]
  label_style = label_style or entry[3]
  local seqno = enumerate(el, info, PREDICATES[category], TYPES[category])
  cat = ox.translate(cat, "utf-8", info)
  local ls = LABEL_STYLES[label_style] or LABEL_STYLES.value
  local ref = label or ox.get_reference(el, info)
  if op == "definition" then
    return {
      (label and fmt('\n<text:bookmark text:name="%s"/>', label) or "")
        .. format_spec(ox.translate(ls[1], "utf-8", info), {
          e = cat,
          n = fmt(
            '<text:sequence text:ref-name="%s" text:name="%s" text:formula="ooow:%s+1" style:num-format="1">%s</text:sequence>',
            ref,
            counter,
            counter,
            seqno
          ),
          c = caption or "",
        }),
    }
  end
  return fmt(
    '<text:sequence-ref text:reference-format="%s" text:ref-name="%s">%s</text:sequence-ref>',
    ls[2],
    ref,
    format_spec(ls[3], { e = cat, n = seqno })
  )
end

-- Locals the later parts share
shared.category_map = category_map
shared.standalone_link_p = standalone_link_p
shared.labelled = labelled
shared.PREDICATES = PREDICATES
shared.format_spec = format_spec
shared.format_label = format_label
