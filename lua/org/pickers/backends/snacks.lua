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
---@param finish fun(items?: org.PickerItem[], query?: string)
function M.pick(spec, finish)
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
  M.api().pick({
    source = "org",
    title = spec.title,
    items = items,
    pattern = spec.query,
    format = function(item)
      local out = {}
      for i, c in ipairs(item.org_item.display or { { item.text } }) do
        out[i] = { c[1], c[2] }
      end
      return out
    end,
    preview = spec.preview and "file" or "none",
    layout = not spec.preview and { preset = "select" } or nil,
    actions = {
      confirm = function(picker, item)
        if answered[picker] then
          return
        end
        local chosen = {}
        local selected = spec.multi and picker.selected and picker:selected({ fallback = true }) or { item }
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
        finish(chosen, query)
        picker:close()
      end,
    },
    on_close = function(picker)
      if not answered[picker] then
        answered[picker] = true
        finish(nil)
      end
    end,
  })
end

return M
