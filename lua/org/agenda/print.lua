---@mod org.agenda.print PostScript and PDF output of the agenda (ps-print)
---
--- A small port of what `org-agenda-write` gets from Emacs's
--- `ps-print-buffer-with-faces` (and `ps2pdf` for .pdf): the agenda text in
--- Courier, paged, with ps-print's header box on every page (the buffer name
--- "Agenda View" on the left, "page/pages" and the date on the right). The
--- layout uses ps-print's defaults and metrics (letter paper, margins of
--- 2 cm left/right and 1.5 cm top/bottom, 8.5 pt text or 7 pt in landscape,
--- a 14/12 pt Helvetica header, 1 cm between header and text, long lines
--- wrapped at the text width, tabs every 8 columns), so pages break at the
--- same lines as in Emacs.
---
--- Both writers are pure Lua: PostScript level 2 with ISO Latin-1 fonts, and
--- PDF 1.4 with the standard Courier/Helvetica fonts in WinAnsiEncoding.
--- Characters outside Latin-1 are replaced (box drawing by `-`, `|` or `+`,
--- dashes by `-`, typographic quotes by ASCII ones, anything else by `?`
--- per column).
---
--- Settings are ps-print's variables with `_` for `-` (see |M.settings|).

local M = {}

---------------------------------------------------------------------------
-- Settings
---------------------------------------------------------------------------

local CM = 72 / 2.54

--- ps-page-dimensions-database: width, height (points) and media name.
M.PAPER = {
  a4 = { 72 * 21.0 / 2.54, 72 * 29.7 / 2.54, "A4" },
  a3 = { 72 * 29.7 / 2.54, 72 * 42.0 / 2.54, "A3" },
  letter = { 72 * 8.5, 72 * 11.0, "Letter" },
  legal = { 72 * 8.5, 72 * 14.0, "Legal" },
  ["letter-small"] = { 72 * 7.68, 72 * 10.16, "LetterSmall" },
  tabloid = { 72 * 11.0, 72 * 17.0, "Tabloid" },
  ledger = { 72 * 17.0, 72 * 11.0, "Ledger" },
  statement = { 72 * 5.5, 72 * 8.5, "Statement" },
  executive = { 72 * 7.5, 72 * 10.0, "Executive" },
  a4small = { 72 * 7.47, 72 * 10.85, "A4Small" },
  b4 = { 72 * 10.125, 72 * 14.33, "B4" },
  b5 = { 72 * 7.16, 72 * 10.125, "B5" },
}

--- The ps-print variables that are used, with Emacs's defaults.
M.defaults = {
  ps_paper_type = "letter",
  ps_landscape_mode = false,
  ps_number_of_columns = 1,
  ps_font_size = { 7, 8.5 }, -- a number, or { landscape, portrait }
  ps_header_font_size = { 10, 12 },
  ps_header_title_font_size = { 12, 14 },
  ps_left_margin = 2 * CM,
  ps_right_margin = 2 * CM,
  ps_inter_column = 2 * CM,
  ps_top_margin = 1.5 * CM,
  ps_bottom_margin = 1.5 * CM,
  ps_header_offset = 1 * CM,
  ps_header_line_pad = 0.15,
  ps_header_lines = 2,
  ps_print_header = true,
  ps_print_header_frame = true,
  ps_show_n_of_n = true,
  ps_print_color_p = true, -- false or "black-white": no colours
  ps_left_header = nil, -- list of strings or function(page, pages)
  ps_right_header = nil,
  ps2pdf = false, -- .pdf through the ps2pdf program when it is installed
}

--- Normalize settings: `ps-paper-type` and `ps_paper_type` are the same key;
--- symbols may be written as strings with or without a leading quote.
---@param opts? table
---@return table
function M.settings(opts)
  local s = vim.deepcopy(M.defaults)
  for k, v in pairs(opts or {}) do
    if type(k) == "string" then
      k = k:gsub("-", "_")
      if type(v) == "string" then
        v = v:gsub("^'", "")
      end
      s[k] = v
    end
  end
  if type(s.ps_paper_type) == "string" then
    s.ps_paper_type = s.ps_paper_type:lower():gsub("_", "-")
  end
  return s
