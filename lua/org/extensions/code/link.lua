---@mod org.extensions.code.link The `code:` link type
---
--- `[[code:src/app.lua::M.setup]]` opens the file and jumps to the symbol
--- (LSP document symbols, else treesitter, else a text search);
--- `[[code:src/app.lua::42]]` jumps to a line. A relative path is looked up
--- from the git root of the org file, then of the working directory, then
--- from the org file's directory and the working directory.

local git = require("org.extensions.code.git")
local symbols = require("org.extensions.code.symbols")
local utils = require("org.utils")

local M = {}

local function opts()
  return require("org.extensions").opts("code") or require("org.extensions.code").defaults
end

--- Split a `code:` path into file and target (symbol name or line number).
---@param path string
---@return string file, string|nil target
function M.split(path)
  local file, target = path:match("^(.-)::(.*)$")
  if not file then
    return path, nil
  end
  target = vim.trim(target)
  return file, target ~= "" and target or nil
end

--- Absolute path of the file of a `code:` link followed from `from` (a
--- buffer, default the current one, or the path of the org file), or nil.
---@param file string
---@param from? integer|string
---@return string|nil
function M.resolve(file, from)
  from = from or vim.api.nvim_get_current_buf()
  local expanded = vim.fs.normalize(file)
  if expanded:match("^/") or expanded:match("^%a:[/\\]") then
    return vim.fs.normalize(expanded)
  end
  local bases = {}
  local name = type(from) == "string" and from or vim.api.nvim_buf_get_name(from)
  local org_dir = name ~= "" and vim.fs.dirname(vim.fn.fnamemodify(name, ":p")) or nil
  bases[#bases + 1] = (type(from) == "number" or name ~= "") and git.root(from) or nil
  bases[#bases + 1] = git.root(vim.fn.getcwd())
  bases[#bases + 1] = org_dir
  bases[#bases + 1] = vim.fn.getcwd()
  for _, root in ipairs(require("org.extensions.code").recent_roots()) do
    bases[#bases + 1] = root
  end
  for _, b in ipairs(bases) do
    local p = vim.fs.normalize(b .. "/" .. file)
    if vim.uv.fs_stat(p) then
      return p
    end
  end
  return nil
end

--- Follow a `code:` link (the `follow` of the link type).
---@param path string
---@return boolean
function M.follow(path)
  local file, target = M.split(path)
  local abs = M.resolve(file)
  if not abs then
    utils.warn("code: link: cannot find " .. file)
    return false
  end
  vim.cmd("normal! m'")
  utils.open_file(abs)
  local buf = vim.api.nvim_get_current_buf()
  if not target then
    return true
  end
  local lnum = tonumber(target)
  local pos
  if lnum then
    pos = { lnum = lnum, col = 0 }
  else
    pos = symbols.find(buf, target)
    if not pos then
      utils.warn("code: link: no symbol " .. target .. " in " .. vim.fn.fnamemodify(abs, ":~:."))
      return true
    end
  end
  local last = vim.api.nvim_buf_line_count(buf)
  pcall(vim.api.nvim_win_set_cursor, 0, { math.max(1, math.min(pos.lnum, last)), pos.col or 0 })
  pcall(vim.cmd, "normal! zv")
  return true
end

--- Is `buf` a code buffer links and captures can point at (a file that
--- is not org)?
---@param buf integer
---@return boolean
function M.is_code_buffer(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return false
  end
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" or name:match("^%a[%w+.-]*://") or vim.bo[buf].buftype ~= "" then
    return false
  end
  local ft = vim.bo[buf].filetype
  if ft == "org" or ft == "orgagenda" then
    return false
  end
  return not vim.tbl_contains(opts().exclude_filetypes or {}, ft)
end

--- The path written in a link to `file`: relative to the git root with
--- `link_path = "relative"` (when inside one), else absolute with `~`.
---@param file string
---@return string
function M.link_path(file)
  if opts().link_path == "relative" then
    local root = git.root(file)
    local rel = root and git.relpath(root, file)
    if rel then
      return rel
    end
  end
  return vim.fn.fnamemodify(file, ":p:~")
end

--- A `code:` link to `lnum` of `buf`: to the symbol there when one is found
--- (and `store_symbol` is on), else to the line.
---@param buf integer
---@param lnum integer
---@param col? integer
---@return { link: string, desc: string, symbol?: string }
function M.link_for(buf, lnum, col)
  local file = vim.api.nvim_buf_get_name(buf)
  local path = M.link_path(file)
  local base = vim.fs.basename(file)
  local sym = opts().store_symbol ~= false and symbols.at(buf, lnum, col) or nil
  if sym and not sym:find("::", 1, true) and not sym:find("[%[%]]") then
    return { link = "code:" .. path .. "::" .. sym, desc = sym .. " (" .. base .. ")", symbol = sym }
  end
  return { link = "code:" .. path .. "::" .. lnum, desc = base .. ":" .. lnum }
end

--- The `store` of the link type: a `code:` link from a code buffer, nil
--- elsewhere (so org buffers keep their own links).
---@return { link: string, desc: string }|nil
function M.store()
  local buf = vim.api.nvim_get_current_buf()
  if opts().store_links == false or not M.is_code_buffer(buf) then
    return nil
  end
  local cur = vim.api.nvim_win_get_cursor(0)
  local l = M.link_for(buf, cur[1], cur[2])
  return { link = l.link, desc = l.desc }
end

--- The `complete` of the link type: a file, then an optional symbol.
---@return string|nil
function M.complete()
  local f = utils.input({ prompt = "code: file: ", completion = "file" })
  if not f or vim.trim(f) == "" then
    return nil
  end
  local sym = utils.input({ prompt = "Symbol or line (empty for none): " })
  if sym and vim.trim(sym) ~= "" then
    return "code:" .. vim.trim(f) .. "::" .. vim.trim(sym)
  end
  return "code:" .. vim.trim(f)
end

--- Where a `code:` link points, found without opening the file (no
--- language server: treesitter, else a text search): `{ path, lnum, col,
--- len, first, last, lang }` with `first`..`last` the lines of the
--- definition (the whole file without a target), or nil and an error.
---@param path string the link's path (`file::target`)
---@param from? integer|string the buffer or path of the org file
---@return table|nil, string|nil
function M.locate(path, from)
  local file, target = M.split(path)
  local abs = M.resolve(file, from)
  if not abs or vim.fn.filereadable(abs) ~= 1 then
    return nil, "code: link: cannot find " .. file
  end
  local ft = vim.filetype.match({ filename = abs }) or ""
  local out = { path = abs, lnum = 1, col = 0, len = 0, lang = require("org.extensions.code.context").lang(ft) }
  local n = target and tonumber(target)
  if n then
    out.lnum, out.first, out.last = n, n, n
  elseif target then
    local pos = symbols.find_in_file(abs, target)
    if not pos then
      return nil, "code: link: no symbol " .. target .. " in " .. vim.fn.fnamemodify(abs, ":~:.")
    end
    out.lnum, out.col, out.len, out.first, out.last = pos.lnum, pos.col, pos.len, pos.first, pos.last
  end
  return out
end

--- The link type table registered in `links.types.code`.
M.type = {
  --- For other extensions: the target's position (`M.locate`).
  locate = function(path, from)
    return M.locate(path, from)
  end,
  --- For `#+transclude:`: the file, the lines of the definition and the
  --- src block language.
  transclude = function(path, ctx)
    local loc, err = M.locate(path, ctx and (ctx.filename or ctx.bufnr))
    if not loc then
      return nil, err
    end
    local lines = loc.first and (loc.first .. "-" .. loc.last) or nil
    return { path = loc.path, lines = lines, src = loc.lang ~= "" and loc.lang or nil }
  end,
  follow = function(path)
    return M.follow(path)
  end,
  store = function()
    return M.store()
  end,
  complete = function()
    return M.complete()
  end,
  export = function(path, desc, backend)
    local file, target = M.split(path)
    local text = desc or (target and (file .. ":" .. target) or file)
    if backend == "html" then
      local html = text:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
      return "<code>" .. html .. "</code>"
    elseif backend == "latex" then
      return "\\texttt{" .. text:gsub("([_%%#&{}$])", "\\%1") .. "}"
    elseif backend == "md" or backend == "markdown" then
      return "`" .. text .. "`"
    end
    return text
  end,
}

return M
