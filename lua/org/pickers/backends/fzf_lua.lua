--- fzf-lua backend (FzfLua.fzf_exec). Each entry is "<index>\t<text>",
--- with the index hidden (`--with-nth=2..`); the builtin previewer is
--- given the item's file and line through `parse_entry`.
local pickers = require("org.pickers")
local utils = require("org.utils")

local M = {}

local function api()
  local ok, fzf = pcall(require, "fzf-lua")
  if ok and type(fzf) == "table" and type(fzf.fzf_exec) == "function" then
    return fzf
  end
end

function M.available()
  return api() ~= nil
end

--- The item of an entry ("<index>\t...", maybe with ANSI codes).
local function item_of(items, entry)
  local idx = tonumber(tostring(entry or ""):match("^%s*(%d+)\t"))
  return idx and items[idx] or nil
end

--- The builtin previewer of files and buffers, at the entry's item.
local function previewer(items)
  local ok, builtin = pcall(require, "fzf-lua.previewer.builtin")
  if not ok or type(builtin) ~= "table" or not builtin.buffer_or_file then
    return nil
  end
  local P = builtin.buffer_or_file:extend()
  function P:new(o, opts, fzf_win)
    P.super.new(self, o, opts, fzf_win)
    setmetatable(self, P)
    return self
  end
  function P:parse_entry(entry)
    local it = item_of(items, entry)
    if not it then
      return {}
    end
    local bufnr = it.bufnr
    if it.filename then
      -- the buffer of this very file: bufnr() takes a file pattern, which
      -- finds work.org_archive's buffer for work.org
      bufnr = utils.find_buffer(it.filename)
    end
    return {
      path = it.filename or (bufnr and vim.api.nvim_buf_get_name(bufnr)) or nil,
      bufnr = bufnr,
      line = it.lnum or 1,
      col = it.col or 1,
    }
  end
  return P
end

local function colored(item, ansi)
  local parts = {}
  for i, c in ipairs(item.display or { { pickers.line(item) } }) do
    local text = c[1]:gsub("[\t\n]", " ")
    parts[i] = ansi and c[2] and ansi(c[2], text) or text
  end
  return table.concat(parts)
end

---@param spec org.PickerSpec
---@param finish fun(items?: org.PickerItem[], query?: string)
function M.pick(spec, finish)
  local fzf = api()
  local ok_u, futils = pcall(require, "fzf-lua.utils")
  local ansi
  if ok_u and type(futils) == "table" and type(futils.ansi_from_hl) == "function" then
    ansi = function(hl, s)
      return (futils.ansi_from_hl(hl, s))
    end
  end
  local entries = {}
  for i, it in ipairs(spec.items) do
    entries[i] = i .. "\t" .. colored(it, ansi)
  end
  -- Every close answers once: enter with its choice, any other way (esc,
  -- ctrl-c, ctrl-q, ctrl-z, an abort bind, hide) with a cancel. Only enter
  -- runs an action of ours, so the cancel comes from the window closing.
  local answered = false
  local function accept(selected, o)
    answered = true
    local chosen = {}
    for _, e in ipairs(selected or {}) do
      local it = item_of(spec.items, e)
      if it then
        chosen[#chosen + 1] = it
      end
    end
    local query = o and o.last_query and vim.trim(o.last_query) or nil
    if #chosen == 0 and not (spec.allow_query and query and query ~= "") then
      finish(nil)
      return
    end
    finish(chosen, query)
  end
  fzf.fzf_exec(entries, {
    prompt = spec.title .. "> ",
    winopts = {
      title = " " .. spec.title .. " ",
      -- fzf-lua closes the window before it runs the action of the key
      on_close = function()
        vim.schedule(function()
          if not answered then
            finish(nil)
          end
          answered = false
        end)
      end,
    },
    query = spec.query,
    fzf_opts = {
      ["--ansi"] = true,
      ["--delimiter"] = "\t",
      ["--with-nth"] = "2..",
      ["--multi"] = spec.multi and true or false,
      ["--no-multi"] = not spec.multi and true or nil,
    },
    previewer = spec.preview and previewer(spec.items) or nil,
    actions = { ["enter"] = accept },
  })
end

M._item_of = item_of

return M
