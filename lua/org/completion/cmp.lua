--- nvim-cmp source. Register with:
---   require("cmp").register_source("org", require("org.completion.cmp").new())
--- and add { name = "org" } to your sources for filetype org.
local completion = require("org.completion")

local Source = {}
Source.__index = Source

function Source.new()
  return setmetatable({}, Source)
end

function Source:is_available()
  return vim.bo.filetype == "org"
end

function Source:get_trigger_characters()
  return { "#", "+", ":", "[", "*" }
end

function Source:get_keyword_pattern()
  return [[\%([#*:]\|\k\|[-_+]\)*]]
end

function Source:complete(params, callback)
  local line = params.context.cursor_before_line
  local col = #line
  local result = completion.get(params.context.cursor_line, col, params.context.bufnr)
  if not result then
    return callback({ items = {}, isIncomplete = false })
  end
  local row = params.context.cursor.row - 1
  local items = {}
  for _, it in ipairs(result.items) do
    items[#items + 1] = {
      label = it.word,
      detail = "org " .. it.kind,
      textEdit = {
        newText = it.word,
        range = { start = { line = row, character = result.start }, ["end"] = { line = row, character = col } },
      },
    }
  end
  callback({ items = items, isIncomplete = false })
end

return Source
