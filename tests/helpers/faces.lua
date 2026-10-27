-- org.nvim's highlighting against every face Emacs Org 9.8.12 draws
-- (tests/fixtures/emacs/faces/expected/, scripts/emacs-parity/faces.el),
-- one family of faces at a time:
--
--   require("tests.helpers.faces").spec("headline", KNOWN)
--
-- runs one test per fixture file comparing, byte by byte, the faces of the
-- family that org.nvim draws there (syntax groups and decoration marks,
-- mapped to Emacs face names by FACE_OF) with those Emacs draws, and "#"
-- (hidden) for the families that own it. The groups org.nvim draws that
-- have no Emacs face (OrgListBullet, OrgHorizontalRule, ...) are left out.
local M = {}

local P = require("tests.emacs_parity")

--- org.nvim group (lowercase: syntax groups and the groups of marks are
--- matched without case) -> the Emacs face it stands for.
M.FACE_OF = {
  -- headlines
  orgheadlinelevel1 = "level-1",
  orgheadlinelevel2 = "level-2",
  orgheadlinelevel3 = "level-3",
  orgheadlinelevel4 = "level-4",
  orgheadlinelevel5 = "level-5",
  orgheadlinelevel6 = "level-6",
  orgheadlinelevel7 = "level-7",
  orgheadlinelevel8 = "level-8",
  orgtodo = "todo",
  orgdone = "done",
  orgheadlinedone = "headline-done",
  orgheadlinetodo = "headline-todo",
  orgheadlinearchived = "archived",
  orgarchived = "archived",
  orgpriority = "priority",
  orgprioritya = "priority",
  orgpriorityb = "priority",
  orgpriorityc = "priority",
  orgtags = "tag",
  orginlinetask = "inlinetask",
  -- (Emacs draws the COMMENT keyword in org-special-keyword)
  orgheadlinecomment = "special-keyword",
  orghiddenstars = "hide",
  -- lists
  orglistterm = "list-dt",
  orgcheckbox = "checkbox",
  orgcheckboxchecked = "checkbox",
  orgcheckboxpartial = "checkbox",
  orgstatistic = "checkbox-statistics-todo",
  orgstatisticdone = "checkbox-statistics-done",
  -- dates and planning
  orgtimestamp = "date",
  orgtimestampinactive = "date",
  orgplanning = "special-keyword",
  orgclock = "special-keyword",
  orgsexpdate = "sexp-date",
  -- keywords, drawers, comments
  orgkeyword = "meta-line",
  orgkeywordvalue = "meta-line",
  orgtitle = "document-title",
  orgtitlekeyword = "document-info-keyword",
  orginfokeyword = "document-info-keyword",
  orginfovalue = "document-info",
  orgdrawer = "drawer",
  orgpropertykey = "special-keyword",
  orgpropertyvalue = "property-value",
  orgcomment = "font-lock-comment-face",
  orgfixedwidth = "code",
  -- tables
  orgtable = "table",
  orgtableseparator = "table",
  orgtablehline = "table",
  orgtableborder = "table",
  orgtableformula = "formula",
  -- blocks and LaTeX
  orgblock = "block",
  orgquoteblock = "quote",
  orgverseblock = "verse",
  orgblockdelimiter = "block-delimiter",
  orglatex = "latex-and-related",
  orglatexentity = "latex-and-related",
  orglatexscript = "latex-and-related",
  -- links and objects
  orglink = "link",
  orglinkplain = "link",
  orglinkbracket = "link",
  orglinktargethidden = "link",
  orgradiolink = "link",
  orgfootnote = "footnote",
  orgtarget = "target",
  orgmacro = "macro",
  orgmacromarker = "macro",
  orginlinesrc = "inline-src-block",
  orginlinesrcmarker = "inline-src-block",
  orginlinesrclang = "inline-src-block",
  orginlinesrcheader = "inline-src-block",
  orginlinesrcbody = "inline-src-block",
  orgexportsnippetmarker = "font-lock-comment-face",
  orgexportsnippetbackend = "tag",
  orgcite = "cite",
  -- emphasis
  orgbold = "bold",
  orgbolddelimiter = "bold",
  orgitalic = "italic",
  orgitalicdelimiter = "italic",
  orgunderline = "underline",
  orgunderlinedelimiter = "underline",
  orgstrikethrough = "strike-through",
  orgstrikethroughdelimiter = "strike-through",
  orgverbatim = "verbatim",
  orgverbatimdelimiter = "verbatim",
  orgcode = "code",
  orgcodedelimiter = "code",
}