end

--- Is KEY (normalized) a print setting rather than an agenda option?
function M.is_setting(k)
  k = type(k) == "string" and k:gsub("-", "_") or ""
  return k:match("^ps_") ~= nil or k == "ps2pdf"
end

local function sized(v, landscape)
  if type(v) == "table" then
    return landscape and v[1] or v[2]
  end
  return v
end

--- Page geometry, like ps-get-page-dimensions and the PostScript setup of
--- ps-print (all lengths in points).
---@param s table normalized settings
function M.layout(s)
  local paper = M.PAPER[s.ps_paper_type]
  if not paper then
    local names = vim.tbl_keys(M.PAPER)
    table.sort(names)
    error("ps_paper_type must be one of: " .. table.concat(names, ", "), 0)
  end
  local L = { landscape = s.ps_landscape_mode and true or false, media = paper[3] }
  L.media_w, L.media_h = paper[1], paper[2]
  L.w, L.h = paper[1], paper[2]
  if L.landscape then
    L.w, L.h = L.h, L.w
  end
  L.cols = math.max(1, math.floor(tonumber(s.ps_number_of_columns) or 1))
  L.font_size = sized(s.ps_font_size, L.landscape)
  L.hdr_size = sized(s.ps_header_font_size, L.landscape)
  L.title_size = sized(s.ps_header_title_font_size, L.landscape)
  -- ps-font-info-database: Courier 10.55 / 6.0, Helvetica 11.56 per 10 pt
  L.line_h = 10.55 * L.font_size / 10
  L.char_w = 6.0 * L.font_size / 10
  L.hdr_lh = 11.56 * L.hdr_size / 10
  L.title_lh = 11.56 * L.title_size / 10
  L.lm, L.rm, L.ic = s.ps_left_margin, s.ps_right_margin, s.ps_inter_column
  L.print_w = (L.w - L.lm - s.ps_right_margin - (L.cols - 1) * L.ic) / L.cols
  L.print_h = L.h - s.ps_bottom_margin - s.ps_top_margin
  L.bm = s.ps_bottom_margin
  L.header = s.ps_print_header and true or false
  L.header_lines = math.max(1, math.floor(tonumber(s.ps_header_lines) or 2))
  if L.header then
    L.pad = s.ps_header_line_pad * L.title_lh
    L.header_h = L.pad + L.title_lh + L.hdr_lh * (L.header_lines - 1) + L.pad
    L.header_offset = s.ps_header_offset
    L.print_h = L.print_h - L.header_offset - L.header_h
  end
  if L.print_w <= 0 or L.print_h <= 0 then
    error("Bad page layout: the margins leave no room for the text", 0)
  end
  -- LinesPerColumn in ps-print's PostScript setup
  L.lines = math.floor((L.print_h + L.line_h * 0.45) / L.line_h + 0.5)
  L.lines = math.max(1, L.lines)
  L.width = math.max(1, math.floor(L.print_w / L.char_w + 1e-9))
  return L
end

---------------------------------------------------------------------------
-- Text: UTF-8 to Latin-1 cells with styles
---------------------------------------------------------------------------

local HORIZ = {}
for _, c in ipairs({
  0x2500,
  0x2501,
  0x2504,
  0x2505,
  0x2508,
  0x2509,
  0x254C,
  0x254D,
  0x2550,
  0x2574,
  0x2576,
  0x2578,
  0x257A,
  0x257C,
  0x257E,
}) do
  HORIZ[c] = true
end
local VERT = {}
for _, c in ipairs({
  0x2502,
  0x2503,
  0x2506,
  0x2507,
  0x250A,
  0x250B,
  0x254E,
  0x254F,
  0x2551,
  0x2575,
  0x2577,
  0x2579,
  0x257B,
  0x257D,
  0x257F,
}) do
  VERT[c] = true
