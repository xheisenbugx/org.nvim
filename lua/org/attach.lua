---@mod org.attach Attachments (org-attach)
---
--- Each entry gets an attachment directory. It is the `DIR` property when
--- set (the deprecated `ATTACH_DIR` too), otherwise derived from the
--- entry's ID: `<dir of org file>/<attach.dir>/<folder>`, where the folder
--- comes from `attach.id_to_path` (by default `ab/cdef-...` for the ID
--- `abcdef-...`). Parents' `DIR` / `ID` count when
--- `attach.use_inheritance` says so. Attaching adds the `ATTACH` tag
--- (`attach.auto_tag`). `attachment:file.pdf` links resolve inside the
--- directory of the entry containing the link.

local config = require("org.config")
local edit = require("org.edit")
local ui = require("org.ui")
local utils = require("org.utils")

local M = {}

local function cfg()
  return config.opts.attach or {}
end

local function file_dir(file, bufnr)
  local name = bufnr and vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_name(bufnr) or ""
  if name ~= "" then
    return vim.fn.fnamemodify(name, ":p:h")
  end
  if file.filename then
    return vim.fn.fnamemodify(file.filename, ":p:h")
  end
  return vim.fn.getcwd()
end

--- `inherit` argument of get_property for org-attach-use-inheritance.
local function inherit()
  local v = cfg().use_inheritance
  if v == nil or v == "selective" then
    return nil -- follow use_property_inheritance
  end
  return v and true or false
end

--- Built-in ID -> folder functions (org-attach-id-*-folder-format).
M.id_to_path = {
  uuid = function(id)
    return #id > 2 and (id:sub(1, 2) .. "/" .. id:sub(3)) or nil
  end,
  ts = function(id)
    return #id > 6 and (id:sub(1, 6) .. "/" .. id:sub(7)) or nil
  end,
  fallback = function(id)
    return "__/" .. id:sub(1, 1) .. "/" .. id
  end,
}

--- `dir` (a DIR property, an ID path) as an absolute path relative to
--- `base`. utils.expand, not vim.fn.expand(), which runs `backticks` in
--- document text as shell commands.
local function absolute(dir, base)
  return utils.expand(dir, base)
end

--- The folder for `id` (org-attach-dir-from-id): the first folder given by
--- `attach.id_to_path` that exists (also under the default "data/"), or
--- the first one when `existing` is false or none exists.
function M.dir_from_id(id, base, existing)
  local root = absolute(cfg().dir or "data/", base)
  local fallback_root = absolute("data/", base)
  local first
  for _, f in ipairs(cfg().id_to_path or { "uuid", "ts", "fallback" }) do
    local fn = type(f) == "function" and f or M.id_to_path[f]
    local name = fn and fn(id)
    if name then
      local candidate = absolute(name, root)
      if not existing or utils.is_dir(candidate) then
        return candidate
      end
      if fallback_root ~= root and utils.is_dir(absolute(name, fallback_root)) then
        return absolute(name, fallback_root)
      end
      first = first or candidate
    end
  end
  return first
end

--- Attachment directory for the entry at target (org-attach-dir), whether
--- it exists or not.
---@param target? org.Target
---@param create_id? boolean give the entry a directory (org-attach-dir-get-create)
---@return string|nil dir, org.Headline|nil hl
function M.dir_for(target, create_id)
  local bufnr, file, hl = edit.resolve(target)
  if not hl then
    return nil
  end
  local base = file_dir(file, bufnr)
  local dir = hl:get_property("DIR", inherit()) or hl:get_property("ATTACH_DIR", inherit())
  if dir and dir ~= "" then
    return absolute(dir, base), hl
  end
  local id = hl:get_property("ID", inherit())
  if id and id:match("%S") then
    return M.dir_from_id(id, base, true), hl
  end
  if not create_id then
    return nil, hl
  end
  local method = cfg().preferred_new_method
  if method == nil then
    method = "id"
  end
  if method == "ask" then
    local c = utils.getchar("Create new ID [1] property or DIR [2] property for attachments?")
    method = c == "1" and "id" or (c == "2" and "dir" or nil)
    if not method then
      return nil, hl
    end
  end
  if method == "id" then
    id = require("org.id").get_create({ bufnr = bufnr, lnum = hl.line })
    hl = edit.refresh(bufnr, hl.line)
    return M.dir_from_id(id, base, false), hl
  elseif method == "dir" then
    local d = M.set_directory({ bufnr = bufnr, lnum = hl.line })
    return d, edit.refresh(bufnr, hl.line)
  end
  utils.error("No existing directory.  DIR or ID property has to be explicitly created")
  return nil, hl