--- Emacs faces that stand for one org.nvim face (Emacs face -> name used
--- in the comparison).
M.SAME = {
  ["block-begin-line"] = "block-delimiter",
  ["block-end-line"] = "block-delimiter",
}

--- The faces each family compares ("#": hidden text).
M.FAMILIES = {
  headline = {
    "level-1",
    "level-2",
    "level-3",
    "level-4",
    "level-5",
    "level-6",
    "level-7",
    "level-8",
    "todo",
    "done",
    "headline-done",
    "headline-todo",
    "archived",
    "priority",
    "tag",
    "inlinetask",
    "hide",
  },
  list = { "list-dt", "checkbox", "checkbox-statistics-todo", "checkbox-statistics-done" },
  date = { "date", "special-keyword", "sexp-date" },
  meta = {
    "meta-line",
    "document-title",
    "document-info",
    "document-info-keyword",
    "drawer",
    "special-keyword",
    "property-value",
    "font-lock-comment-face",
    "code",
  },
  table = { "table", "formula" },
  block = { "block", "block-delimiter", "quote", "verse", "latex-and-related" },
  object = { "link", "footnote", "target", "macro", "inline-src-block", "cite", "#" },
  emphasis = { "bold", "italic", "underline", "strike-through", "verbatim", "code", "#" },
}

local function set_of(list)
  local t = {}
  for _, v in ipairs(list) do
    t[v] = true
  end
  return t
end