end
local SUBST = {
  [0x2010] = "-",
  [0x2011] = "-",
  [0x2012] = "-",
  [0x2013] = "-",
  [0x2014] = "-",
  [0x2015] = "-",
  [0x2212] = "-",
  [0x2018] = "'",
  [0x2019] = "'",
  [0x201A] = "'",
  [0x201B] = "'",
  [0x201C] = '"',
  [0x201D] = '"',
  [0x201E] = '"',
  [0x2022] = "*",
  [0x2023] = ">",
  [0x2026] = ".",
  [0x2039] = "<",
  [0x203A] = ">",
  [0x2190] = "<",
  [0x2192] = ">",
  [0x2191] = "^",
  [0x2193] = "v",
  [0x20AC] = "E",
  [0x2713] = "x",
  [0x2714] = "x",
  [0x2717] = "x",
  [0x2718] = "x",
  [0x25CF] = "*",
  [0x25CB] = "o",
}

--- The Latin-1 byte string for one UTF-8 character of display width W.
local function latin1(ch, w)
  local b1 = ch:byte(1)
  if b1 < 0x80 then
    return (b1 < 0x20 or b1 == 0x7F) and "?" or ch
  end
  local cp
  local n = #ch
  if n == 2 then
    cp = (b1 % 0x20) * 0x40 + ch:byte(2) % 0x40
  elseif n == 3 then
    cp = ((b1 % 0x10) * 0x40 + ch:byte(2) % 0x40) * 0x40 + ch:byte(3) % 0x40
  elseif n == 4 then
    cp = (((b1 % 0x08) * 0x40 + ch:byte(2) % 0x40) * 0x40 + ch:byte(3) % 0x40) * 0x40 + ch:byte(4) % 0x40
  end
  if cp and cp >= 0xA0 and cp <= 0xFF then
    return string.char(cp)
  end
  local r
  if not cp then
    r = "?"
  elseif SUBST[cp] then
    r = SUBST[cp]
  elseif cp >= 0x2500 and cp <= 0x257F then
    r = HORIZ[cp] and "-" or VERT[cp] and "|" or "+"
  elseif cp >= 0x2580 and cp <= 0x259F then
    r = "#"
  else
    r = "?"
  end
  if w > 1 then
    r = r .. string.rep(r == "?" and "?" or " ", w - 1)
  end
  return r:sub(1, math.max(w, 1))
end

local style_cache

--- Print style of a highlight group: fg colour (nil for the default), bold,
--- italic.
local function group_style(group, color)
  local key = group .. (color and "+c" or "")
  if style_cache[key] then
    return style_cache[key]
  end
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = group, link = false })
  local st = { bold = false, italic = false }
  if ok and hl then
    st.bold, st.italic = hl.bold or false, hl.italic or false
    if color and hl.fg then
      local okn, normal = pcall(vim.api.nvim_get_hl, 0, { name = "Normal", link = false })
      if not (okn and normal.fg == hl.fg) then
        st.fg = { math.floor(hl.fg / 65536) % 256 / 255, math.floor(hl.fg / 256) % 256 / 255, hl.fg % 256 / 255 }
      end
    end
  end
  style_cache[key] = st
  return st
end

--- Font index: 0 regular, 1 bold, 2 oblique, 3 bold oblique.
local function font_of(st)
  return (st.bold and 1 or 0) + (st.italic and 2 or 0)
end

local function same_style(a, b)
  if a.font ~= b.font then
    return false
  end
  if (a.fg == nil) ~= (b.fg == nil) then
    return false
  end
  return a.fg == nil or (a.fg[1] == b.fg[1] and a.fg[2] == b.fg[2] and a.fg[3] == b.fg[3])
end

