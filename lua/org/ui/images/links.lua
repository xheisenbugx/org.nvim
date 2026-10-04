---@mod org.ui.images.links Image links
---
--- Image links and their width and alignment, the preview functions of
--- link types (org-link-set-parameters :preview), remote images.
--- Part of org.ui.images, which loads it.

local config = require("org.config")
local utils = require("org.utils")
local shared = require("org.ui.images.shared")

local M = require("org.ui.images")

local executable = shared.executable
local opts = shared.opts

---------------------------------------------------------------------------
-- Image links
---------------------------------------------------------------------------

local function is_image(path, exts)
  local ext = path:match("%.([%w]+)$")
  return ext and vim.tbl_contains(exts, ext:lower())
end

--- `:width` (or `:align`, `:center`) of an #+ATTR_x line, as written.
local function attr_value(line, key)
  local v = line:match(":" .. key .. "%s+([^%s]+)")
  return v
end

--- Whether an ATTR :width value can be read (org-display-inline-image--width).
local function width_readable(v)
  if type(v) ~= "string" then
    return false
  end
  if v == "t" then
    return true
  end
  local s = v:gsub("^%+", "")
  local n = tonumber(s:match("^[%d.]+"))
  if s:match("^%d+$") or s:match("^%d+px$") then
    return true
  elseif s:match("^[%d.]+%%") then
    return true
  elseif s:match("^%d*%.%d+") then
    return n ~= nil and n >= 0 and n <= 2
  end
  return false
end

--- The value of `ui.images.actual_width` for `row`, or of an inherited
--- ORG-IMAGE-ACTUAL-WIDTH property (org-property-or-variable-value).
local function actual_width(bufnr, row)
  local v = opts().actual_width
  if v == nil then
    v = true
  end
  local ok, file = pcall(require("org.files").get_buffer, bufnr)
  if ok then
    local hl = file:headline_at(row)
    local p = hl and hl:get_property("ORG-IMAGE-ACTUAL-WIDTH", true)
      or (file.settings.properties or {})["ORG-IMAGE-ACTUAL-WIDTH"]
    if p then
      p = vim.trim(p)
      if p == "t" then
        v = true
      elseif p == "nil" then
        v = false
      elseif p:match("^%(%s*[%d.]+%s*%)$") then
        v = { tonumber(p:match("[%d.]+")) }
      elseif tonumber(p) then
        v = tonumber(p)
      end
    end
  end
  return v
end

--- The width an image link asks for: nil (its natural size), `{ px = n }`
--- or `{ fraction = f }` of the text width (org-display-inline-image--width).
function M.image_width(bufnr, row, attrs)
  local actual = actual_width(bufnr, row)
  if actual == true then
    return nil
  elseif type(actual) == "number" then
    return { px = actual }
  end
  -- nil or a list: #+ATTR_ORG, else another #+ATTR_x, else the list's car
  local org_w, other_w
  for _, a in ipairs(attrs or {}) do
    local backend = a:lower():match("^%s*#%+attr_([%w_-]+):")
    if backend then
      local v = attr_value(a, "width")
      if backend == "org" then
        org_w = org_w or v
      elseif not other_w and width_readable(v) then
        other_w = v
      end
    end
  end
  local w = width_readable(org_w) and org_w or other_w
  local n
  if w == "t" then
    return nil
  elseif not width_readable(w) then
    n = type(actual) == "table" and actual[1] or nil
  elseif w:match("^%+?[%d.]+%%") then
    n = tonumber(w:match("[%d.]+")) / 100
    return { fraction = n }
  else
    n = tonumber((w:gsub("^%+", ""):match("^[%d.]+")))
    if w:match("^%+?%d*%.%d") then
      return { fraction = n }
    end
  end
  return n and { px = n } or nil
end

