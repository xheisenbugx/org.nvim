--- telescope.nvim backend (pickers.new with a table finder, the generic
--- sorter and a buffer previewer showing the item's file, or its buffer,
--- at `lnum`).
local pickers = require("org.pickers")

local M = {}

local ns = vim.api.nvim_create_namespace("org.pickers.telescope")

function M.available()
  local ok = pcall(require, "telescope.pickers")
  return ok
end

--- Highlight the line of the entry previewed last in the preview buffer,
--- and center it. A file read for an earlier entry can finish after the
--- preview has moved on to another entry of the same file.
local function show_line(self, bufnr)
  local lnum = self.state and self.state.org_lnum or 1
  if not vim.api.nvim_buf_is_valid(bufnr) or lnum > vim.api.nvim_buf_line_count(bufnr) then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  vim.api.nvim_buf_set_extmark(bufnr, ns, lnum - 1, 0, {
    end_row = lnum,
    hl_group = "TelescopePreviewLine",
    hl_eol = true,
  })
  local win = self.state and self.state.winid
  if win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == bufnr then
    vim.api.nvim_win_set_cursor(win, { lnum, 0 })
    vim.api.nvim_win_call(win, function()
      vim.cmd("normal! zz")
    end)
  end
end

--- The previewer: the item's file at its line, or the lines of its buffer
--- when the file is loaded or there is none (the grep previewer reads the
--- file, and takes the item table for a path when there is none).
---@param topts table
function M.previewer(topts)
  local conf = require("telescope.config").values
  local ok_u, putils = pcall(require, "telescope.previewers.utils")
  return require("telescope.previewers").new_buffer_previewer({
    title = "Preview",
    dyn_title = function(_, entry)
      local item = entry.value
      return item.filename and vim.fn.fnamemodify(item.filename, ":~:.") or ("[buffer " .. tostring(item.bufnr) .. "]")
    end,
    -- reuse the preview of a file
    get_buffer_by_name = function(_, entry)
      return entry.value.filename
    end,
    define_preview = function(self, entry)
      local item = entry.value
      self.state.org_lnum = item.lnum or 1
      local b = pickers.buffer(item)
      if b then
        vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, vim.api.nvim_buf_get_lines(b, 0, -1, false))
        if ok_u then
          putils.highlighter(self.state.bufnr, vim.bo[b].filetype, {})
        end
        -- telescope puts a new preview buffer in the window when scheduled
        local pbuf = self.state.bufnr
        vim.schedule(function()
          show_line(self, pbuf)
        end)
      elseif item.filename then
        conf.buffer_previewer_maker(item.filename, self.state.bufnr, {
          bufname = self.state.bufname,
          winid = self.state.winid,
          preview = topts.preview,
          callback = function(bufnr)
            show_line(self, bufnr)
          end,
        })
      end
    end,
  })
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
      previewer = spec.preview and M.previewer(topts) or nil,
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
