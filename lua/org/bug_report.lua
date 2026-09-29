---@mod org.bug_report Reporting a bug (org-submit-bug-report)
---
--- Emacs composes a mail to the Org mailing list with the Org and Emacs
--- versions and, if you agree, the options you changed. org.nvim's bugs
--- go to its GitHub issues: `:Org bug_report` asks the same questions,
--- puts the report in a buffer and opens a new issue prefilled with it.

local config = require("org.config")
local utils = require("org.utils")

local M = {}

M.ISSUES_URL = "https://github.com/xheisenbugx/org.nvim/issues/new"

--- The privacy notice shown before asking to include the configuration
--- (Emacs's *Warn about privacy* buffer).
M.PRIVACY = {
  "You are about to submit a bug report to the org.nvim issue tracker.",
  "",
  "Please read :h org-installation if your report is about installing",
  "org.nvim, and search https://github.com/xheisenbugx/org.nvim/issues",
  "to see if the issue has already been dealt with.",
  "",
  "We also would like to add your org.nvim configuration to the bug report.",
  "It will help us debugging the issue.",
  "",
  "*HOWEVER*, some options you have set may contain private information.",
  "The names of customers, colleagues, or friends, might appear in the form",
  "of file names, tags, todo states or search strings. If you answer",
  '"yes" to the prompt, you might want to check and remove such private',
  "information before submitting the report.",
}

local function nvim_version()
  local v = vim.version()
  return string.format("NVIM v%d.%d.%d%s", v.major, v.minor, v.patch, v.prerelease and ("-" .. v.prerelease) or "")
end

local function os_name()
  local u = vim.uv.os_uname()
  return string.format("%s %s (%s)", u.sysname, u.release, u.machine)
end

--- The options that differ from their defaults, as `path = value` lines
--- (Emacs: the org- and outline- variables changed from their standard
--- value, and the hooks and functions that are set).
---@return string[]
function M.changed_options()
  local customize = require("org.customize")
  local out = {}
  local function get(tbl, path)
    for _, k in ipairs(path) do
      if type(tbl) ~= "table" then
        return nil
      end
      tbl = tbl[k]
    end
    return tbl
  end
  for _, o in ipairs(customize.options()) do
    if not o.section then
      local cur = get(config.opts, o.path)
      if not vim.deep_equal(cur, get(config.defaults, o.path)) then
        out[#out + 1] = table.concat(o.path, ".") .. " = " .. customize.show(cur)
      end
    end
  end
  return out
end

--- The body of the report.
---@param include_config boolean
---@return string[]
function M.body(include_config)
  local lines = {
    "Remember to cover the basics, that is, what you expected to happen and",
    "what in fact did happen.  You don't know how to make a good report?  See",
    "",
    "     https://github.com/xheisenbugx/org.nvim/blob/main/CONTRIBUTING.md",
    "",
    "------------------------------------------------------------------------",
    "",
    "Neovim  : " .. nvim_version(),
    "Package : " .. require("org.version").string(true),
    "OS      : " .. os_name(),
  }
  if include_config then
    vim.list_extend(lines, { "", "current state:", "==============", "```lua" })
    vim.list_extend(lines, M.changed_options())
    lines[#lines + 1] = "```"
  end
  return lines
end

--- Percent-encode `s` for a URL query.
local function urlencode(s)
  return (s:gsub("[^%w%-%._~]", function(c)
    return string.format("%%%02X", c:byte())
  end))
end

--- The issue URL for `title` and `body`; the body is left out when the
--- URL would be too long for a browser (it is in the report buffer).
---@param title string
---@param body string[]
---@return string url, boolean with_body
function M.url(title, body)
  local base = M.ISSUES_URL .. "?title=" .. urlencode(title)
  local full = base .. "&body=" .. urlencode(table.concat(body, "\n"))
  if #full <= 8000 then
    return full, true
  end
  return base, false
end

--- Submit a bug report (org-submit-bug-report).
function M.submit()
  local _, warn = require("org.ui").float(M.PRIVACY, { title = "Warn about privacy" })
  local include = utils.confirm("Include your org.nvim configuration?")
  if vim.api.nvim_win_is_valid(warn) then
    vim.api.nvim_win_close(warn, true)
  end
  local summary = utils.input({ prompt = "Bug report subject: " })
  if summary == nil then
    return true
  end
  -- Emacs: "[BUG] <subject> [<Org version>]"
  local title = string.format("[BUG] %s [%s]", summary, require("org.version").string(false))
  local body = M.body(include)
  local buf = vim.api.nvim_create_buf(true, true)
  vim.bo[buf].syntax = "markdown"
  pcall(vim.api.nvim_buf_set_name, buf, "org-bug-report")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.list_extend({ "# " .. title, "" }, body))
  vim.cmd("botright split")
  vim.api.nvim_win_set_buf(0, buf)
  local url, with_body = M.url(title, body)
  if not with_body then
    pcall(vim.fn.setreg, "+", table.concat(body, "\n"))
    utils.notify("The report is too long for the issue URL: paste it from this buffer (also in the + register)")
  end
  vim.ui.open(url)
  return true
end

return M
