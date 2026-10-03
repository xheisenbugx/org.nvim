---@mod org.lint.checkers.babel org-lint checkers: source blocks and Babel headers
---
--- Checker functions by name: `C[name](doc)` returns `{ lnum, col,
--- message }` reports. lua/org/lint/init.lua registers them
--- (`M.checkers`) and runs them.

local util = require("org.lint.util")
local data = require("org.lint.data")
local helpers = require("org.lint.helpers")

local trim = util.trim
local nw = util.nw
local contains = util.contains
local HEADER_ARG_NAMES = data.HEADER_ARG_NAMES
local ANY = data.ANY
local COMMON_HEADER_VALUES = data.COMMON_HEADER_VALUES
local LANG_HEADER_ARGS = data.LANG_HEADER_ARGS
local LOADED_LANGUAGES = data.LOADED_LANGUAGES
local map_type = helpers.map_type
local aff_value = helpers.aff_value
local aff_values = helpers.aff_values
local at_begin = helpers.at_begin
local at_post = helpers.at_post
local parse_header_args = helpers.parse_header_args
local header_values_for = helpers.header_values_for
local assoc_values = helpers.assoc_values
local prev_sibling = helpers.prev_sibling
local ancestor = helpers.ancestor
local headline_of = helpers.headline_of
local headline_properties = helpers.headline_properties
local local_ids = helpers.local_ids
local known_language = helpers.known_language
local babel_data = helpers.babel_data

local C = {}