--- Printed lines: each logical line is split in cells (one Latin-1 byte per
--- column, tabs expanded), wrapped at `width` columns and grouped in runs of
--- one style.
---@param lines string[]
---@param spans? table<integer, {s: integer, e: integer, group: string}[]> 0-based row -> byte spans
---@param width integer
---@param color boolean
---@return {text: string, font: integer, fg?: number[]}[][]
function M.format(lines, spans, width, color)
  style_cache = {}
  local plain = { font = 0 }
  local out = {}
  for i, line in ipairs(lines) do
    local by_byte = {}
    -- line highlights first, so that the spans inside them win
    for pass = 1, 2 do
      for _, sp in ipairs((spans or {})[i - 1] or {}) do
        if (pass == 1) == (sp.line == true) then
          local st = group_style(sp.group, color)
          local style = { font = font_of(st), fg = st.fg }
          for b = sp.s + 1, math.min(sp.e, #line) do
            by_byte[b] = style
          end
        end
      end
    end
    local cells, styles = {}, {}
    local pos = 1
    for ch in line:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
      local style = by_byte[pos] or plain
      if ch == "\t" then
        local n = 8 - #cells % 8
        for _ = 1, n do
          cells[#cells + 1], styles[#styles + 1] = " ", style
        end
      else
        local w = ch:byte() < 0x80 and 1 or vim.fn.strdisplaywidth(ch)
        local s = latin1(ch, w)
        for k = 1, #s do
          cells[#cells + 1], styles[#styles + 1] = s:sub(k, k), style
        end
      end
      pos = pos + #ch
    end
    local start = 1
    repeat
      local stop = math.min(#cells, start + width - 1)
      local runs = {}
      local k = start
      while k <= stop do
        local st = styles[k]
        local j = k
        while j + 1 <= stop and same_style(styles[j + 1], st) do
          j = j + 1
        end
        runs[#runs + 1] = { text = table.concat(cells, "", k, j), font = st.font, fg = st.fg }
        k = j + 1
      end
      out[#out + 1] = runs
      start = stop + 1
    until start > #cells
  end
  return out
end

---------------------------------------------------------------------------
-- Pages
---------------------------------------------------------------------------

-- Helvetica widths (1/1000 em) of the characters of page numbers and dates;
-- other characters use the average width.
local HELV = { [" "] = 278, ["/"] = 278, [":"] = 278, [","] = 278, ["."] = 278, ["-"] = 333 }
for d = 0, 9 do
  HELV[tostring(d)] = 556
end
local function helv_width(s, size)
  local w = 0
  for c in s:gmatch(".") do
    w = w + (HELV[c] or 509)
  end
  return w * size / 1000
end

local function header_items(list, page, pages)
  local out = {}
  for _, it in ipairs(list) do
    if type(it) == "function" then
      it = it(page, pages)
    end
    out[#out + 1] = tostring(it or "")
  end
  return out
end

--- Drawing operations of every page (in landscape page coordinates):
--- { kind = "rect"|"text", ... }.
---@param lines string[]
---@param spans? table
---@param opts? table print settings
---@return table L layout
---@return table[] pages
function M.paginate(lines, spans, opts)
  local s = M.settings(opts)
  local L = M.layout(s)
  local color = s.ps_print_color_p ~= false and s.ps_print_color_p ~= "black-white"
  local rows = M.format(lines, spans, L.width, color)
  local per_col = L.lines
  local ncolpages = math.max(1, math.ceil(#rows / per_col))
  local left = s.ps_left_header or { "Agenda View", "" }
  local date = os.date("%x")
  local right = s.ps_right_header
    or {
      function(p, n)
        return s.ps_show_n_of_n and (p .. "/" .. n) or tostring(p)
      end,
      date,
    }
  local pages = {}
  local top = L.bm + L.print_h
  for cp = 1, ncolpages do
    local sheet = math.floor((cp - 1) / L.cols) + 1
    local col = (cp - 1) % L.cols
    local ops = pages[sheet] or {}
    pages[sheet] = ops
    local x0 = L.lm + col * (L.print_w + L.ic)
    if L.header then
      local fy = top + L.header_offset
      if s.ps_print_header_frame then
        -- ps-header-frame-alist: shadow 0.0, back 0.9, border 0.4 of 0.0
        ops[#ops + 1] = { kind = "rect", x = x0 + 1, y = fy - 1, w = L.print_w, h = L.header_h, fill = 0.0 }
        ops[#ops + 1] = { kind = "rect", x = x0, y = fy, w = L.print_w, h = L.header_h, fill = 0.9, stroke = 0.4 }
      end
      local lh = header_items(left, cp, ncolpages)
      local rh = header_items(right, cp, ncolpages)
      -- HeaderStart: bottom pad plus the (negative) descent of the header font
      local y = fy + L.pad + 0.225 * L.hdr_size + L.hdr_lh * (L.header_lines - 1)
      for n = 1, L.header_lines do
        local font = n == 1 and "title" or "header"
        local size = n == 1 and L.title_size or L.hdr_size
        if lh[n] and lh[n] ~= "" then
          ops[#ops + 1] = { kind = "text", font = font, size = size, x = x0 + L.pad, y = y, text = lh[n] }
        end
        if rh[n] and rh[n] ~= "" then
          local tx = x0 + L.print_w - L.pad - helv_width(rh[n], size)
          ops[#ops + 1] = { kind = "text", font = font, size = size, x = tx, y = y, text = rh[n], right = true }
        end
        y = y - L.hdr_lh
      end
    end
    local descent = 0.25 * L.font_size
    for r = 1, per_col do
      local row = rows[(cp - 1) * per_col + r]
      if not row then
        break
      end
      local y = top - r * L.line_h + descent
      if #row > 0 then
        ops[#ops + 1] = { kind = "line", x = x0, y = y, runs = row }
      end
    end
  end
  return L, pages
end

--- Latin-1 conversion of header text (UTF-8).
local function header_text(s)
  local out = {}
  for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    out[#out + 1] = latin1(ch, 1)
  end
  return table.concat(out)
end

--- A PostScript/PDF string literal: ( ) \ escaped, bytes >= 128 as \ooo.
function M.string_literal(s)
  return "("
    .. s:gsub("[()\\]", "\\%0"):gsub("[\128-\255]", function(c)
      return string.format("\\%03o", c:byte())
    end)
    .. ")"
end

local function num(x)
  local s = string.format("%.3f", x):gsub("0+$", ""):gsub("%.$", "")
  return s == "-0" and "0" or s
end

-- Text fonts (regular, bold, oblique, bold oblique), then the header title
-- and header fonts.
local FONTS = { "Courier", "Courier-Bold", "Courier-Oblique", "Courier-BoldOblique", "Helvetica-Bold", "Helvetica" }

---------------------------------------------------------------------------
-- PostScript
---------------------------------------------------------------------------

--- The agenda as a PostScript document (a string).
---@param lines string[]
---@param spans? table 0-based row -> { s, e, group } byte spans
---@param opts? table print settings
---@return string
function M.postscript(lines, spans, opts)
  local L, pages = M.paginate(lines, spans, opts)
  local o = {
    "%!PS-Adobe-3.0",
    "%%Title: Agenda View",
    "%%Creator: Neovim org.nvim",
    "%%CreationDate: " .. os.date("%H:%M:%S %b %d %Y"),
    "%%Orientation: " .. (L.landscape and "Landscape" or "Portrait"),
    "%%DocumentNeededResources: font Courier Courier-Bold Courier-Oblique Courier-BoldOblique",
    "%%+ font Helvetica Helvetica-Bold",
    string.format("%%%%DocumentMedia: %s %s %s 0 () ()", L.media, num(L.media_w), num(L.media_h)),
    string.format("%%%%BoundingBox: 0 0 %d %d", math.floor(L.media_w + 0.5), math.floor(L.media_h + 0.5)),
    "%%Pages: " .. #pages,
    "%%PageOrder: Ascend",
    "%%EndComments",
    "%%BeginProlog",
    "/ISOfont { % /new /base",
    "  findfont dup length dict begin",
    "  { 1 index /FID ne { def } { pop pop } ifelse } forall",
    "  /Encoding ISOLatin1Encoding def currentdict end definefont pop",
    "} bind def",
    "/Rect { % x y w h",
    "  4 2 roll moveto dup 0 exch rlineto exch 0 rlineto neg 0 exch rlineto closepath",
    "} bind def",
    "/S { show } bind def",
    "/M { moveto } bind def",
    "%%EndProlog",
    "%%BeginSetup",
  }
  for _, f in ipairs(FONTS) do
    o[#o + 1] = string.format("/%s-ISO /%s ISOfont", f, f)
  end
  o[#o + 1] = string.format("/F0 /Courier-ISO findfont %s scalefont def", num(L.font_size))
  o[#o + 1] = string.format("/F1 /Courier-Bold-ISO findfont %s scalefont def", num(L.font_size))
  o[#o + 1] = string.format("/F2 /Courier-Oblique-ISO findfont %s scalefont def", num(L.font_size))
  o[#o + 1] = string.format("/F3 /Courier-BoldOblique-ISO findfont %s scalefont def", num(L.font_size))
  o[#o + 1] = string.format("/FT /Helvetica-Bold-ISO findfont %s scalefont def", num(L.title_size))
  o[#o + 1] = string.format("/FH /Helvetica-ISO findfont %s scalefont def", num(L.hdr_size))
  o[#o + 1] =
    string.format("mark { << /PageSize [%s %s] >> setpagedevice } stopped cleartomark", num(L.media_w), num(L.media_h))
  o[#o + 1] = "%%EndSetup"
  for p, ops in ipairs(pages) do
    o[#o + 1] = string.format("%%%%Page: %d %d", p, p)
    o[#o + 1] = "save"
    if L.landscape then
      o[#o + 1] = num(L.media_w) .. " 0 translate 90 rotate"
    end
    for _, op in ipairs(ops) do
      if op.kind == "rect" then
        local path = string.format("%s %s %s %s Rect", num(op.x), num(op.y), num(op.w), num(op.h))
        o[#o + 1] = string.format("newpath %s gsave %s setgray fill grestore", path, num(op.fill))
        if op.stroke then
          o[#o + 1] = string.format("%s setlinewidth 0 setgray stroke", num(op.stroke))
        else
          o[#o + 1] = "newpath"
        end
      elseif op.kind == "text" then
        local s = M.string_literal(header_text(op.text))
        o[#o + 1] = "0 setgray " .. (op.font == "title" and "FT" or "FH") .. " setfont"
        if op.right then
          -- right-aligned with the real font metrics
          local xr = op.x + helv_width(header_text(op.text), op.size)
          o[#o + 1] = string.format("%s dup stringwidth pop %s exch sub %s M S", s, num(xr), num(op.y))
        else
          o[#o + 1] = string.format("%s %s M %s S", num(op.x), num(op.y), s)
        end
      else
        o[#o + 1] = string.format("%s %s M", num(op.x), num(op.y))
        for _, run in ipairs(op.runs) do
          local color = run.fg and string.format("%s %s %s setrgbcolor", num(run.fg[1]), num(run.fg[2]), num(run.fg[3]))
            or "0 setgray"
          o[#o + 1] = string.format("%s F%d setfont %s S", color, run.font, M.string_literal(run.text))
        end
      end
    end
    o[#o + 1] = "restore showpage"
  end
  o[#o + 1] = "%%Trailer"
  o[#o + 1] = "%%EOF"
  return table.concat(o, "\n") .. "\n"
end

---------------------------------------------------------------------------
-- PDF
---------------------------------------------------------------------------

--- The agenda as a PDF 1.4 document (a binary string).
---@param lines string[]
---@param spans? table
---@param opts? table print settings
---@return string
function M.pdf(lines, spans, opts)
  local L, pages = M.paginate(lines, spans, opts)
  local objs = {}
  local function add(body)
    objs[#objs + 1] = body
    return #objs
  end
  -- 1 catalog, 2 pages (filled in last), 3.. fonts
  add("<< /Type /Catalog /Pages 2 0 R >>")
  add(false)
  local font_res = {}
  for i, f in ipairs(FONTS) do
    local id = add(string.format("<< /Type /Font /Subtype /Type1 /BaseFont /%s /Encoding /WinAnsiEncoding >>", f))
    font_res[#font_res + 1] = string.format("/F%d %d 0 R", i, id)
  end
  local resources = "<< /Font << " .. table.concat(font_res, " ") .. " >> >>"
  local text_font = { [0] = "/F1", "/F2", "/F3", "/F4" }
  local kids = {}
  for _, ops in ipairs(pages) do
    local c = {}
    for _, op in ipairs(ops) do
      if op.kind == "rect" then
        local r = string.format("%s %s %s %s re", num(op.x), num(op.y), num(op.w), num(op.h))
        if op.stroke then
          c[#c + 1] = string.format("%s g 0 G %s w %s B", num(op.fill), num(op.stroke), r)
        else
          c[#c + 1] = string.format("%s g %s f", num(op.fill), r)
        end
      elseif op.kind == "text" then
        c[#c + 1] = string.format(
          "BT 0 g %s %s Tf %s %s Td %s Tj ET",
          op.font == "title" and "/F5" or "/F6",
          num(op.size),
          num(op.x),
          num(op.y),
          M.string_literal(header_text(op.text))
        )
      else
        local t = { string.format("BT %s %s Td", num(op.x), num(op.y)) }
        for _, run in ipairs(op.runs) do
          local color = run.fg and string.format("%s %s %s rg", num(run.fg[1]), num(run.fg[2]), num(run.fg[3])) or "0 g"
          local font = text_font[run.font] .. " " .. num(L.font_size)
          t[#t + 1] = string.format("%s %s Tf %s Tj", color, font, M.string_literal(run.text))
        end
        t[#t + 1] = "ET"
        c[#c + 1] = table.concat(t, " ")
      end
    end
    local stream = table.concat(c, "\n") .. "\n"
    local cid = add(string.format("<< /Length %d >>\nstream\n%sendstream", #stream, stream))
    local pid = add(
      string.format(
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 %s %s] /Resources %s /Contents %d 0 R >>",
        num(L.w),
        num(L.h),
        resources,
        cid
      )
    )
    kids[#kids + 1] = pid .. " 0 R"
  end
  objs[2] = string.format("<< /Type /Pages /Kids [%s] /Count %d >>", table.concat(kids, " "), #kids)
  local info = add(
    string.format("<< /Title (Agenda View) /Creator (Neovim org.nvim) /CreationDate (D:%s) >>", os.date("%Y%m%d%H%M%S"))
  )
  local out = { "%PDF-1.4\n%\226\227\207\211\n" }
  local offsets = {}
  local pos = #out[1]
  for i, body in ipairs(objs) do
    offsets[i] = pos
    local s = string.format("%d 0 obj\n%s\nendobj\n", i, body)
    out[#out + 1] = s
    pos = pos + #s
  end
  local xref = { "xref", "0 " .. (#objs + 1), "0000000000 65535 f " }
  for i = 1, #objs do
    xref[#xref + 1] = string.format("%010d 00000 n ", offsets[i])
  end
  out[#out + 1] = table.concat(xref, "\n") .. "\n"
  out[#out + 1] = string.format("trailer\n<< /Size %d /Root 1 0 R /Info %d 0 R >>\n", #objs + 1, info)
  out[#out + 1] = string.format("startxref\n%d\n%%%%EOF\n", pos)
  return table.concat(out)
end

---------------------------------------------------------------------------
-- Files
---------------------------------------------------------------------------

local function write_binary(path, data)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local fd, err = io.open(path, "wb")
  if not fd then
    error("cannot write " .. path .. ": " .. tostring(err), 0)
  end
  fd:write(data)
  fd:close()
end

--- Write LINES as PostScript (.ps) or PDF (.pdf, by `ps2pdf` when the
--- `ps2pdf` setting is on and the program is installed, like Emacs).
---@param path string
---@param kind "ps"|"pdf"
---@param lines string[]
---@param spans? table
---@param opts? table print settings
function M.write(path, kind, lines, spans, opts)
  if kind == "ps" then
    write_binary(path, M.postscript(lines, spans, opts))
    return
  end
  local s = M.settings(opts)
  if s.ps2pdf and vim.fn.executable("ps2pdf") == 1 then
    local ps = path:gsub("%.[^./]*$", "") .. ".ps"
    write_binary(ps, M.postscript(lines, spans, opts))
    local res = vim.system({ "ps2pdf", ps, path }):wait()
    os.remove(ps)
    if res.code == 0 then
      return
    end
  end
  write_binary(path, M.pdf(lines, spans, opts))
end

return M
