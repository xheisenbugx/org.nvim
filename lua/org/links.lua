---@mod org.links Hyperlinks
---
--- Supports bracket links `[[target][description]]`, `[[target]]`, angle
--- links `<https://...>`, plain links (`https://...`, `file:...`) and radio
--- targets `<<<text>>>`. Link types follow Emacs: http(s), ftp, mailto,
--- news, doi, file, id, shell, help, attachment, `#custom-id`, `*heading`,
--- fuzzy (dedicated `<<target>>`, `#+NAME:`, headline, text), abbreviations
--- (`#+LINK:` / `links.abbreviations`) and custom types (`links.types`).

local config = require("org.config")
local files = require("org.files")
local utils = require("org.utils")

local M = {}

---@class org.Link
---@field raw string
---@field target string link path as written (abbreviations expanded in `resolved`)
---@field desc string|nil
---@field start_col integer 1-based inclusive
---@field end_col integer 1-based inclusive
---@field type string
---@field path string part after "type:" (or the whole target)

--- Links stored with `store_link`, most recent first: { link, desc }.
M.stored = {}

M.URL_SCHEMES = {
  http = true,
  https = true,
  ftp = true,
  mailto = true,
  news = true,
  doi = true,
  file = true,
  id = true,
  shell = true,
  elisp = true,
  help = true,
  attachment = true,
  info = true,
  irc = true,
  docview = true,
  ["file+sys"] = true,
  ["file+emacs"] = true,
}

local EXTERNAL_EXT = {
  pdf = true, png = true, jpg = true, jpeg = true, gif = true, svg = true, webp = true, bmp = true,
  mp3 = true, mp4 = true, mkv = true, mov = true, avi = true, wav = true, flac = true, ogg = true,
  doc = true, docx = true, xls = true, xlsx = true, ppt = true, pptx = true, odt = true, ods = true,
  zip = true, epub = true, dmg = true,
}

---------------------------------------------------------------------------
-- Parsing
---------------------------------------------------------------------------

local function unescape(s)
  return (s:gsub("\\([%[%]\\])", "%1"))
end

--- Escape a link target for use inside [[...]].
function M.escape(s)
  return (s:gsub("([%[%]])", "\\%1"))
end