--- "center" or "right" for a stand-alone image link (org-image--align).
function M.image_align(lines, lk, para)
  if not para or para.first ~= para.last then
    return nil
  end
  local line = lines[para.first]
  local before, after = line:sub(1, lk.col), line:sub(lk.end_col + 1)
  if not before:match("^%s*$") or not after:match("^%s*$") then
    return nil
  end
  local found
  for _, a in ipairs(para.attrs) do
    local backend = a:lower():match("^%s*#%+attr_([%w_-]+):")
    if backend then
      local v = (a:match(":center%s+t%f[%W]") and "center") or attr_value(a, "align")
      if v == "left" or v == "center" or v == "right" then
        found = v
        if backend == "org" then
          break
        end
      end
    end
  end
  if found then
    return (found == "center" or found == "right") and found or nil
  end
  local g = opts().align
  return (g == "center" or g == "right") and g or nil
end

local function link_file(bufnr, row, lk)
  local links = require("org.links")
  local path = (lk.path or ""):gsub("::.*$", "")
  if lk.type == "file" then
    return links.resolve_path(path, bufnr)
  elseif lk.type == "attachment" then
    local ok, p = pcall(require("org.attach").resolve_attachment, path, { bufnr = bufnr, lnum = row })
    return ok and p or nil
  end
end

---------------------------------------------------------------------------
-- Preview functions (org-link-set-parameters :preview)
---------------------------------------------------------------------------

---@class org.images.PreviewContext
---@field bufnr integer
---@field row integer 1-based
---@field col integer 0-based start of the link
---@field end_col integer 0-based, exclusive
---@field type string the link type
---@field link table the link (org.Link, or { type, path } for a description link)
---@field refresh boolean asked again with link_preview_refresh
---@field callback fun(file: string?) for a preview that returned true

--- Preview functions registered with `set_preview`, by link type.
local preview_fns = {}

--- Register `fn` as the preview function of `type` links (the `:preview`
--- parameter of org-link-set-parameters), or remove it with nil. A
--- `preview` function in `links.types.<type>` is used first.
--- `fn(path, ctx)` gets the link's path and an `org.images.PreviewContext`
--- and returns the image file to show, nil or false when there is nothing
--- to show, or true when it will call `ctx.callback(file)` later. A type
--- org.nvim does not know becomes a link type (`links.types.<type>`), like
--- with org-link-set-parameters.
---@param type string
---@param fn? fun(path: string, ctx: org.images.PreviewContext): string|boolean|nil
function M.set_preview(type, fn)
  preview_fns[type] = fn
  local lo = config.opts.links
  if fn and lo and not require("org.links").URL_SCHEMES[type] then
    lo.types = lo.types or {}
    lo.types[type] = lo.types[type] or {}
  end
end

--- file: and attachment: links to an existing image file
--- (org-link-preview-file, org-attach-preview-file).
local function file_preview(path, ctx)
  local file = link_file(ctx.bufnr, ctx.row, { type = ctx.type, path = path })
  if file and is_image(file, opts().extensions or M.IMAGE_EXTENSIONS) and vim.uv.fs_stat(file) then
    return file
  end
end

local function remote_dir()
  local dir = vim.fn.stdpath("cache") .. "/org/remote-images"
  vim.fn.mkdir(dir, "p")
  return dir
end

--- Download `url` to the file `out` and call `cb(ok, err)` (replaced in the
--- tests).
function M._fetch(url, out, cb)
  if not executable("curl") then
    return cb(false, "curl is needed to show remote images")
  end
  local tmp = out .. ".part"
  vim.system({ "curl", "-fsSL", "--max-time", "30", "-o", tmp, url }, {}, function(res)
    vim.schedule(function()
      if res.code == 0 and vim.uv.fs_stat(tmp) then
        vim.uv.fs_rename(tmp, out)
        cb(true)
      else
        os.remove(tmp)
        cb(false, "can't download " .. url)
      end
    end)
  end)
end

-- Downloads under way: fetching[out] = callbacks
local fetching = {}

