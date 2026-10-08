---@mod org.capture.templates Capture templates and the selection menu
---
--- Part of org.capture, which loads it: the templates available in a
--- context, the selection menu and the entry points that start a
--- capture from a key (prompt, capture_string, command).

local config = require("org.config")
local ui = require("org.ui")
local utils = require("org.utils")
local shared = require("org.capture.shared")

local M = require("org.capture")

---------------------------------------------------------------------------
-- Templates
---------------------------------------------------------------------------

--- Used when no template is configured (or none is available in the
--- current context), like the fallback of org-capture-select-template.
M.DEFAULT_TEMPLATES = {
  t = { description = "Task", type = "entry", target = "", headline = "Tasks", template = "* TODO %?\n  %u\n  %a" },
}

--- Templates used when the template text is empty (org-capture-set-plist).
local EMPTY_TEMPLATES = {
  entry = "* %?\n  %a",
  item = "- %?",
  checkitem = "- [ ] %?",
  ["table-line"] = "| %? |",
}

local function is_template(v)
  return type(v) == "table"
    and (
      v.template ~= nil
      or v.type ~= nil
      or v.target ~= nil
      or v.file ~= nil
      or v.headline ~= nil
      or v.olp ~= nil
      or v.id ~= nil
      or v.datetree ~= nil
      or v.location ~= nil
    )
end

local function rx_match(str, re)
  return str ~= nil and str ~= "" and vim.fn.match(str, re) >= 0
end

--- The context used by `capture.templates_contexts`: the current buffer.
local function context_env()
  local bufnr = vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(bufnr)
  return {
    file = (name ~= "" and vim.bo[bufnr].buftype == "") and name or nil,
    mode = vim.bo[bufnr].filetype,
    buffer = name ~= "" and vim.fn.fnamemodify(name, ":t") or "",
  }
end

--- Does one context rule hold (org-contextualize-validate-key)?
local function rule_ok(rule, env)
  if type(rule) == "function" then
    return rule() and true or false
  end
  if type(rule) ~= "table" then
    return false
  end
  return (rule.in_file and env.file and rx_match(env.file, rule.in_file))
    or (rule.in_mode and rx_match(env.mode, rule.in_mode))
    or (rule.in_buffer and rx_match(env.buffer, rule.in_buffer))
    or (rule.not_in_file and env.file and not rx_match(env.file, rule.not_in_file))
    or (rule.not_in_mode and not rx_match(env.mode, rule.not_in_mode))
    or (rule.not_in_buffer and not rx_match(env.buffer, rule.not_in_buffer))
    or false
end

--- Normalize a `templates_contexts` entry to { key, replacement, rules }.
local function normalize_context(c)
  local key, repl, rules = c[1], c[2], c[3]
  if type(repl) ~= "string" or repl == "" then
    rules, repl = c[2], key
  end
  if type(rules) == "function" or (type(rules) == "table" and not vim.islist(rules)) then
    rules = { rules }
  end
  return { key = key, repl = repl, rules = rules or {} }
end

--- The templates available in the current context: `capture.templates`
--- filtered and remapped by `capture.templates_contexts`
--- (org-contextualize-keys), or the default template when none is left.
---@return table<string, table|string>
function M.templates(env)
  local templates = config.opts.capture.templates or {}
  local contexts = vim.tbl_map(normalize_context, config.opts.capture.templates_contexts or {})
  local out, hidden = {}, {}
  if #contexts == 0 then
    out = templates
  else
    env = env or context_env()
    for key, t in pairs(templates) do
      local mine = vim.tbl_filter(function(c)
        return c.key == key
      end, contexts)
      if #mine == 0 then
        out[key] = t
      else
        local valid, repl = false, nil
        for _, c in ipairs(mine) do
          for _, r in ipairs(c.rules) do
            if rule_ok(r, env) then
              valid = true
              if c.repl ~= c.key then
                repl = c.repl
              end
            end
          end
        end
        if valid and not repl then
          out[key] = t
        elseif valid then
          if templates[repl] == nil then
            error(string.format("Undefined key `%s' as contextual replacement for `%s'", repl, key), 0)
          end
          out[key] = templates[repl]
          hidden[repl] = true
        end
      end
    end
    for k in pairs(hidden) do
      out[k] = nil
    end
  end
  if vim.tbl_isempty(out) then
    return M.DEFAULT_TEMPLATES
  end
  return out
