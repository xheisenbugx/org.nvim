---@mod org.lineedit Headline-aware line motions and kill
---
--- org-beginning-of-line (C-a), org-end-of-line (C-e) and org-kill-line
--- (C-k), with `special_ctrl_a_e` (org-special-ctrl-a/e), `special_ctrl_k`
--- (org-special-ctrl-k) and `ctrl_k_protect_subtree`
--- (org-ctrl-k-protect-subtree). They have no default keys: map the
--- `beginning_of_line`, `end_of_line` and `kill_line` actions, e.g. to
--- <C-a> / <C-e> / <C-k> in Insert mode.
---
--- Emacs point sits between characters; in Normal mode the cursor is on a
--- character, so "end of line" is the last character and a cursor on a
--- character counts as the point after it when moving to the end.

local config = require("org.config")
local parser = require("org.parser")
local utils = require("org.utils")

local M = {}

local function insert_mode()
  return vim.fn.mode():match("^[iR]") ~= nil
end

--- The C-a / C-e part of `special_ctrl_a_e`.
local function special(which)
  local v = config.opts.special_ctrl_a_e
  if type(v) == "table" then
    return v[which]
  end
  return v
end

--- Last command, to detect a directly repeated key (last-command).
local last = {}

local function repeated(name, row, col)
  local tick = vim.api.nvim_buf_get_changedtick(0)
  local r = last.name == name
    and last.buf == vim.api.nvim_get_current_buf()
    and last.row == row
    and last.col == col
    and last.tick == tick
  return r
end

local function remember(name)
  local pos = vim.api.nvim_win_get_cursor(0)
  last = {
    name = name,
    buf = vim.api.nvim_get_current_buf(),
    row = pos[1],
    col = pos[2],
    tick = vim.api.nvim_buf_get_changedtick(0),
  }
end