--- http(s) links to an image (org-display-remote-inline-images): nothing
--- with "skip", else the image downloaded into the cache, at once with
--- "download", once (and on refresh) with "cache".
local function remote_preview(path, ctx)
  local mode = opts().remote
  if not mode or mode == "skip" then
    return nil
  end
  local url = ctx.type .. ":" .. path
  local ext = path:gsub("[?#].*$", ""):match("%.(%w+)$")
  if not ext or not is_image("x." .. ext, opts().extensions or M.IMAGE_EXTENSIONS) then
    return nil
  end
  local out = remote_dir() .. "/" .. utils.sha256(url):sub(1, 32) .. "." .. ext:lower()
  if mode ~= "download" and not ctx.refresh and vim.uv.fs_stat(out) then
    return out
  end
  if fetching[out] then
    table.insert(fetching[out], ctx.callback)
    return true
  end
  fetching[out] = { ctx.callback }
  M._fetch(url, out, function(ok, err)
    local cbs = fetching[out] or {}
    fetching[out] = nil
    if not ok and err then
      utils.warn(err)
    end
    for _, cb in ipairs(cbs) do
      cb(ok and out or nil)
    end
  end)
  return true
end

local builtin_previews = {
  file = file_preview,
  attachment = file_preview,
  http = remote_preview,
  https = remote_preview,
}

--- The preview function of `type` links, and whether it is the built-in
--- file one.
local function preview_for(type)
  local def = require("org.links").link_type(type)
  local fn = (def and def.preview) or preview_fns[type]
  if fn then
    return fn, false
  end
  fn = builtin_previews[type]
  if fn == remote_preview and (not opts().remote or opts().remote == "skip") then
    return nil, false
  end
  return fn, fn == file_preview
end

--- A description that is a sole plain or angle link of a type that can be
--- previewed.
local function description_link(desc)
  local d = vim.trim(desc or "")
  local target = d:match("^<([^<>]+)>$") or d
  local scheme, rest = target:match("^([%a][%w+%-]*):(%S+)$")
  if scheme then
    local links = require("org.links")
    local t = links.URL_SCHEMES[scheme:lower()] and scheme:lower() or scheme
    if preview_for(t) then
      return { type = t, path = rest }
    end
  end
end

--- Links of rows `first..last` (1-based) to preview, in the range `range`
--- ({ row, col, end_row, end_col }, 0-based columns) when given. Like
--- org-link-preview-region: links of a type with a preview function, without
--- a description unless `include_linked`, or whose description is a sole
--- such link. File and attachment links are resolved now (`path` is the
--- image file) and dropped when they are not images; other types carry
--- their `preview` function and the link's `link_path`.
---@class org.images.LinkSpec
---@field row integer
---@field col integer
---@field end_col integer
---@field text string
---@field type string
---@field link table
---@field path? string
---@field width? table
---@field align? string
---@field preview? function
---@field link_path? string

---@return org.images.LinkSpec[]
function M.find_image_links(bufnr, first, last, include_linked, range)
  local links = require("org.links")
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local info, paras = M.scan(lines)
  local out = {}
  for row = math.max(1, first), math.min(last, #lines) do
    local line = lines[row]
    if not info[row].skip and (line:find(":", 1, true) or line:find("[[", 1, true)) then
      for _, lk in ipairs(links.real_links(line)) do
        local col, end_col = lk.start_col - 1, lk.end_col
        local inside = not range
          or (
            (row > range.row + 1 or (row == range.row + 1 and end_col > range.col))
            and (row < range.end_row + 1 or (row == range.end_row + 1 and col < range.end_col))
          )
        if inside then
          local target
          local desc = lk.desc ~= nil and lk.desc ~= ""
          if include_linked or not desc then
            target = lk
          else
            target = description_link(lk.desc)
          end
          local fn, builtin = nil, false
          if target then
            fn, builtin = preview_for(target.type)
          end
          local spec
          if fn then
            local path = (target.path or ""):gsub("::.*$", "")
            spec = { row = row, col = col, end_col = end_col, type = target.type, link = target }
            if builtin then
              spec.path = fn(path, { bufnr = bufnr, row = row, type = target.type })
              spec = spec.path and spec or nil
            else
              spec.preview, spec.link_path = fn, target.path or ""
            end
          end
          if spec then
            local para = info[row].para and paras[info[row].para]
            spec.text = line:sub(col + 1, end_col)
            spec.width = M.image_width(bufnr, row, para and para.attrs)
            spec.align = M.image_align(lines, spec, para)
            out[#out + 1] = spec
          end
        end
      end
    end
  end
  return out
end
