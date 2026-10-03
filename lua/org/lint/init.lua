---@mod org.lint Linting (org-lint)
---
--- Checks an Org buffer for syntax mistakes, like Emacs `org-lint`. The
--- buffer is parsed into elements and objects following Org's element
--- parser (org-element), then every checker reports problems as
--- `{ lnum, col, checker, message, trust }`. Checker names, messages and
--- the reported lines follow Emacs Org 9.8.
---
--- ```lua
--- require("org.lint").lint(0)            -- list of reports
--- require("org.lint").show()             -- location list
--- require("org.lint").show({ "invalid-fuzzy-link" })
--- ```

local M = {}

---@class org.LintReport
---@field lnum integer 1-based line
---@field col integer 1-based byte column
---@field checker string checker name
---@field message string
---@field trust "high"|"low"

local helpers = require("org.lint.helpers")
local object = require("org.lint.object")
local timestamp = require("org.lint.timestamp")

M.parse = object.parse
M._timestamp = timestamp.parse_timestamp
M._interpret_timestamp = timestamp.interpret_timestamp
M._parse_header_args = helpers.parse_header_args
M._duration_p = helpers.duration_p

---------------------------------------------------------------------------
-- Checkers
---------------------------------------------------------------------------

-- Checker functions by name, from the files of lua/org/lint/checkers/.
local C = {}
for _, group in ipairs({
  "structure",
  "babel",
  "links",
  "keywords",
  "properties",
  "footnotes",
  "elements",
  "citations",
  "markup",
}) do
  for name, fn in pairs(require("org.lint.checkers." .. group)) do
    C[name] = fn
  end
end

--- Checkers in Emacs registration order: name, trust, summary.
M.checkers = {
  { "misplaced-heading", "low", "Report accidentally misplaced heading lines." },
  { "duplicate-custom-id", "high", "Report duplicate CUSTOM_ID properties" },
  { "duplicate-name", "high", "Report duplicate NAME values" },
  { "duplicate-target", "high", "Report duplicate targets" },
  { "duplicate-footnote-definition", "high", "Report duplicate footnote definitions" },
  { "orphaned-affiliated-keywords", "low", "Report orphaned affiliated keywords" },
  { "combining-keywords-with-affiliated", "low", "Report independent keywords preceding affiliated keywords." },
  { "obsolete-affiliated-keywords", "high", "Report obsolete affiliated keywords" },
  { "deprecated-export-blocks", "low", "Report deprecated export block syntax" },
  { "deprecated-header-syntax", "low", "Report deprecated Babel header syntax" },
  { "missing-language-in-src-block", "high", "Report missing language in source blocks" },
  { "suspicious-language-in-src-block", "low", "Report suspicious language in source blocks" },
  { "missing-backend-in-export-block", "high", "Report missing backend in export blocks" },
  { "invalid-babel-call-block", "high", "Report invalid Babel call blocks" },
  { "wrong-header-argument", "high", "Report wrong babel headers" },
  { "wrong-header-value", "low", "Report invalid value in babel headers" },
  { "named-result", "high", "Report results evaluation with #+name keyword." },
  { "empty-header-argument", "low", "Report empty values in babel headers" },
  { "deprecated-category-setup", "high", "Report misuse of CATEGORY keyword" },
  { "invalid-coderef-link", "high", 'Report "coderef" links with unknown destination' },
  { "invalid-custom-id-link", "high", 'Report "custom-id" links with unknown destination' },
  { "invalid-fuzzy-link", "high", 'Report "fuzzy" links with unknown destination' },
  { "invalid-id-link", "high", 'Report "id" links with unknown destination' },
  { "trailing-bracket-after-link", "low", "Report potentially confused trailing ']' after link." },
  { "unclosed-brackets-in-link-description", "low", "Report unclosed '[' in link description." },
  { "link-to-local-file", "low", "Report links to non-existent local files" },
  { "non-existent-setupfile-parameter", "low", "Report SETUPFILE keywords with non-existent file parameter" },
  { "wrong-include-link-parameter", "low", "Report INCLUDE keywords with misleading link parameter" },
  { "obsolete-include-markup", "low", "Report obsolete markup in INCLUDE keyword" },
  { "unknown-options-item", "low", "Report unknown items in OPTIONS keyword" },
  { "misspelled-export-option", "low", "Report potentially misspelled export options in properties." },
  { "invalid-macro-argument-and-template", "low", "Report spurious macro arguments or invalid macro templates" },
  { "special-property-in-properties-drawer", "high", "Report special properties in properties drawers" },
  { "obsolete-properties-drawer", "high", "Report obsolete syntax for properties drawers" },
  { "invalid-effort-property", "high", "Report invalid duration in EFFORT property" },
  { "invalid-id-property", "high", 'Report search string delimiter "::" in ID property' },
  { "undefined-footnote-reference", "high", "Report missing definition for footnote references" },
  { "unreferenced-footnote-definition", "high", "Report missing reference for footnote definitions" },
  { "extraneous-element-in-footnote-section", "high", "Report non-footnote definitions in footnote section" },
  { "invalid-keyword-syntax", "low", "Report probable invalid keywords" },
  { "invalid-image-alignment", "high", "Report unsupported align attribute for keyword" },
  { "invalid-block", "low", "Report invalid blocks" },
  { "mismatched-planning-repeaters", "low", "Report mismatched repeaters in planning info line" },
  { "misplaced-planning-info", "low", "Report misplaced planning info line" },
  { "incomplete-drawer", "low", "Report probable incomplete drawers" },
  { "indented-diary-sexp", "low", "Report probable indented diary-sexps" },
  { "quote-section", "low", "Report obsolete QUOTE section" },
  { "file-application", "high", 'Report obsolete "file+application" link' },
  { "percent-encoding-link-escape", "low", "Report obsolete escape syntax in links" },
  { "spurious-colons", "high", "Report spurious colons in tags" },
  { "non-existent-bibliography", "high", "Report invalid bibliography file" },
  { "missing-print-bibliography", "high", 'Report missing "print_bibliography" keyword' },
  { "invalid-cite-export-declaration", "high", 'Report invalid value for "cite_export" keyword' },
  { "incomplete-citation", "low", "Report incomplete citation object" },
  { "item-number", "high", "Report inconsistent item numbers in lists" },
  { "priority", "high", "Report out-of-bounds, invalid, and malformed priorities." },
  { "LaTeX-$-fragment", "high", "Report potentially confusing $...$ LaTeX markup.", default = false },
  { "LaTeX-$", "low", "Report $ that might be treated as LaTeX fragment boundary." },
  { "beamer-frame", "low", "Report that frame text contains beamer frame environment." },
  { "timestamp-syntax", "low", "Report malformed timestamps." },
  { "clock-syntax", "low", "Report malformed clocks." },
  { "planning-inactive", "high", "Report inactive timestamps in SCHEDULED/DEADLINE." },
}

