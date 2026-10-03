-- HTML helpers shared by the site generator: escaping, URL encoding and
-- syntax highlighting of code blocks.
local M = {}

local ESC = { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;" }

--- Escape text for HTML content and double-quoted attributes.
function M.escape(s)
  return (tostring(s):gsub('[&<>"]', ESC))
end

local UNESC = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = "\194\160" }

--- Undo `escape` (and numeric character references).
function M.unescape(s)
  return (
    s:gsub("&(#?x?)(%w+);", function(kind, name)
      if kind == "" then
        return UNESC[name] or ("&" .. name .. ";")
      end
      local n = tonumber(name, kind == "#x" and 16 or 10)
      return n and vim.fn.nr2char(n) or ("&" .. kind .. name .. ";")
    end)
  )
end

--- Percent-encode a URL fragment or query value (RFC 3986 unreserved kept).
function M.urlencode(s)
  return (s:gsub("[^%w%-_%.~]", function(c)
    return string.format("%%%02X", c:byte())
  end))
end

function M.urldecode(s)
  return (s:gsub("%%(%x%x)", function(h)
    return string.char(tonumber(h, 16))
  end))
end

--- Iterate the code points of a UTF-8 string (invalid bytes as themselves).
local function utf8_codes(s)
  local i = 1
  return function()
    if i > #s then
      return nil
    end
    local c = s:byte(i)
    local n = c >= 0xF0 and 4 or c >= 0xE0 and 3 or c >= 0xC0 and 2 or 1
    local cp = c
    if n > 1 then
      cp = c % (2 ^ (7 - n))
      for k = 1, n - 1 do
        local b = s:byte(i + k) or 0x80
        cp = cp * 64 + (b % 64)
      end
    end
    local at = i
    i = i + n
    return at, cp
  end
end

