---@mod org.dblock Dynamic blocks (#+BEGIN: name params ... #+END:)
---
--- Writers are registered by name: `register(name, fn)` where
--- `fn(params, ctx)` returns the block's content lines. `ctx` holds
--- `{ bufnr, start_line, end_line, name, content }` (`content` holds the
--- block's current lines). Built-in: clocktable, columnview.

local utils = require("org.utils")

local M = {}

---@alias org.DblockWriter fun(params: table<string, any>, ctx: { bufnr: integer, start_line: integer, end_line: integer, name: string, content: string[] }): string[]|nil

---@type table<string, org.DblockWriter>
M.writers = {}

--- Register a writer for `#+BEGIN: name` blocks (name is case-insensitive).
--- `params` are the parsed `:key value` pairs of the BEGIN line; the
--- returned lines replace the block's content.
---
--- ```lua
--- require("org.dblock").register("myblock", function(params, ctx)
---   return { "| generated | table |" }
--- end)
--- ```
---@param name string
---@param fn org.DblockWriter
function M.register(name, fn)
  M.writers[name:lower()] = fn
end

local BEGIN = "^%s*#%+[Bb][Ee][Gg][Ii][Nn]:%s+(%S+)%s*(.-)%s*$"
local END = "^%s*#%+[Ee][Nn][Dd]:%s*$"

--- Parse ":key value :key2 "quoted value" :list (a b)" into a table.
function M.parse_params(str)
  local params = {}
  local i = 1
  str = str or ""
  local n = #str
  while i <= n do
    local ks, ke, key = str:find("^%s*:([%w_%-]+)", i)
    if not ks then
      break
    end
    i = ke + 1
    local rest = str:sub(i)
    local value
    local ws = rest:match("^(%s*)")
    local j = i + #ws
    local c = str:sub(j, j)
    if c == '"' then
      -- a Lisp string: \" and \\ are escapes, \n a newline
      local k, buf = j + 1, {}
      while k <= n do
        local ch = str:sub(k, k)
        if ch == "\\" and k < n then
          local nx = str:sub(k + 1, k + 1)
          buf[#buf + 1] = nx == "n" and "\n" or nx == "t" and "\t" or nx
          k = k + 2
        elseif ch == '"' then
          break
        else
          buf[#buf + 1] = ch
          k = k + 1
        end
      end
      value = table.concat(buf)
      i = k + 1
    elseif c == "(" then
      local depth, k = 0, j
      while k <= n do
        local ch = str:sub(k, k)
        if ch == "(" then
          depth = depth + 1
        elseif ch == ")" then
          depth = depth - 1
          if depth == 0 then
            break
          end
        end
        k = k + 1
      end
      value = str:sub(j, k)
      i = k + 1
    elseif c == "" or c == ":" then
      value = true
      i = j
    else
      local vs, ve = str:find("^[^%s]+", j)
      local v = str:sub(vs, ve)
      -- timestamps with spaces: <2026-01-01 Thu>
      if v:match("^[<%[]") and not v:match("[>%]]$") then
        local close = str:find("[>%]]", ve + 1)
        if close then
          ve = close
          v = str:sub(vs, ve)
        end
      end
      value = v
      i = ve + 1
      if value == "nil" then
        value = false
      elseif value == "t" then
        value = true
      elseif tonumber(value) then
        value = tonumber(value)
      end
    end
    params[key:lower()] = value
  end
  return params
end

--- Find the dynamic block around `lnum`.
---@return { start_line: integer, end_line: integer, name: string, params: table, raw_params: string }|nil
function M.find_at(bufnr, lnum)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local s
  for i = lnum, 1, -1 do
    local l = lines[i]
    if l:match(BEGIN) then
      s = i
      break
    end
    if l:match(END) and i ~= lnum then
      return nil
    end
  end
  if not s then
    return nil
  end
  for i = s + 1, #lines do
    if lines[i]:match(END) then
      if i < lnum then
        return nil
      end
      local name, raw = lines[s]:match(BEGIN)
      return { start_line = s, end_line = i, name = name, raw_params = raw, params = M.parse_params(raw) }
    end
    if lines[i]:match(BEGIN) then
      return nil
    end
  end
  return nil
end

function M.at_cursor()
  return M.find_at(vim.api.nvim_get_current_buf(), vim.api.nvim_win_get_cursor(0)[1])
end

--- Rewrite the content of one block.
function M.update_block(bufnr, block)
  local writer = M.writers[block.name:lower()]
  if not writer then
    utils.warn("No writer for dynamic block: " .. block.name)
    return false
  end
  local ok, lines = pcall(writer, block.params, {
    bufnr = bufnr,
    start_line = block.start_line,
    end_line = block.end_line,
    name = block.name,
    content = vim.api.nvim_buf_get_lines(bufnr, block.start_line, block.end_line - 1, false),
  })
  if not ok then
    utils.error("Dynamic block " .. block.name .. ": " .. tostring(lines))
    return false
  end
  local indent = vim.api.nvim_buf_get_lines(bufnr, block.start_line - 1, block.start_line, false)[1]:match("^(%s*)")
  if indent ~= "" and lines then
    lines = vim.tbl_map(function(l)
      return indent .. l
    end, lines)
  end
  vim.api.nvim_buf_set_lines(bufnr, block.start_line, block.end_line - 1, false, lines or {})
  return true
end

function M.update_at_cursor()
  local bufnr = vim.api.nvim_get_current_buf()
  local block = M.at_cursor()
  if not block then
    utils.notify("Not in a dynamic block")
    return nil
  end
  return M.update_block(bufnr, block)
end

--- Update every dynamic block in the buffer (bottom to top).
function M.update_all(bufnr)
  if type(bufnr) ~= "number" or bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local starts = {}
  for i, l in ipairs(lines) do
    if l:match(BEGIN) then
      starts[#starts + 1] = i
    end
  end
  local count = 0
  for k = #starts, 1, -1 do
    local block = M.find_at(bufnr, starts[k])
    if block and M.update_block(bufnr, block) then
      count = count + 1
    end
  end
  utils.notify(string.format("Updated %d dynamic block(s)", count))
  return count
end

--- Insert (or update) a clock table at the cursor (org-clock-report).
function M.insert_clocktable()
  return require("org.clock").clock_report()
end

--- Insert `#+BEGIN: name params` / `#+END:` below the cursor line and
--- fill it.
local function insert_block(bufnr, header)
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  vim.api.nvim_buf_set_lines(bufnr, lnum, lnum, false, { "#+BEGIN: " .. header, "#+END:" })
  local block = M.find_at(bufnr, lnum + 1)
  vim.api.nvim_win_set_cursor(0, { lnum + 1, 0 })
  return M.update_block(bufnr, block)
end

--- Insert (or update) a column view block at the cursor
--- (org-columns-insert-dblock). Prompts for the scope: local, global or the
--- ID of an entry.
function M.insert_columnview()
  local bufnr = vim.api.nvim_get_current_buf()
  local existing = M.at_cursor()
  if existing and existing.name:lower() == "columnview" then
    return M.update_block(bufnr, existing)
  end
  local candidates = { "global", "local" }
  for _, hl in ipairs(require("org.files").get_buffer(bufnr).headlines) do
    local id = hl.properties.ID
    if id and id ~= "" and not vim.tbl_contains(candidates, id) then
      candidates[#candidates + 1] = id
    end
  end
  local id = utils.input_complete("Capture columns (local, global, entry with :ID: property) [local]: ", candidates)
  if id == nil then
    return nil
  end
  id = vim.trim(id)
  if id == "" then
    id = "local"
  end
  return insert_block(bufnr, "columnview :hlines 1 :id " .. id)
end

--- Prompt for a registered dynamic block type and insert it at the cursor
--- (org-dynamic-block-insert-dblock).
function M.insert_dblock()
  local names = vim.tbl_keys(M.writers)
  table.sort(names)
  local name = utils.input_complete("Dynamic block: ", names)
  if name == nil then
    return nil
  end
  name = vim.trim(name):lower()
  if name == "" then
    return nil
  end
  if not M.writers[name] then
    utils.warn("No writer for dynamic block: " .. name)
    return nil
  end
  if name == "clocktable" then
    return M.insert_clocktable()
  elseif name == "columnview" then
    return M.insert_columnview()
  end
  return insert_block(vim.api.nvim_get_current_buf(), name)
end

---------------------------------------------------------------------------
-- Built-in writers
---------------------------------------------------------------------------

M.register("clocktable", function(params, ctx)
  return require("org.clock").clocktable(params, ctx.bufnr, ctx.start_line, ctx.content)
end)

M.register("columnview", function(params, ctx)
  return require("org.columns").dblock(params, ctx)
end)

return M
