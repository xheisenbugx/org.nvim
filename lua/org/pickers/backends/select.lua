--- vim.ui.select backend: one item at a time, no preview. With
--- `allow_query` a "+ New" entry first asks for the text.
local pickers = require("org.pickers")
local utils = require("org.utils")

local M = {}

function M.available()
  return true
end

local CREATE = {}

---@param spec org.PickerSpec
---@param finish fun(items?: org.PickerItem[], query?: string)
function M.pick(spec, finish)
  local list = {}
  if spec.allow_query then
    list[1] = CREATE
  end
  vim.list_extend(list, spec.items)
  vim.ui.select(list, {
    prompt = spec.title,
    kind = "org_picker",
    format_item = function(item)
      if item == CREATE then
        return spec.create_label or "+ New…"
      end
      return pickers.line(item)
    end,
  }, function(choice)
    if choice == CREATE then
      utils.run(function()
        local text = utils.input({ prompt = pickers.create_prompt(spec) })
        text = text and vim.trim(text) or ""
        finish(text ~= "" and {} or nil, text)
      end)
    elseif choice then
      finish({ choice })
    else
      finish(nil)
    end
  end)
end

return M
