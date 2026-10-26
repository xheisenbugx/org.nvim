-- What the two emphasis highlighters (`ui.highlighter`: "syntax" regions,
-- or "parser", org.ui.emphasis) draw on each byte of a buffer, in one form
-- both can be compared in:
--
--   local hl = require("tests.helpers.highlighter")
--   local a = hl.state(buf, "syntax")
--   local b = hl.state(buf, "parser")
--   local diffs = hl.diff(buf, a, b)
--
-- A byte's state is the emphasis kinds covering it ("bold italic"), a ">"
-- when the innermost one draws a marker there, and "#" when it is hidden
-- (an emphasis marker, a link bracket or target; and whatever else the
-- syntax conceals: macro markers, hidden keywords).
local M = {}

local KINDS = {
  orgbold = "bold",
  orgitalic = "italic",
  orgunderline = "underline",
  orgstrikethrough = "strike",
  orgverbatim = "verbatim",
  orgcode = "code",
}

--- The kind of a syntax or highlight group name, and whether it draws a
--- marker; nil for any other group.
local function kind_of(name)
  name = name:lower()
  local delim = name:match("^(.-)delimiter$")
  local k = KINDS[delim or name]
  if k then
    return k, delim ~= nil
  end
end

--- The groups drawn on byte `c` (1-based) of line `l` of the current
--- buffer, lowercase and joined by " ": its syntax groups (`synstack()`)
--- and the groups of the decoration marks over it, whichever highlighter
--- draws the buffer. "conceal" is added when the byte is hidden.
---@param l integer
---@param c integer
---@return string
function M.groups(l, c)
  local out = {}
  for _, id in ipairs(vim.fn.synstack(l, c)) do
    out[#out + 1] = vim.fn.synIDattr(id, "name"):lower()
  end
  local hidden = vim.fn.synconcealed(l, c)[1] == 1
  for _, m in ipairs(require("org.ui.decorations").line_marks(vim.api.nvim_get_current_buf(), l - 1)) do
    local o = m[2]
    if c - 1 >= m[1] and c - 1 < (o.end_col or m[1] + 1) then
      if o.hl_group then
        out[#out + 1] = o.hl_group:lower()
      end
      hidden = hidden or o.conceal == ""
    end
  end
  if hidden then
    out[#out + 1] = "conceal"
  end
  return table.concat(out, " ")
end

--- Whether group `group` (any case) is drawn on byte `c` of line `l`.
function M.has(l, c, group)
  return (" " .. M.groups(l, c) .. " "):find(" " .. group:lower() .. " ", 1, true) ~= nil
end

--- Draw buffer `buf` with highlighter `engine` (the current window shows it).
function M.use(buf, engine)
  require("org.config").opts.ui.highlighter = engine
  vim.api.nvim_buf_call(buf, function()
    vim.cmd("syntax clear")
    vim.b.current_syntax = nil
    require("org.syntax").apply(buf)
  end)
  require("org.ui.decorations").attach(buf, true)
end

local function format(kinds, delim, hidden)
  table.sort(kinds)
  return table.concat(kinds, " ") .. (delim and ">" or "") .. (hidden and "#" or "")
end

--- Per line, per byte: the state string (see the top of the file).
---@param buf integer shown in the current window
---@param engine "syntax"|"parser"
---@return string[][]
function M.state(buf, engine)
  M.use(buf, engine)
  local out = {}
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local deco = require("org.ui.decorations")
  vim.api.nvim_buf_call(buf, function()
    for l, line in ipairs(lines) do
      local row = {}
      local marks = engine == "parser" and deco.line_marks(buf, l - 1) or {}
      for c = 1, #line do
        local kinds, seen, delim = {}, {}, false
        local hidden = vim.fn.synconcealed(l, c)[1] == 1
        if engine == "syntax" then
          local stack = vim.fn.synstack(l, c)
          local inner
          for _, id in ipairs(stack) do
            local k, d = kind_of(vim.fn.synIDattr(id, "name"))
            if k then
              if not seen[k] then
                seen[k] = true
                kinds[#kinds + 1] = k
              end
              inner = d
            end
          end
          delim = inner or false
        else
          local best = -1
          for _, m in ipairs(marks) do
            local o = m[2]
            if c - 1 >= m[1] and c - 1 < (o.end_col or m[1] + 1) then
              local k, d = kind_of(o.hl_group or "")
              if k then
                if not seen[k] then
                  seen[k] = true
                  kinds[#kinds + 1] = k
                end
                if (o.priority or 0) >= best then
                  best, delim = o.priority or 0, d
                end
              end
              if o.conceal == "" then
                hidden = true
              end
            end
          end
        end
        row[c] = format(kinds, delim, hidden)
      end
      out[l] = row
    end
  end)
  return out
end

local LETTERS = { bold = "b", italic = "i", underline = "u", strike = "s", verbatim = "v", code = "c" }
-- Bold and italic of the syntax of a block's language (Emacs: the faces
-- of its mode, mhtml-mode making <b> text bold and <em> italic)
local NATIVE = {
  htmlbold = { "b" },
  htmlitalic = { "i" },
  htmlbolditalic = { "b", "i" },
  htmlitalicbold = { "b", "i" },
}
local ORDER = "biusvc"

--- Buffer `buf` (shown in the current window) as the Emacs fontify fixture
--- writes it (scripts/emacs-parity/fontify.el): per line with emphasis or
--- hidden bytes, runs of "<count><code>". The faces of hidden bytes are
--- left out: they aren't drawn (Emacs gives emphasis markers no face when
--- it hides them).
---@param engine "syntax"|"parser"
---@return table<integer, string>
function M.emacs_codes(buf, engine)
  local st = M.state(buf, engine)
  local out = {}
  -- Emacs draws fixed-width lines in org-code, where org.nvim has its own
  -- group (orgFixedWidth): "c" from the colon on
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local kinds = require("org.ui.emphasis").kinds(lines)
  for l, row in ipairs(st) do
    local fixed = kinds[l] == "fixed" and lines[l]:find(":", 1, true)
    local runs, cur, n, any = {}, nil, 0, false
    for c, v in ipairs(row) do
      local hidden = v:find("#", 1, true) ~= nil
      local code = ""
      if not hidden then
        local set = {}
        for k in v:gsub("[>#]", ""):gmatch("%S+") do
          set[LETTERS[k]] = true
        end
        if fixed and c >= fixed then
          set.c = true
        end
        -- (the group drawn there: the innermost one; a tag inside the
        -- italic region of <em> is drawn as a tag)
        if kinds[l] == "none" then
          for _, k in ipairs(NATIVE[vim.fn.synIDattr(vim.fn.synID(l, c, 1), "name"):lower()] or {}) do
            set[k] = true
          end
        end
        for i = 1, #ORDER do
          local c = ORDER:sub(i, i)
          if set[c] then
            code = code .. c
          end
        end
      end
      code = hidden and "#" or (code == "" and "." or code)
      any = any or code ~= "."
      if code == cur then
        n = n + 1
      else
        if cur then
          runs[#runs + 1] = n .. cur
        end
        cur, n = code, 1
      end
    end
    if cur then
      runs[#runs + 1] = n .. cur
    end
    if any then
      out[l] = table.concat(runs, ",")
    end
  end
  return out
end

--- Emacs fixture runs with the faces of hidden bytes left out (see
--- `emacs_codes`).
---@param runs string
---@return string
function M.normalize_emacs(runs)
  local out, cur, n = {}, nil, 0
  for count, code in runs:gmatch("(%d+)([^,]+)") do
    if code:find("#", 1, true) then
      code = "#"
    end
    if code == cur then
      n = n + tonumber(count)
    else
      if cur then
        out[#out + 1] = n .. cur
      end
      cur, n = code, tonumber(count)
    end
  end
  if cur then
    out[#out + 1] = n .. cur
  end
  return table.concat(out, ",")
end

--- The lines where states `a` and `b` differ, as readable text: the line,
--- then under each byte that differs both states.
---@return string[]
function M.diff(buf, a, b)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local out = {}
  for l, line in ipairs(lines) do
    local cols = {}
    for c = 1, #line do
      if a[l][c] ~= b[l][c] then
        cols[#cols + 1] = string.format("    col %d %q: %q vs %q", c, line:sub(c, c), a[l][c], b[l][c])
      end
    end
    if #cols > 0 then
      out[#out + 1] = string.format("line %d: %s", l, line)
      for i = 1, math.min(#cols, 6) do
        out[#out + 1] = cols[i]
      end
    end
  end
  return out
end

return M
