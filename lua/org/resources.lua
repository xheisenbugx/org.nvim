---@mod org.resources Remote resources (org-resource-download-policy)
---
--- Whether a URL may be downloaded, like Emacs `org-file-contents`: always
--- with `resource_download_policy = true`, when it is safe (it or the
--- requesting file matches `safe_remote_resources`), or, with "prompt",
--- when the user says so. Answers that mark a URL, its domain or the file
--- safe are remembered in stdpath("data")/org/safe-remote-resources.json
--- (Emacs saves them with customize).

local config = require("org.config")
local utils = require("org.utils")

local M = {}

--- Downloaded contents by URL (org--file-cache).
M._cache = {}

local function store_file()
  return vim.fn.stdpath("data") .. "/org/safe-remote-resources.json"
end

local saved

--- Patterns saved by earlier answers.
local function saved_patterns()
  if not saved then
    saved = {}
    local lines = utils.readfile and utils.readfile(store_file()) or nil
    if lines then
      local ok, list = pcall(vim.json.decode, table.concat(lines, "\n"))
      if ok and type(list) == "table" then
        saved = list
      end
    end
  end
  return saved
end

local function save_pattern(pat)
  local list = saved_patterns()
  if vim.tbl_contains(list, pat) then
    return
  end
  list[#list + 1] = pat
  local file = store_file()
  vim.fn.mkdir(vim.fn.fnamemodify(file, ":h"), "p")
  pcall(vim.fn.writefile, { vim.json.encode(list) }, file)
end

--- URLs whose download was refused or failed this session, so that a
--- parse doesn't ask again.
M._refused = {}

--- Forget the saved patterns (tests).
function M._reset()
  saved = nil
  M._cache = {}
  M._refused = {}
end

local function file_uri(file)
  if not file or file == "" then
    return nil
  end
  return "file://" .. (utils.realpath(file) or vim.fs.normalize(file))
end

--- Is `uri` safe: does it, or "file://" .. the requesting `file`, match
--- one of `safe_remote_resources` (Vim regexes) or a saved answer
--- (org--safe-remote-resource-p)?
---@param uri string
---@param file? string
function M.is_safe(uri, file)
  local furi = file_uri(file)
  local pats = vim.list_extend(vim.deepcopy(config.opts.safe_remote_resources or {}), saved_patterns())
  for _, p in ipairs(pats) do
    local ok, re = pcall(vim.regex, p)
    if ok and (re:match_str(uri) or (furi and re:match_str(furi))) then
      return true
    end
  end
  return false
end

--- The domain part of `uri` as Emacs quotes it: scheme, user and host
--- ("https://www.example.com"), or nil when it isn't http(s).
function M.domain(uri)
  local s, e = uri:find("https?://")
  if not s then
    return nil
  end
  local rest = uri:sub(e + 1)
  local user = rest:match("^[^@/\n]+@") or ""
  rest = rest:sub(#user + 1)
  local www = rest:match("^www%.") or ""
  local host = rest:sub(#www + 1):match("^[^:/?\n]+")
  if not host then
    return nil
  end
  return uri:sub(s, e) .. user .. www .. host
end

--- A Vim regex matching exactly `s` (Emacs: "\\`" (regexp-quote s) "\\'").
local function exactly(s)
  return "^\\V" .. vim.fn.escape(s, "\\") .. "\\$"
end

--- Ask whether `uri` may be downloaded (org--confirm-resource-safe): y (this
--- once, also <Space>), n (skip), ! (and always this URL), d (and the
--- domain), f (and everything requested by `file`). Returns true to fetch.
---@param uri string
---@param file? string
function M.confirm(uri, file)
  local current = file and file ~= "" and (utils.realpath(file) or file) or nil
  local domain = M.domain(uri)
  local lines = {
    "An org-mode document would like to download " .. uri .. ", which is not considered safe.",
    "",
    "Do you want to download this?  You can type",
    " ! to download this resource, and permanently mark it as safe.",
  }
  if domain then
    lines[#lines + 1] = " d to download this resource, and mark the domain (" .. domain .. ") as safe."
  end
  if current then
    lines[#lines + 1] = " f to download this resource, and permanently mark all resources in " .. current .. " as safe."
  end
  lines[#lines + 1] = " y to download this resource, just this once."
  lines[#lines + 1] = " n to skip this resource."
  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  local _, win = require("org.ui").float(lines, {
    title = "Org Remote Resource",
    width = math.min(width + 2, vim.o.columns - 4),
    enter = false,
  })
  vim.wo[win].wrap = true
  local prompt = string.format("Please type y, n%s, d, or !: ", current and ", f" or "")
  local choice
  while not choice do
    vim.api.nvim_echo({ { prompt, "Question" } }, false, {})
    vim.cmd("redraw")
    local ok, ch = pcall(vim.fn.getcharstr)
    if not ok or ch == "\27" or ch == "\3" then
      choice = "n"
    elseif ch == "y" or ch == "n" or ch == "!" or ch == "d" or ch == " " or (ch == "f" and current) then
      choice = ch
    end
  end
  if vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
  vim.api.nvim_echo({ { "" } }, false, {})
  if choice == "!" then
    save_pattern(exactly(uri))
  elseif choice == "d" and domain then
    save_pattern("^\\V" .. vim.fn.escape(domain, "\\") .. "\\(/\\|\\$\\)")
  elseif choice == "f" then
    save_pattern(exactly("file://" .. current))
  end
  return choice ~= "n"
end

--- May `uri`, requested by `file`, be downloaded
--- (org--should-fetch-remote-resource-p)?
---@param uri string
---@param file? string
function M.should_fetch(uri, file)
  local policy = config.opts.resource_download_policy
  if policy == true then
    return true
  end
  if M.is_safe(uri, file) then
    return true
  end
  return policy == "prompt" and M.confirm(uri, file) or false
end

--- Download `uri` with curl. Replaced in tests.
---@return string|nil text, string|nil err
function M._download(uri)
  if vim.fn.executable("curl") == 0 then
    return nil, "curl is needed to download " .. uri
  end
  local res = vim.system({ "curl", "-fsSL", uri }, { text = true }):wait(30000)
  if res.code ~= 0 then
    return nil, "Unable to fetch file from " .. string.format("%q", uri)
  end
  return res.stdout or ""
end

--- The lines of the remote `uri` requested by `file` (org-file-contents),
--- once allowed by `resource_download_policy`; cached for the session.
---@param uri string
---@param file? string
---@return string[]|nil lines, string|nil err
function M.contents(uri, file)
  if M._cache[uri] then
    return M._cache[uri]
  end
  if not M.should_fetch(uri, file) then
    return nil, string.format("The remote resource %q is considered unsafe, and will not be downloaded.", uri)
  end
  local text, err = M._download(uri)
  if not text then
    return nil, err
  end
  local lines = vim.split((text:gsub("\n$", "")), "\n", { plain = true })
  M._cache[uri] = lines
  return lines
end

--- The lines of the remote setup file `uri` of `file` (org-file-contents
--- from org-collect-keywords), or nil. It asks only once a session, and
--- never without a UI or in a fast event (a parse can run anywhere);
--- then only URLs allowed without asking are fetched.
---@param uri string
---@param file? string
---@return string[]|nil
function M.setup_contents(uri, file)
  if M._cache[uri] then
    return M._cache[uri]
  end
  if M._refused[uri] or vim.in_fast_event() then
    return nil
  end
  local policy = config.opts.resource_download_policy
  local can_ask = #vim.api.nvim_list_uis() > 0
  if policy == "prompt" and not can_ask and not M.is_safe(uri, file) then
    return nil
  end
  local lines, err = M.contents(uri, file)
  if not lines then
    M._refused[uri] = true
    if err then
      utils.warn(err)
    end
  end
  return lines
end

return M
