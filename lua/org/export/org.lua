---@mod org.export.org Org back-end (port of Emacs ox-org.el) and the
--- Org syntax interpreter (org-element-interpret-data).

local ox = require("org.export.ox")
local element = require("org.export.element")

local M = {}

M.extension = "org"

local fmt = string.format
local nw = ox.nw

local function src_indent()
  local c = require("org.config").opts
  return c.edit_src_content_indentation or 2
end

--- Align table lines like org-table-align.
function M.align_table_lines(lines)
  local tbl = require("org.table")
  return table.concat(tbl.render(tbl.parse(lines)), "\n")
end

local function escape_code(s)
  local lines = vim.split((s:gsub("\n$", "")), "\n", { plain = true })
  return table.concat(ox.escape_code(lines), "\n") .. (s == "" and "" or "\n")
end

local function block_value(el)
  local val = el.value or ""
  local lines = vim.split((val:gsub("\n$", "")), "\n", { plain = true })
  if el.preserve_indent then
    return val
  end
  lines = element.remove_indentation(lines)
  local ind = src_indent()
  if ind > 0 then
    local pad = string.rep(" ", ind)
    for i, l in ipairs(lines) do
      if l:match("%S") then
        lines[i] = pad .. l
      end
    end
  end
  return table.concat(lines, "\n") .. (val == "" and "" or "\n")
end

local function interpret_timestamp(ts)
  return ox.interpret_timestamp(ts)
end

local function tags_string(tags)
  if not tags or #tags == 0 then
    return nil
  end
  return ":" .. table.concat(tags, ":") .. ":"
end

local function align_tags(heading, tags)
  local col = require("org.config").opts.tags_column or -77
  local w = vim.fn.strdisplaywidth(heading)
  if col == 0 then
    return " " .. tags
  elseif col < 0 then
    return string.rep(" ", math.max(-(col + w + vim.fn.strdisplaywidth(tags)), 1)) .. tags
  end
  return string.rep(" ", math.max(col - w, 1)) .. tags
end

--- Interpreters: fn(node, contents) -> string (without post-blank).
local I = {}

I["org-data"] = function(el, contents)
  return string.rep("\n", el.pre_blank or 0) .. (contents or "")
end

I.headline = function(el, contents)
  local title = element.interpret(el.title)
  local heading = string.rep("*", el.level)
    .. (el.todo_keyword and (" " .. el.todo_keyword) or "")
    .. (el.priority and fmt(" [#%s]", el.priority) or "")
    .. (el.commentedp and " COMMENT" or "")
    .. " "
    .. title
  local tags = tags_string(el.tags)
  return heading .. (tags and align_tags(heading, tags) or "") .. string.rep("\n", 1 + (el.pre_blank or 0)) .. (contents or "")
end

I.inlinetask = function(el, contents)
  local title = element.interpret(el.title)
  local task = string.rep("*", el.level)
    .. (el.todo_keyword and (" " .. el.todo_keyword) or "")
    .. (el.priority and fmt(" [#%s]", el.priority) or "")
    .. (title ~= "" and (" " .. title) or "")
  local tags = tags_string(el.tags)
  local s = task .. (tags and align_tags(task, tags) or "")
  if contents then
    s = s .. "\n" .. contents .. string.rep("*", el.level) .. " end"
  end
  return s
end

I.section = function(_, contents)
  return contents
end

I.paragraph = function(_, contents)
  return contents
end