C["deprecated-header-syntax"] = function(doc)
  local props = {}
  for _, e in ipairs(COMMON_HEADER_VALUES) do
    if e[1] ~= "dir" then
      props[#props + 1] = e[1]
    end
  end
  local out = {}
  for _, el in ipairs(doc.elements) do
    if el.type == "keyword" and el.key == "PROPERTY" then
      -- regexp-opt: longest alternative wins
      local best
      local low = el.value:lower()
      for _, p in ipairs(props) do
        if low:sub(1, #p) == p and low:sub(#p + 1, #p + 1):match("^[ \t]$") and (not best or #p > #best) then
          best = p
        end
      end
      if best then
        out[#out + 1] =
          at_begin(el, string.format('Deprecated syntax for "%s".  Use header-args instead', el.value:sub(1, #best)))
      end
    elseif el.type == "node-property" and el.key then
      for _, p in ipairs(props) do
        if el.key:lower() == p then
          out[#out + 1] = at_begin(el, string.format('Deprecated syntax for "%s".  Use :header-args: instead', el.key))
          break
        end
      end
    end
  end
  return out
end

C["missing-language-in-src-block"] = function(doc)
  local out = {}
  for _, b in ipairs(map_type(doc, "src-block")) do
    if not b.language then
      out[#out + 1] = at_post(b, "Missing language in source block")
    end
  end
  return out
end

C["suspicious-language-in-src-block"] = function(doc)
  local out = {}
  for _, b in ipairs(map_type(doc, "src-block")) do
    if b.language and not known_language(b.language) then
      out[#out + 1] = at_post(b, string.format("Unknown source block language: '%s'", b.language))
    end
  end
  return out
end

C["missing-backend-in-export-block"] = function(doc)
  local out = {}
  for _, b in ipairs(map_type(doc, "export-block")) do
    if not b.backend then
      out[#out + 1] = at_post(b, "Missing backend in export block")
    end
  end
  return out
end

C["invalid-babel-call-block"] = function(doc)
  local out = {}
  for _, b in ipairs(map_type(doc, "babel-call")) do
    if not b.call then
      out[#out + 1] = at_post(b, "Invalid syntax in babel call block")
    elseif b.end_header and b.end_header:match("^%[.*%]$") then
      out[#out + 1] = at_post(b, "Babel call's end header must not be wrapped within brackets")
    end
  end
  return out
end

C["wrong-header-argument"] = function(doc)
  local out = {}
  for _, d in ipairs(babel_data(doc, true)) do
    local allowed = {}
    for _, n in ipairs(HEADER_ARG_NAMES) do
      allowed[n] = true
    end
    for _, lang in ipairs(d.lang and { d.lang } or LOADED_LANGUAGES) do
      for _, e in ipairs(LANG_HEADER_ARGS[lang] or {}) do
        allowed[e[1]] = true
      end
    end
    for _, h in ipairs(d.headers) do
      if h.name:sub(1, 1) ~= ":" then
        table.insert(out, 1, { d.lnum, d.col, string.format('Missing colon in header argument "%s"', h.name) })
      elseif not allowed[h.name:sub(2)] then
        table.insert(out, 1, { d.lnum, d.col, string.format('Unknown header argument "%s"', h.name) })
      end
    end
  end
  return out
end

C["wrong-header-value"] = function(doc)
  local out = {}
  for _, d in ipairs(babel_data(doc, false)) do
    local allowed_list = header_values_for(d.lang)
    local joined
    if d.kind == "src-block" then
      local parts = { d.el.parameters or "" }
      for _, v in ipairs(aff_values(d.el, "HEADER")) do
        parts[#parts + 1] = v
      end
      joined = table.concat(parts, " ")
    elseif d.kind == "inline-src-block" then
      joined = d.el.parameters or ""
    else
      joined = (d.el.inside_header or "") .. " " .. (d.el.end_header or "")
    end
    for _, h in ipairs(parse_header_args(trim(joined))) do
      local allowed = assoc_values(allowed_list, h.name:sub(2))
      if type(allowed) == "table" then
        local vals
        if type(h.value) == "string" then
          vals = vim.split(trim(h.value), "%s+", { trimempty = true })
        else
          vals = { h.value == nil and vim.NIL or h.value }
        end
        local groups = {}
        for _, v in ipairs(vals) do
          local valid = false
          local forbidden = false
          for gi, group in ipairs(allowed) do
            local member = false
            if type(v) == "string" then
              for _, g in ipairs(group) do
                if g ~= ANY and tostring(g) == v then
                  member = true
                end
              end
            end
            if not member then
              if contains(group, ANY) then
                valid = true
                groups[gi] = v
              end
            elseif groups[gi] ~= nil then
              table.insert(out, 1, {
                d.lnum,
                d.col,
                string.format(
                  'Forbidden combination in header "%s": %s, %s',
                  h.name,
                  groups[gi] == vim.NIL and "nil" or tostring(groups[gi]),
                  v == vim.NIL and "nil" or tostring(v)
                ),
              })
              forbidden = true
              break
            else
              groups[gi] = v
              valid = true
            end
          end
          if not forbidden and not valid then
            table.insert(out, 1, {
              d.lnum,
              d.col,
              string.format('Unknown value "%s" for header "%s"', v == vim.NIL and "nil" or tostring(v), h.name),
            })
          end
        end
      end
    end
  end
  return out
end

--- Header arguments in effect for a src block (defaults, #+PROPERTY,
--- inherited HEADER-ARGS properties, #+HEADER lines, block parameters).
local function src_block_args(doc, el)
  local args = { exports = "code" }
  local lang = el.language
  local function apply(str)
    for _, h in ipairs(parse_header_args(str)) do
      if h.name:sub(1, 1) == ":" then
        args[h.name:sub(2)] = type(h.value) == "string" and h.value or tostring(h.value)
      end
    end
  end
  for _, k in ipairs(map_type(doc, "keyword")) do
    if k.key == "PROPERTY" then
      local rest = k.value:match("^header%-args +(.*)$") or k.value:match("^header%-args%+ +(.*)$")
      if rest then
        apply(rest)
      end
      if lang then
        local l2, r2 = k.value:match("^header%-args:(%S-)%+? +(.*)$")
        if l2 == lang then
          apply(r2)
        end
      end
    end
  end
  local chain = {}
  local h = headline_of(el)
  while h do
    table.insert(chain, 1, h)
    h = ancestor(h, "headline")
  end
  for _, hl in ipairs(chain) do
    local props = headline_properties(doc, hl)
    if props["HEADER-ARGS"] then
      apply(props["HEADER-ARGS"])
    end
    if lang and props["HEADER-ARGS:" .. lang:upper()] then
      apply(props["HEADER-ARGS:" .. lang:upper()])
    end
  end
  for _, v in ipairs(aff_values(el, "HEADER")) do
    apply(v)
  end
  apply(el.parameters)
  return args
end

C["named-result"] = function(doc)
  local out = {}
  for _, el in ipairs(doc.elements) do
    local res = aff_value(el, "RESULTS")
    local name = aff_value(el, "NAME")
    if res and name then
      local origin
      if nw(res.value) then
        local v = res.value
        if v:sub(1, 1) == "#" then
          origin = local_ids(doc)[v:sub(2)]
        elseif v:match("^id:") then
          origin = local_ids(doc)[v:sub(4)]
        else
          -- resolve to the element (target, named element or headline)
          local up = v:upper()
          for _, cand in ipairs(doc.elements) do
            local n = aff_value(cand, "NAME")
            if cand ~= el and n and (n.value == v or n.value:upper() == up) then
              origin = cand
              break
            end
          end
        end
      else
        origin = prev_sibling(el)
      end
      if origin and origin.type == "src-block" then
        local exports = src_block_args(doc, origin).exports
        if exports ~= "results" and exports ~= "both" then
          out[#out + 1] = at_begin(
            el,
            string.format(
              'Links to "%s" will not be valid during export unless the parent source block has '
                .. ":exports results or both",
              name.value
            )
          )
        end
      end
    end
  end
  return out
end

C["empty-header-argument"] = function(doc)
  local out = {}
  for _, d in ipairs(babel_data(doc, false)) do
    for _, h in ipairs(d.headers) do
      if h.value == nil then
        table.insert(out, 1, { d.lnum, d.col, string.format('Empty value in header argument "%s"', h.name) })
      end
    end
  end
  return out
end

return C
