---@mod org.links.open Following links (org-open-at-point)
---
--- Opening a link by type: files and their apps, id:, help:, man:,
--- info:, attachment: and internal links, the window a link opens in
--- (org-link-frame-setup), path resolution and the open_at_point
--- commands. shell: and elisp: links run in org.links.shell. Part of
--- org.links, which loads it.

local files = require("org.files")
local utils = require("org.utils")
local shared = require("org.links.shared")

local M = require("org.links")

local goto_pos = shared.goto_pos
local lopts = shared.lopts
local push_jump = shared.push_jump
local split_words = shared.split_words

-- open_shell, open_elisp and run_in_terminal come from org.links.shell,
-- which loads after this file: they are looked up in `shared` when called.

-- Files Neovim cannot display usefully open with the system application.
-- Emacs (org-file-apps) opens .pdf, .html and .mm files with the system
-- application and everything else in Emacs, which can display images and
-- office documents; Neovim cannot, so those go to the system app too.
local EXTERNAL_EXT = {
  pdf = true,
  png = true,
  jpg = true,
  jpeg = true,
  gif = true,
  svg = true,
  webp = true,
  bmp = true,
  mp3 = true,
  mp4 = true,
  mkv = true,
  mov = true,
  avi = true,
  wav = true,
  flac = true,
  ogg = true,
  doc = true,
  docx = true,
  xls = true,
  xlsx = true,
  ppt = true,
  pptx = true,
  odt = true,
  ods = true,
  zip = true,
  epub = true,
  dmg = true,
  html = true,
  htm = true,
  xhtml = true,
  mm = true,
}

---------------------------------------------------------------------------
-- Windows (org-link-frame-setup)
---------------------------------------------------------------------------

