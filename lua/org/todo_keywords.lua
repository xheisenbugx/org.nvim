---@mod org.todo_keywords TODO keyword sequences
---
--- Parses Emacs-style keyword sequences:
---   "TODO(t) NEXT(n!) | DONE(d@/!) CANCELLED(c@)"
--- Flags inside parens: key char, `!` = log time, `@` = log note;
--- `/x` after the enter flag is the flag used when *leaving* the state.

local M = {}

---@class org.TodoKeyword
---@field name string
---@field key string|nil
---@field done boolean
---@field seq integer sequence index
---@field index integer position in the flat keyword list
---@field log_enter "time"|"note"|nil
---@field log_leave "time"|"note"|nil

---@class org.TodoConfig
local TodoConfig = {}
TodoConfig.__index = TodoConfig

local function flag(c)
  if c == "!" then
    return "time"
  elseif c == "@" then
    return "note"
  end
end

local function parse_token(token)
  local name, inner = token:match("^([^%(]+)%((.*)%)$")
  if not name then
    return { name = token }
  end
  local kw = { name = name }
  local key = inner:match("^([^!@/])")
  if key then
    kw.key = key
    inner = inner:sub(2)
  end
  local enter, leave = inner:match("^([!@]?)/?([!@]?)$")
  kw.log_enter = flag(enter)
  kw.log_leave = flag(leave)
  return kw
end

--- Normalize user config into a list of sequence strings.
---@param spec string[]|string
---@return string[]
function M.normalize(spec)
  if type(spec) == "string" then
    return { spec }
  end
  spec = spec or {}
  local flat = false
  for _, v in ipairs(spec) do
    if v == "|" then
      flat = true
    end
  end
  if flat then
    return { table.concat(spec, " ") }
  end
  -- a list of single-word keywords without "|" is also a single sequence
  local single_words = #spec > 0
  for _, v in ipairs(spec) do
    if v:find("%s") then
      single_words = false
    end
  end
  if single_words then
    return { table.concat(spec, " ") }
  end
  return spec
end

---@param sequences string[]|string
---@return org.TodoConfig
function M.new(sequences)
  local self = setmetatable({
    keywords = {},
    by_name = {},
    sequences = {},
    has_fast_keys = false,
  }, TodoConfig)
  for si, seq in ipairs(M.normalize(sequences)) do
    local tokens = vim.split(vim.trim(seq), "%s+")
    local has_bar = vim.tbl_contains(tokens, "|")
    local list = {}
    local done = false
    for ti, tok in ipairs(tokens) do
      if tok == "|" then
        done = true
      elseif tok ~= "" then
        local kw = parse_token(tok)
        -- without "|", the last keyword is the DONE state
        kw.done = done or (not has_bar and ti == #tokens and #tokens > 1)
        kw.seq = si
        if not self.by_name[kw.name] then
          kw.index = #self.keywords + 1
          self.keywords[#self.keywords + 1] = kw
          self.by_name[kw.name] = kw
          list[#list + 1] = kw
          if kw.key then
            self.has_fast_keys = true
          end
        end
      end
    end
    if #list > 0 then
      self.sequences[#self.sequences + 1] = list
    end
  end
  return self
end

function TodoConfig:get(name)
  return name and self.by_name[name] or nil
end

function TodoConfig:is_keyword(name)
  return name ~= nil and self.by_name[name] ~= nil
end

function TodoConfig:is_done(name)
  local kw = self:get(name)
  return kw ~= nil and kw.done
end

function TodoConfig:is_todo(name)
  local kw = self:get(name)
  return kw ~= nil and not kw.done
end

---@return string[]
function TodoConfig:names()
  return vim.tbl_map(function(k)
    return k.name
  end, self.keywords)
end

function TodoConfig:todo_names()
  local out = {}
  for _, k in ipairs(self.keywords) do
    if not k.done then
      out[#out + 1] = k.name
    end
  end
  return out
end

function TodoConfig:done_names()
  local out = {}
  for _, k in ipairs(self.keywords) do
    if k.done then
      out[#out + 1] = k.name
    end
  end
  return out
end

--- First not-done keyword (of the given sequence, or the first sequence).
function TodoConfig:first_todo(seq)
  local list = self.sequences[seq or 1] or {}
  for _, k in ipairs(list) do
    if not k.done then
      return k.name
    end
  end
  return list[1] and list[1].name
end

--- First done keyword in the sequence of `name` (or first sequence).
function TodoConfig:first_done(name)
  local kw = self:get(name)
  local list = self.sequences[kw and kw.seq or 1] or {}
  for _, k in ipairs(list) do
    if k.done then
      return k.name
    end
  end
  return self:done_names()[1]
end

--- Cycle within the keyword's sequence. `dir` = 1 or -1.
--- nil -> first (or last) keyword of the first sequence; past the end -> nil.
---@return string|nil
function TodoConfig:cycle(current, dir)
  dir = dir or 1
  local kw = self:get(current)
  if not kw then
    local list = self.sequences[1] or {}
    if dir > 0 then
      return list[1] and list[1].name
    end
    return list[#list] and list[#list].name
  end
  local list = self.sequences[kw.seq]
  local pos
  for i, k in ipairs(list) do
    if k.name == kw.name then
      pos = i
    end
  end
  local nxt = list[pos + dir]
  return nxt and nxt.name or nil
end

--- Switch to the first keyword of the next/previous sequence.
function TodoConfig:next_sequence(current, dir)
  local kw = self:get(current)
  local n = #self.sequences
  if n == 0 then
    return nil
  end
  local seq = kw and kw.seq or 0
  seq = ((seq - 1 + (dir or 1)) % n) + 1
  return self.sequences[seq][1].name
end

--- Vim regex alternation of all keywords (escaped).
function TodoConfig:vim_alternation(filter)
  local out = {}
  for _, k in ipairs(self.keywords) do
    if filter == nil or (filter == "done") == k.done then
      out[#out + 1] = vim.fn.escape(k.name, [[\/.*$^~[]])
    end
  end
  return table.concat(out, [[\|]])
end

M.TodoConfig = TodoConfig

--- The config-level TodoConfig (cached per todo_keywords value).
local cache = { spec = nil, cfg = nil }
function M.global()
  local spec = require("org.config").opts.todo_keywords
  if cache.spec ~= spec or not cache.cfg then
    cache.spec = spec
    cache.cfg = M.new(spec)
  end
  return cache.cfg
end

return M