end

--- Template for `key` (a copy with `key` set), or nil.
function M.get_template(key, env)
  local t = M.templates(env)[key]
  if not is_template(t) then
    return nil
  end
  local copy = vim.tbl_extend("force", {}, t)
  copy.key = key
  return copy
end

--- Menu items for the selection dispatcher.
function M.menu_items(env)
  local entries = {}
  for key, t in pairs(M.templates(env)) do
    if is_template(t) then
      entries[#entries + 1] = { key = key, label = t.description or key, value = key }
    else
      local label = type(t) == "string" and t or (type(t) == "table" and t.description) or key
      entries[#entries + 1] = { key = key, label = label }
    end
  end
  return ui.tree_from_keys(entries)
end

local function visual_selection()
  local mode = vim.fn.mode()
  if mode ~= "v" and mode ~= "V" and mode ~= "\22" then
    return nil
  end
  local srow, scol, erow, ecol = utils.visual_range()
  utils.exit_visual()
  local lines = vim.api.nvim_buf_get_lines(0, srow - 1, erow, false)
  if mode == "v" and #lines > 0 then
    lines[#lines] = lines[#lines]:sub(1, utils.char_end(lines[#lines], ecol))
    lines[1] = lines[1]:sub(scol)
  end
  return table.concat(lines, "\n")
end

--- Template selection menu, then capture with the chosen template. In
--- visual mode the selection becomes `opts.initial` (`%i`). A count works
--- like Emacs's prefix argument: 4 (C-u) goes to a template's target, 16
--- (C-u C-u) to the last stored entry, 1 (C-1) asks for the date tree
--- date. Must run inside a coroutine; `require("org").capture()` handles
--- that.
---@param opts? table `{ initial?: string, date?: table, here?: boolean }`, as for `capture()`
---@return integer|nil capture buffer (nil when cancelled)
function M.prompt(opts)
  opts = opts or {}
  local count = opts.count or vim.v.count
  if count == 4 then
    return M.goto_target()
  elseif count == 16 then
    return M.goto_last_stored()
  elseif count == 1 then
    opts.date_prompt = true
  end
  opts.initial = opts.initial or visual_selection()
  if opts.date == nil and config.opts.capture.use_agenda_date and vim.bo.filetype == "orgagenda" then
    -- org-capture-use-agenda-date: the date at point (C-1: with its time)
    opts.date = require("org.agenda.view").cursor_date(count == 1)
  end
  local env = context_env()
  local items = M.menu_items(env)
  local key = ui.menu({ title = "Capture", items = items })
  if type(key) ~= "string" then
    return
  end
  local tpl = M.get_template(key, env)
  if not tpl then
    utils.warn("No capture template for key: " .. key)
    return
  end
  return M.capture(tpl, opts)
end

--- Capture with a template inserted at the cursor (C-0 C-c c).
---@param opts? table as for `capture()`
function M.prompt_here(opts)
  return M.prompt(vim.tbl_extend("force", opts or {}, { here = true, count = 0 }))
end

--- Capture a string (org-capture-string): ask for the initial text (`%i`),
--- then capture with the template at `key`, or choose one from the menu.
---@param text? string initial text (asked when nil)
---@param key? string template key
---@return integer|nil capture buffer (nil when cancelled)
function M.capture_string(text, key)
  text = text or utils.input({ prompt = "Initial text: " })
  if text == nil then
    return
  end
  if key and key ~= "" then
    return M.capture(key, { initial = text })
  end
  return M.prompt({ initial = text, count = 0 })
end

--- `:Org capture [key]`: capture with the template at `key` of
--- `capture.templates`, or open the template menu when empty. Must run
--- inside a coroutine; `require("org").capture(key)` handles that.
---@param args? string template key
---@return integer|nil capture buffer (nil when cancelled / unknown key)
function M.command(args)
  local key = vim.trim(args or "")
  if key == "" then
    return M.prompt()
  end
  return M.capture(key)
end

-- Shared with the parts loaded after this one
shared.EMPTY_TEMPLATES = EMPTY_TEMPLATES
