---@mod org.extensions.lsp.code_actions textDocument/codeAction
---
--- Entry commands (TODO state, priority, schedule, deadline, refile,
--- archive) run the existing org actions at the position through
--- `workspace/executeCommand` ("org.action"); line conversions and org-lint
--- quick fixes are plain text edits.

local links = require("org.links")
local parser = require("org.parser")
local util = require("org.extensions.lsp.util")
local targets = require("org.extensions.lsp.targets")

local M = {}

M.COMMAND = "org.action"

--- Default entry commands: action name and title.
M.ENTRY_ACTIONS = {
  { "todo_next", "Cycle TODO state" },
  { "todo", "Change TODO state…" },
  { "priority", "Set priority…" },
  { "schedule", "Schedule…" },
  { "deadline", "Set deadline…" },
  { "refile", "Refile subtree…" },
  { "archive_subtree", "Archive subtree" },
}

local function command_action(title, uri, lnum, col, action)
  return {
    title = title,
    kind = "refactor",
    command = {
      title = title,
      command = M.COMMAND,
      arguments = { { uri = uri, line = lnum - 1, character = col - 1, action = action } },
    },
  }
end

local function edit_action(title, kind, uri, edits, diag)
  return {
    title = title,
    kind = kind,
    diagnostics = diag and { diag } or nil,
    isPreferred = diag and true or nil,
    edit = { changes = { [uri] = edits } },
  }
end

local function text_edit(lnum, s, e, text)
  return { range = util.range(lnum, s, e), newText = text }
end

---------------------------------------------------------------------------
-- Suggestions for broken links
---------------------------------------------------------------------------

