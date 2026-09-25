---@mod org.attach Attachments (org-attach)
---
--- Each entry gets an attachment directory. It is the `DIR` property when
--- set (inherited), otherwise derived from the entry's ID:
---   <dir of org file>/<attach.dir>/<first 2 chars of ID>/<rest of ID>
--- Attaching adds the `ATTACH` tag. `attachment:file.pdf` links resolve
--- inside the directory of the entry containing the link.

local config = require("org.config")
local edit = require("org.edit")
local ui = require("org.ui")
local utils = require("org.utils")

local M = {}

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

--- Attachment directory for the entry at target.
---@param target? org.Target
---@param create_id? boolean create an ID when the entry has none
---@return string|nil dir, org.Headline|nil hl
function M.dir_for(target, create_id)
  local bufnr, file, hl = edit.resolve(target)
  if not hl then
    return nil
  end
  local dir = hl:get_property("DIR", true)
  local base = file_dir(file, bufnr)
  if dir and dir ~= "" then
    dir = vim.fn.expand(dir)
    if not dir:match("^/") then
      dir = base .. "/" .. dir
    end
    return vim.fs.normalize(dir), hl
  end
  local id = hl.properties.ID
  if not id and create_id then
    id = require("org.id").get_create({ bufnr = bufnr, lnum = hl.line })
    hl = edit.refresh(bufnr, hl.line)
  end
  if not id then
    -- look for an ancestor with an ID (inherited attachment dir)
    local p = hl.parent
    while p and not id do
      id = p.properties.ID
      p = p.parent
    end
  end
  if not id then
    return nil, hl
  end
  local root = (config.opts.attach or {}).dir or "data/"
  root = vim.fn.expand(root)
  if not root:match("^/") then
    root = base .. "/" .. root
  end
  local sub = #id > 2 and (id:sub(1, 2) .. "/" .. id:sub(3)) or id
  return vim.fs.normalize(root .. "/" .. sub), hl
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

