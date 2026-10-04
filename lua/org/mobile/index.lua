---@mod org.mobile.index Setup, file list and index.org
---
--- Checking the setup, the files to stage (org-mobile-files-alist) and
--- the lines of index.org.
--- Part of org.mobile, which loads it.

local config = require("org.config")
local files = require("org.files")
local utils = require("org.utils")
local shared = require("org.mobile.shared")

local M = require("org.mobile")

local cfg = shared.cfg
local inbox_path = shared.inbox_path
local org_dir = shared.org_dir
local staging_dir = shared.staging_dir

---------------------------------------------------------------------------
-- Setup and file list
---------------------------------------------------------------------------

--- Check the configuration (org-mobile-check-setup). Errors with a message.
function M.check_setup()
  if not utils.is_dir(org_dir()) then
    error("Please set `org_directory' to the directory where your org files live", 0)
  end
  if not staging_dir() or not utils.is_dir(staging_dir()) then
    error("Option `mobile.directory' must point to an existing directory", 0)
  end
  local inbox = inbox_path()
  if not inbox or not utils.is_dir(vim.fn.fnamemodify(inbox, ":h")) then
    error("Option `mobile.inbox_for_pull' must point to a file in an existing directory", 0)
  end
  if not M.checksum_binary() then
    error("No executable found to compute checksums", 0)
  end
  if cfg().use_encryption then
    if not M.encryption_password():match("%S") then
      error("To use encryption, you must set `mobile.encryption_password'", 0)
    end
    if vim.fn.executable("openssl") == 0 then
      error("OpenSSL is needed to encrypt files", 0)
    end
  end
end

local function emacs_match(re, s)
  local ok, vre = pcall(function()
    return vim.regex(require("org.agenda.search").emacs_regexp(re))
  end)
  if not ok then
    ok, vre = pcall(vim.regex, re)
  end
  return ok and vre:match_str(s) ~= nil
end

