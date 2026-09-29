---@mod org.export.engrave Engraved LaTeX source code (engrave-faces)
---
--- ox-latex's `engraved` source block backend runs engrave-faces-latex on
--- the font-locked code. Here tree-sitter's highlights query gives the faces
--- (the same capture -> face table as HTML, `org.export.fontify`), and
--- engrave-faces' default preset, or a colour scheme, their colours. The
--- LaTeX follows engrave-faces-latex 0.3.1: \EF<slug>{...} commands for the
--- preset faces, defined in the preamble by \definecolor/\newcommand.

local fontify = require("org.export.fontify")

local M = {}

local fmt = string.format

--- engrave-faces-themes' default preset (engrave-faces.el 0.3.1), in order:
--- { face, short, slug, attributes }.
M.DEFAULT = {
  { "default", "default", "D", { fg = "#000000", bg = "#ffffff" } },
  { "shadow", "shadow", "h", { fg = "#7f7f7f" } },
  { "success", "success", "sc", { fg = "#228b22", weight = "bold" } },
  { "warning", "warning", "w", { fg = "#ff8e00", weight = "bold" } },
  { "error", "error", "e", { fg = "#ff0000", weight = "bold" } },
  { "font-lock-comment-face", "fl-comment", "c", { fg = "#b22222" } },
  { "font-lock-comment-delimiter-face", "fl-comment-delim", "cd", { fg = "#b22222" } },
  { "font-lock-string-face", "fl-string", "s", { fg = "#8b2252" } },
  { "font-lock-doc-face", "fl-doc", "d", { fg = "#8b2252" } },
  { "font-lock-doc-markup-face", "fl-doc-markup", "m", { fg = "#008b8b" } },
  { "font-lock-keyword-face", "fl-keyword", "k", { fg = "#9370db" } },
  { "font-lock-builtin-face", "fl-builtin", "b", { fg = "#483d8b" } },
  { "font-lock-function-name-face", "fl-function", "f", { fg = "#0000ff" } },
  { "font-lock-variable-name-face", "fl-variable", "v", { fg = "#a0522d" } },
  { "font-lock-type-face", "fl-type", "t", { fg = "#228b22" } },
  { "font-lock-constant-face", "fl-constant", "o", { fg = "#008b8b" } },
  { "font-lock-warning-face", "fl-warning", "wr", { fg = "#ff0000", weight = "bold" } },
  { "font-lock-negation-char-face", "fl-neg-char", "nc", {} },
  { "font-lock-preprocessor-face", "fl-preprocessor", "pp", { fg = "#483d8b" } },
  { "font-lock-regexp-grouping-construct", "fl-regexp", "rc", { weight = "bold" } },
  { "font-lock-regexp-grouping-backslash", "fl-regexp-backslash", "rb", { weight = "bold" } },
  { "org-block", "org-block", "ob", {} },
  { "highlight-numbers-number", "hl-number", "hn", { fg = "#008b8b" } },
  { "highlight-quoted-quote", "hl-qquote", "hq", { fg = "#9370db" } },
  { "highlight-quoted-symbol", "hl-qsymbol", "hs", { fg = "#008b8b" } },
  { "rainbow-delimiters-depth-1-face", "rd-1", "rda", { fg = "#707183" } },
  { "rainbow-delimiters-depth-2-face", "rd-2", "rdb", { fg = "#7388d6" } },
  { "rainbow-delimiters-depth-3-face", "rd-3", "rdc", { fg = "#909183" } },
  { "rainbow-delimiters-depth-4-face", "rd-4", "rdd", { fg = "#709870" } },
  { "rainbow-delimiters-depth-5-face", "rd-5", "rde", { fg = "#907373" } },
  { "rainbow-delimiters-depth-6-face", "rd-6", "rdf", { fg = "#6276ba" } },
  { "rainbow-delimiters-depth-7-face", "rd-7", "rdg", { fg = "#858580" } },
  { "rainbow-delimiters-depth-8-face", "rd-8", "rdh", { fg = "#80a880" } },
  { "rainbow-delimiters-depth-9-face", "rd-9", "rdi", { fg = "#887070" } },
}

