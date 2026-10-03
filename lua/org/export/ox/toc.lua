---@mod org.export.ox.toc Tables of contents: collecting headlines, tables, figures, listings
---
--- Part of org.export.ox, which loads it: the functions are fields of
--- that module.

local element = require("org.export.element")
local M = require("org.export.ox")

---------------------------------------------------------------------------
-- Tables of contents
---------------------------------------------------------------------------

function M.excluded_from_toc_p(headline, info)
  if headline.footnote_section_p or M.low_level_p(headline, info) then
    return true
  end
  if M.get_node_property("UNNUMBERED", headline, true) == "notoc" then
    return true
  end
  local depth = info.with_toc
  return type(depth) == "number" and M.get_relative_level(headline, info) > depth
end

function M.collect_headlines(info, n, scope)
  if scope and scope.type ~= "headline" then
    scope = element.lineage(scope, "headline")
  end
  local root = scope or info.parse_tree
  local limit = info.headline_levels
  local depth
  if type(n) ~= "number" then
    depth = limit
  else
    depth = math.min(scope and (M.get_relative_level(scope, info) + n) or n, limit)
  end
  return element.map(root.contents, "headline", function(h)
    if not M.excluded_from_toc_p(h, info) and depth >= M.get_relative_level(h, info) then
      return h
    end
  end, { ignore = info.ignore })
end

function M.collect_elements(types, info, predicate)
  return element.map(info.parse_tree, types, function(el)
    if el.caption and (not predicate or predicate(el, info)) then
      return el
    end
  end, { ignore = info.ignore })
end

function M.collect_tables(info)
  return M.collect_elements("table", info)
end

function M.collect_figures(info, predicate)
  return M.collect_elements("paragraph", info, predicate)
end

function M.collect_listings(info)
  return M.collect_elements("src-block", info)
end

--- Back-end for TOC entries: no footnotes/targets, links become text.
function M.toc_entry_backend(parent, extra)
  local t = {
    ["footnote-reference"] = function()
      return nil
    end,
    link = function(l, c, i)
      return c or M.data(l.raw_link, i)
    end,
    ["radio-target"] = function(_, c)
      return c
    end,
    target = function()
      return nil
    end,
  }
  for k, v in pairs(extra or {}) do
    t[k] = v
  end
  return M.create_backend(parent, t)
end
