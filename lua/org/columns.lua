---@mod org.columns Column view
---
--- `open()` shows headlines and their properties as columns drawn over the
--- headlines (like Emacs), or as a table in a split (`columns_view`).
--- The format comes from the nearest COLUMNS property, `#+COLUMNS:`, or
--- `columns_default_format`. Summary operators: {+} {$} {:} {X} {X/} {X%}
--- {min} {max} {mean} {:min} {:max} {:mean} {@min} {@max} {@mean} {est+}
--- (optionally with a format, `{+;%.2f}`).
---
--- This file holds the column format parser and property values; it loads
--- the rest from org/columns/: summary (summary operators, computing
--- summaries), dblock (the columnview dynamic block), view (drawing the
--- table and overlay views), edit (editing values and columns) and open
--- (keys, quitting, opening the view).

local date = require("org.date")
local utils = require("org.utils")

local M = {}
-- The parts in org/columns/ add their functions to this table and
-- require it back, so it must be in package.loaded before they load.
package.loaded["org.columns"] = M

--- `s` cut to at most `width` display cells (org-columns--truncate-below-width).
local function truncate_below(s, width)
  local out = s
  while utils.width(out) > width do
    out = vim.fn.strcharpart(out, 0, vim.fn.strchars(out) - 1)
  end
  return out
end

--- `s` truncated to `width` cells, ending with `columns_ellipses` when cut
--- (org-columns-add-ellipses).
function M.add_ellipses(s, width)
  if utils.width(s) <= width then
    return s
  end
  local ell = require("org.config").opts.columns_ellipses or ".."
  if width <= utils.width(ell) then
    return truncate_below(ell, width)
  end
  return truncate_below(s, width - utils.width(ell)) .. ell
end

local ns = vim.api.nvim_create_namespace("org.columns")

--- Special properties: computed, never summarized nor set in a drawer.
M.SPECIAL = {
  ITEM = true,
  TODO = true,
  PRIORITY = true,
  TAGS = true,
  ALLTAGS = true,
  CATEGORY = true,
  LEVEL = true,
  FILE = true,
  SCHEDULED = true,
  DEADLINE = true,
  CLOSED = true,
  TIMESTAMP = true,
  TIMESTAMP_IA = true,
  CLOCKSUM = true,
  CLOCKSUM_T = true,
  BLOCKED = true,
}

--- Summary operators (Emacs org-columns-summary-types-default).
M.SUMMARY_TYPES = {
  "+",
  "$",
  "X",
  "X/",
  "X%",
  "max",
  "mean",
  "min",
  ":",
  ":max",
  ":mean",
  ":min",
  "@max",
  "@mean",
  "@min",
  "est+",
}

--- What each summary type computes, shown when choosing one.
M.SUMMARY_DESCRIPTIONS = {
  ["+"] = "sum",
  ["$"] = "sum as currency, two decimals",
  ["X"] = "checkbox: [X] when all children are",
  ["X/"] = "checkbox: [n/m] children done",
  ["X%"] = "checkbox: [n%] children done",
  max = "largest number",
  mean = "arithmetic mean",
  min = "smallest number",
  [":"] = "sum of times, HH:MM",
  [":max"] = "largest time",
  [":mean"] = "mean time",
  [":min"] = "smallest time",
  ["@max"] = "oldest age",
  ["@mean"] = "mean age",
  ["@min"] = "youngest age",
  ["est+"] = "sum of low-high estimates",
}

--- Parse a column format string.
---@return { width?: integer, prop: string, title: string, summary?: string, summary_fmt?: string }[]
function M.parse_format(fmt)
  -- org-columns-compile-format: repeatedly search
  -- %[WIDTH]PROP[(TITLE)][{SUMMARY[;FORMAT]}], so a title may hold "%"
  -- or spaces and columns need no space between them.
  fmt = fmt or ""
  local cols = {}
  local pos = 1
  while true do
    local _, e, width, prop = fmt:find("%%(%d*)([%w_%-]+)", pos)
    if not e then
      break
    end
    local title = fmt:match("^%(([^%)]*)%)", e + 1)
    if title then
      e = e + #title + 2
    end
    local summary = fmt:match("^{([^}]*)}", e + 1)
    if summary then
      e = e + #summary + 2
    end
    pos = e + 1
    -- org-string-nw-p: a blank title or operator is none
    if title and not title:match("%S") then
      title = nil
    end
    local sfmt
    if summary and summary:match("%S") then
      summary, sfmt = summary:match("^([^;]*);?(.*)$")
      if sfmt == "" then
        sfmt = nil
      end
    else
      summary = nil
    end
    cols[#cols + 1] = {
      width = tonumber(width),
      prop = prop,
      title = title or prop,
      summary = summary,
      summary_fmt = sfmt,
    }
  end
  return cols
end

--- Raw value of a column for a headline (Emacs org-entry-get with
--- selective inheritance). LEVEL is an ordinary property here, like Emacs.
function M.value(hl, prop)
  local key = prop:upper()
  if key == "ITEM" then
    return hl.title
  elseif key == "TODO" then
    return hl.todo or ""
  elseif key == "PRIORITY" then
    return hl.priority or hl.file:priorities().default
  elseif key == "TAGS" then
    return #hl.tags > 0 and (":" .. table.concat(hl.tags, ":") .. ":") or ""
  elseif key == "LEVEL" then
    return hl.properties.LEVEL or ""
  elseif key == "CLOCKSUM" or key == "CLOCKSUM_T" then
    -- time clocked in the subtree (CLOCKSUM_T: today only), org-duration style
    local from, to
    if key == "CLOCKSUM_T" then
      from, to = require("org.clock").special_range("today")
    end
    local m = require("org.clock").sum_minutes(hl, from, to)
    return m > 0 and date.duration_to_string(m) or ""
  end
  return hl:get_property(prop) or ""
end

-- Local functions the parts below share
local shared = require("org.columns.shared")
shared.ns = ns

require("org.columns.summary")
require("org.columns.dblock")
require("org.columns.view")
require("org.columns.edit")
require("org.columns.open")

return M
