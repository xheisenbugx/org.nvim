--- telescope.nvim backend (pickers.new with a table finder, the generic
--- sorter and the grep previewer, which shows `filename` at `lnum`).
local pickers = require("org.pickers")

local M = {}

function M.available()
  local ok = pcall(require, "telescope.pickers")
  return ok
end

--- Display text and highlights of an item, in telescope's form:
--- `{ { { start, finish }, group }, ... }` (byte offsets, 0-based start).
---@param item org.PickerItem
---@return string, table
function M.display(item)
  local parts, hls, col = {}, {}, 0
  for i, c in ipairs(item.display or { { pickers.line(item) } }) do
    local text = c[1]:gsub("\n", " ")
    parts[i] = text
    if c[2] and #text > 0 then
      hls[#hls + 1] = { { col, col + #text }, c[2] }
    end
    col = col + #text
  end
  return table.concat(parts), hls
end

---@param spec org.PickerSpec
---@param finish fun(items?: org.PickerItem[], query?: string)
---@param topts? table telescope picker options (theme, layout)
function M.pick(spec, finish, topts)
  topts = topts or {}
  local tpickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  tpickers
    .new(topts, {
      prompt_title = spec.title,
      default_text = spec.query,
      finder = finders.new_table({
        results = spec.items,
        entry_maker = function(item)
          return {
            value = item,
            ordinal = pickers.line(item),
            display = function(entry)
              return M.display(entry.value)
            end,
            filename = item.filename,
            bufnr = not item.filename and item.bufnr or nil,
            lnum = item.lnum,
            col = item.col,
          }
        end,
      }),
      sorter = conf.generic_sorter(topts),
      previewer = spec.preview and conf.grep_previewer(topts) or nil,
      -- runs for each prompt: builtin.resume() makes a new picker of this one
      attach_mappings = function(prompt_bufnr)
        local answered = false
        actions.select_default:replace(function()
          local picker = action_state.get_current_picker(prompt_bufnr)
          local chosen = {}
          if spec.multi and picker and picker.get_multi_selection then
            for _, e in ipairs(picker:get_multi_selection()) do
              chosen[#chosen + 1] = e.value
            end
          end
          if #chosen == 0 then
            local e = action_state.get_selected_entry()
            if e then
              chosen[1] = e.value
            end
          end
          local query = vim.trim(action_state.get_current_line() or "")
          if #chosen == 0 and not (spec.allow_query and query ~= "") then
            return
          end
          -- before closing: closing wipes the prompt
          answered = true
          actions.close(prompt_bufnr)
          finish(chosen, query)
        end)
        -- closed without a choice
        vim.api.nvim_create_autocmd("BufWipeout", {
          buffer = prompt_bufnr,
          once = true,
          callback = function()
            if not answered then
              answered = true
              finish(nil)
            end
          end,
        })
        return true
      end,
    })
    :find()
end

return M
