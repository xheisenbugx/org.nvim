--- blink.cmp source for org buffers.
---
--- LazyVim / blink.cmp:
---   sources = {
---     per_filetype = { org = { inherit_defaults = true, "org" } },
---     providers = { org = { name = "Org", module = "org.completion.blink" } },
---   }
local completion = require("org.completion")

local Source = {}
Source.__index = Source

function Source.new()
  return setmetatable({}, Source)
end

function Source:enabled()
  return vim.bo.filetype == "org"
end

function Source:get_trigger_characters()
  return { "#", "+", ":", "[", "*", "_" }
end

local kinds = {
  todo = "Keyword",
  keyword = "Keyword",
  tag = "Constant",
  language = "Module",
  property = "Property",
  startup = "EnumMember",
  option = "EnumMember",
  link = "Reference",
  heading = "Reference",
  custom_id = "Reference",
}

function Source:get_completions(ctx, callback)
  local ok_types, types = pcall(require, "blink.cmp.types")
  local Kind = ok_types and types.CompletionItemKind or {}
  local line = ctx.line
  local col = ctx.cursor[2]
  local result = completion.get(line, col, ctx.bufnr)
  if not result then
    callback({ items = {}, is_incomplete_forward = false, is_incomplete_backward = false })
    return
  end
  local row = ctx.cursor[1] - 1
  local items = {}
  for _, it in ipairs(result.items) do
    items[#items + 1] = {
      label = it.word,
      kind = Kind[kinds[it.kind] or "Text"],
      labelDetails = { description = "org " .. it.kind },
      textEdit = {
        newText = it.word,
        range = {
          start = { line = row, character = result.start },
          ["end"] = { line = row, character = col },
        },
      },
    }
  end
  callback({ items = items, is_incomplete_forward = false, is_incomplete_backward = false })
end

return Source
