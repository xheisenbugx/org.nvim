---@mod org.export.fontify Source code highlighting for the exporters
---
--- Emacs colours exported code with the major mode's font-lock (htmlize for
--- HTML, htmlfontify for ODT). Here tree-sitter's highlights query gives the
--- faces, and the highlight groups of the current colour scheme their look.

local M = {}

--- Tree-sitter capture -> Emacs face name without the font-lock- prefix and
--- -face suffix (the htmlize CSS class after the prefix). The first matching
--- prefix wins; `false` = no face (like font-lock, which leaves plain
--- variable uses alone).
M.FACES = {
  { "comment.documentation", "doc" },
  { "comment", "comment" },
  { "string.escape", "escape" },
  { "string.regexp", "regexp" },
  { "string", "string" },
  { "character", "string" },
  { "keyword", "keyword" },
  { "conditional", "keyword" },
  { "repeat", "keyword" },
  { "exception", "keyword" },
  { "include", "keyword" },
  { "function.builtin", "builtin" },
  { "function.call", "function-call" },
  { "function.method.call", "function-call" },
  { "function.macro", "preprocessor" },
  { "function", "function-name" },
  { "method", "function-name" },
  { "constructor", "type" },
  { "variable.builtin", "builtin" },
  { "variable.member", "property-use" },
  { "variable.parameter", false },
  { "variable", false },
  { "type.builtin", "type" },
  { "type", "type" },
  { "constant.builtin", "constant" },
  { "constant.macro", "preprocessor" },
  { "constant", "constant" },
  { "boolean", "constant" },
  { "number", "number" },
  { "float", "number" },
  { "operator", "operator" },
  { "punctuation.bracket", "bracket" },
  { "punctuation.delimiter", "delimiter" },
  { "punctuation", "misc-punctuation" },
  { "property", "property-name" },
  { "attribute", "preprocessor" },
  { "preproc", "preprocessor" },
  { "define", "preprocessor" },
  { "tag.attribute", "variable-name" },
  { "tag.delimiter", "delimiter" },
  { "tag", "function-name" },
  { "module", "type" },
  { "namespace", "type" },
  { "label", "constant" },
}

--- The face name of a capture ("keyword.return" -> "keyword"), or nil.
function M.face(capture)
  for _, f in ipairs(M.FACES) do
    local p = f[1]
    if capture == p or capture:sub(1, #p + 1) == p .. "." then
      return f[2] or nil
    end
  end
  return (capture:gsub("%.", "-"))
end

--- Tree-sitter language for an Org source block language.
function M.ts_lang(lang)
  local ft = vim.filetype.match({ filename = "x." .. lang }) or lang
  local ok, tslang = pcall(vim.treesitter.language.get_lang, ft)
  return ok and tslang or lang
end

--- Split `code` into highlighted runs: one list per line of { text, capture }
--- (capture nil for plain text), or nil when the language has no
--- tree-sitter parser or highlights query.
---@param code string
---@param lang string
---@return table[]|nil
function M.runs(code, lang)
  if not lang or lang == "" then
    return nil
  end
  local tslang = M.ts_lang(lang)
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
    local runs = {}
    local c = 1
    while c <= #l do
      local cap = marks[i][c]
      local e = c
      while e < #l and marks[i][e + 1] == cap do
        e = e + 1
      end
      runs[#runs + 1] = { l:sub(c, e), cap }
      c = e + 1
    end
    out[i] = runs
  end
  return out
end

--- Resolved attributes of a highlight group (links followed), or {}.
function M.hl(group, lang)
  local names = lang and { group .. "." .. lang, group } or { group }
  for _, name in ipairs(names) do
    local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
    if ok and hl and next(hl) then
      return hl
    end
  end
  return {}
end

--- CSS declarations of a highlight group, in htmlize's order
--- (htmlize-css-specs): color, background-color, font-weight, font-style,
--- text-decoration.
---@return string[]
function M.css_specs(hl)
  local specs = {}
  if hl.fg then
    specs[#specs + 1] = string.format("color: #%06x;", hl.fg)
  end
  if hl.bg then
    specs[#specs + 1] = string.format("background-color: #%06x;", hl.bg)
  end
  if hl.bold then
    specs[#specs + 1] = "font-weight: bold;"
  end
  if hl.italic then
    specs[#specs + 1] = "font-style: italic;"
  end
  if hl.underline or hl.undercurl or hl.underdouble or hl.underdotted or hl.underdashed then
    specs[#specs + 1] = "text-decoration: underline;"
  elseif hl.strikethrough then
    specs[#specs + 1] = "text-decoration: line-through;"
  end
  return specs
end

return M
