---@mod org.yank Pasting images and files (yank-media, drag and drop)
---
--- Emacs 9.8's yank-media handlers and file drops for Org buffers:
--- `yank_media` pastes an image from the system clipboard (saved as an
--- attachment or into a directory, and linked) or files copied in a file
--- manager; files dropped on the terminal (which pastes their paths) are
--- attached, opened or linked (`yank.dnd_method`). See |org-yank-media|.

local config = require("org.config")
local utils = require("org.utils")

local M = {}

local function cfg()
  return config.opts.yank or {}
end

-- mailcap-mime-type-to-extension for the usual image types
local EXTENSIONS = {
  ["image/png"] = "png",
  ["image/jpeg"] = "jpeg",
  ["image/gif"] = "gif",
  ["image/webp"] = "webp",
  ["image/tiff"] = "tiff",
  ["image/svg+xml"] = "svg",
  ["image/bmp"] = "bmp",
}

local function run(cmd)
  local ok, res = pcall(function()
    return vim.system(cmd, { text = false }):wait(5000)
  end)
  if ok and res and res.code == 0 then
    return res.stdout or ""
  end
  return nil
end

--- The system clipboard: its MIME types and a reader for one of them.
--- wl-paste on Wayland, xclip on X11, osascript on macOS.
---@return { types: string[], read: fun(mime: string): string|nil }|nil
function M.clipboard()
  if vim.env.WAYLAND_DISPLAY and vim.fn.executable("wl-paste") == 1 then
    local out = run({ "wl-paste", "--list-types" })
    if not out then
      return nil
    end
    return {
      types = vim.split(out, "\n", { trimempty = true }),
      read = function(mime)
        return run({ "wl-paste", "--no-newline", "--type", mime })
      end,
    }
  elseif vim.env.DISPLAY and vim.fn.executable("xclip") == 1 then
    local out = run({ "xclip", "-selection", "clipboard", "-t", "TARGETS", "-o" })
    if not out then
      return nil
    end
    return {
      types = vim.split(out, "\n", { trimempty = true }),
      read = function(mime)
        return run({ "xclip", "-selection", "clipboard", "-t", mime, "-o" })
      end,
    }
  elseif vim.fn.has("mac") == 1 and vim.fn.executable("osascript") == 1 then
    local info = run({ "osascript", "-e", "clipboard info" }) or ""
    local types = {}
    if info:find("PNGf", 1, true) then
      types[#types + 1] = "image/png"
    end
    if info:find("furl", 1, true) then
      types[#types + 1] = "text/uri-list"
    end
    return {
      types = types,
      read = function(mime)
        if mime == "image/png" then
          local tmp = vim.fn.tempname() .. ".png"
          local script = {
            "set f to open for access POSIX file " .. string.format("%q", tmp) .. " with write permission",
            "write (the clipboard as «class PNGf») to f",
            "close access f",
          }
          local cmd = { "osascript" }
          for _, l in ipairs(script) do
            vim.list_extend(cmd, { "-e", l })
          end
          if not run(cmd) then
            return nil
          end
          local fd = io.open(tmp, "rb")
          local data = fd and fd:read("*a")
          if fd then
            fd:close()
          end
          os.remove(tmp)
          return data
        elseif mime == "text/uri-list" then
          local p = run({ "osascript", "-e", "POSIX path of (the clipboard as «class furl»)" })
          return p and ("file://" .. vim.trim(p)) or nil
        end
      end,
    }
  end
  return nil
end

--- Default image name (org-yank-image-autogen-filename).
local function autogen_name()
  local sec, usec = vim.uv.gettimeofday()
  return os.date("clipboard-%Y%m%dT%H%M%S.", sec) .. string.format("%06d", usec)
end

local function buffer_dir()
  local name = vim.api.nvim_buf_get_name(0)
  return name ~= "" and vim.fn.fnamemodify(name, ":p:h") or vim.fn.getcwd()
end

--- Make `dir` absolute like expand-file-name in the buffer's directory.
local function absolute(dir)
  dir = vim.fs.normalize(dir)
  if not dir:match("^/") then
    dir = buffer_dir() .. "/" .. dir
  end
  return vim.fs.normalize(vim.fn.fnamemodify(dir, ":p")):gsub("/$", "")
end

--- The directory images go to (org-yank-image-save-method), or "attach".
local function image_dir()
  local m = cfg().image_save_method
  if m == nil or m == "attach" then
    return "attach"
  elseif type(m) == "function" then
    local d = m()
    if type(d) ~= "string" then
      error("`yank.image_save_method' did not return a string: " .. vim.inspect(d), 0)
    end
    return absolute(d)
  elseif type(m) == "string" then
    return absolute(m)
  end
  error("Unknown value of `yank.image_save_method': " .. vim.inspect(m), 0)
end

--- Insert `text` at the cursor like a paste: after the cursor in Normal
--- mode, at it in Insert mode.
local function put(text)
  local insert = vim.api.nvim_get_mode().mode:match("^i") ~= nil
  vim.api.nvim_put({ text }, "c", not insert, true)
end

local function link_string(link, desc)
  return require("org.links").format_for_buffer(link, desc)
end

--- Save image `data` of type `mime` and insert a link to it
--- (org--image-yank-media-handler): as an attachment of the entry
--- (`yank.image_save_method = "attach"`) or in a directory.
---@param mime string
---@param data string
---@return string|nil the inserted link
function M.save_image(mime, data)
  local ext = EXTENSIONS[mime] or mime:match("^image/([%w%-]+)") or "img"
  local namefn = cfg().image_file_name_function
  local base = type(namefn) == "function" and namefn() or autogen_name()
  if not base or base == "" then
    return nil
  end
  local dir = image_dir()
  local attach = dir == "attach"
  if attach then
    dir = vim.fs.normalize(vim.fn.fnamemodify(vim.fn.tempname(), ":h"))
  else
    vim.fn.mkdir(dir, "p")
  end
  local path = dir .. "/" .. base .. "." .. ext
  local fd = io.open(path, "wb")
  if not fd then
    utils.error("Cannot write " .. path)
    return nil
  end
  fd:write(data)
  fd:close()
  local text
  if attach then
    local dest, link, desc = require("org.attach").attach_file(path, "mv")
    if not dest then
      return nil
    end
    text = link_string(link, desc)
  else
    text = link_string("file:" .. path)
  end
  put(text)
  return text
end

--- Ask like org--dnd-rmc: a key menu; nil when cancelled.
local function choose(title, items)
  return require("org.ui").menu({ title = title, items = items })
end

local IMAGE_EXT = { png = true, jpg = true, jpeg = true, gif = true, webp = true, tiff = true, svg = true, bmp = true }

--- Attach a dropped / pasted file (org--dnd-attach-file). `action`: "copy"
--- (cp), "move" (mv), "ask" or "private" (`yank.dnd_default_attach_method`,
--- else `attach.method`). An image goes to `yank.image_save_method` when
--- that is a directory.
local function attach_file(path, action, sep)
  local method
  if action == "copy" then
    method = "cp"
  elseif action == "move" then
    method = "mv"
  elseif action == "ask" then
    method = choose("Attach using method", {
      { key = "c", label = "copy", value = "cp" },
      { key = "m", label = "move", value = "mv" },
      { key = "l", label = "hard link", value = "ln" },
      { key = "s", label = "symbolic link", value = "lns" },
    })
    if not method then
      return false
    end
  else
    method = cfg().dnd_default_attach_method or (config.opts.attach or {}).method or "cp"
  end
  local ext = (vim.fn.fnamemodify(path, ":e") or ""):lower()
  local link
  if IMAGE_EXT[ext] and image_dir() ~= "attach" then
    local dir = image_dir()
    vim.fn.mkdir(dir, "p")
    local stored = dir .. "/" .. vim.fn.fnamemodify(path, ":t")
    local ok, err
    if method == "mv" then
      ok, err = vim.uv.fs_rename(path, stored)
    elseif method == "ln" then
      ok, err = vim.uv.fs_link(path, stored)
    elseif method == "lns" then
      ok, err = vim.uv.fs_symlink(path, stored)
    else
      ok, err = vim.uv.fs_copyfile(path, stored)
    end
    if not ok then
      utils.error(tostring(err))
      return false
    end
    link = "file:" .. stored
  else
    local dest, l = require("org.attach").attach_file(path, method)
    if not dest then
      return false
    end
    link = l
  end
  -- Emacs passes the (LINK DESCRIPTION) list's cdr as description: none
  put(link_string(link) .. sep)
  return true
end

--- Handle a dropped / pasted local file per `yank.dnd_method`
--- (org--dnd-local-file-handler): "attach", "open", "file-link" or "ask".
--- Returns false when the choice was cancelled.
---@param path string
---@param action? "copy"|"move"|"ask"|"private"
---@param sep? string text after the link (default " ")
---@return boolean
function M.handle_file(path, action, sep)
  sep = sep or " "
  local method = cfg().dnd_method or "ask"
  if method == "ask" then
    method = choose("What to do with file?", {
      { key = "a", label = "attach", value = "attach" },
      { key = "o", label = "open", value = "open" },
      { key = "f", label = "insert file: link", value = "file-link" },
    })
    if not method then
      return false
    end
  end
  if method == "attach" then
    return attach_file(path, action or "private", sep)
  elseif method == "open" then
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    return true
  elseif method == "file-link" then
    put(link_string(path) .. sep)
    return true
  end
  return false
end

--- Handle several files like org--dnd-multi-local-file-handler: no
--- separator after a single file, a space after each of several.
---@param paths string[]
---@param action? string
---@return boolean handled (false: the first choice was cancelled)
function M.handle_files(paths, action)
  local sep = #paths == 1 and "" or " "
  for i, p in ipairs(paths) do
    if not M.handle_file(p, action, sep) and i == 1 then
      return false
    end
  end
  return true
end

local function decode_uri(u)
  return (u:gsub("^file://", ""):gsub("%%(%x%x)", function(h)
    return string.char(tonumber(h, 16))
  end))
end

--- Local files named by pasted text: `file://` URIs (one per line) or
--- paths as terminals paste dropped files (shell quoted or escaped,
--- separated by spaces or newlines). Nil unless every one exists.
---@param text string
---@return string[]|nil
function M.parse_dropped(text)
  text = vim.trim(text:gsub("%z", ""))
  if text == "" then
    return nil
  end
  local paths = {}
  if text:match("^file://") then
    for line in text:gmatch("[^\r\n]+") do
      if not line:match("^file://") then
        return nil
      end
      paths[#paths + 1] = decode_uri(vim.trim(line))
    end
  else
    local cur, i, quote = nil, 1, nil
    while i <= #text do
      local c = text:sub(i, i)
      if quote then
        if c == quote then
          quote = nil
        elseif c == "\\" and quote == '"' and i < #text then
          i = i + 1
          cur = (cur or "") .. text:sub(i, i)
        else
          cur = (cur or "") .. c
        end
      elseif c == "'" or c == '"' then
        quote, cur = c, cur or ""
      elseif c == "\\" and i < #text then
        i = i + 1
        cur = (cur or "") .. text:sub(i, i)
      elseif c:match("%s") then
        if cur then
          paths[#paths + 1] = cur
          cur = nil
        end
      else
        cur = (cur or "") .. c
      end
      i = i + 1
    end
    if quote then
      return nil
    end
    if cur then
      paths[#paths + 1] = cur
    end
  end
  for k, p in ipairs(paths) do
    p = vim.fs.normalize(p)
    if not p:match("^/") or vim.fn.filereadable(p) == 0 then
      return nil
    end
    paths[k] = p
  end
  return #paths > 0 and paths or nil
end

--- Paste from the system clipboard like Emacs's yank-media in Org
--- buffers: an image is saved and linked (`yank.image_save_method`,
--- `yank.image_file_name_function`); files copied in a file manager are
--- handled like dropped files (cut moves them). Returns false when the
--- clipboard holds neither, so the key does its default.
function M.yank_media()
  local clip = M.clipboard()
  if not clip then
    return false
  end
  local image
  for _, t in ipairs(clip.types) do
    if t == "image/png" then
      image = t
      break
    elseif t:match("^image/") and not image then
      image = t
    end
  end
  if image then
    local data = clip.read(image)
    if data and data ~= "" then
      return M.save_image(image, data) ~= nil
    end
  end
  for _, t in ipairs(clip.types) do
    if t:match("^x%-special/%a+%-copied%-files$") then
      -- first line: copy or cut, then file:// URIs
      local data = clip.read(t) or ""
      local lines = vim.split(data:gsub("%z", ""), "[\r\n]+", { trimempty = true })
      local action = table.remove(lines, 1) == "cut" and "move" or "copy"
      local paths = {}
      for _, l in ipairs(lines) do
        local p = decode_uri(l)
        if vim.fn.filereadable(p) == 1 then
          paths[#paths + 1] = p
        else
          utils.notify(string.format("File `%s' is not readable, skipping", p))
        end
      end
      return #paths > 0 and M.handle_files(paths, action)
    end
  end
  for _, t in ipairs(clip.types) do
    if t == "text/uri-list" then
      local paths = M.parse_dropped(clip.read(t) or "")
      if paths then
        return M.handle_files(paths, "copy")
      end
    end
  end
  return false
end

--- vim.paste wrapper: in Org buffers, text that names existing files
--- (a file dropped on the terminal) is handled like a drop
--- (`yank.dnd_paste`). Everything else pastes as usual.
function M.setup_paste()
  if M._paste_wrapped then
    return
  end
  M._paste_wrapped = true
  local orig = vim.paste
  vim.paste = function(lines, phase)
    if phase == -1 and vim.bo.filetype == "org" and cfg().dnd_paste ~= false then
      local paths = M.parse_dropped(table.concat(lines, "\n"))
      if paths then
        local ok, handled = pcall(M.handle_files, paths, "private")
        if ok and handled then
          return true
        end
      end
    end
    return orig(lines, phase)
  end
end

return M
