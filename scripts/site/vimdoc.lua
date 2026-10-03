-- Vim help (vimdoc) to HTML, for the documentation website.
--
-- `split` cuts doc/org.txt into pages at its `====` chapter rules (and the
-- Extensions chapter at its `----` rules); `render` turns a page's lines into
-- HTML: `*tags*` become anchors, `|links|` hyperlinks (to the page holding the
-- tag, or to Neovim's own help for Vim tags), `>lang ... <` code blocks are
-- highlighted, `Heading ~` lines become headings, prose paragraphs and
-- bullet lists flow, and aligned text (key tables, option lists) stays
-- preformatted as in `:help`.
local html = require("site.html")

local M = {}

local RULE_LEN = 40

local function is_rule(line, ch)
  return #line >= RULE_LEN and line == string.rep(ch, #line)
end

--- Code block opener: the line ends with ">" or ">lang" after a space (or
--- is only that). Returns the text before the marker and the language.
local function code_open(line)
  local lang = line:match("^>(%w*)$")
  if lang then
    return "", lang
  end
  local before, l = line:match("^(.*%s)>(%w*)$")
  if before then
    return (before:gsub("%s+$", "")), l
  end
end
M.code_open = code_open

--- The tags of a line: `*tag*` preceded by the start of the line or white
--- space and followed by white space or the end, outside code spans.
local function line_tags(line)
  -- not inside `code` (like the vimdoc parser :helptags uses since 0.12)
  line = line:gsub("`[^`]+`", function(c)
    return string.rep(" ", #c)
  end)
  local tags = {}
  for s, tag, e in line:gmatch("()%*([^*%s|]+)%*()") do
    local before = s == 1 or line:sub(s - 1, s - 1):match("%s")
    local after = e > #line or line:sub(e, e):match("%s")
    if before and after then
      tags[#tags + 1] = tag
    end
  end
  return tags
end
M.line_tags = line_tags

--- Iterate over the lines that aren't inside a code block, with their index.
local function text_lines(lines)
  local i, in_code = 0, false
  return function()
    while true do
      i = i + 1
      local line = lines[i]
      if line == nil then
        return nil
      end
      if in_code then
        if line:match("^<") then
          in_code = false
        elseif line:match("^%S") then
          in_code = false
          if code_open(line) then
            in_code = true
          end
          return i, line
        end
      else
        if code_open(line) then
          in_code = true
        end
        return i, line
      end
    end
  end
end

--- Every tag defined in `lines`, in order.
function M.tags(lines)
  local out = {}
  for _, line in text_lines(lines) do
    for _, t in ipairs(line_tags(line)) do
      out[#out + 1] = t
    end
  end
  return out
end

--- Strip `*tags*` and the alignment before them from a header line.
local function header_text(line)
  local text = line:gsub("%s*%*[^*%s|]+%*", "")
  return vim.trim(text)
end

--- Chapter titles from the CONTENTS table: tag → "Document structure".
local function contents_titles(lines)
  local titles = {}
  for _, line in ipairs(lines) do
    local title, tag = line:match("^%s*%d+%.%s+(.-)%s+%.+%s+|([^|]+)|%s*$")
    if title then
      titles[tag] = title
    end
  end
  return titles
end

--- Split a help file into pages.
--- Returns a list of { name, title, lines, parent? }: `name` is the first
--- tag of the page's header line ("index" for the part before the first
--- chapter, which includes the CONTENTS), `lines` excludes the rule.
function M.split(lines)
  local titles = contents_titles(lines)
  local pages = {}
  local cur = { name = "index", title = "Contents", lines = {} }
  pages[1] = cur
  local chapter -- the current ====-chapter page, parent of ----sections
  local i = 1
  local in_code = false
  while i <= #lines do
    local line = lines[i]
    local rule = not in_code and (is_rule(line, "=") and "=" or is_rule(line, "-") and "-")
    if rule and lines[i + 1] then
      local header = lines[i + 1]
      local tags = line_tags(header)
      local name = tags[1]
      if not name or (rule == "=" and name:match("%-contents$")) then
        -- the CONTENTS chapter stays on the index page
        cur.lines[#cur.lines + 1] = line
      else
        local title = titles[name] or header_text(header)
        cur = { name = name, title = title, lines = {}, level = rule == "=" and 1 or 2 }
        if rule == "=" then
          chapter = cur
        else
          cur.parent = chapter and chapter.name
        end
        pages[#pages + 1] = cur
      end
    else
      cur.lines[#cur.lines + 1] = line
    end
    if in_code then
      if line:match("^<") then
        in_code = false
      elseif line:match("^%S") then
        in_code = code_open(line) ~= nil
      end
    elseif code_open(line) then
      in_code = true
    end
    i = i + 1
  end
  return pages
end

-- Inline markup ---------------------------------------------------------------

--- Render the inline markup of one line of text.
--- ctx.link(tag) → href or nil; ctx.tags[tag] → true for tags defined here
--- (rendered as anchors); ctx.on_tag(tag) called for each anchor.
local function inline(text, ctx)
  local out = {}
  local i = 1
  local n = #text
  while i <= n do
    local s = text:find("[|*`<h]", i)
    if not s then
      out[#out + 1] = html.escape(text:sub(i))
      break
    end
    out[#out + 1] = html.escape(text:sub(i, s - 1))
    local c = text:sub(s, s)
    local handled
    if c == "|" then
      local tag, e = text:match("^|([^|%s]+)|()", s)
      -- `true|false|"x"` and `[a|b|c]` are alternatives, not links
      local prev, nxt = text:sub(s - 1, s - 1), tag and text:sub(e, e) or ""
      if tag and (s == 1 or not prev:match("[%w\"'%]>_]")) and not nxt:match("[%w\"'%[<_]") then
        local href = ctx.link(tag)
        if href then
          out[#out + 1] = '<a class="hl" href="' .. html.escape(href) .. '">' .. html.escape(tag) .. "</a>"
        else
          out[#out + 1] = '<span class="hl">' .. html.escape(tag) .. "</span>"
        end
        i, handled = e, true
      end
    elseif c == "*" then
      local tag, e = text:match("^%*([^*%s|]+)%*()", s)
      local before = s == 1 or text:sub(s - 1, s - 1):match("%s")
      local after = tag and (e > n or text:sub(e, e):match("%s"))
      if tag and before and after and ctx.tags[tag] then
        if ctx.on_tag then
          ctx.on_tag(tag)
        end
        out[#out + 1] = '<a class="tag" id="'
          .. html.escape(tag)
          .. '" href="#'
          .. html.escape(html.urlencode(tag))
          .. '">'
          .. html.escape(tag)
          .. "</a>"
        i, handled = e, true
      end
    elseif c == "`" then
      local code, e = text:match("^`([^`]+)`()", s)
      if code and not code:find("\n.*\n") then
        out[#out + 1] = "<code>" .. html.escape(code) .. "</code>"
        i, handled = e, true
      end
    elseif c == "<" then
      local key, e = text:match("^(<[%a][%w%-]*>)()", s)
      if key then
        out[#out + 1] = '<span class="key">' .. html.escape(key) .. "</span>"
        i, handled = e, true
      end
    elseif c == "h" then
      local url, e = text:match("^(https?://[^%s<>\"'`|]+)()", s)
      if url and (s == 1 or not text:sub(s - 1, s - 1):match("[%w_]")) then
        local trail = url:match("[.,;:)]+$") or ""
        url = url:sub(1, #url - #trail)
        out[#out + 1] = '<a href="' .. html.escape(url) .. '">' .. html.escape(url) .. "</a>"
        i, handled = e - #trail, true
      end
    end
    if not handled then
      out[#out + 1] = html.escape(c)
      i = s + 1
    end
  end
  return table.concat(out)
end
M.inline = inline

-- Blocks ------------------------------------------------------------------------

--- A line of flowing prose: starts in column 0 and has no alignment gaps
--- (two spaces are fine after the end of a sentence).
local function prose_line(line)
  if line:match("^%s") then
    return false
  end
  local gaps = line:gsub("([.!?:])  ", "%1 ")
  return not gaps:find("%S  +%S")
end

local function bullet(line)
  local ind, mark, rest = line:match("^(%s*)([-*•])%s+(%S.*)$")
  if ind then
    return #ind, #ind + #mark + (#line - #ind - #mark - #rest), rest, "ul"
  end
  ind, mark, rest = line:match("^(%s*)(%d+[.)])%s+(%S.*)$")
  if ind then
    return #ind, #ind + #mark + (#line - #ind - #mark - #rest), rest, "ol"
  end
end

local render_block

--- A list: every line starts an item at the same indent or continues one
--- (indented deeper than the bullet). Returns the HTML or nil.
local function list_block(lines, ctx)
  local ind0, _, _, kind = bullet(lines[1])
  if not ind0 then
    return nil
  end
  local items = {}
  for _, line in ipairs(lines) do
    local ind, width, rest, k = bullet(line)
    if ind == ind0 and k == kind then
      items[#items + 1] = { width = width, lines = { rest } }
    else
      local item = items[#items]
      local lead = #line:match("^%s*")
      if lead <= ind0 then
        return nil
      end
      -- continuation lines are dedented to the item's text column (or as
      -- far as they go)
      item.lines[#item.lines + 1] = line:sub(math.min(lead, item.width) + 1)
    end
  end
  local out = { "<" .. kind .. ">" }
  for _, item in ipairs(items) do
    out[#out + 1] = "<li>" .. render_block(item.lines, ctx, true) .. "</li>"
  end
  out[#out + 1] = "</" .. kind .. ">"
  return table.concat(out, "\n")
end

local function prose(lines, ctx, bare)
  local parts = {}
  for _, l in ipairs(lines) do
    parts[#parts + 1] = vim.trim(l)
  end
  -- one call, so `code` can wrap across lines
  local text = inline(table.concat(parts, " "), ctx)
  return bare and text or ("<p>" .. text .. "</p>")
end

--- Render a run of non-blank text lines. `bare` (a list item's text) leaves
--- a single paragraph unwrapped.
function render_block(lines, ctx, bare)
  local n = 0
  while n < #lines and prose_line(lines[n + 1]) and not bullet(lines[n + 1]) do
    n = n + 1
  end
  if n == #lines then
    return prose(lines, ctx, bare)
  end
  local rest = vim.list_slice(lines, n + 1)
  local tail = list_block(rest, ctx)
  if n > 0 and tail then
    return prose(vim.list_slice(lines, 1, n), ctx) .. "\n" .. tail
  elseif n == 0 and tail then
    return tail
  end
  return '<pre class="help">' .. inline(table.concat(lines, "\n"), ctx) .. "</pre>"
end

--- Render a code block (lines between `>lang` and `<`), dedented.
local function code_block(lines, lang)
  while #lines > 0 and lines[#lines]:match("^%s*$") do
    lines[#lines] = nil
  end
  local indent
  for _, l in ipairs(lines) do
    if l:match("%S") then
      local w = #l:match("^%s*")
      indent = indent and math.min(indent, w) or w
    end
  end
  local out = {}
  for _, l in ipairs(lines) do
    out[#out + 1] = l:sub((indent or 0) + 1)
  end
  local code = table.concat(out, "\n")
  local cls = lang ~= "" and (' class="language-' .. html.escape(lang) .. '"') or ""
  return '<pre class="code"><code' .. cls .. ">" .. html.highlight(code, lang) .. "</code></pre>"
end

--- Render the tags at the end of a line (after an alignment gap) as an
--- anchor bar, and return the rest of the line.
local function trailing_tags(line, ctx)
  local text = line:gsub("%s+$", "")
  local tags = {}
  while true do
    local rest, gap, t = text:match("^(.-)(%s*)%*([^*%s|]+)%*$")
    if not t or not ctx.tags[t] or (rest ~= "" and gap == "") then
      break
    end
    table.insert(tags, 1, t)
    text = rest
    if rest == "" or #gap >= 2 then
      break -- the start of the line, or the alignment gap before the tags
    end
    -- one space: part of a run of tags, or a tag inside the text
    if not rest:match("%*[^*%s|]+%*$") then
      return line, nil
    end
  end
  if #tags == 0 then
    return line, nil
  end
  local out = {}
  for _, t in ipairs(tags) do
    out[#out + 1] = inline("*" .. t .. "*", ctx)
  end
  return text, '<div class="tags">' .. table.concat(out, " ") .. "</div>"
end

--- Render a page's lines. `ctx`:
---   link(tag) → href|nil   where a |link| points
---   tags                   set of the tags defined in the whole help file
---   on_tag(tag, heading)   called for every anchor, with the heading it's under
---   on_heading(id, text, level)
---   title                  the page's title (for its <h1>)
function M.render(lines, ctx)
  local out = {}
  local heading = ctx.title
  local on_tag = ctx.on_tag
  local rctx = setmetatable({
    on_tag = on_tag and function(t)
      on_tag(t, heading)
    end,
  }, { __index = ctx })
  local block = {}
  local function flush()
    if #block > 0 then
      out[#out + 1] = render_block(block, rctx)
      block = {}
    end
  end
  local i = 1
  -- the page's header line (after the rule) becomes the <h1>
  if ctx.header then
    local _, bar = trailing_tags(lines[1] or "", rctx)
    out[#out + 1] = "<h1>" .. html.escape(ctx.title) .. "</h1>"
    if bar then
      out[#out + 1] = bar
    end
    i = 2
  end
  while i <= #lines do
    local line = lines[i]
    local before, lang = code_open(line)
    if before then
      if before ~= "" then
        local text, bar = trailing_tags(before, rctx)
        if bar then
          flush()
          out[#out + 1] = bar
        end
        if text ~= "" then
          block[#block + 1] = text
        end
      end
      flush()
      local code = {}
      i = i + 1
      while i <= #lines do
        local l = lines[i]
        if l:match("^<") then
          i = i + 1
          break
        elseif l:match("^%S") then
          break
        end
        code[#code + 1] = l
        i = i + 1
      end
      out[#out + 1] = code_block(code, lang)
    elseif line:match("^%s*$") then
      flush()
      i = i + 1
    elseif is_rule(line, "=") or is_rule(line, "-") then
      flush()
      out[#out + 1] = "<hr>"
      i = i + 1
    elseif line:match("%s~$") or line == "~" then
      flush()
      local text, bar = trailing_tags(line:gsub("%s*~$", ""), rctx)
      if bar then
        out[#out + 1] = bar
      end
      text = vim.trim(text)
      heading = text
      local id = "h-" .. html.slug(text, ctx.slugs)
      if ctx.on_heading then
        ctx.on_heading(id, text, 3)
      end
      out[#out + 1] = '<h3 id="' .. html.escape(id) .. '">' .. inline(text, rctx) .. "</h3>"
      i = i + 1
    else
      local text, bar = trailing_tags(line, rctx)
      if bar then
        flush()
        out[#out + 1] = bar
        if text:match("%S") then
          block[#block + 1] = text
        end
      else
        block[#block + 1] = line
      end
      i = i + 1
    end
  end
  flush()
  return table.concat(out, "\n")
end

return M