--- Highlight groups giving a preset face its look when a theme is taken
--- from a colour scheme (engrave-faces-generate-preset reads the Emacs
--- faces). The first group with attributes wins.
M.GROUPS = {
  default = { "Normal" },
  shadow = { "NonText" },
  success = { "DiagnosticOk" },
  warning = { "DiagnosticWarn" },
  error = { "DiagnosticError", "ErrorMsg" },
  ["font-lock-comment-face"] = { "@comment" },
  ["font-lock-comment-delimiter-face"] = { "@comment" },
  ["font-lock-string-face"] = { "@string" },
  ["font-lock-doc-face"] = { "@comment.documentation", "@comment" },
  ["font-lock-doc-markup-face"] = { "@string.special" },
  ["font-lock-keyword-face"] = { "@keyword" },
  ["font-lock-builtin-face"] = { "@function.builtin" },
  ["font-lock-function-name-face"] = { "@function" },
  ["font-lock-variable-name-face"] = { "@variable" },
  ["font-lock-type-face"] = { "@type" },
  ["font-lock-constant-face"] = { "@constant" },
  ["font-lock-warning-face"] = { "WarningMsg" },
  ["font-lock-preprocessor-face"] = { "@keyword.directive", "PreProc" },
  ["font-lock-regexp-grouping-construct"] = { "@string.regexp" },
  ["font-lock-regexp-grouping-backslash"] = { "@string.escape" },
  ["highlight-numbers-number"] = { "@number" },
  ["highlight-quoted-quote"] = { "@keyword" },
  ["highlight-quoted-symbol"] = { "@constant" },
  ["rainbow-delimiters-depth-1-face"] = { "RainbowDelimiterRed" },
  ["rainbow-delimiters-depth-2-face"] = { "RainbowDelimiterYellow" },
  ["rainbow-delimiters-depth-3-face"] = { "RainbowDelimiterBlue" },
  ["rainbow-delimiters-depth-4-face"] = { "RainbowDelimiterOrange" },
  ["rainbow-delimiters-depth-5-face"] = { "RainbowDelimiterGreen" },
  ["rainbow-delimiters-depth-6-face"] = { "RainbowDelimiterViolet" },
  ["rainbow-delimiters-depth-7-face"] = { "RainbowDelimiterCyan" },
}

--- Face name of `org.export.fontify` -> the Emacs face.
M.FACE = {
  doc = "font-lock-doc-face",
  comment = "font-lock-comment-face",
  escape = "font-lock-escape-face",
  regexp = "font-lock-regexp-face",
  string = "font-lock-string-face",
  keyword = "font-lock-keyword-face",
  builtin = "font-lock-builtin-face",
  ["function-call"] = "font-lock-function-call-face",
  preprocessor = "font-lock-preprocessor-face",
  ["function-name"] = "font-lock-function-name-face",
  type = "font-lock-type-face",
  ["property-use"] = "font-lock-property-use-face",
  ["property-name"] = "font-lock-property-name-face",
  ["variable-name"] = "font-lock-variable-name-face",
  constant = "font-lock-constant-face",
  number = "font-lock-number-face",
  operator = "font-lock-operator-face",
  bracket = "font-lock-bracket-face",
  delimiter = "font-lock-delimiter-face",
  ["misc-punctuation"] = "font-lock-misc-punctuation-face",
}

--- :inherit of the Emacs faces outside the preset (font-lock.el).
M.INHERIT = {
  ["font-lock-function-call-face"] = "font-lock-function-name-face",
  ["font-lock-variable-use-face"] = "font-lock-variable-name-face",
  ["font-lock-property-name-face"] = "font-lock-variable-name-face",
  ["font-lock-property-use-face"] = "font-lock-property-name-face",
  ["font-lock-escape-face"] = "font-lock-regexp-grouping-backslash",
  ["font-lock-regexp-face"] = "font-lock-string-face",
  ["font-lock-bracket-face"] = "font-lock-punctuation-face",
  ["font-lock-delimiter-face"] = "font-lock-punctuation-face",
  ["font-lock-misc-punctuation-face"] = "font-lock-punctuation-face",
}

local function hex(n)
  return fmt("#%06x", n)
end