end

--- Files were added to or removed from `dir` (org-attach-after-change-hook):
--- fire the User autocmd `OrgAttachAfterChange` (data: `{ dir }`) and, with
--- `attach.git`, commit the attachment repository (org-attach-git-commit).
local function after_change(dir, target)
  local data = { dir = dir }
  pcall(vim.api.nvim_exec_autocmds, "User", { pattern = "OrgAttachAfterChange", data = data, modeline = false })
  local vcs = require("org.attach_git")
  if vcs.enabled() then
    local bufnr, file = edit.resolve(target)
    vcs.commit(vcs.dir(dir, absolute(cfg().dir or "data/", file_dir(file, bufnr))))
  end
end

--- An attachment is about to be opened (org-attach-open-hook): fire the
--- User autocmd `OrgAttachOpen` (data: `{ path }`) and, with `attach.git`,
--- fetch its git-annex content when missing (org-attach-git-annex-get-maybe).
local function before_open(path, dir, target)
  pcall(vim.api.nvim_exec_autocmds, "User", { pattern = "OrgAttachOpen", data = { path = path }, modeline = false })
  local vcs = require("org.attach_git")
  if vcs.enabled() then
    local bufnr, file = edit.resolve(target)
    vcs.annex_get_maybe(path, vcs.dir(dir, absolute(cfg().dir or "data/", file_dir(file, bufnr))))
  end
end

--- Full path of an attachment name for the entry at `opts` (bufnr/lnum).
function M.resolve_attachment(name, opts)
  opts = opts or {}
  local dir = M.dir_for({ bufnr = opts.bufnr, lnum = opts.lnum })
  if not dir then
    return nil
  end
  return vim.fs.normalize(dir .. "/" .. name)
end

