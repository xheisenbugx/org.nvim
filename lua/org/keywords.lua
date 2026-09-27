---@mod org.keywords File keywords and local SETUPFILE dependencies

local utils = require("org.utils")

local M = {}

local LITERAL_BLOCKS = { SRC = true, EXAMPLE = true, EXPORT = true, COMMENT = true, VERSE = true }
local MAX_SETUP_DEPTH, MAX_SETUP_IMPORTS = 64, 256

local function setup_path(path, dir)
  -- Never use fn.expand here: setup directives are document text, and Vim
  -- expansion evaluates backticks/expressions and interprets % and #. Like
  -- Emacs (expand-file-name), only `~` is expanded, not $VARIABLES.
  path = vim.fs.normalize(path, { expand_env = false })
  if not path:match("^/") and not path:match("^%a:[/\\]") then
    path = dir .. "/" .. path
  end
  return vim.fs.normalize(path, { expand_env = false })
end

local function literal_block_end(lines, start)
  local kind = lines[start]:upper():match("^%s*#%+BEGIN_(%S+)")
  if not LITERAL_BLOCKS[kind] then
    return nil
  end
  for i = start + 1, #lines do
    -- An unescaped headline terminates the section: an unmatched BEGIN
    -- is ordinary text, so subsequent keywords still take effect.
    if lines[i]:match("^%*+ ") then
      return nil
    end
    if lines[i]:upper():match("^%s*#%+END_" .. kind .. "%s*$") then
      return i
    end
  end
end

-- bufnr -> { name, normalized, realpath }: a dependency check runs on every
-- cached parse, so don't resolve every loaded buffer's name each time.
local buf_names = {}

--- utils.find_buffer, with buffer paths resolved once per buffer name.
local function loaded_buffer(path)
  path = vim.fs.normalize(path)
  local real = vim.uv.fs_realpath(path)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(b)
    if name ~= "" and vim.api.nvim_buf_is_loaded(b) then
      local cached = buf_names[b]
      if not cached or cached[1] ~= name then
        cached = { name, vim.fs.normalize(name), vim.uv.fs_realpath(name) or false }
        buf_names[b] = cached
      end
      if cached[2] == path or (real and cached[3] == real) then
        return b
      end
    end
  end
end

--- A dependency includes unloaded/missing files and unsaved visiting buffers.
--- Keep nanoseconds separate: epoch nanoseconds exceed Lua's exact integers.
local function source_state(path)
  local buf = loaded_buffer(path)
  if buf then
    return "buffer:" .. buf .. ":" .. vim.api.nvim_buf_get_changedtick(buf), buf
  end
  local st = vim.uv.fs_stat(path)
  if not st then
    return "missing"
  end
  return table.concat({ st.type, st.mtime.sec, st.mtime.nsec, st.ctime.sec, st.ctime.nsec, st.size, st.ino }, ":")
end

function M.dependencies_valid(dependencies)
  for path, state in pairs(dependencies or {}) do
    if source_state(path) ~= state then
      return false
    end
  end
  return true
end

local function identity(path)
  return vim.uv.fs_realpath(path) or vim.fs.normalize(path)
end

--- Collect keyword elements in appearance order, recursively inserting local
--- setup file keywords at each SETUPFILE. Repeated imports are allowed; only
--- cycles on the current recursion path are skipped, like org-collect-keywords.
---@param lines string[]
---@param filename? string
---@return table[] keywords { key, value, line, filename, source_line }
---@return table<string,string> dependencies
function M.collect(lines, filename)
  local keywords, dependencies, active = {}, {}, {}
  local imports = 0
  if filename then
    active[identity(filename)] = true
  end
  local function scan(content, dir, source, source_line, depth)
    local skip_to = 0
    for i, line in ipairs(content) do
      local b = line:byte(1)
      if i > skip_to and (b == 35 or ((b == 32 or b == 9) and line:find("^%s+#%+"))) then
        skip_to = literal_block_end(content, i) or skip_to
        local key, value = line:match("^%s*#%+([%w_%-]+):%s*(.-)%s*$")
        if key then
          key = key:upper()
          local root_line = source_line or i
          keywords[#keywords + 1] = { key = key, value = value, line = i, filename = source, source_line = root_line }
          if key == "SETUPFILE" and value ~= "" then
            local path = value:match('^"(.*)"$') or value
            -- Loading a document never fetches a URL or invokes a remote
            -- file handler. Missing/local unreadable files are left to lint.
            -- Like org-url-p (ffap-url-regexp): `a:b.setup` is a local file.
            local remote = path:match("^%a[%w+%.%-]*://") or path:match("^mailto:") or path:match("^news:")
            if path ~= "" and not remote and depth < MAX_SETUP_DEPTH and imports < MAX_SETUP_IMPORTS then
              path = setup_path(path, dir)
              local id = identity(path)
              local state, buf = source_state(path)
              -- Keep even a cyclic edge: a symlink can later point at a
              -- different file, making that formerly skipped import useful.
              dependencies[path] = state
              if not active[id] then
                imports = imports + 1
                local setup
                if buf then
                  setup = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
                elseif state:match("^file:") then
                  local ok, result = pcall(utils.readfile, path)
                  setup = ok and result or nil
                end
                if setup then
                  active[id] = true
                  scan(setup, vim.fn.fnamemodify(path, ":h"), path, root_line, depth + 1)
                  active[id] = nil
                end
              end
            end
          end
        end
      end
    end
  end
  scan(lines, filename and vim.fn.fnamemodify(filename, ":p:h") or vim.fn.getcwd(), filename, nil, 0)
  return keywords, dependencies
end

return M