--- Levenshtein distance of two (short) strings, ignoring case.
function M.distance(a, b)
  a, b = a:lower(), b:lower()
  if #a > 80 or #b > 80 then
    return math.huge
  end
  local prev = {}
  for j = 0, #b do
    prev[j] = j
  end
  for i = 1, #a do
    local cur = { [0] = i }
    local ca = a:sub(i, i)
    for j = 1, #b do
      local cost = ca == b:sub(j, j) and 0 or 1
      cur[j] = math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
    end
    prev = cur
  end
  return prev[#b]
end

--- Up to three candidates close to `word`.
local function closest(word, candidates)
  local scored = {}
  local seen = {}
  local max = math.max(2, math.floor(#word / 3))
  for _, c in ipairs(candidates) do
    if not seen[c] and c ~= "" then
      seen[c] = true
      local d = M.distance(word, c)
      local contains = c:lower():find(word:lower(), 1, true) or word:lower():find(c:lower(), 1, true)
      if d <= max or (contains and #word >= 3) then
        scored[#scored + 1] = { c, contains and math.min(d, 1) or d }
      end
    end
  end
  table.sort(scored, function(x, y)
    return x[2] < y[2] or (x[2] == y[2] and x[1] < y[1])
  end)
  local out = {}
  for i = 1, math.min(3, #scored) do
    out[i] = scored[i][1]
  end
  return out
end

local function link_at_diag(doc, d)
  local lnum, col = d.data.lnum, d.data.col
  local line = doc.lines[lnum] or ""
  for _, l in ipairs(links.parse_links(line)) do
    if col >= l.start_col and col <= l.end_col then
      return lnum, l
    end
  end
end

local function fix_link(doc, d, kind)
  local lnum, l = link_at_diag(doc, d)
  if not l or l.raw:sub(1, 2) ~= "[[" then
    return {}
  end
  local idx = targets.index(doc.file)
  local prefix, word, candidates = "", l.path, {}
  if kind == "custom_id" then
    prefix = "#"
    for _, hl in ipairs(doc.file.headlines) do
      candidates[#candidates + 1] = hl.properties.CUSTOM_ID
    end
  else
    if word:sub(1, 1) == "*" then
      prefix, word = "*", word:sub(2)
    else
      for _, t in pairs(idx.targets) do
        candidates[#candidates + 1] = t.text
      end
      for _, n in pairs(idx.names) do
        candidates[#candidates + 1] = n.text
      end
    end
    for _, hl in ipairs(doc.file.headlines) do
      candidates[#candidates + 1] = links.normalize_string(hl.title)
    end
  end
  local out = {}
  for _, c in ipairs(closest(word, candidates)) do
    local s = l.start_col + 2
    local e = s + #l.raw_target - 1
    out[#out + 1] = edit_action(
      string.format("Change link to %s%s", prefix, c),
      "quickfix",
      doc.uri,
      { text_edit(lnum, s, e, links.escape(prefix .. c)) },
      d
    )
  end
  return out
end

---------------------------------------------------------------------------
-- org-lint quick fixes
---------------------------------------------------------------------------

local TAGS = "(:[%w_@#%%:\128-\255]+:)%s*$"

M.fixers = {
  ["spurious-colons"] = function(doc, d)
    local lnum = d.data.lnum
    local line = doc.lines[lnum] or ""
    local s, _, tags = line:find("%s" .. TAGS)
    if not s then
      return {}
    end
    s = s + 1
    local list = vim.tbl_filter(function(t)
      return t ~= ""
    end, vim.split(tags:sub(2, -2), ":", { plain = true }))
    local new = #list > 0 and (":" .. table.concat(list, ":") .. ":") or ""
    local from = #list > 0 and s or (line:sub(1, s - 1):find("%s*$"))
    return {
      edit_action(
        "Remove the spurious colons from the tags",
        "quickfix",
        doc.uri,
        { text_edit(lnum, from, s + #tags - 1, new) },
        d
      ),
    }
  end,
  ["planning-inactive"] = function(doc, d)
    local lnum = d.data.lnum
    local line = doc.lines[lnum] or ""
    local edits = {}
    for _, kw in ipairs({ "SCHEDULED", "DEADLINE" }) do
      local ks = line:find(kw .. ":", 1, true)
      if ks then
        local os_, oe = line:find("^%s*%[[^%]]*%]", ks + #kw + 1)
        if os_ then
          local open = line:find("[", os_, true)
          edits[#edits + 1] = text_edit(lnum, open, open, "<")
          edits[#edits + 1] = text_edit(lnum, oe, oe, ">")
        end
      end
    end
    if #edits == 0 then
      return {}
    end
    return { edit_action("Make the planning timestamp active", "quickfix", doc.uri, edits, d) }
  end,
  ["obsolete-affiliated-keywords"] = function(doc, d)
    local lnum = d.data.lnum
    local line = doc.lines[lnum] or ""
    local repl = d.message:match('Use "([%w_]+)" instead')
    local s, e = line:find("#%+[%a]+:")
    if not repl or not s then
      return {}
    end
    return {
      edit_action(
        "Replace with #+" .. repl .. ":",
        "quickfix",
        doc.uri,
        { text_edit(lnum, s, e, "#+" .. repl .. ":") },
        d
      ),
    }
  end,
  ["invalid-custom-id-link"] = function(doc, d)
    return fix_link(doc, d, "custom_id")
  end,
  ["invalid-fuzzy-link"] = function(doc, d)
    return fix_link(doc, d, "fuzzy")
  end,
}

---------------------------------------------------------------------------
-- Line conversions
---------------------------------------------------------------------------

local function conversions(doc, lnum)
  local line = doc.lines[lnum]
  local out = {}
  if not line or line:match("^%s*$") or parser.headline_level(line) then
    return out
  end
  if line:match("^%s*#%+") or line:match("^%s*|") or line:match("^%s*:%w*:") then
    return out
  end
  out[#out + 1] = command_action("Convert line to heading", doc.uri, lnum, 1, "toggle_heading")
  out[#out].kind = "refactor.rewrite"
  local indent, bullet, rest = line:match("^(%s*)([-+*] )(.*)$")
  if not bullet then
    indent, bullet, rest = line:match("^(%s*)(%d+[.)] )(.*)$")
  end
  if bullet and indent == "" and bullet == "* " then
    bullet = nil
  end
  if bullet then
    if not rest:match("^%[[ Xx%-]%]") then
      local col = #indent + #bullet + 1
      out[#out + 1] =
        edit_action("Convert item to checkbox", "refactor.rewrite", doc.uri, { text_edit(lnum, col, col - 1, "[ ] ") })
    end
  else
    local ind, text = line:match("^(%s*)(.*)$")
    out[#out + 1] = edit_action(
      "Convert line to checkbox item",
      "refactor.rewrite",
      doc.uri,
      { text_edit(lnum, #ind + 1, #ind + #text, "- [ ] " .. text) }
    )
  end
  return out
end

--- textDocument/codeAction
---@param doc org.lsp.Doc
---@param params table
---@return table[] CodeAction[]
function M.actions(doc, params)
  local o = util.opts().code_actions or {}
  local lnum, col = util.from_pos(params.range.start)
  local only = params.context and params.context.only
  local out = {}
  for _, d in ipairs(params.context and params.context.diagnostics or {}) do
    local checker = type(d.data) == "table" and d.data.checker or d.code
    local fix = checker and M.fixers[checker]
    if fix and d.source == "org-lint" then
      if type(d.data) ~= "table" then
        d.data = { checker = checker, lnum = d.range.start.line + 1, col = d.range.start.character + 1 }
      end
      local ok, res = pcall(fix, doc, d)
      if ok then
        vim.list_extend(out, res)
      end
    end
  end
  if o.conversions ~= false then
    vim.list_extend(out, conversions(doc, lnum))
  end
  local hl = doc.file:headline_at(lnum)
  if hl and o.entry ~= false then
    local list = type(o.entry) == "table" and o.entry or M.ENTRY_ACTIONS
    for _, a in ipairs(list) do
      if require("org.actions").list[a[1]] then
        out[#out + 1] = command_action(a[2] or a[1], doc.uri, lnum, col, a[1])
      end
    end
  end
  if only then
    out = vim.tbl_filter(function(a)
      for _, k in ipairs(only) do
        if a.kind == k or a.kind:sub(1, #k + 1) == k .. "." then
          return true
        end
      end
      return false
    end, out)
  end
  return out
end

--- workspace/executeCommand "org.action": run an org action at a position
--- of a document, in a window showing it.
---@param args { uri: string, line: integer, character: integer, action: string }
function M.execute(args)
  if type(args) ~= "table" or not args.action or not args.uri then
    return false
  end
  local path = vim.uri_to_fname(args.uri)
  local bufnr = require("org.utils").find_buffer(path) or vim.fn.bufadd(path)
  vim.fn.bufload(bufnr)
  local win = vim.fn.bufwinid(bufnr)
  if win == -1 then
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, bufnr)
  end
  vim.api.nvim_set_current_win(win)
  local last = vim.api.nvim_buf_line_count(bufnr)
  pcall(vim.api.nvim_win_set_cursor, win, { math.min(args.line + 1, last), args.character or 0 })
  return require("org.actions").run(args.action)
end

return M