--- Names of the checkers run by default.
---@return string[]
function M.checker_names()
  local out = {}
  for _, c in ipairs(M.checkers) do
    if c.default ~= false then
      out[#out + 1] = c[1]
    end
  end
  return out
end

---------------------------------------------------------------------------
-- Entry points
---------------------------------------------------------------------------

--- Lint an org buffer (org-lint).
---@param bufnr? integer default current buffer
---@param checkers? string[] checker names (default: all the default checkers)
---@param text? string[] lines linted instead of the buffer's (the buffer
---still gives the file name); report lines are then indexes into `text`
---@return org.LintReport[] reports sorted by position
function M.lint(bufnr, checkers, text)
  return M.check(M.document(bufnr, text), checkers)
end

--- The parsed document the checkers of `lint` look at (for running them
--- in parts with `check`). With `defer`, its objects (links, timestamps,
--- ...) are left for `doc:collect_objects()`, which `check` needs first.
---@param bufnr? integer default current buffer
---@param text? string[] lines instead of the buffer's
---@param defer? boolean
function M.document(bufnr, text, defer)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local lines = text or vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local name = vim.api.nvim_buf_get_name(bufnr)
  local file
  local ok, files = pcall(require, "org.files")
  if text then
    local okf, f = pcall(require("org.parser").parse, text, name ~= "" and name or nil)
    file = okf and f or nil
  elseif ok then
    local okf, f = pcall(files.get_buffer, bufnr)
    file = okf and f or nil
  end
  local doc = M.parse(lines, {
    file = file,
    bufnr = bufnr,
    filename = name,
    dir = name ~= "" and vim.fn.fnamemodify(name, ":p:h") or vim.fn.getcwd(),
    objects = not defer,
  })
  doc.eol = vim.bo[bufnr].eol or vim.bo[bufnr].fixeol
  return doc
end