--- Parse every link in `line`. Returns a list sorted by column.
---@param line string
---@return org.Link[]
function M.parse_links(line)
  local out = {}
  local covered = {}
  local function cover(s, e)
    for i = s, e do
      covered[i] = true
    end
  end
  -- bracket links
  local init = 1
  while true do
    local s = line:find("[[", init, true)
    if not s then
      break
    end
    -- find end of target (unescaped "]")
    local i = s + 2
    local target_end
    while i <= #line do
      local c = line:sub(i, i)
      if c == "\\" then
        i = i + 2
      elseif c == "]" then
        target_end = i - 1
        break
      elseif c == "[" then
        break
      else
        i = i + 1
      end
    end
    if not target_end then
      init = s + 2
    else
      local target = line:sub(s + 2, target_end)
      local after = line:sub(target_end + 1, target_end + 2)
      if after == "]]" and target ~= "" then
        out[#out + 1] = { raw = line:sub(s, target_end + 2), target = unescape(target), start_col = s, end_col = target_end + 2 }
        cover(s, target_end + 2)
        init = target_end + 3
      elseif after == "][" then
        local de = line:find("]]", target_end + 3, true)
        if de and target ~= "" then
          out[#out + 1] = {
            raw = line:sub(s, de + 1),
            target = unescape(target),
            desc = line:sub(target_end + 3, de - 1),
            start_col = s,
            end_col = de + 1,
          }
          cover(s, de + 1)
          init = de + 2
        else
          init = s + 2
        end
      else
        init = s + 2
      end
    end
  end
  -- angle links <type:path>
  init = 1
  while true do
    local s, e, inner = line:find("<([%a][%w+%-]*:[^>\n]+)>", init)
    if not s then
      break
    end
    local scheme = inner:match("^([%a][%w+%-]*):")
    if not covered[s] and (M.URL_SCHEMES[scheme] or (config.opts.links.types or {})[scheme]) then
      out[#out + 1] = { raw = line:sub(s, e), target = inner, start_col = s, end_col = e }
      cover(s, e)
    end
    init = e + 1
  end
  -- plain links type:path
  init = 1
  while true do
    local s, e, scheme = line:find("%f[%w]([%a][%w+%-]*):[^%s%[%]<>()\"']+", init)
    if not s then
      break
    end
    local text = line:sub(s, e)
    if not covered[s] and (M.URL_SCHEMES[scheme:lower()] or (config.opts.links.types or {})[scheme]) then
      -- trim trailing punctuation
      local trimmed = text:gsub("[%.,;:!%?]+$", "")
      e = s + #trimmed - 1
      if trimmed:match("^%a[%w+%-]*:.") then
        out[#out + 1] = { raw = trimmed, target = trimmed, start_col = s, end_col = e }
        cover(s, e)
      end
    end
    init = e + 1
  end
  table.sort(out, function(a, b)
    return a.start_col < b.start_col
  end)
  for _, l in ipairs(out) do
    M.classify(l)
  end
  return out
end

--- Fill `type` and `path` fields from `target`.
---@param link org.Link|{target: string}
function M.classify(link)
  local t = link.target
  local scheme, rest = t:match("^([%a][%w+%-]*):(.*)$")
  local custom = config.opts.links.types or {}
  if scheme and (M.URL_SCHEMES[scheme:lower()] or custom[scheme] or M.abbreviation(scheme)) then
    link.type = M.URL_SCHEMES[scheme:lower()] and scheme:lower() or scheme
    link.path = rest
  elseif t:sub(1, 1) == "#" then
    link.type = "custom-id"
    link.path = t:sub(2)
  elseif t:sub(1, 1) == "*" then
    link.type = "heading"
    link.path = t:sub(2)
  elseif t:match("^[/~]") or t:match("^%.%.?/") or t:match("^%a:[/\\]") then
    link.type = "file"
    link.path = t
  elseif t:match("^%(.*%)$") then
    link.type = "coderef"
    link.path = t:sub(2, -2)
  else
    link.type = "fuzzy"
    link.path = t
  end
  return link
end

local function radio_targets(bufnr)
  local out = {}
  for _, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    for t in l:gmatch("<<<(.-)>>>") do
      out[#out + 1] = t
    end
  end
  return out
end

--- Link under the cursor (or nil).
---@return org.Link|nil
function M.link_at_cursor()
  local lnum, col = utils.cursor()
  local line = vim.api.nvim_get_current_line()
  for _, l in ipairs(M.parse_links(line)) do
    if col >= l.start_col and col <= l.end_col then
      l.lnum = lnum
      return l
    end
  end
  -- radio targets: plain text matching a <<<target>>>
  if utils.is_org() and line ~= "" and not line:find("<<<", 1, true) then
    local lower = line:lower()
    for _, t in ipairs(radio_targets(0)) do
      local init = 1
      while true do
        local s, e = lower:find(t:lower(), init, true)
        if not s then
          break
        end
        if col >= s and col <= e then
          return { raw = line:sub(s, e), target = t, type = "radio", path = t, start_col = s, end_col = e, lnum = lnum }
        end
        init = e + 1
      end
    end
  end
  return nil
end

---------------------------------------------------------------------------
-- Abbreviations
---------------------------------------------------------------------------

--- Abbreviation definition for `name` (buffer #+LINK first, then config).
function M.abbreviation(name, file)
  if not name then
    return nil
  end
  file = file or (utils.is_org() and files.get_buffer(0) or nil)
  if file and file.settings.link_abbrevs[name] then
    return file.settings.link_abbrevs[name]
  end
  return (config.opts.links.abbreviations or {})[name]
end

local function url_hex(s)
  return (s:gsub("[^%w%-%._~]", function(c)
    return string.format("%%%02X", c:byte())
  end))
end

--- Expand link abbreviations: `gh:user/repo` -> `https://github.com/user/repo`.
function M.expand_abbrev(target, file)
  local name, tag = target:match("^([%w_%-]+):(.*)$")
  if not name then
    name, tag = target, ""
  end
  local def = M.abbreviation(name, file)
  if not def then
    return target
  end
  if type(def) == "function" then
    return def(tag)
  end
  if def:find("%s", 1, true) then
    return (def:gsub("%%s", function()
      return tag
    end))
  elseif def:find("%h", 1, true) then
    return (def:gsub("%%h", function()
      return url_hex(tag)
    end))
  end
  return def .. tag
end

---------------------------------------------------------------------------
-- Opening
---------------------------------------------------------------------------

local function push_jump()
  vim.cmd("normal! m'")
end

local function goto_line(lnum, col)
  push_jump()
  local last = vim.api.nvim_buf_line_count(0)
  vim.api.nvim_win_set_cursor(0, { math.max(1, math.min(lnum, last)), col or 0 })
  pcall(vim.cmd, "normal! zv")
end

--- Search the current buffer for an in-file link target.
--- Returns true when found (cursor moved).
function M.search_in_buffer(search)
  search = vim.trim(search)
  if search == "" then
    return true
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  if search:match("^%d+$") then
    goto_line(tonumber(search))
    return true
  end
  local is_org = utils.is_org(bufnr) or vim.api.nvim_buf_get_name(bufnr):match("%.org$")
  local file = is_org and files.get_buffer(bufnr) or nil
  if search:sub(1, 1) == "#" and file then
    local hl = file:find_by_custom_id(search:sub(2))
    if hl then
      goto_line(hl.line)
      return true
    end
    return false
  end
  if search:sub(1, 1) == "*" and file then
    local want = vim.trim(search:sub(2))
    local hl = file:find_by_title(want)
    if not hl then
      local lw = want:lower()
      hl = file:find_headline(function(h)
        return h:plain_title():lower() == lw
      end)
    end
    if hl then
      goto_line(hl.line)
      return true
    end
    return false
  end
  local regex = search:match("^/(.*)/$")
  if regex then
    push_jump()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    local found = vim.fn.search(regex, "cW")
    return found > 0
  end
  -- fuzzy: dedicated target, #+NAME:, headline, plain text
  local lower = search:lower()
  for i, l in ipairs(lines) do
    local s = l:lower():find("<<" .. lower .. ">>", 1, true)
    if s and not l:lower():find("<<<" .. lower .. ">>>", 1, true) then
      goto_line(i, s - 1)
      return true
    end
  end
  for i, l in ipairs(lines) do
    local s = l:lower():find("<<<" .. lower .. ">>>", 1, true)
    if s then
      goto_line(i, s - 1)
      return true
    end
  end
  for i, l in ipairs(lines) do
    local name = l:match("^%s*#%+[Nn][Aa][Mm][Ee]:%s*(.-)%s*$")
    if name and name:lower() == lower then
      goto_line(i)
      return true
    end
  end
  if file then
    local hl = file:find_headline(function(h)
      return h:plain_title():lower() == lower
    end)
    if hl then
      goto_line(hl.line)
      return true
    end
  end
  for i, l in ipairs(lines) do
    local s = l:lower():find(lower, 1, true)
    if s then
      goto_line(i, s - 1)
      return true
    end
  end
  return false
end

local function run_external(app, path)
  if type(app) == "function" then
    return app(path)
  end
  if app == "system" or app == "default" then
    return vim.ui.open(path)
  end
  local cmd = vim.split(app, "%s+", { trimempty = true })
  if app:find("%s", 1, true) and app:find("%%s") then
    cmd = vim.tbl_map(function(p)
      return (p:gsub("%%s", path))
    end, cmd)
  else
    cmd[#cmd + 1] = path
  end
  vim.system(cmd, { detach = true })
end

--- Directory used to resolve relative paths of links in `bufnr`.
local function base_dir(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr or 0)
  if name ~= "" and not name:match("^%a[%w+%-]*://") then
    return vim.fn.fnamemodify(name, ":p:h")
  end
  return vim.fn.getcwd()
end

--- Resolve a file link path relative to the buffer.
function M.resolve_path(path, bufnr)
  path = vim.fn.expand(path)
  if not path:match("^/") and not path:match("^%a:[/\\]") then
    path = base_dir(bufnr) .. "/" .. path
  end
  return vim.fs.normalize(path)
end

local function open_file_link(path, search, opts)
  opts = opts or {}
  local full = M.resolve_path(path, opts.bufnr)
  local ext = (full:match("%.([%w]+)$") or ""):lower()
  local apps = config.opts.links.file_apps or {}
  if apps[ext] then
    return run_external(apps[ext], full)
  end
  if EXTERNAL_EXT[ext] and not opts.force_vim then
    return vim.ui.open(full)
  end
  if utils.is_dir(full) then
    vim.cmd("edit " .. vim.fn.fnameescape(full))
    return
  end
  push_jump()
  utils.open_file(full, nil, { split = opts.split })
  if search and search ~= "" then
    if not M.search_in_buffer(search) then
      utils.warn("Link search not found: " .. search)
    end
  end
end

--- Open a link target string (as written inside [[...]]).
---@param target string
---@param opts? { bufnr?: integer, split?: string, link?: org.Link }
function M.open(target, opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local file = utils.is_org(bufnr) and files.get_buffer(bufnr) or nil
  local link = M.classify({ target = target })
  local custom = config.opts.links.types or {}

  -- abbreviations (only for types not built in)
  if link.type ~= "file" and not M.URL_SCHEMES[link.type] and not custom[link.type] then
    local scheme = target:match("^([%w_%-]+):")
    if scheme and M.abbreviation(scheme, file) then
      local expanded = M.expand_abbrev(target, file)
      if expanded ~= target then
        return M.open(expanded, opts)
      end
    end
  end
  if custom[link.type] then
    return custom[link.type](link.path, link)
  end

  local t = link.type
  if t == "http" or t == "https" or t == "ftp" or t == "mailto" or t == "news" or t == "irc" then
    return vim.ui.open(target)
  elseif t == "doi" then
    return vim.ui.open("https://doi.org/" .. link.path)
  elseif t == "file" or t == "file+sys" or t == "file+emacs" or t == "docview" then
    local path, search = link.path, nil
    local p, s = link.path:match("^(.-)::(.*)$")
    if p then
      path, search = p, s
    end
    if t == "file+sys" then
      return vim.ui.open(M.resolve_path(path, bufnr))
    end
    if path == "" then
      return M.search_in_buffer(search or "") or utils.warn("Not found: " .. tostring(search))
    end
    return open_file_link(path, search, { bufnr = bufnr, split = opts.split, force_vim = t == "file+emacs" })
  elseif t == "id" then
    local id_path, search = link.path, nil
    local p, s = link.path:match("^(.-)::(.*)$")
    if p then
      id_path, search = p, s
    end
    local loc = require("org.id").find(id_path)
    if not loc then
      utils.warn("Cannot find entry with ID: " .. id_path)
      return
    end
    push_jump()
    utils.open_file(loc.filename, loc.headline and loc.headline.line or loc.lnum, { split = opts.split })
    if search then
      M.search_in_buffer(search)
    end
    return
  elseif t == "shell" then
    local cmd = link.path
    if config.opts.links.confirm_shell ~= false and not utils.confirm("Execute shell command: " .. cmd .. " ?") then
      return
    end
    vim.cmd("botright split")
    vim.cmd("terminal " .. cmd)
    return
  elseif t == "elisp" then
    utils.warn("elisp: links are not supported in Neovim")
    return
  elseif t == "help" or t == "info" then
    local ok, err = pcall(vim.cmd.help, link.path)
    if not ok then
      utils.warn(tostring(err))
    end
    return
  elseif t == "attachment" then
    local path, search = link.path, nil
    local p, s = link.path:match("^(.-)::(.*)$")
    if p then
      path, search = p, s
    end
    local full = require("org.attach").resolve_attachment(path, { bufnr = bufnr })
    if not full then
      utils.warn("Attachment not found: " .. path)
      return
    end
    return open_file_link(full, search, { bufnr = bufnr, split = opts.split })
  elseif t == "custom-id" or t == "heading" or t == "fuzzy" or t == "radio" or t == "coderef" then
    local search = target
    if t == "radio" then
      search = link.path
    elseif t == "coderef" then
      search = "(ref:" .. link.path .. ")"
    end
    if not M.search_in_buffer(search) then
      if t == "fuzzy" and target:match("^%a[%w+%-]*:") then
        return vim.ui.open(target)
      end
      if t == "fuzzy" then
        -- Emacs offers to create a headline; we just report
        utils.warn("No match for fuzzy link: " .. target)
      else
        utils.warn("Link target not found: " .. target)
      end
    end
    return
  end
  vim.ui.open(target)
end

--- Open the link under the cursor. Returns false when there is none.
function M.open_at_point()
  local link = M.link_at_cursor()
  if not link then
    return false
  end
  if link.type == "radio" then
    return M.search_in_buffer(link.path)
  end
  M.open(link.target, { bufnr = vim.api.nvim_get_current_buf(), link = link })
end

---------------------------------------------------------------------------
-- Storing
---------------------------------------------------------------------------

local function add_stored(link, desc)
  for i, s in ipairs(M.stored) do
    if s.link == link then
      table.remove(M.stored, i)
      break
    end
  end
  table.insert(M.stored, 1, { link = link, desc = desc })
  while #M.stored > 50 do
    table.remove(M.stored)
  end
  return M.stored[1]
end

local function display_path(path)
  return vim.fn.fnamemodify(path, ":~")
end

--- Name of the element at `lnum` (its `#+NAME:` line, or a src block /
--- table / block below one).
local function named_element_at(bufnr, lnum)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local name_pat = "^%s*#%+[Nn][Aa][Mm][Ee]:%s*(.-)%s*$"
  local function name_above(l)
    local k = l - 1
    while k >= 1 and lines[k]:match("^%s*#%+[%w_]+:") do
      local nm = lines[k]:match(name_pat)
      if nm then
        return nm
      end
      k = k - 1
    end
  end
  local line = lines[lnum] or ""
  local nm = line:match(name_pat)
  if nm and nm ~= "" then
    return nm
  end
  if line:match("^%s*#%+[%w_]+:") then
    local k = lnum + 1
    while lines[k] and lines[k]:match("^%s*#%+[%w_]+:") and not lines[k]:lower():match("^%s*#%+begin_") do
      k = k + 1
    end
    return name_above(k)
  end
  if line:match("^%s*|") then
    local k = lnum
    while k > 1 and lines[k - 1]:match("^%s*|") do
      k = k - 1
    end
    return name_above(k)
  end
  -- inside a #+begin_ ... #+end_ block
  for k = lnum, 1, -1 do
    local l = lines[k]
    if k < lnum and l:lower():match("^%s*#%+end_") then
      return nil
    end
    if l:lower():match("^%s*#%+begin_") then
      return name_above(k)
    end
    if l:match("^%*+%s") then
      return nil
    end
  end
end

--- Link to a code line from a src / example edit buffer: `(label)`,
--- creating the `(ref:label)` when `interactive`.
local function coderef_link(bufnr, lnum, interactive)
  local src = vim.b[bufnr].org_special_source
  if not src or not vim.api.nvim_buf_is_valid(src) then
    return nil
  end
  local pat = require("org.babel.blocks").coderef_pattern(vim.b[bufnr].org_special_switches)
  local fmt = (vim.b[bufnr].org_special_switches or ""):match('%-l%s+"(.-)"') or "(ref:%s)"
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
  local label = line:match(pat)
  if not label then
    if not interactive then
      return nil
    end
    label = utils.input({ prompt = "Code line label: " })
    if not label or vim.trim(label) == "" then
      return nil
    end
    label = vim.trim(label)
    local ref = fmt:gsub("%%s", function()
      return label
    end)
    local pad = math.max(1, 79 - #ref - vim.fn.strdisplaywidth(line))
    vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum, false, { line .. string.rep(" ", pad) .. ref })
  end
  local name = vim.api.nvim_buf_get_name(src)
  if name == "" then
    return { link = "(" .. label .. ")", desc = nil }
  end
  return { link = "file:" .. display_path(name) .. "::(" .. label .. ")", desc = nil }
end

--- Compute a link to the current location without storing it.
---@param opts? { interactive?: boolean, bufnr?: integer, lnum?: integer }
---@return { link: string, desc: string|nil }|nil
function M.link_to_location(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  if vim.bo[bufnr].filetype == "orgagenda" then
    -- in the agenda: a link to the entry of the item at the cursor
    local view = require("org.agenda.view")
    local item = view.item_at_cursor()
    local target = item and view.resolve_target(item)
    if not target then
      return nil
    end
    return M.link_to_location({ bufnr = target.bufnr, lnum = target.lnum, interactive = opts.interactive })
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" or vim.bo[bufnr].buftype ~= "" and vim.bo[bufnr].buftype ~= "acwrite" then
    return nil
  end
  local lnum = opts.lnum
  if not lnum then
    lnum = bufnr == vim.api.nvim_get_current_buf() and vim.api.nvim_win_get_cursor(0)[1] or 1
  end
  if name:match("^org%-special://") then
    return coderef_link(bufnr, lnum, opts.interactive)
  end
  if name:match("CAPTURE%-") then
    return nil
  end
  local path = display_path(name)
  if vim.bo[bufnr].filetype == "org" then
    local file = files.get_buffer(bufnr)
    local hl = file:headline_at(lnum)
    local cur_line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
    -- a dedicated <<target>> under the cursor
    local col = bufnr == vim.api.nvim_get_current_buf() and (vim.api.nvim_win_get_cursor(0)[2] + 1) or nil
    local init = 1
    while col do
      local s, e, target = cur_line:find("<<([^<>]+)>>", init)
      if not s then
        break
      end
      if col >= s and col <= e and cur_line:sub(s - 1, s - 1) ~= "<" and cur_line:sub(e + 1, e + 1) ~= ">" then
        return { link = "file:" .. path .. "::" .. target, desc = nil }
      end
      init = e + 1
    end
    -- a named element (#+NAME:)
    local element = named_element_at(bufnr, lnum)
    if element then
      return { link = "file:" .. path .. "::" .. element, desc = element }
    end
    if not hl then
      local text = vim.trim(cur_line)
      if text ~= "" and #text <= 80 and not text:find("[%[%]]") then
        return { link = "file:" .. path .. "::" .. text, desc = nil }
      end
    end
    if hl then
      local desc = hl:plain_title()
      if hl.properties.CUSTOM_ID then
        return { link = "file:" .. path .. "::#" .. hl.properties.CUSTOM_ID, desc = desc }
      end
      local use_id = config.opts.links.use_id
      if use_id == true or (use_id == "create-if-interactive" and opts.interactive) then
        local id = require("org.id").get_create({ bufnr = bufnr, lnum = hl.line })
        return { link = "id:" .. id, desc = desc }
      elseif use_id == "use-existing" and hl.properties.ID then
        return { link = "id:" .. hl.properties.ID, desc = desc }
      end
      return { link = "file:" .. path .. "::*" .. desc, desc = desc }
    end
  end
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
  local text = vim.trim(line)
  if text ~= "" and #text <= 80 and not text:find("[%[%]]") and vim.bo[bufnr].filetype ~= "org" then
    return { link = "file:" .. path .. "::" .. text, desc = nil }
  end
  return { link = "file:" .. path .. "::" .. lnum, desc = nil }
end

--- Store a link to the current location (org-store-link).
function M.store_link()
  local l = M.link_to_location({ interactive = true })
  if not l then
    utils.warn("Cannot store a link to this buffer")
    return
  end
  add_stored(l.link, l.desc)
  utils.notify("Stored: " .. (l.desc or l.link))
  return l
end

--- Store a link programmatically.
function M.store(link, desc)
  return add_stored(link, desc)
end

---------------------------------------------------------------------------
-- Inserting
---------------------------------------------------------------------------

local PREFIXES = { "file:", "id:", "https://", "http://", "mailto:", "shell:", "help:", "attachment:", "doi:", "file+sys:" }

function M._complete(arglead, _, _)
  local out = {}
  local ftarget = arglead:match("^file:(.*)$") or arglead:match("^attachment:(.*)$")
  if ftarget and not arglead:match("^attachment:") then
    for _, f in ipairs(vim.fn.getcompletion(ftarget, "file")) do
      out[#out + 1] = "file:" .. f
    end
    return out
  end
  if arglead:match("^[%./~]") then
    return vim.fn.getcompletion(arglead, "file")
  end
  local candidates = {}
  for _, s in ipairs(M.stored) do
    candidates[#candidates + 1] = s.link
  end
  for _, p in ipairs(PREFIXES) do
    candidates[#candidates + 1] = p
  end
  for name in pairs(config.opts.links.abbreviations or {}) do
    candidates[#candidates + 1] = name .. ":"
  end
  for name in pairs(config.opts.links.types or {}) do
    candidates[#candidates + 1] = name .. ":"
  end
  if utils.is_org() then
    for name in pairs(files.get_buffer(0).settings.link_abbrevs) do
      candidates[#candidates + 1] = name .. ":"
    end
    for _, hl in ipairs(files.get_buffer(0).headlines) do
      candidates[#candidates + 1] = "*" .. hl:plain_title()
    end
  end
  local seen = {}
  for _, c in ipairs(candidates) do
    if not seen[c] and c:lower():find(arglead:lower(), 1, true) == 1 then
      seen[c] = true
      out[#out + 1] = c
    end
  end
  return out
end

--- Shorten a stored link pointing at the current file to its search part.
local function shorten_for_current(link)
  local p, s = link:match("^file:(.-)::(.*)$")
  if p then
    local cur = vim.api.nvim_buf_get_name(0)
    if cur ~= "" and vim.fs.normalize(vim.fn.expand(p)) == vim.fs.normalize(cur) then
      return s
    end
  end
  return link
end

--- Build a bracket link string.
function M.format(target, desc)
  if desc and desc ~= "" and desc ~= target then
    return "[[" .. M.escape(target) .. "][" .. desc .. "]]"
  end
  return "[[" .. M.escape(target) .. "]]"
end

--- Insert (or edit) a link. In visual mode the selection becomes the description.
function M.insert_link()
  local mode = vim.fn.mode()
  local visual = mode == "v" or mode == "V" or mode == "\22"
  local srow, scol, erow, ecol
  local desc_default, target_default
  local existing = nil
  if visual then
    srow, scol, erow, ecol = utils.visual_range()
    vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
    if srow ~= erow then
      ecol = #vim.api.nvim_buf_get_lines(0, srow - 1, srow, false)[1]
      erow = srow
    end
    local line = vim.api.nvim_buf_get_lines(0, srow - 1, srow, false)[1]
    -- include a full multibyte char at the end
    local last_char = vim.fn.strcharpart(line:sub(ecol), 0, 1)
    ecol = ecol + math.max(#last_char, 1) - 1
    desc_default = line:sub(scol, ecol)
  else
    existing = M.link_at_cursor()
    if existing and existing.type ~= "radio" then
      target_default = existing.target
      desc_default = existing.desc
    else
      existing = nil
    end
  end

  local target = nil
  local ok, value = pcall(vim.fn.input, {
    prompt = "Link: ",
    default = target_default or "",
    completion = "customlist,v:lua.require'org.links'._complete",
    cancelreturn = vim.NIL,
  })
  if not ok or value == vim.NIL or vim.trim(value) == "" then
    return
  end
  target = vim.trim(value)
  -- a stored link: use its description by default
  for _, s in ipairs(M.stored) do
    if s.link == target then
      desc_default = desc_default or s.desc
    end
  end
  target = shorten_for_current(target)
  if not target:match("^%a[%w+%-]*:") and target:match("^[/~]") or target:match("^%.%.?/") then
    target = "file:" .. target
  end
  local desc = utils.input({ prompt = "Description: ", default = desc_default or "" })
  if desc == nil then
    return
  end
  local text = M.format(target, vim.trim(desc))
  if visual then
    local line = vim.api.nvim_buf_get_lines(0, srow - 1, srow, false)[1]
    vim.api.nvim_buf_set_lines(0, srow - 1, srow, false, { line:sub(1, scol - 1) .. text .. line:sub(ecol + 1) })
    vim.api.nvim_win_set_cursor(0, { srow, scol - 1 + #text - 1 })
  elseif existing then
    local line = vim.api.nvim_get_current_line()
    vim.api.nvim_set_current_line(line:sub(1, existing.start_col - 1) .. text .. line:sub(existing.end_col + 1))
    vim.api.nvim_win_set_cursor(0, { existing.lnum, existing.start_col - 1 + #text - 1 })
  else
    local row, col0 = unpack(vim.api.nvim_win_get_cursor(0))
    local line = vim.api.nvim_get_current_line()
    local at = line == "" and 0 or math.min(col0 + 1, #line)
    vim.api.nvim_set_current_line(line:sub(1, at) .. text .. line:sub(at + 1))
    vim.api.nvim_win_set_cursor(0, { row, at + #text - 1 })
  end
end

local function insert_text_at_cursor(text)
  local row, col0 = unpack(vim.api.nvim_win_get_cursor(0))
  local line = vim.api.nvim_get_current_line()
  local at = line == "" and 0 or math.min(col0 + 1, #line)
  vim.api.nvim_set_current_line(line:sub(1, at) .. text .. line:sub(at + 1))
  vim.api.nvim_win_set_cursor(0, { row, at + #text - 1 })
end

--- Insert the most recently stored link (org-insert-last-stored-link).
function M.insert_last_stored_link()
  local s = M.stored[1]
  if not s then
    utils.warn("No stored link")
    return
  end
  insert_text_at_cursor(M.format(shorten_for_current(s.link), s.desc))
end

--- Insert every stored link as a list item and clear the list
--- (org-insert-all-links).
function M.insert_all_links()
  if #M.stored == 0 then
    utils.warn("No stored links")
    return
  end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local indent = vim.api.nvim_get_current_line():match("^(%s*)") or ""
  local out = {}
  for _, s in ipairs(M.stored) do
    out[#out + 1] = indent .. "- " .. M.format(shorten_for_current(s.link), s.desc)
  end
  if vim.api.nvim_get_current_line():match("^%s*$") then
    vim.api.nvim_buf_set_lines(0, row - 1, row, false, out)
  else
    vim.api.nvim_buf_set_lines(0, row, row, false, out)
  end
  M.stored = {}
end

---------------------------------------------------------------------------
-- Misc
---------------------------------------------------------------------------

function M.toggle_link_display()
  if vim.wo.conceallevel == 0 then
    vim.wo.conceallevel = 2
    utils.notify("Descriptive link display")
  else
    vim.wo.conceallevel = 0
    utils.notify("Literal link display")
  end
end

--- Move to the next (dir = 1) or previous (dir = -1) link of any kind.
local function goto_link(dir)
  local lnum, col = utils.cursor()
  local last = vim.api.nvim_buf_line_count(0)
  local l = lnum
  while l >= 1 and l <= last do
    local line = vim.api.nvim_buf_get_lines(0, l - 1, l, false)[1]
    local found
    local list = M.parse_links(line)
    if dir > 0 then
      for _, lk in ipairs(list) do
        if l > lnum or lk.start_col > col then
          found = lk
          break
        end
      end
    else
      for i = #list, 1, -1 do
        local lk = list[i]
        if l < lnum or lk.start_col < col then
          found = lk
          break
        end
      end
    end
    if found then
      vim.cmd("normal! m'")
      vim.api.nvim_win_set_cursor(0, { l, found.start_col - 1 })
      pcall(vim.cmd, "normal! zv")
      return true
    end
    l = l + dir
  end
  return false
end

function M.next_link()
  for _ = 1, math.max(vim.v.count, 1) do
    if not goto_link(1) then
      utils.notify("No further link found")
      return
    end
  end
end

function M.prev_link()
  for _ = 1, math.max(vim.v.count, 1) do
    if not goto_link(-1) then
      utils.notify("No previous link found")
      return
    end
  end
end

--- Links in the entry at the cursor (headline and body, not children).
function M.entry_links()
  if not utils.is_org() then
    return {}
  end
  local lnum = utils.cursor()
  local hl = files.get_buffer(0):headline_at(lnum)
  if not hl then
    return {}
  end
  local out = {}
  local last = hl.body_end or hl.line
  for l, line in ipairs(vim.api.nvim_buf_get_lines(0, hl.line - 1, last, false)) do
    for _, lk in ipairs(M.parse_links(line)) do
      lk.lnum = hl.line + l - 1
      out[#out + 1] = lk
    end
  end
  return out
end

--- On a headline without a link at the cursor, open one of the entry's
--- links (Emacs offers every link of the entry). Returns false when the
--- entry has none.
function M.open_entry_links()
  local list = M.entry_links()
  if #list == 0 then
    return false
  end
  local chosen = list[1]
  if #list > 1 then
    local labels = {}
    for i, lk in ipairs(list) do
      labels[i] = lk.desc and (lk.desc .. " (" .. lk.target .. ")") or lk.target
    end
    local pick, idx = utils.select(labels, { prompt = "Open link" })
    if not pick then
      return
    end
    chosen = list[idx]
  end
  M.open(chosen.target, { bufnr = vim.api.nvim_get_current_buf(), link = chosen })
end

--- C-c C-o: open the link / footnote / date at point; elsewhere on a
--- headline, offer the entry's links (org-open-at-point).
function M.open_at_point_or_entry()
  local r = require("org.context").open_at_point()
  if r ~= false then
    return r
  end
  if not require("org.parser").headline_level(vim.api.nvim_get_current_line()) then
    return false
  end
  return M.open_entry_links()
end

--- Jump back to the position before the last link was followed
--- (org-mark-ring-goto).
function M.mark_ring_goto()
  vim.cmd("normal! \15")
end

return M
