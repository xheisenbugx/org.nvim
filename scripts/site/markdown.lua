-- A small GitHub-flavoured Markdown renderer, enough for README.md and the
-- files under docs/: ATX headings (with GitHub's anchor slugs), paragraphs,
-- nested lists, fenced code (highlighted), tables, block quotes and
-- `> [!NOTE]` alerts, rules, raw HTML blocks (<div>, <details>, <img>...),
-- and inline code, emphasis, links, images and autolinks.
local html = require("site.html")

local M = {}

-- Inline ----------------------------------------------------------------------

local function inline(text, ctx)
  local out = {}
  local i, n = 1, #text
  local function link_href(href)
    return ctx.link and ctx.link(href) or href
  end
  while i <= n do
    local s = text:find("[`!%[<*_\\h~]", i)
    if not s then
      out[#out + 1] = html.escape(text:sub(i))
      break
    end
    out[#out + 1] = html.escape(text:sub(i, s - 1))
    local c = text:sub(s, s)
    local done
    if c == "\\" and text:sub(s + 1, s + 1):match("%p") then
      out[#out + 1] = html.escape(text:sub(s + 1, s + 1))
      i, done = s + 2, true
    elseif c == "`" then
      local ticks = text:match("^`+", s)
      local close = text:find(ticks, s + #ticks, true)
      if close then
        local code = text:sub(s + #ticks, close - 1):gsub("\n", " ")
        if code:match("^ .* $") then
          code = code:sub(2, -2)
        end
        out[#out + 1] = ctx.code and ctx.code(code) or ("<code>" .. html.escape(code) .. "</code>")
        i, done = close + #ticks, true
      end
    elseif c == "!" then
      local alt, src, e = text:match("^!%[([^%]]*)%]%(([^)%s]+)[^)]*%)()", s)
      if alt then
        out[#out + 1] = '<img src="'
          .. html.escape(link_href(src))
          .. '" alt="'
          .. html.escape(alt)
          .. '" loading="lazy">'
        i, done = e, true
      end
    elseif c == "[" then
      -- [text](href), where text may hold an image or brackets
      local depth, j = 0, s
      while j <= n do
        local ch = text:sub(j, j)
        if ch == "\\" then
          j = j + 1
        elseif ch == "[" then
          depth = depth + 1
        elseif ch == "]" then
          depth = depth - 1
          if depth == 0 then
            break
          end
        end
        j = j + 1
      end
      local href, e = text:match("^%(<?([^)%s>]*)>?[^)]*%)()", j + 1)
      if depth == 0 and href then
        out[#out + 1] = '<a href="'
          .. html.escape(link_href(href))
          .. '">'
          .. inline(text:sub(s + 1, j - 1), ctx)
          .. "</a>"
        i, done = e, true
      end
    elseif c == "<" then
      local url, e = text:match("^<(https?://[^>%s]+)>()", s)
      if url then
        out[#out + 1] = '<a href="' .. html.escape(url) .. '">' .. html.escape(url) .. "</a>"
        i, done = e, true
      else
        -- inline HTML tag, passed through (links in it rewritten)
        local tag, e2 = text:match("^(</?[%a][^<>]*>)()", s)
        if tag then
          out[#out + 1] = ctx.rewrite_html and ctx.rewrite_html(tag) or tag
          i, done = e2, true
        end
      end
    elseif c == "*" or c == "_" then
      local delim = text:match("^%" .. c .. "%" .. c, s) and c .. c or c
      local inner_start = s + #delim
      local prev = s > 1 and text:sub(s - 1, s - 1) or " "
      if not text:sub(inner_start, inner_start):match("%s") and not (c == "_" and prev:match("[%w]")) then
        local close = inner_start
        while true do
          close = text:find(delim, close, true)
          if not close then
            break
          end
          local after = text:sub(close + #delim, close + #delim)
          if
            close > inner_start
            and not text:sub(close - 1, close - 1):match("%s")
            and not (c == "_" and after:match("[%w]"))
            and (#delim == 2 or text:sub(close + 1, close + 1) ~= c)
          then
            break
          end
          close = close + 1
        end
        if close then
          local tagname = #delim == 2 and "strong" or "em"
          out[#out + 1] = "<"
            .. tagname
            .. ">"
            .. inline(text:sub(inner_start, close - 1), ctx)
            .. "</"
            .. tagname
            .. ">"
          i, done = close + #delim, true
        end
      end
    elseif c == "~" then
      local inner, e = text:match("^~~(.-)~~()", s)
      if inner and inner ~= "" then
        out[#out + 1] = "<del>" .. inline(inner, ctx) .. "</del>"
        i, done = e, true
      end
    elseif c == "h" then
      local url, e = text:match("^(https?://[^%s<>]+)()", s)
      if url and (s == 1 or not text:sub(s - 1, s - 1):match("[%w_/]")) then
        local trail = url:match("[.,;:)]+$") or ""
        url = url:sub(1, #url - #trail)
        out[#out + 1] = '<a href="' .. html.escape(url) .. '">' .. html.escape(url) .. "</a>"
        i, done = e - #trail, true
      end
    end
    if not done then
      out[#out + 1] = html.escape(c)
      i = s + 1
    end
  end
  return table.concat(out)
end
M.inline = inline

-- Blocks ----------------------------------------------------------------------

local function list_marker(line)
  local ind, m, sp = line:match("^(%s*)([-*+])(%s+)%S")
  if ind then
    return #ind, #ind + 1 + #sp, "ul"
  end
  local num
  ind, num, sp = line:match("^(%s*)(%d+[.)])(%s+)%S")
  if ind then
    return #ind, #ind + #num + #sp, "ol", tonumber(num:match("%d+"))
  end
end

local function table_cells(line)
  line = vim.trim(line):gsub("^|", ""):gsub("|$", "")
  local cells, cur, i = {}, {}, 1
  local in_code = false
  while i <= #line do
    local ch = line:sub(i, i)
    if ch == "\\" and line:sub(i + 1, i + 1) == "|" then
      cur[#cur + 1] = "|"
      i = i + 1
    elseif ch == "`" then
      in_code = not in_code
      cur[#cur + 1] = ch
    elseif ch == "|" and not in_code then
      cells[#cells + 1] = vim.trim(table.concat(cur))
      cur = {}
    else
      cur[#cur + 1] = ch
    end
    i = i + 1
  end
  cells[#cells + 1] = vim.trim(table.concat(cur))
  return cells
end

local BLOCK_TAGS = {
  div = true,
  details = true,
  summary = true,
  p = true,
  img = true,
  br = true,
  table = true,
  picture = true,
  ["/div"] = true,
  ["/details"] = true,
  ["/summary"] = true,
  ["/p"] = true,
  ["/picture"] = true,
}

local ALERTS = { NOTE = "Note", TIP = "Tip", IMPORTANT = "Important", WARNING = "Warning", CAUTION = "Caution" }

local render

--- Render Markdown `lines` (a list) to HTML.
--- ctx.link(href) → href      rewrite a link or image target
--- ctx.rewrite_html(tag) → tag rewrite an HTML tag's src/href
--- ctx.code(text) → html|nil   render a code span (nil: the default)
--- ctx.on_heading(id, text, level)
function render(lines, ctx)
  ctx.slugs = ctx.slugs or {}
  local out = {}
  local i = 1
  local para = {}
  local function flush()
    if #para > 0 then
      local parts = {}
      for k, l in ipairs(para) do
        local hard = (l:match("  $") or l:match("\\$")) and k < #para
        l = vim.trim(l):gsub("\\$", "")
        parts[#parts + 1] = l .. (hard and "\1" or "")
      end
      -- one call, so `code` and emphasis can wrap across lines; \1 marks
      -- a hard line break
      local text = inline(table.concat(parts, "\n"), ctx):gsub("\1", "<br>")
      out[#out + 1] = "<p>" .. text .. "</p>"
      para = {}
    end
  end
  while i <= #lines do
    local line = lines[i]
    local fence, lang = line:match("^%s*(```+)%s*([%w_+%-]*)")
    if not fence then
      fence, lang = line:match("^%s*(~~~+)%s*([%w_+%-]*)")
    end
    local hlevel, htext = line:match("^(#+)%s+(.-)%s*#*%s*$")
    if fence then
      flush()
      local indent = #line:match("^%s*")
      local code = {}
      i = i + 1
      while i <= #lines and not lines[i]:match("^%s*" .. fence:gsub("%p", "%%%0")) do
        code[#code + 1] = lines[i]:sub(math.min(indent, #lines[i]:match("^%s*")) + 1)
        i = i + 1
      end
      i = i + 1
      local cls = lang ~= "" and (' class="language-' .. html.escape(lang) .. '"') or ""
      out[#out + 1] = '<pre class="code"><code'
        .. cls
        .. ">"
        .. html.highlight(table.concat(code, "\n"), lang)
        .. "</code></pre>"
    elseif hlevel and #hlevel <= 6 then
      flush()
      local plain = htext:gsub("`", ""):gsub("%*%*", ""):gsub("%[([^%]]*)%]%b()", "%1")
      local id = html.slug(plain, ctx.slugs)
      local level = #hlevel
      if ctx.on_heading then
        ctx.on_heading(id, plain, level)
      end
      out[#out + 1] = string.format('<h%d id="%s">%s</h%d>', level, html.escape(id), inline(htext, ctx), level)
      i = i + 1
    elseif line:match("^%s*$") then
      flush()
      i = i + 1
    elseif line:match("^%s*%-%-%-+%s*$") or line:match("^%s*%*%*%*+%s*$") or line:match("^%s*___+%s*$") then
      flush()
      out[#out + 1] = "<hr>"
      i = i + 1
    elseif line:match("^%s*>") then
      flush()
      local quote = {}
      while i <= #lines and lines[i]:match("^%s*>") do
        quote[#quote + 1] = lines[i]:gsub("^%s*> ?", "")
        i = i + 1
      end
      local alert = quote[1]:match("^%[!(%u+)%]%s*$")
      if alert and ALERTS[alert] then
        table.remove(quote, 1)
        out[#out + 1] = '<div class="alert alert-'
          .. alert:lower()
          .. '"><p class="alert-title">'
          .. ALERTS[alert]
          .. "</p>"
          .. render(quote, ctx)
          .. "</div>"
      else
        out[#out + 1] = "<blockquote>" .. render(quote, ctx) .. "</blockquote>"
      end
    elseif line:match("^%s*|") and lines[i + 1] and lines[i + 1]:match("^%s*|?%s*:?%-+:?%s*|") then
      flush()
      local head = table_cells(line)
      local aligns = {}
      for k, c in ipairs(table_cells(lines[i + 1])) do
        aligns[k] = c:match("^:.*:$") and "center" or c:match(":$") and "right" or nil
      end
      local function row(cells, tag)
        local r = {}
        for k, c in ipairs(cells) do
          local style = aligns[k] and (' style="text-align:' .. aligns[k] .. '"') or ""
          r[#r + 1] = "<" .. tag .. style .. ">" .. inline(c, ctx) .. "</" .. tag .. ">"
        end
        return "<tr>" .. table.concat(r) .. "</tr>"
      end
      local t = { '<div class="table-wrap"><table>', "<thead>" .. row(head, "th") .. "</thead>", "<tbody>" }
      i = i + 2
      while i <= #lines and lines[i]:match("^%s*|") do
        t[#t + 1] = row(table_cells(lines[i]), "td")
        i = i + 1
      end
      t[#t + 1] = "</tbody></table></div>"
      out[#out + 1] = table.concat(t, "\n")
    elseif list_marker(line) and (#para == 0 or line:match("^%s*[-*+]") or line:match("^%s*1[.)]")) then
      flush()
      local ind0, _, kind, start = list_marker(line)
      local items = {}
      while i <= #lines do
        local l = lines[i]
        local ind, width, k = list_marker(l)
        if ind and ind <= ind0 + 1 and k == kind then
          items[#items + 1] = { width = width, lines = { l:sub(width + 1) } }
          i = i + 1
        elseif l:match("^%s*$") then
          -- a blank line continues the list if the next line is indented
          -- or another item
          local nxt = lines[i + 1]
          if
            nxt and (#nxt:match("^%s*") > ind0 or (list_marker(nxt) == ind0 and select(3, list_marker(nxt)) == kind))
          then
            items[#items].lines[#items[#items].lines + 1] = ""
            items[#items].loose = true
            i = i + 1
          else
            break
          end
        elseif #l:match("^%s*") > ind0 then
          local item = items[#items]
          local lead = #l:match("^%s*")
          item.lines[#item.lines + 1] = l:sub(math.min(lead, item.width) + 1)
          i = i + 1
        elseif not list_marker(l) and not l:match("^%s*[#>|`]") then
          -- lazy continuation of the item's paragraph
          local item = items[#items]
          item.lines[#item.lines + 1] = l
          i = i + 1
        else
          break
        end
      end
      local open = "<" .. kind .. ((start and start ~= 1) and (' start="' .. start .. '"') or "") .. ">"
      local t = { open }
      for _, item in ipairs(items) do
        local body = render(item.lines, ctx)
        if not item.loose then
          -- a tight item: its first paragraph isn't wrapped in <p>
          body = body:gsub("^<p>(.-)</p>", "%1", 1)
        end
        t[#t + 1] = "<li>" .. body .. "</li>"
      end
      t[#t + 1] = "</" .. kind .. ">"
      out[#out + 1] = table.concat(t, "\n")
    elseif line:match("^%s*<") and BLOCK_TAGS[(line:match("^%s*<(/?%a+)") or ""):lower()] then
      -- an HTML block: up to the next blank line; Markdown resumes after it
      flush()
      while i <= #lines and not lines[i]:match("^%s*$") do
        local l = lines[i]
        out[#out + 1] = l:gsub("<[%a/][^<>]*>", function(tag)
          return ctx.rewrite_html and ctx.rewrite_html(tag) or tag
        end)
        i = i + 1
      end
    else
      para[#para + 1] = line
      i = i + 1
    end
  end
  flush()
  return table.concat(out, "\n")
end

M.render = render

return M