local function add_tag(bufnr, lnum, tag, remove)
  local file = require("org.files").get_buffer(bufnr)
  local hl = file:headline_at(lnum)
  if not hl then
    return
  end
  local tags = vim.deepcopy(hl.tags)
  local has = vim.tbl_contains(tags, tag)
  if remove and has then
    tags = vim.tbl_filter(function(t)
      return t ~= tag
    end, tags)
  elseif not remove and not has then
    tags[#tags + 1] = tag
  else
    return
  end
  edit.update_headline(bufnr, hl.line, { tags = tags })
end

--- Attach a file to the entry at target.
---@param path string source file
---@param method? "cp"|"mv"|"ln"
---@param target? org.Target
---@return string|nil destination
function M.attach_file(path, method, target)
  method = method or (config.opts.attach or {}).method or "cp"
  path = vim.fs.normalize(vim.fn.expand(path))
  if not utils.exists(path) then
    utils.warn("No such file: " .. path)
    return nil
  end
  local bufnr = edit.resolve(target)
  local dir, hl = M.dir_for(target, true)
  if not dir or not hl then
    utils.warn("Not under a headline")
    return nil
  end
  vim.fn.mkdir(dir, "p")
  local name = vim.fn.fnamemodify(path, ":t")
  local dest = dir .. "/" .. name
  local ok, err
  if method == "mv" then
    ok, err = vim.uv.fs_rename(path, dest)
    if not ok then
      ok, err = vim.uv.fs_copyfile(path, dest)
      if ok then
        os.remove(path)
      end
    end
  elseif method == "ln" then
    ok, err = vim.uv.fs_symlink(path, dest)
  elseif method == "lns" then
    -- symbolic link with a path relative to the attachment directory
    ok, err = vim.uv.fs_symlink(M.relative_path(path, dir), dest)
  else
    ok, err = vim.uv.fs_copyfile(path, dest)
  end
  if not ok then
    utils.error("Attach failed: " .. tostring(err))
    return nil
  end
  add_tag(bufnr, hl.line, "ATTACH")
  pcall(function()
    require("org.links").store("attachment:" .. name, name)
  end)
  utils.notify("Attached " .. name)
  return dest
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
    utils.warn("Not under a headline")
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
  add_tag(bufnr, hl.line, "ATTACH")
  utils.notify("Attached " .. name)
  return dest
end

--- Save the contents of buffer `src` as an attachment (org-attach-buffer).
---@return string|nil destination
function M.attach_buffer(src, target, name)
  local bufnr = edit.resolve(target)
  local dir, hl = M.dir_for(target, true)
  if not dir or not hl then
    utils.warn("Not under a headline")
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
  utils.writefile(dest, vim.api.nvim_buf_get_lines(src, 0, -1, false))
  add_tag(bufnr, hl.line, "ATTACH")
  utils.notify("Attached " .. name)
  return dest
end

--- Make the ATTACH tag match the attachment directory (org-attach-sync):
--- tag the entry when it has files, untag it (and offer to delete the
--- empty directory) otherwise.
function M.sync(target)
  local bufnr = edit.resolve(target)
  local dir, hl = M.dir_for(target)
  if not hl then
    return
  end
  local has = dir and utils.is_dir(dir) and #M.list(target) > 0
  add_tag(bufnr, hl.line, "ATTACH", not has)
  if dir and utils.is_dir(dir) and not has and utils.confirm("Delete empty attachment directory " .. dir .. "?") then
    vim.fn.delete(dir, "d")
  end
  return has
end

local function list_files(dir)
  if not dir or not utils.is_dir(dir) then
    return {}
  end
  local out = {}
  for name, t in vim.fs.dir(dir, { depth = 5 }) do
    if t ~= "directory" then
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

local function prompt_path(prompt, completion)
  local ok, v = pcall(vim.fn.input, { prompt = prompt, completion = completion or "file", cancelreturn = vim.NIL })
  if not ok or v == vim.NIL or vim.trim(v) == "" then
    return nil
  end
  return vim.trim(v)
end

local function choose_attachment(target, prompt)
  local dir = M.dir_for(target)
  local names = list_files(dir)
  if #names == 0 then
    utils.warn("No attachments")
    return nil
  end
  local name = #names == 1 and names[1] or utils.select(names, { prompt = prompt })
  return name and (dir .. "/" .. name) or nil, dir
end

--- The org-attach dispatcher.
function M.menu()
  local bufnr, _, hl = edit.resolve_headline()
  if not hl then
    return
  end
  local target = { bufnr = bufnr, lnum = hl.line }
  local choice = ui.menu({
    title = "Attach",
    items = {
      { key = "a", label = "Attach a file (" .. ((config.opts.attach or {}).method or "cp") .. ")", value = "a" },
      { key = "c", label = "Attach by copying", value = "c" },
      { key = "m", label = "Attach by moving", value = "m" },
      { key = "l", label = "Attach by symlink", value = "l" },
      { key = "y", label = "Attach by relative symlink", value = "y" },
      { key = "u", label = "Attach a file from a URL (curl)", value = "u" },
      { key = "b", label = "Attach the contents of a buffer", value = "b" },
      { key = "n", label = "Create a new attachment file", value = "n" },
      { key = "z", label = "Synchronize the ATTACH tag with the directory", value = "z" },
      { key = "o", label = "Open an attachment", value = "o" },
      { key = "O", label = "Open an attachment with the system app", value = "O" },
      { key = "f", label = "Open the attachment directory", value = "f" },
      { key = "F", label = "Open the attachment directory with the system app", value = "F" },
      { key = "d", label = "Delete an attachment", value = "d" },
      { key = "D", label = "Delete all attachments", value = "D" },
      { key = "s", label = "Set a specific attachment directory (DIR)", value = "s" },
      { key = "S", label = "Unset the attachment directory (remove DIR)", value = "S" },
    },
  })
  if not choice then
    return
  end
  if choice == "a" or choice == "c" or choice == "m" or choice == "l" or choice == "y" then
    local path = prompt_path("File to attach: ")
    if path then
      local method = ({ c = "cp", m = "mv", l = "ln", y = "lns" })[choice]
      M.attach_file(path, method, target)
    end
  elseif choice == "u" then
    local url = utils.input({ prompt = "URL of the file to attach: " })
    if url and vim.trim(url) ~= "" then
      M.attach_url(vim.trim(url), target)
    end
  elseif choice == "b" then
    local names, bufs = {}, {}
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.bo[b].buflisted and b ~= bufnr then
        local n = vim.api.nvim_buf_get_name(b)
        names[#names + 1] = n ~= "" and vim.fn.fnamemodify(n, ":~:.") or ("[No Name] #" .. b)
        bufs[#bufs + 1] = b
      end
    end
    if #names == 0 then
      utils.warn("No other buffers")
      return
    end
    local _, idx = utils.select(names, { prompt = "Buffer to attach" })
    if idx then
      M.attach_buffer(bufs[idx], target)
    end
  elseif choice == "z" then
    M.sync(target)
  elseif choice == "F" then
    local dir = M.dir_for(target, true)
    vim.fn.mkdir(dir, "p")
    vim.ui.open(dir)
  elseif choice == "S" then
    if hl.properties.DIR then
      require("org.properties").delete_property({ bufnr = bufnr, lnum = hl.line }, "DIR")
    else
      utils.notify("No DIR property on this entry")
    end
  elseif choice == "n" then
    local name = utils.input({ prompt = "New attachment file name: " })
    if name and vim.trim(name) ~= "" then
      local dir = M.dir_for(target, true)
      vim.fn.mkdir(dir, "p")
      add_tag(bufnr, hl.line, "ATTACH")
      vim.cmd("split " .. vim.fn.fnameescape(dir .. "/" .. vim.trim(name)))
    end
  elseif choice == "o" or choice == "O" then
    local path = choose_attachment(target, "Open attachment")
    if path then
      if choice == "O" then
        vim.ui.open(path)
      else
        require("org.links").open("file:" .. path, { bufnr = bufnr })
      end
    end
  elseif choice == "f" then
    local dir = M.dir_for(target, true)
    vim.fn.mkdir(dir, "p")
    vim.cmd("edit " .. vim.fn.fnameescape(dir))
  elseif choice == "d" then
    local path = choose_attachment(target, "Delete attachment")
    if path and utils.confirm("Delete " .. vim.fn.fnamemodify(path, ":t") .. "?") then
      os.remove(path)
      if #M.list(target) == 0 then
        add_tag(bufnr, hl.line, "ATTACH", true)
      end
    end
  elseif choice == "D" then
    local dir = M.dir_for(target)
    if dir and utils.is_dir(dir) and utils.confirm("Delete all attachments in " .. dir .. "?") then
      vim.fn.delete(dir, "rf")
      add_tag(bufnr, hl.line, "ATTACH", true)
    end
  elseif choice == "s" then
    local dir = prompt_path("Attachment directory: ", "dir")
    if dir then
      edit.set_property(bufnr, hl.line, "DIR", dir)
    end
  end
end

return M