--- Turn the ATTACH tag (`attach.auto_tag`) on or off (org-attach-tag).
local function set_tag(bufnr, lnum, off)
  local tag = cfg().auto_tag
  if tag == nil then
    tag = "ATTACH"
  end
  if not tag then
    return
  end
  local file = require("org.files").get_buffer(bufnr)
  local hl = file:headline_at(lnum)
  if not hl then
    return
  end
  local tags = vim.deepcopy(hl.tags)
  local has = vim.tbl_contains(tags, tag)
  if off and has then
    tags = vim.tbl_filter(function(t)
      return t ~= tag
    end, tags)
  elseif not off and not has then
    tags[#tags + 1] = tag
  else
    return
  end
  edit.update_headline(bufnr, hl.line, { tags = tags })
end

local function copy_dir(src, dest)
  local res = vim.system({ "cp", "-R", src, dest }):wait()
  if res.code ~= 0 then
    return nil, vim.trim(res.stderr or "")
  end
  return true
end

--- Store the link to an attachment (org-attach-store-link-p).
local function store_link(source, dest)
  local mode = cfg().store_link
  if mode == nil then
    mode = "attached"
  end
  local link, desc
  if mode == "attached" then
    link, desc = "attachment:" .. vim.fn.fnamemodify(dest, ":t"), vim.fn.fnamemodify(dest, ":t")
  elseif mode == "file" then
    link, desc = "file:" .. dest, vim.fn.fnamemodify(dest, ":t")
  elseif mode == true then
    link, desc = "file:" .. source, vim.fn.fnamemodify(source, ":t")
  end
  if link then
    pcall(function()
      require("org.links").store(link, desc)
    end)
  end
  local name = vim.fn.fnamemodify(dest, ":t")
  return link or ("attachment:" .. name), desc or name
end

--- Attach a file (or directory) to the entry at target (org-attach-attach).
---@param path string source file
---@param method? "cp"|"mv"|"ln"|"lns" default `attach.method`: copy, move, hard link, symbolic link
---@param target? org.Target
---@return string|nil destination
---@return string|nil link the link to it (org-attach-attach's LINK, per `attach.store_link`)
---@return string|nil description
function M.attach_file(path, method, target)
  method = method or cfg().method or "cp"
  path = utils.expand(path, vim.fn.getcwd()):gsub("/$", "")
  if not utils.exists(path) then
    utils.warn("No such file: " .. path)
    return nil
  end
  local bufnr = edit.resolve(target)
  local dir, hl = M.dir_for(target, true)
  if not dir or not hl then
    utils.warn("No attachment directory is associated with the current node")
    return nil
  end
  vim.fn.mkdir(dir, "p")
  local name = vim.fn.fnamemodify(path, ":t")
  local dest = dir .. "/" .. name
  local is_dir = utils.is_dir(path)
  local ok, err
  if method == "mv" then
    ok, err = vim.uv.fs_rename(path, dest)
    if not ok and not is_dir then
      ok, err = vim.uv.fs_copyfile(path, dest)
      if ok then
        os.remove(path)
      end
    end
  elseif method == "ln" then
    -- a hard link (add-name-to-file)
    ok, err = vim.uv.fs_link(path, dest)
  elseif method == "lns" then
    ok, err = vim.uv.fs_symlink(path, dest)
  elseif is_dir then
    ok, err = copy_dir(path, dest)
  else
    ok, err = vim.uv.fs_copyfile(path, dest)
  end
  if not ok then
    utils.error("Attach failed: " .. tostring(err))
    return nil
  end
  after_change(dir, target)
  set_tag(bufnr, hl.line)
  local link, desc = store_link(path, dest)
  utils.notify(string.format('File "%s" is now an attachment', name))
  return dest, link, desc
end

--- `path` relative to directory `dir` (both absolute).
function M.relative_path(path, dir)
  local a = vim.split(vim.fs.normalize(path), "/", { plain = true })
  local b = vim.split(vim.fs.normalize(dir), "/", { plain = true })
  local i = 1
  while a[i] and b[i] and a[i] == b[i] do
    i = i + 1
  end
  local parts = {}
  for _ = i, #b do
    parts[#parts + 1] = ".."
  end
  for k = i, #a do
    parts[#parts + 1] = a[k]
  end
  return table.concat(parts, "/")
end

--- Download `url` into the attachment directory (org-attach-url).
---@return string|nil destination
function M.attach_url(url, target)
  local bufnr = edit.resolve(target)
  local dir, hl = M.dir_for(target, true)
  if not dir or not hl then
    utils.warn("No attachment directory is associated with the current node")
    return nil
  end
  if vim.fn.executable("curl") == 0 then
    utils.error("curl is needed to attach a URL")
    return nil
  end
  local name = vim.trim(url):gsub("[?#].*$", ""):match("([^/]+)/*$") or "download"
  vim.fn.mkdir(dir, "p")
  local dest = dir .. "/" .. name
  local res = vim.system({ "curl", "-fsSL", "-o", dest, url }, { text = true }):wait(120000)
  if res.code ~= 0 then
    utils.error("Download failed: " .. vim.trim(res.stderr or ""))
    return nil
  end
  after_change(dir, target)
  set_tag(bufnr, hl.line)
  store_link(url, dest)
  utils.notify(string.format('File "%s" is now an attachment', name))
  return dest
end

--- Save the contents of buffer `src` as an attachment (org-attach-buffer).
---@return string|nil destination
function M.attach_buffer(src, target, name)
  local bufnr = edit.resolve(target)
  local dir, hl = M.dir_for(target, true)
  if not dir or not hl then
    utils.warn("No attachment directory is associated with the current node")
    return nil
  end
  if not src or not vim.api.nvim_buf_is_valid(src) then
    utils.warn("No such buffer")
    return nil
  end
  local bname = vim.api.nvim_buf_get_name(src)
  name = name or (bname ~= "" and vim.fn.fnamemodify(bname, ":t") or ("buffer-" .. src))
  vim.fn.mkdir(dir, "p")
  local dest = dir .. "/" .. name
  if utils.exists(dest) then
    utils.error("File exists: " .. dest)
    return nil
  end
  set_tag(bufnr, hl.line)
  utils.writefile(dest, vim.api.nvim_buf_get_lines(src, 0, -1, false))
  after_change(dir, target)
  return dest
end

--- Attachment names in `dir` (org-attach-file-list): its files and
--- subdirectories, without backup files ending in "~".
local function list_files(dir)
  if not dir or not utils.is_dir(dir) then
    return {}
  end
  local out = {}
  for name in vim.fs.dir(dir) do
    if not name:match("~$") then
      out[#out + 1] = name
    end
  end
  table.sort(out)
  return out
end

--- List attachment names for target.
function M.list(target)
  return list_files((M.dir_for(target)))
end

--- Make the ATTACH tag match the attachment directory (org-attach-sync):
--- tag the entry when it has files, untag it otherwise, and delete an
--- empty directory (`attach.sync_delete_empty_dir`).
function M.sync(target)
  local bufnr = edit.resolve(target)
  local dir, hl = M.dir_for(target)
  if not hl then
    return
  end
  if not dir or not utils.is_dir(dir) then
    set_tag(bufnr, hl.line, true)
    return false
  end
  after_change(dir, target)
  local has = #list_files(dir) > 0
  set_tag(bufnr, hl.line, not has)
  local del = cfg().sync_delete_empty_dir
  if del == nil then
    del = "query"
  end
  if del and not has then
    if del ~= "query" or utils.confirm("Attachment directory is empty.  Delete?") then
      vim.fn.delete(dir, "d")
    end
  end
  return has
end

--- Set the DIR property of the entry (org-attach-set-directory), offering
--- to copy the files over from the old directory. Returns the directory.
---@param target? org.Target
---@param dir? string prompted when nil
function M.set_directory(target, dir)
  local bufnr, file, hl = edit.resolve_headline(target)
  if not hl then
    return nil
  end
  local base = file_dir(file, bufnr)
  local old = M.dir_for({ bufnr = bufnr, lnum = hl.line })
  if not dir then
    local ok, v = pcall(vim.fn.input, {
      prompt = "Attachment directory: ",
      default = hl.properties.DIR or "",
      completion = "dir",
      cancelreturn = vim.NIL,
    })
    if not ok or v == vim.NIL or vim.trim(v) == "" then
      return nil
    end
    dir = vim.trim(v)
  end
  local new = absolute(dir, base)
  edit.set_property(bufnr, hl.line, "DIR", cfg().dir_relative and M.relative_path(new, base) or new)
  if old and old ~= new and utils.is_dir(old) then
    if utils.confirm("Copy over attachments from old directory?") then
      vim.fn.mkdir(new, "p")
      for _, name in ipairs(list_files(old)) do
        copy_dir(old .. "/" .. name, new .. "/" .. name)
      end
    end
    if utils.confirm("Delete " .. old) then
      vim.fn.delete(old, "rf")
    end
  end
  return new
end

--- Remove the DIR (and ATTACH_DIR) property (org-attach-unset-directory),
--- offering to move the files to the new directory.
---@param target? org.Target
function M.unset_directory(target)
  local bufnr, _, hl = edit.resolve_headline(target)
  if not hl then
    return
  end
  local old = M.dir_for({ bufnr = bufnr, lnum = hl.line })
  edit.set_property(bufnr, hl.line, "DIR", nil)
  edit.set_property(bufnr, hl.line, "ATTACH_DIR", nil)
  local new = M.dir_for({ bufnr = bufnr, lnum = hl.line })
  if old and old ~= new and utils.is_dir(old) then
    if new and utils.confirm("Copy over attachments from old directory?") then
      vim.fn.mkdir(new, "p")
      for _, name in ipairs(list_files(old)) do
        copy_dir(old .. "/" .. name, new .. "/" .. name)
      end
    end
    if utils.confirm("Delete " .. old) then
      vim.fn.delete(old, "rf")
    end
  end
end

--- Delete every attachment of the entry (org-attach-delete-all).
---@param target? org.Target
---@param force? boolean no questions
function M.delete_all(target, force)
  local bufnr = edit.resolve(target)
  local dir, hl = M.dir_for(target)
  if not hl or not dir or not utils.is_dir(dir) then
    return false
  end
  if not force and not utils.confirm("Really remove all attachments of this entry?") then
    return false
  end
  if force or utils.confirm("Recursive?") then
    vim.fn.delete(dir, "rf")
  elseif vim.fn.delete(dir, "d") ~= 0 then
    utils.error("Directory not empty: " .. dir)
    return false
  end
  utils.notify("Attachment directory removed")
  after_change(dir, target)
  set_tag(bufnr, hl.line, true)
  return true
end

local function prompt_path(prompt, completion)
  local ok, v = pcall(vim.fn.input, { prompt = prompt, completion = completion or "file", cancelreturn = vim.NIL })
  if not ok or v == vim.NIL or vim.trim(v) == "" then
    return nil
  end
  return vim.trim(v)
end

local function choose_attachment(target, prompt)
  local dir = M.dir_for(target)
  if not dir or not utils.is_dir(dir) then
    utils.warn("No attachment directory exist")
    return nil
  end
  local names = list_files(dir)
  if #names == 0 then
    utils.warn("No attachments")
    return nil
  end
  local name = #names == 1 and names[1] or utils.select(names, { prompt = prompt })
  return name and (dir .. "/" .. name) or nil, dir
end

--- Attach a file with `method` (nil = `attach.method`), asking for it.
local function attach_prompted(method)
  return function(target)
    local path = prompt_path("File to keep as an attachment: ")
    if path then
      M.attach_file(path, method, target)
    end
  end
end

local function attach_buffer_prompted(target)
  local names, bufs = {}, {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[b].buflisted and b ~= target.bufnr then
      local n = vim.api.nvim_buf_get_name(b)
      names[#names + 1] = n ~= "" and vim.fn.fnamemodify(n, ":~:.") or ("[No Name] #" .. b)
      bufs[#bufs + 1] = b
    end
  end
  if #names == 0 then
    utils.warn("No other buffers")
    return
  end
  local _, idx = utils.select(names, { prompt = "Buffer whose contents should be attached" })
  if idx then
    M.attach_buffer(bufs[idx], target)
  end
end

local function reveal(in_nvim)
  return function(target)
    local dir = M.dir_for(target, true)
    if dir then
      vim.fn.mkdir(dir, "p")
      if in_nvim then
        vim.cmd("edit " .. vim.fn.fnameescape(dir))
      else
        vim.ui.open(dir)
      end
    end
  end
end

local function new_attachment(target)
  local name = utils.input({ prompt = "Create attachment named: " })
  if name and vim.trim(name) ~= "" then
    local dir, hl = M.dir_for(target, true)
    if dir then
      vim.fn.mkdir(dir, "p")
      set_tag(target.bufnr, hl.line)
      vim.cmd("split " .. vim.fn.fnameescape(dir .. "/" .. vim.trim(name)))
    end
  end
end

local function open_attachment(in_nvim)
  return function(target)
    local path, dir = choose_attachment(target, "Open attachment")
    if path then
      before_open(path, dir, target)
      if in_nvim then
        vim.cmd("edit " .. vim.fn.fnameescape(path))
      else
        require("org.links").open("file:" .. path, { bufnr = target.bufnr })
      end
    end
  end
end

local function delete_one(target)
  local path, dir = choose_attachment(target, "Delete attachment")
  if path then
    vim.fn.delete(path, utils.is_dir(path) and "rf" or "")
    after_change(dir, target)
  end
end

--- The built-in dispatcher commands (org-attach-commands): key, label,
--- function(target).
local function builtin_commands()
  return {
    { "a", "Attach a file (" .. (cfg().method or "cp") .. ")", attach_prompted(nil) },
    { "c", "Attach by copying", attach_prompted("cp") },
    { "m", "Attach by moving", attach_prompted("mv") },
    { "l", "Attach by hard link", attach_prompted("ln") },
    { "y", "Attach by symbolic link", attach_prompted("lns") },
    {
      "u",
      "Attach a file from a URL (curl)",
      function(target)
        local url = utils.input({ prompt = "URL of the file to attach: " })
        if url and vim.trim(url) ~= "" then
          M.attach_url(vim.trim(url), target)
        end
      end,
    },
    { "b", "Attach the contents of a buffer", attach_buffer_prompted },
    { "n", "Create a new attachment file", new_attachment },
    { "z", "Synchronize the ATTACH tag with the directory", M.sync },
    { "o", "Open an attachment (system app / file_apps)", open_attachment(false) },
    { "O", "Open an attachment in Neovim", open_attachment(true) },
    { "f", "Open the attachment directory (system app)", reveal(false) },
    { "F", "Open the attachment directory in Neovim", reveal(true) },
    { "d", "Delete an attachment", delete_one },
    {
      "D",
      "Delete all attachments",
      function(target)
        M.delete_all(target)
      end,
    },
    {
      "s",
      "Set a specific attachment directory (DIR)",
      function(target)
        M.set_directory(target)
      end,
    },
    { "S", "Unset the attachment directory (remove DIR)", M.unset_directory },
  }
end

--- The dispatcher's commands: the built-ins with `attach.commands` on top
--- (a key set to false removes that command).
---@return { [1]: string, [2]: string, [3]: fun(target: org.Target) }[]
function M.commands()
  local list, index = {}, {}
  for _, c in ipairs(builtin_commands()) do
    list[#list + 1] = c
    index[c[1]] = #list
  end
  local extra = cfg().commands or {}
  local keys = vim.tbl_keys(extra)
  table.sort(keys)
  for _, key in ipairs(keys) do
    local c = extra[key]
    if c == false then
      if index[key] then
        list[index[key]] = false
      end
    elseif type(c) == "table" and type(c[1] or c.fn) == "function" then
      local entry = { key, c.desc or c[2] or key, c.fn or c[1] }
      if index[key] then
        list[index[key]] = entry
      else
        list[#list + 1] = entry
        index[key] = #list
      end
    end
  end
  return vim.tbl_filter(function(c)
    return c ~= false
  end, list)
end

--- The org-attach dispatcher: the commands of `M.commands()` in a menu,
--- or, with `attach.expert`, at a one-line prompt.
function M.menu()
  local bufnr, _, hl = edit.resolve_headline()
  if not hl then
    return
  end
  local target = { bufnr = bufnr, lnum = hl.line }
  local commands = M.commands()
  local by_key = {}
  for _, c in ipairs(commands) do
    by_key[c[1]] = c
  end
  local choice
  if cfg().expert then
    local keys = table.concat(vim.tbl_map(function(c)
      return c[1]
    end, commands)) .. (by_key.q and "" or "q")
    choice = utils.getchar("Select command: [" .. keys .. "]")
    if choice == "q" and not by_key.q then
      utils.notify("Abort")
      return
    end
    if choice and not by_key[choice] then
      utils.error("No such attachment command: " .. choice)
      return
    end
  else
    choice = ui.menu({
      title = "Attach",
      items = vim.tbl_map(function(c)
        return { key = c[1], label = c[2], value = c[1] }
      end, commands),
    })
  end
  if not choice then
    return
  end
  by_key[choice][3](target)
end

--- The files selected in a file manager buffer: netrw's marked files (else
--- the file under the cursor), oil.nvim's Visual selection or the entry
--- under the cursor. Nil when the buffer is not a file manager.
---@return string[]|nil
function M.file_manager_selection()
  local ft = vim.bo.filetype
  if ft == "netrw" then
    local ok, marked = pcall(vim.fn["netrw#Expose"], "netrwmarkfilelist")
    if ok and type(marked) == "table" and #marked > 0 then
      return marked
    end
    local dir = vim.b.netrw_curdir
    local name = vim.trim(vim.fn.getline(".")):gsub("[*@/=|]$", "")
    if not dir or name == "" or name == ".." or name == "." or not utils.exists(dir .. "/" .. name) then
      return {}
    end
    return { vim.fs.normalize(dir .. "/" .. name) }
  elseif ft == "oil" then
    local ok, oil = pcall(require, "oil")
    if not ok then
      return nil
    end
    local dir = oil.get_current_dir()
    local out = {}
    local mode = vim.fn.mode()
    local first, last = vim.fn.line("."), vim.fn.line(".")
    if mode == "v" or mode == "V" then
      first, last = math.min(vim.fn.line("v"), first), math.max(vim.fn.line("v"), last)
    end
    for l = first, last do
      local entry = oil.get_entry_on_line(0, l)
      if entry and dir then
        out[#out + 1] = dir .. entry.name
      end
    end
    return out
  end
  return nil
end

--- Attach the files selected in a netrw or oil.nvim buffer to the entry at
--- the cursor of a window showing an Org buffer, with `attach.method`
--- (org-attach-dired-to-subtree).
---@param paths? string[] default: `file_manager_selection()`
function M.attach_from_file_manager(paths)
  paths = paths or M.file_manager_selection()
  if not paths then
    utils.error("This command must be triggered in a netrw or oil buffer")
    return
  end
  local win
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if w ~= vim.api.nvim_get_current_win() and vim.bo[vim.api.nvim_win_get_buf(w)].filetype == "org" then
      win = w
      break
    end
  end
  if not win then
    utils.error("Can't attach to subtree.  No window displaying an Org buffer")
    return
  end
  local target = { bufnr = vim.api.nvim_win_get_buf(win), lnum = vim.api.nvim_win_get_cursor(win)[1] }
  local done = {}
  for _, p in ipairs(paths) do
    done[#done + 1] = M.attach_file(p, nil, target)
  end
  if (cfg().method or "cp") == "mv" and vim.bo.filetype == "netrw" then
    pcall(vim.cmd, "edit")
  end
  return done
end

return M