--- A preset from the highlight groups of the current colour scheme
--- (engrave-faces-generate-preset).
function M.preset_from_highlights()
  local out = {}
  for _, e in ipairs(M.DEFAULT) do
    local attrs = {}
    for _, g in ipairs(M.GROUPS[e[1]] or {}) do
      local hl = fontify.hl(g)
      if next(hl) then
        attrs.fg = hl.fg and hex(hl.fg) or nil
        attrs.bg = hl.bg and hex(hl.bg) or nil
        attrs.weight = hl.bold and "bold" or nil
        attrs.slant = hl.italic and "italic" or nil
        attrs.strike = hl.strikethrough or nil
        break
      end
    end
    if e[1] == "default" then
      attrs.fg = attrs.fg or "#000000"
      attrs.bg = attrs.bg or "#ffffff"
    end
    out[#out + 1] = { e[1], e[2], e[3], attrs }
  end
  return out
end

local cache = {}

--- The preset of THEME (engrave-faces-get-theme): nil or "default" = the
--- default preset, true or "t" = the current colour scheme, another name =
--- that Neovim colour scheme (loaded for the moment, like Emacs'
--- load-theme).
function M.get_theme(theme)
  if theme == nil or theme == false or theme == "default" or theme == "nil" then
    return M.DEFAULT
  end
  if theme == true or theme == "t" then
    return M.preset_from_highlights()
  end
  if cache[theme] then
    return cache[theme]
  end
  if vim.g.colors_name == theme then
    return M.preset_from_highlights()
  end
  if not vim.tbl_contains(vim.fn.getcompletion("", "color"), theme) then
    error(fmt("Theme `%s' is not found in the engraved presets or available colour schemes.", theme), 0)
  end
  local prev, bg = vim.g.colors_name, vim.o.background
  vim.cmd.colorscheme(theme)
  local preset = M.preset_from_highlights()
  vim.o.background = bg
  if prev then
    pcall(vim.cmd.colorscheme, prev)
  else
    vim.cmd("highlight clear")
    vim.g.colors_name = nil
  end
  cache[theme] = preset
  return preset
end

local function lookup(preset, face)
  for _, e in ipairs(preset) do
    if e[1] == face then
      return e
    end
  end
end

--- engrave-faces-latex-gen-preamble-line
function M.preamble_line(face, slug, a)
  local bgbox = a.bg and face ~= "default"
  local out = {}
  if a.fg then
    out[#out + 1] = fmt("\\definecolor{EF%s}{HTML}{%s}\n", slug, a.fg:sub(2))
  end
  if a.bg then
    out[#out + 1] = fmt("\\definecolor{Ef%s}{HTML}{%s}\n", slug, a.bg:sub(2))
  end
  out[#out + 1] = "\\newcommand{\\EF" .. slug .. "}[1]{"
  local n = 0
  if bgbox then
    out[#out + 1] = "\\colorbox{Ef" .. slug .. "}{\\efstrut{}"
    n = n + 1
  end
  if a.fg then
    out[#out + 1] = "\\textcolor{EF" .. slug .. "}{"
    n = n + 1
  end
  if a.strike then
    out[#out + 1] = "\\sout{"
    n = n + 1
  end
  if a.weight == "bold" or a.weight == "extra-bold" then
    out[#out + 1] = "\\textbf{"
    n = n + 1
  end
  if a.slant == "italic" then
    out[#out + 1] = "\\textit{"
    n = n + 1
  end
  out[#out + 1] = "#1}" .. string.rep("}", n) .. " % " .. face
  return table.concat(out)
end

--- engrave-faces-latex-gen-preamble: the \EF.. commands of a preset.
function M.gen_preamble(preset)
  local out = {}
  for _, e in ipairs(preset) do
    if e[4].bg then
      out[1] = "\\newcommand\\efstrut{\\vrule height 2.1ex depth 0.8ex width 0pt}\n"
      break
    end
  end
  local lines = {}
  for _, e in ipairs(preset) do
    lines[#lines + 1] = M.preamble_line(e[1], e[3], e[4])
  end
  out[#out + 1] = table.concat(lines, "\n")
  return table.concat(out)
end

--- engrave-faces-latex--protect-content
function M.protect(s)
  local out = s:gsub("[\\{}$%%&_#^~]", function(c)
    if c == "\\" then
      return "\\char92{}"
    elseif c == "^" then
      return "\\char94{}"
    elseif c == "~" then
      return "\\char126{}"
    end
    return "\\" .. c
  end)
  return out
end

--- engrave-faces-latex--protect-content-mathescape (mathescape t): maths in
--- comments is left alone.
local function protect_mathescape(s)
  local pat
  if s:find("%$[^\n]+%$") then
    pat = function(l)
      return l:match("^([^$]*)(%$.+%$)([^$]*)$")
    end
  elseif s:find("\\%([^\n]+\\%)") then
    pat = function(l)
      return l:match("^(.-)(\\%(.+\\%))(.-)$")
    end
  end
  local lines = vim.split(s, "\n", { plain = true })
  for i, l in ipairs(lines) do
    if pat then
      local a, b, c = pat(l)
      if a then
        lines[i] = M.protect(a) .. b .. M.protect(c)
      end
    else
      lines[i] = M.protect(l)
    end
  end
  return table.concat(lines, "\n")
end

--- engrave-faces-latex-face-apply for a face outside the preset: its
--- attributes merged along :inherit.
local function face_apply(preset, face, content)
  local a = {}
  local f = face
  while f do
    local e = lookup(preset, f)
    if e then
      for k, v in pairs(e[4]) do
        if a[k] == nil then
          a[k] = v
        end
      end
    end
    f = M.INHERIT[f]
  end
  local open = {}
  if a.bg then
    open[#open + 1] = "\\colorbox[HTML]{" .. a.bg:sub(2) .. "}{"
  end
  if a.fg then
    open[#open + 1] = "\\textcolor[HTML]{" .. a.fg:sub(2) .. "}{"
  end
  if a.strike then
    open[#open + 1] = "\\sout{"
  end
  if a.weight == "bold" or a.weight == "extra-bold" then
    open[#open + 1] = "\\textbf{"
  end
  if a.slant == "italic" then
    open[#open + 1] = "\\textit{"
  end
  return table.concat(open) .. content .. string.rep("}", #open)
end

--- engrave-faces-latex-face-mapper
local function face_mapper(preset, face, content, mathescape)
  local e = face and lookup(preset, face)
  local protected
  if mathescape and face == "font-lock-comment-face" then
    protected = protect_mathescape(content)
  else
    protected = M.protect(content)
  end
  if content:match("^%s+$") then
    return protected
  end
  if e then
    return "\\EF" .. e[3] .. "{" .. protected .. "}"
  end
  if not face then
    return protected
  end
  return face_apply(preset, face, protected)
end

-- Comment starters and their closers: font-lock gives them
-- font-lock-comment-delimiter-face.
local OPENERS = {
  { "^%-%-%[=*%[%s*", "%s*%]=*%]$" },
  { "^%-%-+%s*" },
  { "^/%*+!?%s*", "%s*%*+/$" },
  { "^//+!?%s*" },
  { "^<!%-%-%s*", "%s*%-%->$" },
  { "^%(%*+%s*", "%s*%*+%)$" },
  { "^#+%s*" },
  { "^;+%s*" },
  { "^%%+%s*" },
}

local function split_comment(text)
  for _, o in ipairs(OPENERS) do
    local a = text:match(o[1])
    if a then
      local rest = text:sub(#a + 1)
      local z = o[2] and rest:match(o[2]) or nil
      local body = z and rest:sub(1, #rest - #z) or rest
      local out = { { a, "font-lock-comment-delimiter-face" } }
      if body ~= "" then
        out[#out + 1] = { body, "font-lock-comment-face" }
      end
      if z and z ~= "" then
        out[#out + 1] = { z, "font-lock-comment-delimiter-face" }
      end
      return out
    end
  end
  return { { text, "font-lock-comment-face" } }
end

--- Runs of { text, emacs_face } for CODE in LANG (a single plain run
--- without a tree-sitter parser), adjacent runs of one face merged.
function M.face_runs(code, lang)
  local runs = fontify.flat_runs(code, lang) or { { code } }
  local out = {}
  local function push(text, face)
    local last = out[#out]
    if last and last[2] == face then
      last[1] = last[1] .. text
    else
      out[#out + 1] = { text, face }
    end
  end
  for _, r in ipairs(runs) do
    local name = r[2] and fontify.face(r[2])
    local face = name and M.FACE[name]
    if r[2] and r[2]:match("^constructor") and r[1]:match("^%p+$") then
      -- Lua's table braces: font-lock leaves them alone
      face = nil
    end
    if face == "font-lock-comment-face" then
      for _, p in ipairs(split_comment(r[1])) do
        push(p[1], p[2])
      end
    else
      push(r[1], face)
    end
  end
  return out
end

--- engrave-faces-latex-buffer on CODE: the LaTeX of the engraved code, with
--- the initial \color{EFD} and closing braces moved back before newlines.
---@param code string
---@param lang string|nil
---@param preset table
---@param mathescape boolean|nil
function M.engrave(code, lang, preset, mathescape)
  local out = {}
  for _, r in ipairs(M.face_runs(code, lang)) do
    out[#out + 1] = face_mapper(preset, r[2], r[1], mathescape)
  end
  local s = "\\color{EF" .. lookup(preset, "default")[3] .. "}" .. table.concat(out)
  return (s:gsub("\n(%s*)(}+)", "%2\n%1"))
end

return M