local function set_col(row, col, line)
  if not insert_mode() and #line > 0 then
    col = math.min(col, #line - 1)
  end
  vim.api.nvim_win_set_cursor(0, { row, math.max(0, col) })
end

--- Byte offset where the title of headline `line` starts, after the stars,
--- TODO keyword and priority (the special C-a position).
local function title_start(line, todo_cfg)
  local stars = line:match("^%*+")
  local pos = #stars
  local rest = line:sub(pos + 1)
  local sp, word = rest:match("^( +)(%S+)")
  local after_word = word and rest:sub(#sp + #word + 1, #sp + #word + 1)
  if word and todo_cfg:is_keyword(word) and (after_word == " " or after_word == "") then
    pos = pos + #sp + #word
    rest = line:sub(pos + 1)
  end
  local sp2, prio = rest:match("^( +)(%[#%w%])")
  if prio and (rest:sub(#sp2 + 5, #sp2 + 5) == " " or #sp2 + 4 == #rest) then
    pos = pos + #sp2 + 4
  end
  return math.min(pos + 1, #line)
end

--- Where the tags of headline `line` start, minus the whitespace before
--- them, or nil without tags.
local function tags_start(line)
  local s = line:find("[ \t]+:[%w_@#%%:]+:[ \t]*$")
  return s and s - 1
end

--- org-beginning-of-line: to the start of the line; with
--- `special_ctrl_a_e`, on a headline first to the start of its title and on
--- an item after its bullet and checkbox.
function M.beginning_of_line()
  local pos = vim.api.nvim_win_get_cursor(0)
  local row, origin = pos[1], pos[2]
  local line = vim.api.nvim_get_current_line()
  local sp = special("a")
  local target = 0
  local todo_cfg = require("org.files").get_buffer(0).settings.todo
  local ref
  if sp and parser.headline_level(line) then
    ref = title_start(line, todo_cfg)
  elseif sp then
    local it = require("org.lists").parse_item_line(line)
    if it and require("org.lists").item_at(0, row) then
      local head = line:match("^%s*%S+[ \t]*")
      local after = #head
      local counter = line:sub(after + 1):match("^%[@[%w:]+%][ \t]*")
      if counter then
        after = after + #counter
      end
      local box = line:sub(after + 1):match("^%[[ xX%-]%]")
      if box then
        after = after + 3
        if line:sub(after + 1, after + 1) == " " then
          after = after + 1
        end
      end
      ref = after
    end
  end
  if ref then
    if sp == "reversed" then
      if origin == 0 and repeated("beginning_of_line", row, origin) then
        target = ref
      end
    elseif origin > ref or origin <= 0 then
      target = ref
    end
  end
  set_col(row, target, line)
  remember("beginning_of_line")
  return true
end

--- org-end-of-line: to the end of the line; with `special_ctrl_a_e`, on a
--- headline with tags first to the end of the title.
function M.end_of_line()
  local pos = vim.api.nvim_win_get_cursor(0)
  local row = pos[1]
  local line = vim.api.nvim_get_current_line()
  -- the Normal mode cursor stands for the point after its character
  local origin = pos[2] + ((insert_mode() or #line == 0) and 0 or 1)
  local sp = special("e")
  local eol = #line
  local target = eol
  local tags = sp and parser.headline_level(line) and tags_start(line)
  if tags then
    if sp == "reversed" then
      if origin == eol and repeated("end_of_line", row, pos[2]) then
        target = tags
      end
    elseif origin < tags or origin >= eol then
      target = tags
    end
  end
  if not insert_mode() and target > 0 then
    target = target - 1
  end
  set_col(row, target, line)
  remember("end_of_line")
  return true
end

--- Put killed text into the unnamed register (the kill ring).
local function kill(text, regtype)
  vim.fn.setreg('"', text, regtype)
  pcall(vim.fn.setreg, "-", text, regtype)
end

--- org-kill-line: kill to the end of the line (through the newline at its
--- end). On a folded headline that is the whole hidden subtree:
--- `ctrl_k_protect_subtree` asks first (`true`) or refuses (`"error"`).
--- With `special_ctrl_k`, in a headline's title kill up to the tags, and
--- on the tags kill them.
function M.kill_line()
  local bufnr = vim.api.nvim_get_current_buf()
  local pos = vim.api.nvim_win_get_cursor(0)
  local row, col = pos[1], pos[2]
  local line = vim.api.nvim_get_current_line()
  local heading = parser.headline_level(line) ~= nil
  if not config.opts.special_ctrl_k or col == 0 or not heading then
    local fold_end = vim.fn.foldclosedend(row)
    local hidden = fold_end ~= -1 and fold_end > row
    local protect = config.opts.ctrl_k_protect_subtree
    if hidden and protect then
      if protect == "error" or not utils.confirm("Kill hidden subtree along with headline? ") then
        utils.error("kill_line aborted as it would kill a hidden subtree")
        return
      end
    end
    if hidden then
      -- kill-line goes to the end of the visible line: past the fold
      local lines = vim.api.nvim_buf_get_lines(bufnr, row - 1, fold_end, false)
      local text = { lines[1]:sub(col + 1) }
      vim.list_extend(text, vim.list_slice(lines, 2))
      kill(text, "c")
      local last_line = lines[#lines]
      vim.api.nvim_buf_set_text(bufnr, row - 1, col, fold_end - 1, #last_line, { "" })
    elseif col >= #line or line:sub(col + 1):match("^%s*$") then
      -- at the end of the line (or only blanks after): kill through the newline
      if row >= vim.api.nvim_buf_line_count(bufnr) then
        if col >= #line then
          utils.error("End of buffer")
          return
        end
        kill(line:sub(col + 1), "c")
        vim.api.nvim_buf_set_text(bufnr, row - 1, col, row - 1, #line, { "" })
      else
        kill({ line:sub(col + 1), "" }, "c")
        vim.api.nvim_buf_set_text(bufnr, row - 1, col, row, 0, { "" })
      end
    else
      kill(line:sub(col + 1), "c")
      vim.api.nvim_buf_set_text(bufnr, row - 1, col, row - 1, #line, { "" })
    end
  else
    local tags = tags_start(line)
    if tags and col < tags then
      kill(line:sub(col + 1, tags), "c")
      local new = line:sub(1, col) .. line:sub(tags + 1)
      local todo_cfg = require("org.files").get_buffer(bufnr).settings.todo
      new = require("org.edit").align_tags_line(new, todo_cfg)
      vim.api.nvim_buf_set_lines(bufnr, row - 1, row, false, { new })
    else
      kill(line:sub(col + 1), "c")
      vim.api.nvim_buf_set_text(bufnr, row - 1, col, row - 1, #line, { "" })
    end
  end
  local l = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
  set_col(row, col, l)
  return true
end

return M