--- Run checkers on a `document`.
---@param doc table from `document`
---@param checkers? string[] checker names (default: all the default checkers)
---@return org.LintReport[] reports sorted by position
function M.check(doc, checkers)
  local wanted
  if checkers then
    wanted = {}
    for _, n in ipairs(checkers) do
      wanted[n] = true
    end
  end
  -- Emacs keeps its checkers in reverse registration order; reports on
  -- the same position keep that order (stable sort).
  local reports = {}
  for idx = #M.checkers, 1, -1 do
    local c = M.checkers[idx]
    if (wanted and wanted[c[1]]) or (not wanted and c.default ~= false) then
      local okc, res = pcall(C[c[1]], doc)
      if okc then
        for _, r in ipairs(res) do
          reports[#reports + 1] = { lnum = r[1], col = r[2], checker = c[1], message = r[3], trust = c[2] }
        end
      else
        reports[#reports + 1] = {
          lnum = 1,
          col = 1,
          checker = c[1],
          message = "Checker error: " .. tostring(res),
          trust = c[2],
        }
      end
    end
  end
  for i, r in ipairs(reports) do
    r._i = i
  end
  table.sort(reports, function(a, b)
    if a.lnum ~= b.lnum then
      return a.lnum < b.lnum
    end
    if a.col ~= b.col then
      return a.col < b.col
    end
    return a._i < b._i
  end)
  for _, r in ipairs(reports) do
    r._i = nil
  end
  return reports
end

local function report_items(bufnr, reports)
  local last = vim.api.nvim_buf_line_count(bufnr)
  local items = {}
  for _, r in ipairs(reports) do
    items[#items + 1] = {
      bufnr = bufnr,
      lnum = math.min(r.lnum, last),
      col = r.col,
      text = r.checker .. ": " .. r.message:gsub("%s*\n%s*", " "),
      type = r.trust == "low" and "W" or "E",
      user_data = { checker = r.checker },
    }
  end
  return items
end

--- Keys of the report list (org-lint--report-mode): `h` hides the reports
--- of the checker at the cursor (org-lint--hide-checker), `i` also drops
--- the checker from later refreshes (org-lint--ignore-checker) and `g`
--- lints again with the remaining checkers.
local function report_keys(listbuf, srcwin, bufnr, checkers)
  local function current_checker()
    local list = vim.fn.getloclist(srcwin, { items = 0 }).items
    local item = list[vim.fn.line(".")]
    return item and type(item.user_data) == "table" and item.user_data.checker or nil
  end
  local function set_items(items)
    local idx = math.min(vim.fn.line("."), math.max(#items, 1))
    vim.fn.setloclist(srcwin, {}, "r", { title = "org-lint", items = items, idx = idx })
  end
  local function hide()
    local c = current_checker()
    if not c then
      return
    end
    set_items(vim.tbl_filter(function(it)
      return not (type(it.user_data) == "table" and it.user_data.checker == c)
    end, vim.fn.getloclist(srcwin, { items = 0 }).items))
  end
  local opts = { buffer = listbuf, nowait = true, silent = true }
  vim.keymap.set("n", "h", hide, vim.tbl_extend("force", opts, { desc = "org-lint: hide this checker" }))
  vim.keymap.set("n", "i", function()
    local c = current_checker()
    if c then
      checkers = vim.tbl_filter(function(n)
        return n ~= c
      end, checkers)
      hide()
    end
  end, vim.tbl_extend("force", opts, { desc = "org-lint: ignore this checker" }))
  -- r, not Emacs's g: a mapping of g would take gg, g_ and the other g
  -- commands away (the list buffer is not modifiable, so r is free)
  vim.keymap.set("n", "r", function()
    if vim.api.nvim_buf_is_valid(bufnr) then
      set_items(report_items(bufnr, M.lint(bufnr, checkers)))
    end
  end, { buffer = listbuf, silent = true, desc = "org-lint: refresh the reports" })
end

--- Lint the current buffer and show the reports in the location list
--- (the Neovim counterpart of Emacs' "*Org Lint*" report buffer).
---@param checkers? string[] restrict to these checker names
---@return org.LintReport[]|nil
function M.show(checkers)
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.bo[bufnr].filetype ~= "org" then
    require("org.utils").warn("Not in an Org buffer")
    return nil
  end
  if checkers then
    local known = {}
    for _, c in ipairs(M.checkers) do
      known[c[1]] = true
    end
    for _, n in ipairs(checkers) do
      if not known[n] then
        require("org.utils").warn("Unknown org-lint checker: " .. n)
        return nil
      end
    end
  end
  local names = checkers or M.checker_names()
  local reports = M.lint(bufnr, names)
  local win = vim.api.nvim_get_current_win()
  vim.fn.setloclist(win, {}, " ", { title = "org-lint", items = report_items(bufnr, reports) })
  if #reports == 0 then
    require("org.utils").notify("org-lint: no problems found")
  else
    vim.cmd("lopen")
    report_keys(vim.api.nvim_get_current_buf(), win, bufnr, vim.deepcopy(names))
  end
  return reports
end

--- `:Org lint [checker ...]`
---@param args? string checker names separated by spaces
function M.command(args)
  local names = vim.split(args or "", "%s+", { trimempty = true })
  return M.show(#names > 0 and names or nil)
end

return M