--- Runs ("<count>:<code>") from per-byte codes.
local function runs(codes)
  local out, cur, n, any = {}, nil, 0, false
  for _, c in ipairs(codes) do
    any = any or c ~= "."
    if c == cur then
      n = n + 1
    else
      if cur then
        out[#out + 1] = n .. ":" .. cur
      end
      cur, n = c, 1
    end
  end
  if cur then
    out[#out + 1] = n .. ":" .. cur
  end
  return any and table.concat(out, ",") or nil
end

--- The code of a set of face names (sorted, "+"), "#" when hidden (the
--- faces of a hidden byte left out: Emacs gives the markers it hides no
--- face, and nothing shows them).
local function code(set, hidden)
  if hidden then
    return "#"
  end
  local names = {}
  for k in pairs(set) do
    names[#names + 1] = k
  end
  table.sort(names)
  local c = #names > 0 and table.concat(names, "+") or "."
  if hidden then
    c = (c == "." and "" or c) .. "#"
  end
  return c
end

--- Emacs runs of a fixture line kept to the faces of `family` (and the
--- hidden flag when the family owns it). `native`: the line is the body of
--- a src, example or export block, where only the block faces count (the
--- language's own faces are another highlighter's).
function M.emacs_line(fixture, family, native)
  local want = set_of(M.FAMILIES[family])
  local codes = {}
  for count, c in fixture:gmatch("(%d+):([^,]+)") do
    local hidden = c:sub(-1) == "#"
    local set = {}
    for name in c:gsub("#$", ""):gmatch("[^+]+") do
      name = M.SAME[name] or name
      if want[name] and not (native and name:find("^font%-lock")) then
        set[name] = true
      end
    end
    local cc = (hidden and want["#"]) and "#" or code(hidden and {} or set, false)
    for _ = 1, tonumber(count) do
      codes[#codes + 1] = cc
    end
  end
  return runs(codes)
end

--- What org.nvim draws on each byte of `buf` (shown in the current
--- window): per line, per byte, the set of Emacs faces (all families) and
--- whether the byte is hidden. With the parser highlighter the syntax only
--- draws the languages of src blocks: it is asked there only.
---@return { [1]: table<string, boolean>, [2]: boolean }[][]
function M.nvim_faces(buf)
  local deco = require("org.ui.decorations")
  local parser = require("org.ui.emphasis").active(buf)
  local out = {}
  vim.api.nvim_buf_call(buf, function()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local kinds = require("org.ui.emphasis").kinds(lines)
    for l, line in ipairs(lines) do
      local marks = deco.line_marks(buf, l - 1)
      local row = {}
      local syntax = not parser or kinds[l] == "none"
      for c = 1, #line do
        local set = {}
        local hidden = false
        if syntax then
          for _, id in ipairs(vim.fn.synstack(l, c)) do
            local f = M.FACE_OF[vim.fn.synIDattr(id, "name"):lower()]
            if f then
              set[f] = true
            end
          end
          hidden = vim.fn.synconcealed(l, c)[1] == 1
        end
        row[c] = { set, hidden }
      end
      for _, m in ipairs(marks) do
        local o = m[2]
        local f = o.hl_group and M.FACE_OF[o.hl_group:lower()]
        for c = m[1] + 1, math.min(#line, o.end_col or m[1] + 1) do
          if f then
            row[c][1][f] = true
          end
          if o.conceal == "" then
            row[c][2] = true
          end
        end
      end
      out[l] = row
    end
  end)
  return out
end

--- `nvim_faces` kept to the faces of `family`: line -> runs (nil: nothing).
function M.nvim_lines(faces, family)
  local want = set_of(M.FAMILIES[family])
  local out = {}
  for l, row in ipairs(faces) do
    local codes = {}
    for c, b in ipairs(row) do
      local set = {}
      for f in pairs(b[1]) do
        if want[f] then
          set[f] = true
        end
      end
      codes[c] = (b[2] and want["#"]) and "#" or code(b[2] and {} or set, false)
    end
    out[l] = runs(codes)
  end
  return out
end

--- The fixture files: name -> path of the input.
function M.fixtures()
  local out = {}
  for _, f in ipairs(vim.fn.globpath(P.dir .. "/faces/expected", "*.txt", false, true)) do
    local name = vim.fn.fnamemodify(f, ":t"):gsub("%.txt$", "")
    out[#out + 1] = { expected = f, name = name }
  end
  table.sort(out, function(a, b)
    return a.name < b.name
  end)
  return out
end

--- The input of a fixture: its name with "-" for "/" (the first match of
--- the files the generator reads).
local function input_of(name)
  for _, dir in ipairs({ "examples", "tests/fixtures/emacs/fontify", "tests/fixtures/emacs/faces" }) do
    local prefix = dir:gsub("/", "-") .. "-"
    if name:sub(1, #prefix) == prefix then
      return P.root .. "/" .. dir .. "/" .. name:sub(#prefix + 1)
    end
  end
end

local cache = {} ---@type table<string, table>

--- Differences on one fixture: a list of "line: text / emacs / org.nvim".
--- (What org.nvim draws is computed once per fixture and engine.)
---@param known? table<integer, string> lines left out (line -> reason)
function M.differences(fx, family, known)
  local expected = {}
  local lines = vim.fn.readfile(input_of(fx.name))
  local key = fx.name .. ":" .. tostring(require("org.config").opts.ui.highlighter)
  local faces = cache[key]
  if not faces then
    local buf = org_buffer(lines, { 1, 0 })
    vim.wo.conceallevel = 2
    faces = M.nvim_faces(buf)
    cache = { [key] = faces }
  end
  local kinds = require("org.ui.emphasis").kinds(lines)
  for _, l in ipairs(P.lines(P.read(fx.expected))) do
    local n, r = l:match("^(%d+)\t(.*)$")
    if n then
      n = tonumber(n)
      -- (a src, example or export block's body: "none" lines that aren't
      -- its begin or end line)
      local native = kinds[n] == "none" and not lines[n]:find("^%s*#%+")
      expected[n] = M.emacs_line(r, family, native)
    end
  end
  local got = M.nvim_lines(faces, family)
  local diffs = {}
  for i = 1, #lines do
    if (expected[i] or "") ~= (got[i] or "") and not (known or {})[i] then
      diffs[#diffs + 1] =
        string.format("%d: %s\n  emacs:    %s\n  org.nvim: %s", i, lines[i], expected[i] or "-", got[i] or "-")
    end
  end
  return diffs, #lines
end

--- One test per fixture file for `family`. `KNOWN`: fixture name ->
--- { [line] = reason }.
function M.spec(family, KNOWN)
  for _, fx in ipairs(M.fixtures()) do
    it(fx.name, function()
      local diffs = M.differences(fx, family, (KNOWN or {})[fx.name])
      eq(
        "",
        table.concat(diffs, "\n", 1, math.min(#diffs, 25)) .. (#diffs > 25 and ("\n... " .. #diffs .. " lines") or "")
      )
    end)
  end
end

return M
