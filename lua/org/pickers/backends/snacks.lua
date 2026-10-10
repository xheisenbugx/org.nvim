--- snacks.nvim backend (Snacks.picker.pick).
local pickers = require("org.pickers")

local M = {}

--- Snacks.picker, from the global or require("snacks").
function M.api()
  local S = rawget(_G, "Snacks")
  if type(S) ~= "table" then
    local ok, mod = pcall(require, "snacks")
    S = ok and type(mod) == "table" and mod or nil
  end
  if not S then
    return nil
  end
  local ok, picker = pcall(function()
    return S.picker
  end)
  if ok and type(picker) == "table" and type(picker.pick) == "function" then
    return picker
  end
end

function M.available()
  return M.api() ~= nil
end

---@param spec org.PickerSpec
---@param finish fun(items?: org.PickerItem[], query?: string, how?: org.PickerHow)
---@param user? table `picker_opts.snacks`, merged over these options
function M.pick(spec, finish, user)
  user = user or {}
  local items = {}
  for i, it in ipairs(spec.items) do
    items[i] = {
      idx = i,
      text = pickers.line(it),
      file = it.filename,
      buf = not it.filename and it.bufnr or nil,
      pos = it.lnum and { it.lnum, math.max((it.col or 1) - 1, 0) } or nil,
      org_item = it,
    }
  end
  -- each picker answers once; Snacks.picker.resume() opens a new one with
  -- these options
  local answered = setmetatable({}, { __mode = "k" })
  local api = M.api()
  -- snacks' file preview, of the buffer when the file is loaded
  local function preview(ctx)
    ctx.item.buf = pickers.buffer(ctx.item.org_item)
    return api.preview.file(ctx)
  end
  local function confirm(picker, item, how)
    if answered[picker] then
      return
    end
    local chosen = {}
    local selected
    if how == "qflist" then
      -- the selection, or every item matching the query (snacks' own qflist)
      selected = picker.selected and picker:selected() or {}
      if #selected == 0 then
        selected = picker.items and picker:items() or {}
      end
    else
      selected = spec.multi and picker.selected and picker:selected({ fallback = true }) or { item }
    end
    for _, s in ipairs(selected) do
      if s and s.org_item then
        chosen[#chosen + 1] = s.org_item
      end
    end
    local query = picker.input and picker.input.filter and picker.input.filter.pattern or nil
    query = query and vim.trim(query) or nil
    if #chosen == 0 and not (spec.allow_query and query and query ~= "") then
      return
    end
    answered[picker] = true
    -- answer before closing: closing runs on_close
    finish(chosen, query, how)
    picker:close()
  end
  -- snacks passes the action as the third argument: not a `how`
  local actions = {
    confirm = function(picker, item)
      confirm(picker, item)
    end,
  }
  local input_keys, list_keys = {}, {}
  for _, k in ipairs(pickers.split_keys(spec)) do
    local how, name = k[1], "org_" .. k[1]
    actions[name] = function(picker, item)
      confirm(picker, item, how)
    end
    input_keys[k[2]] = { name, mode = { "n", "i" } }
    list_keys[k[2]] = name
  end
  -- the typed text, whatever matches it
  local qkey = pickers.query_key(spec)
  if qkey then
    actions.org_query = function(picker)
      local query = vim.trim(picker.input and picker.input.filter and picker.input.filter.pattern or "")
      if query ~= "" and not answered[picker] then
        answered[picker] = true
        finish({}, query)
        picker:close()
      end
    end
    input_keys[qkey] = { "org_query", mode = { "n", "i" } }
    list_keys[qkey] = "org_query"
  end
  local user_close = user.on_close
  local opts = vim.tbl_deep_extend(
    "force",
    {
      title = spec.title,
      layout = not spec.preview and { preset = "select" } or nil,
    },
    user,
    {
      source = "org",
      items = items,
      pattern = spec.query,
      format = function(item)
        local out = {}
        for i, c in ipairs(item.org_item.display or { { item.text } }) do
          out[i] = { c[1], c[2] }
        end
        return out
      end,
      preview = spec.preview and preview or "none",
      actions = actions,
      win = { input = { keys = input_keys }, list = { keys = list_keys } },
      on_close = function(picker)
        if type(user_close) == "function" then
          user_close(picker)
        end
        if not answered[picker] then
          answered[picker] = true
          finish(nil)
        end
      end,
    }
  )
  api.pick(opts)
end

return M
