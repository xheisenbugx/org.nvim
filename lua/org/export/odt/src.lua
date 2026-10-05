---@mod org.export.odt.src ODT source code
---
--- Fontified, numbered source code (org-odt-format-code).
---
--- Part of org.export.odt, which loads it.

local ox = require("org.export.ox")
local shared = require("org.export.odt.shared")

local fmt = string.format

local SRC_BLOCK_PARAGRAPH_FORMAT = shared.SRC_BLOCK_PARAGRAPH_FORMAT
local state = shared.state
local encode = shared.encode
local target = shared.target
local span = shared.span

---------------------------------------------------------------------------
-- Source code
---------------------------------------------------------------------------

local function camel(name)
  local out = {}
  for part in name:gmatch("[^%.%-_]+") do
    out[#out + 1] = part:sub(1, 1):upper() .. part:sub(2)
  end
  return table.concat(out)
end

local function hl_color(group, key)
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = group, link = false })
  if ok and hl and hl[key] then
    return fmt("#%06x", hl[key])
  end
end

--- Register the text style of a highlight capture (org-odt-hfy-face-to-css).
local function src_style(info, capture)
  local st = state(info)
  local name = "OrgSrc" .. camel(capture)
  if st.src_styles[name] == nil then
    local color = hl_color("@" .. capture, "fg")
    if not color then
      st.src_styles[name] = false
      return nil
    end
    st.src_styles[name] = info.odt_create_custom_styles_for_srcblocks == false and ""
      or fmt(
        '\n<style:style style:name="%s" style:family="text">\n  <style:text-properties fo:color="%s"/>\n </style:style>',
        name,
        color
      )
    st.src_style_order[#st.src_style_order + 1] = name
  end
  return st.src_styles[name] and name or nil
end

local function hfy_quote(s)
  return (
    s:gsub('[<"&> \t]', {
      ["<"] = "&lt;",
      ['"'] = "&quot;",
      ["&"] = "&amp;",
      [">"] = "&gt;",
      [" "] = "<text:s/>",
      ["\t"] = "<text:tab/>",
    })
  )
end

--- Colorize `code` with tree-sitter (Emacs uses htmlfontify): one string
--- per line, or nil when the language has no parser/highlights query.
local function fontify_lines(code, lang, info)
  if not lang or not info.odt_fontify_srcblocks then
    return nil
  end
  local ft = vim.filetype.match({ filename = "x." .. lang }) or lang
  local tslang = vim.treesitter.language.get_lang(ft) or lang
  local ok, parser = pcall(vim.treesitter.get_string_parser, code, tslang)
  if not ok or not parser then
    return nil
  end
  local okq, query = pcall(vim.treesitter.query.get, tslang, "highlights")
  if not okq or not query then
    return nil
  end
  local okp, trees = pcall(function()
    return parser:parse()
  end)
  if not okp or not trees or not trees[1] then
    return nil
  end
  local lines = vim.split(code, "\n", { plain = true })
  local marks = {}
  for i = 1, #lines do
    marks[i] = {}
  end
  for id, node in query:iter_captures(trees[1]:root(), code, 0, -1) do
    local name = query.captures[id]
    if name and not name:match("^_") and name ~= "spell" and name ~= "nospell" and name ~= "conceal" then
      local sr, sc, er, ec = node:range()
      for r = sr, er do
        local l = lines[r + 1]
        if l then
          local from = r == sr and sc + 1 or 1
          local to = r == er and ec or #l
          for c = from, to do
            marks[r + 1][c] = name
          end
        end
      end
    end
  end
  local out = {}
  for i, l in ipairs(lines) do
    local parts = {}
    local c = 1
    while c <= #l do
      local cap = marks[i][c]
      local e = c
      while e < #l and marks[i][e + 1] == cap do
        e = e + 1
      end
      local text = hfy_quote(l:sub(c, e))
      local style = cap and src_style(info, cap)
      parts[#parts + 1] = style and span(style, text) or text
      c = e + 1
    end
    out[i] = table.concat(parts)
  end
  -- the default face gives the OrgSrcBlock paragraph style
  local st = state(info)
  if st.src_styles.OrgSrcBlock == nil then
    st.src_styles.OrgSrcBlock = info.odt_create_custom_styles_for_srcblocks == false and ""
      or fmt(SRC_BLOCK_PARAGRAPH_FORMAT, hl_color("Normal", "bg") or "#ffffff", hl_color("Normal", "fg") or "#000000")
    table.insert(st.src_style_order, 1, "OrgSrcBlock")
  end
  return out
end

local function split_nonempty_count(code)
  return #vim.split((code:gsub("^\n+", ""):gsub("\n+$", "")), "\n", { plain = true })
end

--- org-odt-do-format-code
local function do_format_code(code, info, lang, refs, retain_labels, num_start)
  local code_length = split_nonempty_count(code)
  local fontified = fontify_lines(code, lang, info)
  local par_style = fontified and "OrgSrcBlock" or "OrgFixedWidthBlock"
  local i = 0
  local out = ox.format_code(code, function(loc, line_num, ref)
    i = i + 1
    if i == code_length then
      par_style = par_style .. "LastLine"
    end
    local label = (ref and retain_labels) and fmt(" (%s)", ref) or ""
    if fontified then
      loc = (fontified[i] or hfy_quote(loc)) .. hfy_quote(label)
    else
      loc = encode(loc .. label)
    end
    if ref then
      loc = target(loc, "coderef-" .. ref)
    end
    loc = fmt('\n<text:p text:style-name="%s">%s</text:p>', par_style, loc)
    if line_num then
      return fmt("\n<text:list-item>%s\n</text:list-item>", loc)
    end
    return loc
  end, num_start, refs)
  if not num_start then
    return out
  end
  return fmt(
    '\n<text:list text:style-name="OrgSrcBlockNumberedLine"%s>%s</text:list>',
    num_start == 0 and ' text:continue-numbering="false"' or ' text:continue-numbering="true"',
    out
  )
end

--- org-odt-format-code
local function format_code(el, info)
  local code, refs = ox.unravel_code(el)
  return do_format_code(code, info, el.language, refs, el.retain_labels, ox.get_loc(el, info))
end

-- Locals the later parts share
shared.do_format_code = do_format_code
shared.format_code = format_code
