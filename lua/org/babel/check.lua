---@mod org.babel.check Header argument checks, named blocks and block editing
---
--- Part of org.babel: it adds its functions to that module, which it
--- requires back. Load it through `require("org.babel")`.

local blocks_mod = require("org.babel.blocks")
local results = require("org.babel.results")
local utils = require("org.utils")

local M = require("org.babel")
local P = require("org.babel.internal")

local buf_lines = M.buf_lines
local block_at_cursor = P.block_at_cursor
local show_scratch = P.show_scratch

--- Header arguments known to Org Babel (for completion and checking).
M.HEADER_ARGS = {
  cache = { "yes", "no" },
  cmdline = {},
  colnames = { "nil", "no", "yes" },
  comments = { "no", "link", "yes", "org", "both", "noweb" },
  dir = {},
  epilogue = {},
  eval = { "yes", "no", "query", "never", "never-export", "no-export", "query-export", "strip-export" },
  exports = { "code", "results", "both", "none" },
  file = {},
  ["file-desc"] = {},
  ["file-ext"] = {},
  ["file-mode"] = {},
  hlines = { "no", "yes" },
  mkdirp = { "yes", "no" },
  ["no-expand"] = {},
  noeval = {},
  noweb = { "yes", "no", "tangle", "no-export", "strip-export", "strip-tangle", "eval", "tangle-eval" },
  ["noweb-prefix"] = { "yes", "no" },
  ["noweb-ref"] = {},
  ["noweb-sep"] = {},
  ["output-dir"] = {},
  padline = { "yes", "no" },
  post = {},
  prologue = {},
  results = {
    "value",
    "output",
    "table",
    "vector",
    "list",
    "scalar",
    "verbatim",
    "file",
    "raw",
    "org",
    "html",
    "latex",
    "code",
    "pp",
    "drawer",
    "link",
    "graphics",
    "replace",
    "silent",
    "none",
    "append",
    "prepend",
  },
  rownames = { "no", "yes" },
  sep = {},
  separator = {},
  session = { "none" },
  stdin = {},
  shebang = {},
  tangle = { "yes", "no" },
  ["tangle-mode"] = {},
  var = {},
  wrap = {},
  -- language specific (org-babel-header-args:LANG)
  db = {},
  ["return"] = {},
  python = {},
  preamble = {},
  ruby = {},
  cmd = {},
  includes = {},
  defines = {},
  namespaces = {},
  flags = {},
  libs = {},
  main = { "yes", "no" },
  engine = { "postgresql", "mysql", "mssql", "sqsh", "vertica", "monetdb", "dbi", "oracle", "saphana" },
  dbhost = {},
  dbport = {},
  dbuser = {},
  dbpassword = {},
  database = {},
  ["out-file"] = {},
  header = {},
  echo = {},
  bail = {},
  csv = {},
  column = {},
  html = {},
  line = {},
  list = {},
  nullvalue = {},
  readonly = { "yes", "no" },
}

