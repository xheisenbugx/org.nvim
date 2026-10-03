---@mod org.export.ox.prune Pruning the parse tree to the export options; tree properties
---
--- Part of org.export.ox, which loads it: the functions are fields of
--- that module.

local element = require("org.export.element")
local M = require("org.export.ox")

local keep_spaces = M.keep_spaces

---------------------------------------------------------------------------
-- Pruning (org-export--prune-tree)
---------------------------------------------------------------------------

local function member_ci(s, list)
  for _, x in ipairs(list or {}) do
    if x:lower() == (s or ""):lower() then
      return true
    end
  end
  return false
end

function M.selected_trees(data, info)
  local select = {}
  for _, t in ipairs(info.select_tags or {}) do
    select[t] = true
  end
  for _, t in ipairs(info.filetags or {}) do
    if select[t] then
      return element.map(data, { headline = true, inlinetask = true }, function(h)
        return h
      end)
    end
  end
  local selected = {}
  local function walk(d, genealogy)
    local t = d.type
    if t == "headline" or t == "inlinetask" then
      local hit = false
      for _, tag in ipairs(d.tags or {}) do
        if select[tag] then
          hit = true
        end
      end
      if hit then
        for _, g in ipairs(genealogy) do
          selected[g] = true
        end
        element.map(d, { headline = true, inlinetask = true }, function(h)
          selected[h] = true
        end)
      elseif t == "headline" then
        local g2 = {}
        for _, x in ipairs(genealogy) do
          g2[#g2 + 1] = x
        end
        g2[#g2 + 1] = d
        for _, c in ipairs(d.contents) do
          walk(c, g2)
        end
      end
    elseif t == "org-data" or element.GREATER[t] then
      for _, c in ipairs(d.contents) do
        walk(c, genealogy)
      end
    end
  end
  walk(data, {})
  if next(selected) == nil then
    return nil
  end
  return selected
end

local function skip_timestamp_p(with, ttype)
  if with == false then
    return true
  elseif with == "active" then
    return not (ttype == "active" or ttype == "active-range" or ttype == "diary")
  elseif with == "active-exclude-diary" then
    return not (ttype == "active" or ttype == "active-range")
  elseif with == "inactive" then
    return not (ttype == "inactive" or ttype == "inactive-range")
  end
  return false
end

function M.skip_p(datum, info, selected, excluded)
  local t = datum.type
  if t == "comment" or t == "comment-block" then
    local prev = M.get_previous_element(datum, info)
    if prev then
      prev.post_blank = math.max(prev.post_blank or 0, datum.post_blank or 0, 1)
    end
    return true
  elseif t == "clock" then
    return not info.with_clocks
  elseif t == "drawer" then
    local w = info.with_drawers
    if not w then
      return true
    end
    if type(w) == "table" then
      local name = datum.drawer_name
      if w.negate then
        return member_ci(name, w)
      end
      return not member_ci(name, w)
    end
    return false
  elseif t == "fixed-width" then
    return not info.with_fixed_width
  elseif t == "footnote-definition" or t == "footnote-reference" then
    return not info.with_footnotes
  elseif t == "headline" or t == "inlinetask" then
    local tasks = info.with_tasks
    local todo = datum.todo_keyword
    if t == "inlinetask" and not info.with_inlinetasks then
      return true
    end
    for _, tag in ipairs(M.get_tags(datum, info, nil, true)) do
      if excluded[tag] then
        return true
      end
    end
    if selected and not selected[datum] then
      return true
    end
    if datum.commentedp then
      return true
    end
    if not info.with_archived_trees and datum.archivedp then
      return true
    end
    if todo then
      if not tasks then
        return true
      end
      if (tasks == "todo" or tasks == "done") and datum.todo_type ~= tasks then
        return true
      end
      if type(tasks) == "table" and not vim.tbl_contains(tasks, todo) then
        return true
      end
    end
    return false
  elseif t == "latex-environment" or t == "latex-fragment" then
    return not info.with_latex
  elseif t == "node-property" then
    local set = info.with_properties
    if not set then
      return true
    end
    if type(set) == "table" then
      return not member_ci(datum.key, set)
    end
    return false
  elseif t == "planning" then
    return not info.with_planning
  elseif t == "property-drawer" then
    return not info.with_properties
  elseif t == "statistics-cookie" then
    return not info.with_statistics_cookies
  elseif t == "table" then
    return not info.with_tables
  elseif t == "table-cell" then
    local tbl = element.lineage(datum, "table")
    return M.table_has_special_column_p(tbl) and datum.parent.contents[1] == datum
  elseif t == "table-row" then
    if info.with_special_rows then
      return false
    end
    return M.table_row_is_special_p(datum, info)
  elseif t == "timestamp" then
    local parent = element.parent_element(datum)
    if parent and (parent.type == "paragraph" or parent.type == "verse-block") then
      local only = true
      for _, c in ipairs(parent.contents) do
        if c.type == "plain-text" then
          if c.value:find("[^ \t\n\r]") then
            only = false
          end
        elseif c.type ~= "timestamp" then
          only = false
        end
      end
      if only then
        return skip_timestamp_p(info.with_timestamps, datum.ts_type)
      end
    end
    return false
  end
  return false
end

function M.prune_tree(data, info)
  local ignore = {}
  local selected = M.selected_trees(data, info)
  local excluded = {}
  for _, t in ipairs(info.exclude_tags or {}) do
    excluded[t] = true
  end
  local function walk(d)
    if d == nil then
      return
    end
    if d.type == nil then
      local copy = {}
      for _, x in ipairs(d) do
        copy[#copy + 1] = x
      end
      for _, x in ipairs(copy) do
        walk(x)
      end
      return
    end
    local t = d.type
    if M.skip_p(d, info, selected, excluded) then
      if t == "table-cell" or t == "table-row" then
        ignore[d] = true
      else
        local ks = keep_spaces(d, info)
        if ks then
          -- replace by the spaces
          local sib = element.siblings(d)
          for i, x in ipairs(sib or {}) do
            if x == d then
              sib[i] = element.text(ks, d.parent)
            end
          end
        else
          element.extract(d)
        end
      end
    else
      if t == "headline" and info.with_archived_trees == "headline" and d.archivedp then
        d.contents = {}
      else
        local copy = {}
        for _, x in ipairs(d.contents or {}) do
          copy[#copy + 1] = x
        end
        for _, x in ipairs(copy) do
          walk(x)
        end
      end
      if d.title then
        walk(d.title)
      end
      if d.tag then
        walk(d.tag)
      end
    end
  end
  -- collect definitions before pruning
  local definitions = {}
  element.map(data, { ["footnote-definition"] = true, ["footnote-reference"] = true }, function(f)
    if f.type == "footnote-definition" or (f.fn_type == "inline" and f.label) then
      definitions[#definitions + 1] = f
    end
  end)
  if selected then
    local first = data.contents[1]
    if first and first.type == "section" then
      element.extract(first)
    end
  end
  walk(data)
  -- parsed options
  for _, key in ipairs({ "title", "date", "author", "subtitle" }) do
    if type(info[key]) == "table" then
      walk(info[key])
    end
  end
  -- missing footnote definitions
  local missing = M.missing_definitions(data, definitions, info.widened_footnote)
  for _, d in ipairs(missing) do
    walk(d)
  end
  M.install_footnote_definitions(missing, data)
  info.ignore = ignore
end

--- Footnote definitions TREE references but lacks, looked up in
--- DEFINITIONS, then with LOOKUP(label) (the widened buffer of a subtree
--- export, like org-footnote-get-definition).
function M.missing_definitions(tree, definitions, lookup)
  local function labels_in(d)
    return element.map(d, "footnote-reference", function(r)
      if r.fn_type == "standard" then
        return r.label
      end
    end)
  end
  local known = {}
  element.map(tree, { ["footnote-reference"] = true, ["footnote-definition"] = true }, function(f)
    if f.type == "footnote-definition" or f.fn_type == "inline" then
      if f.label then
        known[f.label] = true
      end
    end
  end)
  local defined, undefined = {}, {}
  for _, l in ipairs(labels_in(tree)) do
    if known[l] then
      defined[l] = true
    else
      undefined[#undefined + 1] = l
    end
  end
  local missing = {}
  local queued = {}
  for _, l in ipairs(undefined) do
    queued[l] = true
  end
  while #undefined > 0 do
    local label = table.remove(undefined, 1)
    if not defined[label] then
      local def
      for _, d in ipairs(definitions) do
        if d.label == label then
          def = d
          break
        end
      end
      def = def or (lookup and lookup(label))
      if not def then
        error("Definition not found for footnote " .. label, 0)
      end
      defined[label] = true
      missing[#missing + 1] = def
      for _, l in ipairs(labels_in(def)) do
        if not defined[l] and not queued[l] then
          queued[l] = true
          undefined[#undefined + 1] = l
        end
      end
    end
  end
  local out = {}
  for _, d in ipairs(missing) do
    if d.type == "footnote-definition" then
      out[#out + 1] = d
    else
      local nd = element.node("footnote-definition", { label = d.label, post_blank = 1 })
      nd.contents = d.contents
      for _, c in ipairs(nd.contents) do
        c.parent = nd
      end
      out[#out + 1] = nd
    end
  end
  return out
end

function M.install_footnote_definitions(definitions, tree)
  if #definitions == 0 then
    return
  end
  local section = element.map(tree, "headline", function(h)
    if h.footnote_section_p then
      return h
    end
  end, { first_match = true })
  if section then
    element.adopt(section, definitions)
    return
  end
  local seen = {}
  local function insert(data)
    element.map(data, "footnote-reference", function(ref)
      if ref.fn_type == "standard" and not seen[ref.label] then
        seen[ref.label] = true
        for _, d in ipairs(definitions) do
          if d.label == ref.label then
            local sec = element.lineage(ref, "section")
            if sec then
              element.adopt(sec, { d })
            end
            insert(d)
            break
          end
        end
      end
    end)
  end
  insert(tree)
end

--- Change uninterpreted elements back into Org syntax
--- (org-export--remove-uninterpreted-data).
function M.remove_uninterpreted(data, info)
  local types = {
    entity = true,
    bold = true,
    italic = true,
    ["latex-environment"] = true,
    ["latex-fragment"] = true,
    ["strike-through"] = true,
    subscript = true,
    superscript = true,
    underline = true,
  }
  local todo = {}
  element.map(data, types, function(d)
    todo[#todo + 1] = d
  end, { with_affiliated = true })
  for _, d in ipairs(todo) do
    local t = d.type
    local pb = d.post_blank or 0
    local blank = string.rep(t == "latex-environment" and "\n" or " ", pb)
    local new
    if t == "entity" then
      if not info.with_entities then
        new = { element.text(element.interpret(d):gsub(" +$", "") .. blank) }
        new[1].value = "\\" .. d.name .. (d.use_brackets and "{}" or "") .. blank
      end
    elseif t == "bold" or t == "italic" or t == "strike-through" or t == "underline" then
      if not info.with_emphasize then
        local m = ({ bold = "*", italic = "/", ["strike-through"] = "+", underline = "_" })[t]
        new = { element.text(m) }
        vim.list_extend(new, d.contents)
        new[#new + 1] = element.text(m .. blank)
      end
    elseif t == "latex-environment" or t == "latex-fragment" then
      if info.with_latex == "verbatim" then
        new = { element.text(d.value .. blank) }
      end
    elseif t == "subscript" or t == "superscript" then
      local ss = info.with_sub_superscript
      if not ss or (ss == "{}" and not d.use_brackets) then
        new = { element.text((t == "subscript" and "_" or "^") .. (d.use_brackets and "{" or "")) }
        vim.list_extend(new, d.contents)
        new[#new + 1] = element.text((d.use_brackets and "}" or "") .. blank)
      end
    end
    if new then
      local sib = element.siblings(d)
      if sib then
        for i, x in ipairs(sib) do
          if x == d then
            table.remove(sib, i)
            local k = i
            for _, e in ipairs(new) do
              if not (e.type == "plain-text" and e.value == "") then
                e.parent = d.parent
                table.insert(sib, k, e)
                k = k + 1
              end
            end
            break
          end
        end
      end
    end
  end
  -- merge adjacent plain text nodes (like buffer text)
  element.map(data, "*", function(d)
    for _, key in ipairs({ "contents", "title", "tag" }) do
      local list = d[key]
      if type(list) == "table" and d.type ~= "plain-text" then
        local i = 1
        while i < #list do
          if list[i].type == "plain-text" and list[i + 1].type == "plain-text" then
            list[i].value = list[i].value .. list[i + 1].value
            table.remove(list, i + 1)
          else
            i = i + 1
          end
        end
      end
    end
  end)
  return data
end

---------------------------------------------------------------------------
-- Tree properties
---------------------------------------------------------------------------

function M.collect_tree_properties(data, info)
  info.parse_tree = data
  local min = 10000
  for _, d in ipairs(data.contents) do
    if d.type == "headline" and not d.footnote_section_p and not info.ignore[d] then
      min = math.min(min, d.level)
    end
  end
  if min == 10000 then
    min = 1
  end
  info.headline_offset = 1 - min
  local numbering = {}
  local counters = {}
  for k = 1, 20 do
    counters[k] = 0
  end
  element.map(data, "headline", function(h)
    if M.numbered_headline_p(h, info) and not h.footnote_section_p then
      local rel = M.get_relative_level(h, info)
      local out = {}
      for idx = 1, 20 do
        if idx < rel then
          out[#out + 1] = counters[idx]
        elseif idx == rel then
          counters[idx] = counters[idx] + 1
          out[#out + 1] = counters[idx]
        else
          counters[idx] = 0
        end
      end
      numbering[h] = out
    end
  end, { ignore = info.ignore })
  info.headline_numbering = numbering
end