--- The files to stage (org-mobile-files-alist): `{ file, link }` pairs,
--- `link` being the name relative to `org_directory` (or the file name
--- when the file is elsewhere).
---@return { file: string, link: string }[]
function M.files_alist()
  local out_files = {}
  local extra = (config.opts.agenda or {}).text_search_extra_files or {}
  local spec = cfg().files or { "agenda_files" }
  if type(spec) == "string" then
    spec = { spec }
  end
  local with_archives = vim.tbl_contains(spec, "text_search_extra_files") and vim.tbl_contains(extra, "agenda-archives")
  for _, f in ipairs(spec) do
    if f == "agenda_files" or f == "org-agenda-files" then
      vim.list_extend(out_files, files.agenda_file_paths())
      if with_archives then
        for _, af in ipairs(require("org.agenda.view").archive_files(files.agenda_files())) do
          out_files[#out_files + 1] = af.filename
        end
      end
    elseif f == "text_search_extra_files" or f == "org-agenda-text-search-extra-files" then
      for _, e in ipairs(extra) do
        if e ~= "agenda-archives" then
          out_files[#out_files + 1] = e
        end
      end
    elseif type(f) == "string" then
      local p = utils.expand(f, org_dir())
      if utils.is_dir(p) then
        local names = {}
        for name, t in vim.fs.dir(p) do
          if t ~= "directory" and name:match("%.org$") then
            names[#names + 1] = name
          end
        end
        table.sort(names)
        for _, name in ipairs(names) do
          out_files[#out_files + 1] = p .. "/" .. name
        end
      elseif utils.exists(p) then
        out_files[#out_files + 1] = p
      end
    end
  end
  local exclude = cfg().files_exclude_regexp
  local base = org_dir()
  local base_real = (utils.realpath(base) or base):gsub("/$", "") .. "/"
  local seen, out = {}, {}
  for _, file in ipairs(out_files) do
    file = utils.expand(file, base)
    if not (type(exclude) == "string" and exclude ~= "" and emacs_match(exclude, file)) then
      local real = utils.realpath(file) or file
      if not seen[real] then
        seen[real] = true
        local link
        if real:sub(1, #base_real) == base_real then
          link = real:sub(#base_real + 1)
        else
          link = vim.fn.fnamemodify(real, ":t")
        end
        out[#out + 1] = { file = file, link = link }
      end
    end
  end
  return out
end

---------------------------------------------------------------------------
-- index.org
---------------------------------------------------------------------------

local function strip_key(kw)
  return (kw:gsub("%(.*$", ""))
end

local function delete_all(list, remove)
  local set = {}
  for _, x in ipairs(remove) do
    set[x] = true
  end
  return vim.tbl_filter(function(x)
    return not set[x]
  end, list)
end

local function uniq(list)
  local seen, out = {}, {}
  for _, x in ipairs(list) do
    if not seen[x] then
      seen[x] = true
      out[#out + 1] = x
    end
  end
  return out
end

--- The lines of index.org (org-mobile-create-index-file).
---@param alist { file: string, link: string }[]
---@param has_agendas boolean
function M.index_lines(alist, has_agendas)
  local sorted = vim.list_slice(alist)
  table.sort(sorted, function(a, b)
    return a.link < b.link
  end)
  local all_kw, done_kw, all_tags = {}, {}, {}
  for _, e in ipairs(sorted) do
    local f = files.get(e.file)
    if f then
      for _, kw in ipairs(f.settings.todo.keywords) do
        all_kw[#all_kw + 1] = kw.name
        if kw.done then
          done_kw[#done_kw + 1] = kw.name
        end
      end
      for _, d in ipairs(f:tag_definitions()) do
        if d.name then
          all_tags[#all_tags + 1] = d.name
        end
      end
      for _, t in ipairs(f.settings.filetags) do
        all_tags[#all_tags + 1] = t
      end
      for _, hl in ipairs(f.headlines) do
        vim.list_extend(all_tags, hl.tags)
      end
    end
  end
  local done_kwds = uniq(done_kw)
  local todo_kwds = delete_all(uniq(all_kw), done_kwds)
  local lines = { "#+READONLY" }
  for _, seq in ipairs(require("org.todo_keywords").normalize(config.opts.todo_keywords)) do
    local kwds = {}
    for tok in seq:gmatch("%S+") do
      kwds[#kwds + 1] = strip_key(tok)
    end
    lines[#lines + 1] = "#+TODO: " .. table.concat(kwds, " ")
    local dwds = {}
    local bar
    for i, k in ipairs(kwds) do
      if k == "|" then
        bar = i
      end
    end
    if bar then
      dwds = vim.list_slice(kwds, bar)
    elseif #kwds > 0 then
      dwds = { kwds[#kwds] }
    end
    local twds = delete_all(kwds, dwds)
    todo_kwds = delete_all(todo_kwds, twds)
    done_kwds = delete_all(done_kwds, dwds)
  end
  if #todo_kwds > 0 or #done_kwds > 0 then
    lines[#lines + 1] = "#+TODO: " .. table.concat(todo_kwds, " ") .. " | " .. table.concat(done_kwds, " ")
  end
  local def_tags = {}
  for _, spec in ipairs(config.opts.tags or {}) do
    for tok in spec:gmatch("%S+") do
      if tok ~= "\\n" then
        def_tags[#def_tags + 1] = strip_key(tok)
      end
    end
  end
  local tags = delete_all(uniq(all_tags), def_tags)
  table.sort(tags, function(a, b)
    return a:lower() < b:lower()
  end)
  local all = vim.list_extend(vim.list_slice(def_tags), tags)
  lines[#lines + 1] = "#+TAGS: " .. table.concat(all, " ")
  lines[#lines + 1] = "#+ALLPRIORITIES: " .. (cfg().allpriorities or "A B C")
  if has_agendas then
    lines[#lines + 1] = "* [[file:agendas.org][Agenda Views]]"
  end
  for _, e in ipairs(sorted) do
    lines[#lines + 1] = string.format("* [[file:%s][%s]]", e.link, e.link)
  end
  return lines
end

shared.delete_all = delete_all