--- A GitHub-style heading slug: lower case, punctuation and emoji dropped,
--- spaces turned into hyphens. `seen` (optional) numbers duplicates.
function M.slug(text, seen)
  local out = {}
  for _, cp in utf8_codes(text:lower()) do
    if cp < 128 then
      local c = string.char(cp)
      if c:match("[%w_%-]") then
        out[#out + 1] = c
      elseif c == " " then
        out[#out + 1] = "-"
      end
    elseif cp >= 0xC0 and cp <= 0x24F then -- Latin letters with accents
      out[#out + 1] = vim.fn.nr2char(cp)
    end
  end
  local s = table.concat(out)
  if seen then
    local n = seen[s]
    seen[s] = (n or -1) + 1
    if n then
      s = s .. "-" .. (n + 1)
    end
  end
  return s
end

-- Syntax highlighting -------------------------------------------------------

-- Tree-sitter capture → CSS class (the first matching prefix wins).
local CAPTURES = {
  { "comment", "c" },
  { "string", "s" },
  { "character", "s" },
  { "number", "n" },
  { "boolean", "n" },
  { "constant", "n" },
  { "keyword", "k" },
  { "conditional", "k" },
  { "repeat", "k" },
  { "function", "f" },
  { "method", "f" },
  { "variable.builtin", "b" },
  { "variable.member", "m" },
  { "property", "m" },
  { "field", "m" },
  { "type", "t" },
  { "operator", "o" },
  { "label", "t" },
  { "tag", "k" },
}

local function capture_class(name)
  for _, c in ipairs(CAPTURES) do
    if name == c[1] or vim.startswith(name, c[1] .. ".") then
      return c[2]
    end
  end
end

--- Render `code` with one class per byte as spans.
local function spans(code, classes)
  local out, i = {}, 1
  while i <= #code do
    local cls = classes[i]
    local j = i
    while j < #code and classes[j + 1] == cls do
      j = j + 1
    end
    local text = M.escape(code:sub(i, j))
    out[#out + 1] = cls and ('<span class="h-' .. cls .. '">' .. text .. "</span>") or text
    i = j + 1
  end
  return table.concat(out)
end

local function treesitter(code, lang)
  local ok, has = pcall(vim.treesitter.language.add, lang)
  if not ok or not has then
    return nil
  end
  local pok, parser = pcall(vim.treesitter.get_string_parser, code, lang)
  if not pok then
    return nil
  end
  local query = vim.treesitter.query.get(lang, "highlights")
  if not query then
    return nil
  end
  local root = parser:parse()[1]:root()
  -- byte offset of each line start, to turn (row, col) into an offset
  local starts, pos = { 0 }, 1
  while true do
    local nl = code:find("\n", pos, true)
    if not nl then
      break
    end
    starts[#starts + 1] = nl
    pos = nl + 1
  end
  local classes = {}
  for id, node in query:iter_captures(root, code) do
    local cls = capture_class(query.captures[id])
    if cls then
      local sr, sc, er, ec = node:range()
      for b = starts[sr + 1] + sc + 1, starts[er + 1] + ec do
        classes[b] = cls
      end
    end
  end
  return spans(code, classes)
end

-- Line-based highlighters for languages Neovim has no bundled parser for.
local function mark(classes, from, to, cls)
  for b = from, to do
    classes[b] = classes[b] or cls
  end
end

local function each_line(code, fn)
  local classes, pos = {}, 1
  for line in (code .. "\n"):gmatch("(.-)\n") do
    fn(line, pos - 1, classes)
    pos = pos + #line + 1
  end
  return spans(code, classes)
end

local function sh(code)
  return each_line(code, function(line, off, classes)
    -- the command word
    local s, e = line:find("^%s*[%w_./%-]+")
    if s and not line:match("^%s*#") then
      mark(classes, off + s, off + e, "f")
    end
    local i = 1
    while i <= #line do
      local c = line:sub(i, i)
      if c == "#" and (i == 1 or line:sub(i - 1, i - 1):match("%s")) then
        mark(classes, off + i, off + #line, "c")
        return
      elseif c == '"' or c == "'" then
        local close = line:find(c, i + 1, true) or #line
        mark(classes, off + i, off + close, "s")
        i = close
      elseif c == "$" then
        local _, e = line:find("^%$[%w_{}]+", i)
        if e then
          mark(classes, off + i, off + e, "b")
          i = e
        end
      end
      i = i + 1
    end
  end)
end

local function org(code)
  return each_line(code, function(line, off, classes)
    local stars = line:match("^%*+ ")
    if stars then
      local kw_s, kw_e = line:find("^[A-Z]+%f[%s]", #stars + 1)
      if kw_s then
        mark(classes, off + kw_s, off + kw_e, "k")
      end
      local tags = line:find("%s:[%w_@#%%:]+:%s*$")
      if tags then
        mark(classes, off + tags + 1, off + #line, "t")
      end
      mark(classes, off + 1, off + #line, "h")
      return
    end
    if line:match("^%s*#%s") or line:match("^%s*#$") then
      mark(classes, off + 1, off + #line, "c")
      return
    end
    local s, e = line:find("^%s*#%+[%w_%-]+:?")
    if s then
      mark(classes, off + s, off + e, "k")
    end
    s, e = line:find("^%s*:[%w_%-+]+:")
    if s then
      mark(classes, off + s, off + e, "m")
    end
    s, e = line:find("^%s*[A-Z]+:%s")
    if s and line:match("^%s*(%u+):") ~= nil and line:find("<%d%d%d%d%-") then
      mark(classes, off + s, off + e, "k")
    end
    for ts, te in line:gmatch("()[<%[]%d%d%d%d%-%d%d%-%d%d[^>%]]*[>%]]()") do
      mark(classes, off + ts, off + te - 1, "n")
    end
    for ls, le in line:gmatch("()%[%[.-%]%]()") do
      mark(classes, off + ls, off + le - 1, "s")
    end
  end)
end

local ALIAS =
  { shell = "sh", bash = "sh", zsh = "sh", console = "sh", elisp = "commonlisp", ["emacs-lisp"] = "commonlisp" }

--- Highlight `code` written in `lang`; returns HTML (escaped, with spans).
function M.highlight(code, lang)
  lang = ALIAS[lang] or lang
  if lang == "sh" then
    return sh(code)
  elseif lang == "org" then
    return org(code)
  elseif lang and lang ~= "" then
    local ok, html = pcall(treesitter, code, lang)
    if ok and html then
      return html
    end
  end
  return M.escape(code)
end

return M