--- Levenshtein distance (org-string-distance).
local function distance(a, b)
  local prev = {}
  for j = 0, #b do
    prev[j] = j
  end
  for i = 1, #a do
    local cur = { [0] = i }
    for j = 1, #b do
      local cost = a:sub(i, i) == b:sub(j, j) and 0 or 1
      cur[j] = math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
    end
    prev = cur
  end
  return prev[#b]
end

--- Common header argument names (org-babel-header-arg-names).
local COMMON_HEADERS = {
  "cache",
  "cmdline",
  "colnames",
  "comments",
  "dir",
  "eval",
  "exports",
  "epilogue",
  "file",
  "file-desc",
  "file-ext",
  "file-mode",
  "hlines",
  "mkdirp",
  "no-expand",
  "noeval",
  "noweb",
  "noweb-ref",
  "noweb-sep",
  "noweb-prefix",
  "output-dir",
  "padline",
  "post",
  "prologue",
  "results",
  "rownames",
  "sep",
  "session",
  "shebang",
  "tangle",
  "tangle-mode",
  "var",
  "wrap",
}

--- C-c C-v c: like org-babel-check-src-block, report a header argument of
--- the #+begin_src line that is not a known one but is within 2 edits of
--- one ("suspiciously close"). Returns { header, name } or {}.
function M.check_block()
  local _, src = block_at_cursor()
  if not src then
    return
  end
  local known = {}
  for _, n in ipairs(COMMON_HEADERS) do
    known[n] = true
  end
  for _, p in ipairs(blocks_mod.parse_header_string(src.params or "")) do
    if not known[p.key] then
      for _, n in ipairs(COMMON_HEADERS) do
        if distance(p.key, n) <= 2 then
          utils.error(string.format('Supplied header "%s" is suspiciously close to "%s"', p.key, n))
          return { p.key, n }
        end
      end
    end
  end
  utils.notify("No suspicious header arguments found.")
  return {}
end

--- C-c C-v j: insert a header argument on the #+begin_src line.
---@param key? string
---@param value? string
function M.insert_header_arg(key, value)
  local bufnr = vim.api.nvim_get_current_buf()
  local b = M.at_block(bufnr, vim.api.nvim_win_get_cursor(0)[1])
  if not b or b.call then
    utils.warn("No source block at point")
    return
  end
  if not key then
    local names = vim.tbl_keys(M.HEADER_ARGS)
    table.sort(names)
    key = utils.select(names, { prompt = "Header argument" })
    if not key then
      return
    end
  end
  if not value then
    local choices = M.HEADER_ARGS[key] or {}
    if #choices > 0 then
      value = utils.select(choices, { prompt = ":" .. key })
    else
      value = utils.input({ prompt = ":" .. key .. " " })
    end
    if value == nil then
      return
    end
  end
  local line = vim.api.nvim_buf_get_lines(bufnr, b.start - 1, b.start, false)[1]
  local text = ":" .. key .. (vim.trim(value) ~= "" and (" " .. vim.trim(value)) or "")
  vim.api.nvim_buf_set_lines(bufnr, b.start - 1, b.start, false, { (line:gsub("%s+$", "")) .. " " .. text })
end

--- Names of the src blocks in `lines`.
local function block_names(lines)
  local names = {}
  for _, b in ipairs(blocks_mod.parse_blocks(lines)) do
    if b.name and not b.call then
      names[#names + 1] = b.name
    end
  end
  return names
end

--- C-c C-v g: go to a named src block (org-babel-goto-named-src-block).
function M.goto_named_block(name)
  local lines = buf_lines(0)
  if not name then
    local names = block_names(lines)
    if #names == 0 then
      utils.notify("No named src blocks")
      return
    end
    name = utils.select(names, { prompt = "Src block" })
    if not name then
      return
    end
  end
  local b = M.find_named_block(lines, name)
  if not b or b.lob then
    utils.warn("No src block named " .. name)
    return
  end
  vim.cmd("normal! m'")
  vim.api.nvim_win_set_cursor(0, { b.name_line or b.start, 0 })
  pcall(vim.cmd, "normal! zv")
end

--- C-c C-v r: go to a named result (org-babel-goto-named-result).
function M.goto_named_result(name)
  local lines = buf_lines(0)
  if not name then
    local names = {}
    for _, l in ipairs(lines) do
      local nm = blocks_mod.match_results(l)
      if nm and nm ~= "" then
        names[#names + 1] = nm
      end
    end
    if #names == 0 then
      utils.notify("No named results")
      return
    end
    name = utils.select(names, { prompt = "Result" })
    if not name then
      return
    end
  end
  for i, l in ipairs(lines) do
    if blocks_mod.match_results(l) == name then
      vim.cmd("normal! m'")
      vim.api.nvim_win_set_cursor(0, { i, 0 })
      pcall(vim.cmd, "normal! zv")
      return
    end
  end
  utils.warn("No result named " .. name)
end

--- C-c C-v u: go to the #+begin_src line of the block at the cursor.
function M.goto_block_head()
  local b = M.at_block(0, vim.api.nvim_win_get_cursor(0)[1])
  if not b then
    utils.warn("Not in a src block")
    return
  end
  vim.cmd("normal! m'")
  vim.api.nvim_win_set_cursor(0, { b.start, 0 })
end

--- C-c C-v o: open the result of the block: a file link is followed,
--- anything else is shown in a scratch buffer.
function M.open_result()
  local bufnr = vim.api.nvim_get_current_buf()
  local b = M.at_block(bufnr, vim.api.nvim_win_get_cursor(0)[1])
  if not b or not b.results then
    utils.notify("No results for this block")
    return
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, b.results.start, b.results.finish, false)
  local first = vim.trim(lines[1] or "")
  local links = require("org.links").parse_links(first)
  if #lines == 1 and links[1] and links[1].start_col == 1 then
    return require("org.links").open(links[1].target, { bufnr = bufnr })
  end
  local text = results.read(lines)
  if type(text) == "table" then
    return show_scratch(lines, "org", "org-babel-results")
  end
  return show_scratch(vim.split(text, "\n", { plain = true }), "", "org-babel-results")
end

--- C-c C-v d: split the block at the cursor into two blocks, wrap the
--- visual selection in a new block, or insert an empty block
--- (org-babel-demarcate-block).
function M.demarcate_block()
  local bufnr = vim.api.nvim_get_current_buf()
  local mode = vim.fn.mode()
  local visual = mode == "v" or mode == "V" or mode == "\22"
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local b = M.at_block(bufnr, lnum)
  local function header_of(block)
    local l = vim.api.nvim_buf_get_lines(bufnr, block.start - 1, block.start, false)[1]
    return l, vim.api.nvim_buf_get_lines(bufnr, block.finish - 1, block.finish, false)[1]
  end
  if b and not b.call and lnum > b.start and lnum <= b.finish then
    local begin_line, end_line = header_of(b)
    local s, e = lnum, lnum - 1
    if visual then
      local srow, _, erow = utils.visual_range()
      utils.exit_visual()
      s, e = math.max(srow, b.start + 1), math.min(erow, b.finish - 1)
    end
    local body = vim.api.nvim_buf_get_lines(bufnr, b.start, b.finish - 1, false)
    local rel_s, rel_e = s - b.start, e - b.start
    local new = { begin_line }
    vim.list_extend(new, vim.list_slice(body, 1, rel_s - 1))
    vim.list_extend(new, { end_line, "", begin_line })
    vim.list_extend(new, vim.list_slice(body, rel_s, rel_e))
    if visual then
      vim.list_extend(new, { end_line, "", begin_line })
      vim.list_extend(new, vim.list_slice(body, rel_e + 1))
    else
      vim.list_extend(new, vim.list_slice(body, rel_s))
    end
    new[#new + 1] = end_line
    vim.api.nvim_buf_set_lines(bufnr, b.start - 1, b.finish, false, new)
    vim.api.nvim_win_set_cursor(0, { s + 3, 0 })
    return
  end
  -- outside a block: wrap the selection (or insert an empty block)
  local lang = b and not b.call and b.lang or nil
  if not lang then
    local prev
    for _, x in ipairs(blocks_mod.parse_blocks(buf_lines(bufnr))) do
      if not x.call and x.finish < lnum then
        prev = x
      end
    end
    lang = utils.input({ prompt = "Lang: ", default = prev and prev.lang or "" })
    if lang == nil then
      return
    end
    lang = vim.trim(lang)
  end
  local indent = (vim.api.nvim_get_current_line():match("^(%s*)")) or ""
  if visual then
    local srow, _, erow = utils.visual_range()
    utils.exit_visual()
    local sel = vim.api.nvim_buf_get_lines(bufnr, srow - 1, erow, false)
    local new = { indent .. "#+begin_src " .. lang }
    vim.list_extend(new, blocks_mod.escape(sel))
    new[#new + 1] = indent .. "#+end_src"
    vim.api.nvim_buf_set_lines(bufnr, srow - 1, erow, false, new)
    vim.api.nvim_win_set_cursor(0, { srow, 0 })
    return
  end
  local cur = vim.api.nvim_get_current_line()
  local at = cur:match("^%s*$") and lnum - 1 or lnum
  vim.api.nvim_buf_set_lines(bufnr, at, at, false, { indent .. "#+begin_src " .. lang, indent, indent .. "#+end_src" })
  vim.api.nvim_win_set_cursor(0, { at + 2, #indent })
end