I["plain-list"] = function(el, contents)
  if not contents then
    return contents
  end
  -- org-list-repair: every item gets the bullet of the first one, and
  -- ordered items are renumbered
  local first = el.contents[1]
  local ordered = first and first.bullet and first.bullet:match("[%w]") ~= nil
  local term = ordered and (first.bullet:match("[%.%)]") or ".") or nil
  local n = 0
  local out = {}
  for line in (contents:match("\n$") and contents or (contents .. "\n")):gmatch("(.-)\n") do
    local bullet, rest = line:match("^(%d+[%.%)])(.*)$")
    if not bullet then
      bullet, rest = line:match("^([%-%+])(.*)$")
    end
    if bullet and (rest == "" or rest:match("^ ")) then
      if ordered then
        local counter = rest:match("^ %[@(%d+)%]")
        n = counter and tonumber(counter) or (n + 1)
        line = tostring(n) .. term .. rest
      else
        line = "-" .. rest
      end
    end
    out[#out + 1] = line
  end
  return table.concat(out, "\n") .. "\n"
end

I.item = function(el, contents)
  local tag = el.tag and (element.interpret(el.tag) .. " :: ") or nil
  -- the bullet style of the list's first item (org-list-repair)
  local first = el.parent and el.parent.contents and el.parent.contents[1] or el
  local bullet = first.bullet or "- "
  if not bullet:match("[%w]") then
    bullet = "- "
  else
    bullet = "1" .. (bullet:match("[%.%)]") or ".") .. " "
  end
  local s = bullet
    .. (el.counter and fmt("[@%d] ", el.counter) or "")
    .. (({ on = "[X] ", off = "[ ] ", trans = "[-] " })[el.checkbox or ""] or "")
    .. (tag or "")
  if contents then
    local ind = string.rep(" ", tag and 5 or #bullet)
    local pre = math.min(el.pre_blank or 1, 2)
    -- every non-blank line gets the item indentation
    local body = contents:gsub("\n([ \t]*%S)", "\n" .. ind .. "%1"):gsub("^([ \t]*%S)", ind .. "%1")
    if pre == 0 then
      s = s .. ox.trim(body)
    else
      s = s .. string.rep("\n", pre) .. body
    end
  end
  return s
end

I["quote-block"] = function(_, contents)
  return fmt("#+begin_quote\n%s#+end_quote", contents or "")
end

I["center-block"] = function(_, contents)
  return fmt("#+begin_center\n%s#+end_center", contents or "")
end

I["special-block"] = function(el, contents)
  return fmt(
    "#+begin_%s%s\n%s#+end_%s",
    el.block_type,
    el.parameters and (" " .. el.parameters) or "",
    contents or "",
    el.block_type
  )
end

I["verse-block"] = function(_, contents)
  return fmt("#+begin_verse\n%s#+end_verse", contents or "")
end

I["comment-block"] = function(el)
  local lines = element.remove_indentation(vim.split((el.value:gsub("\n$", "")), "\n", { plain = true }))
  return fmt("#+begin_comment\n%s#+end_comment", ox.normalize_string(table.concat(lines, "\n")) or "")
end

I["dynamic-block"] = function(el, contents)
  return fmt("#+begin: %s%s\n%s#+end:", el.block_name, el.arguments and (" " .. el.arguments) or "", contents or "")
end

I.drawer = function(el, contents)
  return fmt(":%s:\n%s%s:END:", el.drawer_name, string.rep("\n", el.pre_blank or 0), contents or "")
end

I["property-drawer"] = function(_, contents)
  return fmt(":PROPERTIES:\n%s:END:", contents or "")
end

I["node-property"] = function(el)
  return fmt("%-10s %s", ":" .. el.key .. ":", el.value or "")
end

I.planning = function(el)
  local parts = {}
  if el.deadline then
    parts[#parts + 1] = "DEADLINE: " .. interpret_timestamp(el.deadline)
  end
  if el.scheduled then
    parts[#parts + 1] = "SCHEDULED: " .. interpret_timestamp(el.scheduled)
  end
  if el.closed then
    parts[#parts + 1] = "CLOSED: " .. interpret_timestamp(el.closed)
  end
  return table.concat(parts, " ")
end

I.clock = function(el)
  local s = "CLOCK: " .. interpret_timestamp(el.value)
  if el.duration then
    local h, m = el.duration:match("^(%-?%d+):(%d+)$")
    if h then
      s = s .. " => " .. fmt("%2s:%02d", h, tonumber(m))
    else
      s = s .. " => " .. el.duration
    end
  end
  return s
end

I["src-block"] = function(el)
  local head = "#+begin_src"
    .. (el.language and (" " .. el.language) or "")
    .. (el.switches and (" " .. el.switches) or "")
    .. (el.parameters and (" " .. el.parameters) or "")
  return head .. "\n" .. (ox.normalize_string(escape_code(block_value(el))) or "") .. "#+end_src"
end

I["example-block"] = function(el)
  return "#+begin_example"
    .. (el.switches and (" " .. el.switches) or "")
    .. "\n"
    .. (ox.normalize_string(escape_code(block_value(el))) or "")
    .. "#+end_example"
end

I["export-block"] = function(el)
  return fmt("#+begin_export %s\n%s#+end_export", el.back_end_type or "", el.value or "")
end

I.keyword = function(el)
  return fmt("#+%s: %s", el.key:lower(), el.value)
end

I["babel-call"] = function(el)
  return "#+call: "
    .. (el.call or "")
    .. (el.inside_header and fmt("[%s]", el.inside_header) or "")
    .. "("
    .. (el.arguments or "")
    .. ")"
    .. (el.end_header and (" " .. el.end_header) or "")
end

I.comment = function(el)
  return (el.value:gsub("\n", "\n# "):gsub("^", "# "))
end

I["fixed-width"] = function(el)
  if el.value == "" then
    return ":\n"
  end
  return (el.value:gsub("\n", "\n: "):gsub("^", ": "))
end

I["horizontal-rule"] = function()
  return "-----"
end

I["latex-environment"] = function(el)
  return el.value
end

I["diary-sexp"] = function(el)
  return el.value
end

I["footnote-definition"] = function(el, contents)
  local pre = math.min(el.pre_blank or 1, 2)
  if pre == 0 then
    return fmt("[fn:%s] %s", el.label, ox.trim(contents or ""))
  end
  return fmt("[fn:%s]%s%s", el.label, string.rep("\n", pre), contents or "")
end

I.table = function(el, contents)
  if el.table_type == "table.el" then
    return table.concat(element.remove_indentation(vim.split((el.value:gsub("\n$", "")), "\n", { plain = true })), "\n")
  end
  local lines = vim.split((contents or ""):gsub("\n$", ""), "\n", { plain = true })
  local s = M.align_table_lines(lines) .. "\n"
  local fm = {}
  for i = #(el.tblfm or {}), 1, -1 do
    fm[#fm + 1] = "#+TBLFM: " .. el.tblfm[i]
  end
  return s .. table.concat(fm, "\n")
end

I["table-row"] = function(el, contents)
  if el.row_type == "rule" then
    return "|-"
  end
  return "|" .. (contents or "")
end

I["table-cell"] = function(_, contents)
  return " " .. (contents or "") .. " |"
end

--- Interpret an object (no post-blank).
local function object_interpret(el, contents)
  local copy = setmetatable({ post_blank = 0 }, { __index = el })
  if contents ~= nil and element.RECURSIVE_OBJECTS[el.type] then
    -- rebuild with the transcoded contents
    local t = el.type
    if t == "bold" then
      return "*" .. contents .. "*"
    elseif t == "italic" then
      return "/" .. contents .. "/"
    elseif t == "underline" then
      return "_" .. contents .. "_"
    elseif t == "strike-through" then
      return "+" .. contents .. "+"
    elseif t == "subscript" then
      return el.use_brackets and ("_{" .. contents .. "}") or ("_" .. contents)
    elseif t == "superscript" then
      return el.use_brackets and ("^{" .. contents .. "}") or ("^" .. contents)
    elseif t == "footnote-reference" then
      return "[fn:" .. (el.label or "") .. (el.fn_type == "inline" and (":" .. contents) or "") .. "]"
    elseif t == "radio-target" then
      return "<<<" .. contents .. ">>>"
    elseif t == "table-cell" then
      return " " .. contents .. " |"
    elseif t == "link" then
      if el.link_type == "radio" then
        return contents
      end
      return "[[" .. el.raw_link .. "][" .. contents .. "]]"
    end
  end
  return element.interpret(copy)
end

--- Affiliated keywords of an element as Org syntax.
function M.affiliated_keywords(el)
  if not el.affiliated_order then
    return ""
  end
  local out = {}
  local function one(key, value)
    local dual
    local k = key:upper()
    if k == "CAPTION" or k == "RESULTS" then
      dual = value[2]
      value = value[1]
    end
    local v = type(value) == "table" and element.interpret(value) or (value or "")
    local d = dual and fmt("[%s]", type(dual) == "table" and element.interpret(dual) or dual) or ""
    return "#+" .. key:lower() .. d .. ": " .. v .. "\n"
  end
  for _, key in ipairs(el.affiliated_order) do
    local value = el[key]
    if value ~= nil then
      if key:match("^attr_") or key == "caption" or key == "header" then
        for _, line in ipairs(value) do
          out[#out + 1] = one(key, line)
        end
      else
        out[#out + 1] = one(key, value)
      end
    end
  end
  return table.concat(out)
end

--- org-export-expand
function M.expand(el, contents, with_affiliated)
  local t = el.type
  local s
  if I[t] then
    s = I[t](el, contents)
  else
    s = object_interpret(el, contents)
  end
  if with_affiliated and element.ELEMENTS[t] then
    s = M.affiliated_keywords(el) .. (s or "")
  end
  return s
end

--- Interpret a whole tree back into Org syntax (org-element-interpret-data).
function M.interpret(data)
  local function fun(d)
    if d.type == nil then
      local out = {}
      for _, x in ipairs(d) do
        out[#out + 1] = fun(x)
      end
      return table.concat(out)
    end
    if d.type == "plain-text" then
      return d.value
    end
    local contents
    if d.contents and #d.contents > 0 then
      local parts = {}
      for _, c in ipairs(d.contents) do
        parts[#parts + 1] = fun(c)
      end
      contents = table.concat(parts)
    end
    local r = M.expand(d, contents, false) or ""
    if d.type == "org-data" then
      return r
    end
    local blank = d.post_blank or 0
    if element.ELEMENTS[d.type] then
      local s = r
      if s ~= "" and not s:match("\n$") then
        s = s .. "\n"
      end
      return M.affiliated_keywords(d) .. s .. string.rep("\n", blank)
    end
    return r .. string.rep(" ", blank)
  end
  return fun(data)
end

---------------------------------------------------------------------------
-- Back-end
---------------------------------------------------------------------------

local function identity(el, contents)
  local s = M.expand(el, contents, true) or ""
  if not s:lower():find("#+attr_", 1, true) then
    return s
  end
  -- drop #+attr_* lines
  local ends_nl = s:match("\n$") ~= nil
  local body = ends_nl and s or (s .. "\n")
  local out = {}
  for line in body:gmatch("(.-)\n") do
    if not line:lower():match("^[ \t]*#%+attr_[%-_%w]+:") then
      out[#out + 1] = line
    end
  end
  local r = table.concat(out, "\n")
  return ends_nl and (r .. "\n") or r
end

local T = {}
for _, t in ipairs({
  "babel-call",
  "bold",
  "center-block",
  "clock",
  "code",
  "diary-sexp",
  "drawer",
  "dynamic-block",
  "entity",
  "example-block",
  "fixed-width",
  "footnote-reference",
  "horizontal-rule",
  "inline-babel-call",
  "inline-src-block",
  "inlinetask",
  "italic",
  "citation",
  "citation-reference",
  "item",
  "latex-environment",
  "latex-fragment",
  "line-break",
  "node-property",
  "paragraph",
  "plain-list",
  "planning",
  "property-drawer",
  "quote-block",
  "radio-target",
  "special-block",
  "src-block",
  "statistics-cookie",
  "strike-through",
  "subscript",
  "superscript",
  "table",
  "table-cell",
  "table-row",
  "target",
  "underline",
  "verbatim",
  "verse-block",
}) do
  T[t] = identity
end

T["footnote-definition"] = function()
  return nil
end

T["export-block"] = function(el)
  if el.back_end_type == "ORG" then
    return el.value
  end
end

T.headline = function(el, contents, info)
  if el.footnote_section_p then
    return nil
  end
  local copy = {}
  for k, v in pairs(el) do
    copy[k] = v
  end
  copy.todo_keyword = info.with_todo_keywords and el.todo_keyword or nil
  copy.tags = info.with_tags and el.tags or {}
  copy.priority = info.with_priority and el.priority or nil
  copy.level = ox.get_relative_level(el, info)
  return I.headline(copy, contents)
end

T.keyword = function(el)
  local k = el.key
  if k == "AUTHOR" or k == "CREATOR" or k == "DATE" or k == "EMAIL" or k == "OPTIONS" or k == "TITLE" then
    return nil
  end
  return I.keyword(el)
end

T.link = function(el, contents, info)
  local c = ox.custom_protocol_maybe(el, contents, "org", info)
  if c then
    return c
  end
  return object_interpret(el, contents)
end

T.timestamp = function(el)
  return ox.timestamp_translate(el)
end

T.section = function(el, contents, info)
  local out = ox.normalize_string(contents or "") or ""
  local headline = element.lineage(el, "headline")
  local seen = {}
  local notes = {}
  local function scan(d)
    element.map(d, "footnote-reference", function(fn)
      if fn.fn_type == "standard" and not seen[fn] and ox.footnote_first_reference_p(fn, info) then
        seen[fn] = true
        notes[#notes + 1] = ox.normalize_string(
          fmt("[fn:%s] %s", fn.label, ox.data(ox.get_footnote_definition(fn, info), info))
        )
      end
    end, { ignore = info.ignore, no_recursion = { headline = true } })
  end
  -- like Emacs, references in the headline title are not scanned (the
  -- map does not enter the headline)
  _ = headline
  scan(el)
  if #notes > 0 then
    out = out .. "\n" .. table.concat(notes, "\n")
  end
  return out
end

T.template = function(contents, info)
  local out = {}
  if info.time_stamp_file then
    out[#out + 1] = ox.format_time("# Created %Y-%m-%d %a %H:%M\n")
  end
  local opts = element.map(info.parse_tree, "keyword", function(k)
    if k.key == "OPTIONS" then
      return "#+options: " .. k.value
    end
  end, { ignore = info.ignore })
  out[#out + 1] = ox.normalize_string(table.concat(opts, "\n")) or ""
  if info.with_title then
    out[#out + 1] = fmt("#+title: %s\n", ox.data(info.title, info))
  end
  if info.with_date then
    local d = ox.get_date(info)
    local date = type(d) == "string" and d or ox.data(d, info)
    if nw(date) then
      out[#out + 1] = fmt("#+date: %s\n", date)
    end
  end
  if info.with_author then
    local a = ox.data(info.author, info)
    if nw(a) then
      out[#out + 1] = fmt("#+author: %s\n", a)
    end
  end
  if info.with_email then
    local e = ox.data(info.email, info)
    if nw(e) then
      out[#out + 1] = fmt("#+email: %s\n", e)
    end
  end
  if info.with_creator and nw(info.creator) then
    out[#out + 1] = fmt("#+creator: %s\n", info.creator)
  end
  out[#out + 1] = contents
  return table.concat(out)
end

M.transcoders = T

M.backend = ox.define_backend("org", {
  transcoders = T,
  options = function()
    local c = ((require("org.config").opts.export or {}).org or {})
    return {
      { "with_special_rows", nil, nil, c.with_special_rows ~= false },
      { "with_cite_processors", nil, nil, c.with_cite_processors == true },
    }
  end,
  filters = {
    ["parse-tree"] = {
      function(tree)
        element.map(tree, "headline", function(h)
          local first = h.contents[1]
          if not first then
            h.contents = { element.node("section", { parent = h }) }
            h.contents[1].parent = h
          elseif first.type ~= "section" then
            local sec = element.node("section", {})
            sec.parent = h
            table.insert(h.contents, 1, sec)
          end
        end)
        return tree
      end,
    },
  },
})

return M