local function normal_windows()
  local out = {}
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_config(w).relative == "" then
      out[#out + 1] = w
    end
  end
  return out
end

--- Make "another window" current, like `pop-to-buffer` with
--- `inhibit-same-window`: a window already showing `bufnr`, the previous
--- window, any other window, or a new split (below when the window is at
--- least 80 lines high, beside it when at least 160 columns wide, like
--- split-window-sensibly).
local function select_other_window(bufnr)
  local cur = vim.api.nvim_get_current_win()
  local others = vim.tbl_filter(function(w)
    return w ~= cur
  end, normal_windows())
  if bufnr then
    for _, w in ipairs(others) do
      if vim.api.nvim_win_get_buf(w) == bufnr then
        vim.api.nvim_set_current_win(w)
        return
      end
    end
  end
  if #others > 0 then
    -- the previous window, else the next one (like other-window)
    local prev = vim.fn.win_getid(vim.fn.winnr("#"))
    vim.api.nvim_set_current_win(vim.tbl_contains(others, prev) and prev or others[1])
    return
  end
  if vim.api.nvim_win_get_height(cur) < 80 and vim.api.nvim_win_get_width(cur) >= 160 then
    vim.cmd("vsplit")
  else
    vim.cmd("split")
  end
end

--- How file: and id: links open: `links.frame_setup.file`
--- (org-link-frame-setup).
local function file_setup()
  local fs = lopts().frame_setup
  local v = type(fs) == "table" and fs.file or fs
  return v or "other-window"
end

--- Show `path` (a file name) or buffer `bufnr` according to `how`.
local function visit(path, how, bufnr)
  how = how or file_setup()
  if type(how) == "function" then
    return how(path)
  end
  bufnr = bufnr or (path and utils.find_buffer(path))
  if how == "other-window" then
    select_other_window(bufnr)
  elseif how == "split" or how == "vsplit" then
    vim.cmd(how)
  elseif how == "tab" then
    vim.cmd("tab split")
  end
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_set_current_buf(bufnr)
  elseif path then
    vim.cmd("hide edit " .. vim.fn.fnameescape(path))
  end
end

---------------------------------------------------------------------------
-- Opening
---------------------------------------------------------------------------

local function run_external(app, path)
  if type(app) == "function" then
    return app(path)
  end
  if app == "system" or app == "default" then
    return vim.ui.open(path)
  end
  local cmd = vim.split(app, "%s+", { trimempty = true })
  if app:find("%s", 1, true) then
    cmd = vim.tbl_map(function(p)
      -- a function: `%` in the file name is not a capture reference
      return (p:gsub("%%s", function()
        return path
      end))
    end, cmd)
  else
    cmd[#cmd + 1] = path
  end
  vim.system(cmd, { detach = true })
end

--- Directory used to resolve relative paths of links in `bufnr`.
local function base_dir(bufnr)
  -- set on buffers that show another file's text (presentation slides)
  local dir = vim.b[bufnr or 0].org_base_dir
  if dir then
    return dir
  end
  local name = vim.api.nvim_buf_get_name(bufnr or 0)
  if name ~= "" and not name:match("^%a[%w+%-]*://") then
    return vim.fn.fnamemodify(name, ":p:h")
  end
  return vim.fn.getcwd()
end
M.base_dir = base_dir

--- `~user/...` -> that user's home (expand-file-name); `~/` and
--- environment variables are left to utils.expand.
local function expand_user(path)
  local user, rest = path:match("^~([%w_.%-]+)(.*)$")
  if user and (rest == "" or rest:match("^[/\\]")) then
    -- lint: allow expand: ~user, user matched by [%w_.-]+
    local home = vim.fn.expand("~" .. user)
    if home ~= "~" .. user then
      return home .. rest
    end
  end
  return path
end

--- Expand `~`, `~user` and environment variables of a path written in a
--- document, leaving a relative path relative.
local function expand_text(path)
  path = expand_user(path)
  if path == "~" or path:match("^~[/\\]") then
    path = utils.home() .. path:sub(2)
  end
  return (
    path
      :gsub("%${([%w_]+)}", function(v)
        return vim.env[v]
      end)
      :gsub("%$([%w_]+)", function(v)
        return vim.env[v]
      end)
  )
end

--- Resolve a file link path relative to the buffer.
function M.resolve_path(path, bufnr)
  if path == "" then
    local name = vim.api.nvim_buf_get_name(bufnr or 0)
    if name ~= "" then
      return vim.fs.normalize(name)
    end
    return vim.fs.normalize(base_dir(bufnr))
  end
  -- utils.expand, not vim.fn.expand(): the path is document text, and Vim
  -- expansion runs `backticks` as shell commands and interprets % # and
  -- wildcards
  return utils.expand(expand_user(path), base_dir(bufnr))
end

local function warn_err(err)
  if err then
    utils.warn(err)
  end
end

--- A listing of the files matching a wildcard file name (`file:*.org`),
--- like the Dired buffer Emacs opens for it: <CR> opens the file on the
--- line, `q` closes the listing.
local function open_wildcard(pattern, how)
  local dir, glob = pattern:match("^(.*)/([^/]*)$")
  dir = dir ~= "" and dir or "/"
  local matches = vim.fn.glob(pattern, false, true)
  if #matches == 0 then
    utils.warn("No files match " .. pattern)
    return false
  end
  table.sort(matches)
  local lines = { "  " .. dir .. ":", "  wildcard " .. glob }
  for _, m in ipairs(matches) do
    lines[#lines + 1] = "  " .. vim.fn.fnamemodify(m, ":t") .. (utils.is_dir(m) and "/" or "")
  end
  if type(how) ~= "function" then
    visit(nil, how)
  end
  local buf = vim.api.nvim_create_buf(true, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  pcall(vim.api.nvim_buf_set_name, buf, pattern)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_win_set_cursor(0, { 3, 2 })
  vim.b[buf].org_wildcard_files = matches
  vim.keymap.set("n", "<CR>", function()
    local i = vim.api.nvim_win_get_cursor(0)[1] - 2
    local file = matches[i]
    if file then
      vim.cmd("edit " .. vim.fn.fnameescape(file))
    end
  end, { buffer = buf, desc = "org: open file" })
  for _, lhs in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", lhs, "<Cmd>bwipeout<CR>", { buffer = buf, desc = "org: close listing" })
  end
  return true
end

--- The file a file link's `path` opens, from buffer `bufnr`: relative to
--- the buffer's directory, a directory's index.org with
--- `links.open_directory_means_index_dot_org`.
---@param path string
---@param bufnr? integer
---@return string
function M.file_link_path(path, bufnr)
  local full = M.resolve_path(path, bufnr)
  if lopts().open_directory_means_index_dot_org and utils.is_dir(full) then
    -- org-open-directory-means-index-dot-org
    full = full:gsub("/+$", "") .. "/index.org"
  end
  return full
end

--- Open a file link (org-open-file). `app` is "vim" (C-u: always in
--- Neovim), "system" (C-u C-u) or nil.
local function open_file_link(path, search, o)
  o = o or {}
  local full = M.file_link_path(path, o.bufnr)
  -- a wildcard in the file name opens a listing of the matches
  -- (org-link-open-as-file: dired)
  if (vim.fn.fnamemodify(full, ":t")):find("[*?{]") and not utils.exists(full) then
    return open_wildcard(full, o.how)
  end
  local ext = (full:match("%.([%w]+)$") or ""):lower()
  local apps = lopts().file_apps or {}
  -- external apps might choke on a missing file (org-open-non-existing-files)
  local function exists_for_app()
    if lopts().open_non_existing_files or utils.exists(full) then
      return true
    end
    utils.error("No such file: " .. full)
    return false
  end
  if o.app == "system" then
    return exists_for_app() and vim.ui.open(full) or nil
  end
  if o.app ~= "vim" then
    local app = apps[ext]
    if app and app ~= "vim" and app ~= "emacs" then
      if not exists_for_app() then
        return nil
      end
      return run_external(app, full)
    end
    if EXTERNAL_EXT[ext] and not app then
      return exists_for_app() and vim.ui.open(full) or nil
    end
  end
  visit(full, o.how)
  if search and search ~= "" then
    if search:match("^%d+$") then
      goto_pos(tonumber(search), 0)
      return true
    end
    local ok, err = M.search_in_buffer(search)
    warn_err(err)
    return ok
  end
  return true
end

--- Open file `path` like org-open-file: `links.file_apps` and the
--- external extensions decide the app; `o.app` "vim" (Emacs IN-EMACS)
--- always opens it in Neovim, `o.how` is the window (default
--- `links.frame_setup`).
---@param o? { app?: string, how?: any }
function M.open_file(path, o)
  return open_file_link(path, nil, o)
end

--- Show an internal link's buffer in another window (C-u C-c C-o).
local function other_window_same_buffer()
  local buf = vim.api.nvim_get_current_buf()
  local view = vim.fn.winsaveview()
  select_other_window(buf)
  vim.api.nvim_set_current_buf(buf)
  vim.fn.winrestview(view)
end

--- A link target (as written inside [[...]]) as following reads it from
--- buffer `bufnr`: blanks around line breaks squeezed, abbreviations
--- expanded (`target`), classified (`type`, `path`), then
--- `links.translation_function` applied.
---@param target string
---@param bufnr integer
---@return { target: string, type: string, path: string }
function M.read_target(target, bufnr)
  local file = utils.is_org(bufnr) and files.get_buffer(bufnr) or nil
  target = target:gsub("[ \t]*\n[ \t]*", " ")
  local link = M.classify({ target = M.expand_abbrev(target, file) }) --[[@as { target: string, type: string, path: string }]]
  local translate = lopts().translation_function
  if translate and M.URL_SCHEMES[link.type] then
    local nt, np = translate(link.type, link.path)
    if nt then
      link.type, link.path = nt, np
      link.target = nt .. ":" .. np
    end
  end
  return link
end

--- The location of an `id:` link's `path` (org-id-find, see `org.id`),
--- the ID and the search option after `::` (an ID containing "::" is
--- tried too). nil when the ID is unknown.
---@param path string
---@return table|nil loc, string id, string|nil option
function M.find_id_link(path)
  local id, option = path, nil
  local p, s = path:match("^(.-)::(.*)$")
  if p then
    id, option = p, s
  end
  local idm = require("org.id")
  local loc = idm.find(id)
  if not loc and option then
    -- an ID containing "::" (backwards compatibility)
    loc = idm.find(path)
    if loc then
      id, option = path, nil
    end
  end
  return loc, id, option
end

--- Open a link target string (as written inside [[...]]).
---@param target string
---@param opts? { bufnr?: integer, split?: string, link?: org.Link, arg?: integer, avoid?: integer[] }
function M.open(target, opts)
  opts = opts or {}
  local arg = opts.arg or 0
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local link = M.read_target(target, bufnr)
  local expanded = link.target
  local lt = M.link_type(link.type)
  if lt and lt.follow then
    return lt.follow(link.path, link, arg)
  elseif lt then
    return false
  end
  local how = opts.split or nil

  local t = link.type
  if t == "http" or t == "https" or t == "ftp" or t == "mailto" or t == "news" or t == "irc" then
    return vim.ui.open(expanded)
  elseif t == "doi" then
    return vim.ui.open((lopts().doi_server_url or "https://doi.org/") .. link.path)
  elseif t == "file" or t == "file+sys" or t == "file+emacs" or t == "docview" or t == "bibtex" then
    local path, search = link.path, nil
    local p, s = link.path:match("^(.-)::(.*)$")
    if p then
      path, search = p, s
    end
    local app = arg >= 16 and "system" or arg > 0 and "vim" or nil
    if t == "file+sys" then
      app = "system"
    elseif t == "file+emacs" then
      app = "vim"
    end
    return open_file_link(path, search, { bufnr = bufnr, how = how, app = app })
  elseif t == "id" then
    local loc, id, option = M.find_id_link(link.path)
    if not loc then
      utils.warn('Cannot find entry with ID "' .. id .. '"')
      return false
    end
    push_jump()
    local target_buf = loc.bufnr or (loc.filename and utils.find_buffer(loc.filename))
    if not (target_buf and target_buf == vim.api.nvim_get_current_buf()) then
      visit(loc.filename, how, target_buf)
    end
    local f = files.get_buffer(0)
    local hl = f and f:find_by_id(id)
    local lnum = hl and hl.line or loc.lnum or 1
    goto_pos(lnum, 0)
    if option then
      -- search within the entry's subtree (org-id-open narrows to it)
      local range = hl and { hl.line, hl.end_line } or nil
      local found, err = M.search_in_buffer(option, { range = range, container = hl })
      if not found then
        warn_err(err)
      end
      return found
    end
    return true
  elseif t == "shell" then
    return shared.open_shell(link.path, bufnr)
  elseif t == "elisp" then
    return shared.open_elisp(link.path, bufnr)
  elseif t == "help" then
    local ok, err = pcall(vim.cmd.help, link.path)
    if not ok then
      utils.warn(tostring(err))
    end
    return ok
  elseif t == "man" then
    local page, search = link.path:match("^(.-)::(.*)$")
    page = page or link.path
    -- structured: `|` in the page must not end the :Man command
    local ok, err = pcall(vim.api.nvim_cmd, { cmd = "Man", args = split_words(page) }, {})
    if not ok then
      utils.warn(tostring(err))
      return false
    end
    if search and search ~= "" then
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      vim.fn.search("\\V" .. vim.fn.escape(search, "\\"), "cW")
    end
    return true
  elseif t == "info" then
    local ifile, node = link.path:match("^([^#:]*)[#:]:?(.*)$")
    ifile = ifile or link.path
    if vim.fn.executable("info") == 0 then
      utils.warn("info: links need the `info` program")
      return false
    end
    local topic = "(" .. ifile .. ")" .. ((node and node ~= "") and node or "Top")
    return shared.run_in_terminal({ "info", topic }, base_dir(bufnr))
  elseif t == "attachment" then
    local path, search = link.path, nil
    local p, s = link.path:match("^(.-)::(.*)$")
    if p then
      path, search = p, s
    end
    local full = require("org.attach").resolve_attachment(path, { bufnr = bufnr })
    if not full then
      utils.warn("Attachment not found: " .. path)
      return false
    end
    local app = arg >= 16 and "system" or arg > 0 and "vim" or nil
    return open_file_link(full, search, { bufnr = bufnr, how = how, app = app })
  end
  -- internal links: custom-id, heading, coderef, fuzzy
  -- org-open-link-functions (org-ctags); `*heading` is a fuzzy path in Emacs
  local hook_path = t == "heading" and ("*" .. link.path) or link.path
  if t ~= "radio" and require("org.ctags").open_link(hook_path) then
    return true
  end
  if bufnr ~= vim.api.nvim_get_current_buf() and vim.api.nvim_buf_is_valid(bufnr) then
    -- followed from elsewhere (the agenda): search the link's buffer
    visit(nil, how, bufnr)
  elseif arg > 0 then
    other_window_same_buffer()
  else
    push_jump()
  end
  local search = expanded
  if t == "coderef" then
    search = "(" .. link.path .. ")"
  end
  local ok, err = M.search_in_buffer(search, { avoid = t == "fuzzy" and opts.avoid or nil })
  warn_err(err)
  return ok
end

--- Open the link written in string `s`, as if it were in an Org buffer
--- (org-link-open-from-string). Prompts for it without `s`. The string must
--- start with a link (bracket, angle or plain) and hold nothing else but
--- white space after it. `arg` is the count of `open_at_point`.
---@param s? string
---@param arg? integer
function M.open_from_string(s, arg)
  if s == nil then
    s = utils.input({ prompt = "Link: " })
    if s == nil then
      return
    end
  end
  local link = M.parse_links(s)[1]
  if not link or link.start_col ~= 1 then
    utils.error(string.format("No valid link in %q", s))
    return
  end
  local rest = s:sub(link.end_col + 1)
  local garbage = rest:gsub("^[ \t]+", "")
  if garbage ~= "" then
    utils.error(string.format("Garbage after link in %q (%q)", s, garbage))
    return
  end
  return M.open(link.target, { arg = arg or vim.v.count })
end

--- :Org link_open_from_string [link]
function M.open_from_string_command(args)
  args = vim.trim(args or "")
  return M.open_from_string(args ~= "" and args or nil)
end

--- Open the link under the cursor. Returns false when there is none. A
--- count stands for the Emacs prefix argument: open files in Neovim even
--- when an external app is configured and show internal links in another
--- window (C-u); 16 opens files with the system app (C-u C-u). Returns
--- true when a link was followed, nil when it could not be.
function M.open_at_point(arg)
  arg = arg or vim.v.count
  local link = M.link_at_cursor()
  if not link then
    return false
  end
  local bufnr = vim.api.nvim_get_current_buf()
  if link.type == "radio" then
    if arg > 0 then
      other_window_same_buffer()
    else
      push_jump()
    end
    local ok, err = M.search_radio_target(link.path)
    warn_err(err)
    return ok or nil
  end
  -- not false: a failed search must not make the key fall back
  return M.open(link.target, {
    bufnr = bufnr,
    link = link,
    arg = arg,
    avoid = { link.lnum, link.start_col + 2 },
  }) ~= false or nil
end

--- Signal that a link was followed (org-follow-link-hook): the User event
--- `OrgFollowLink`, with the buffer the link was followed from as `data`.
---@param bufnr? integer
function M.run_follow_hook(bufnr)
  pcall(vim.api.nvim_exec_autocmds, "User", {
    pattern = "OrgFollowLink",
    data = { bufnr = bufnr or vim.api.nvim_get_current_buf() },
    modeline = false,
  })
end

--- The URL or e-mail address around column `col` (1-based) of `line`, like
--- thing-at-point 'url / 'email.
local function thing_at(line, col)
  local init = 1
  while true do
    local s, e = line:find("%a[%w+.%-]*://[^%s<>\"'()]+", init)
    if not s then
      break
    end
    if col >= s and col <= e then
      return (line:sub(s, e):gsub("[.,;:!?]+$", ""))
    end
    init = e + 1
  end
  init = 1
  while true do
    local s, e = line:find("[%w._%%+%-]+@[%w.%-]+%.%a+", init)
    if not s then
      break
    end
    if col >= s and col <= e then
      return "mailto:" .. line:sub(s, e)
    end
    init = e + 1
  end
end

--- Follow an Org link or a timestamp in any buffer (org-open-at-point-global):
--- a bracket, angle or plain link at the cursor, a timestamp (the agenda of
--- that day), else a URL or an e-mail address. Internal links (headings,
--- targets) are not searched outside Org, like Emacs. A count is the
--- prefix argument. Returns false when there is nothing to follow.
function M.open_at_point_global(arg)
  arg = arg or vim.v.count
  local link = M.link_at_cursor()
  if link and link.type ~= "radio" then
    return M.open(link.target, { arg = arg }) ~= false or nil
  end
  local _, col = utils.cursor()
  local line = vim.api.nvim_get_current_line()
  local ts = require("org.date").at_col(line, col)
  if ts then
    require("org.agenda").open_day(ts.date)
    return true
  end
  local thing = thing_at(line, col)
  if thing then
    return M.open(thing, { arg = arg }) ~= false or nil
  end
  utils.warn("No link found")
  return false
end

--- Search the agenda files for links to the cursor's location
--- (org-occur-link-in-agenda-files): the link `store_link` would make,
--- `[[file:...::*Heading][Heading]]`, is not stored, only searched for.
function M.occur_link_in_agenda_files()
  local l = M.link_to_location({})
  if not l then
    utils.error("Unable to create a link to here")
    return nil
  end
  local text = M.format(l.link, l.desc)
  return require("org.agenda").occur("\\V" .. vim.fn.escape(text, "\\"))
end

-- for the parts loaded after this one
shared.base_dir = base_dir
shared.expand_text = expand_text
