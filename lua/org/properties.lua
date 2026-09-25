---@mod org.properties Property drawers, effort estimates

local config = require("org.config")
local date = require("org.date")
local edit = require("org.edit")
local files = require("org.files")
local utils = require("org.utils")

local M = {}

M.DEFAULT_EFFORTS = { "0:05", "0:10", "0:15", "0:30", "0:45", "1:00", "1:30", "2:00", "3:00", "4:00", "6:00", "8:00" }

local SPECIAL = {
  ITEM = true,
  TODO = true,
  PRIORITY = true,
  TAGS = true,
  ALLTAGS = true,
  CATEGORY = true,
  LEVEL = true,
  FILE = true,
  SCHEDULED = true,
  DEADLINE = true,
  CLOSED = true,
  TIMESTAMP = true,
  TIMESTAMP_IA = true,
  CLOCKSUM = true,
  CLOCKSUM_T = true,
  BLOCKED = true,
}

local function collect_files(bufnr)
  local list = {}
  if vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].filetype == "org" then
    list[1] = files.get_buffer(bufnr)
  end
  for _, f in ipairs(files.agenda_files()) do
    list[#list + 1] = f
  end
  return list
end

--- Property names used across the buffer and agenda files.
function M.known_names(bufnr)
  local seen, out = {}, {}
  local function add(k)
    if k and not seen[k:upper()] and not k:match("_ALL$") then
      seen[k:upper()] = true
      out[#out + 1] = k
    end
  end
  add(config.opts.effort_property or "Effort")
  for _, name in ipairs({ "ID", "CUSTOM_ID", "CATEGORY", "ORDERED", "STYLE", "COLUMNS", "LOGGING", "NOBLOCKING" }) do
    add(name)
  end
  for _, f in ipairs(collect_files(bufnr or vim.api.nvim_get_current_buf())) do
    for _, hl in ipairs(f.headlines) do
      for k in pairs(hl.properties) do
        add(k)
      end
    end
    for k in pairs(f.settings.properties) do
      add(k)
    end
  end
  table.sort(out)
  return out
end

--- Values seen for property `name`.
function M.known_values(name, bufnr)
  local seen, out = {}, {}
  local key = name:upper()
  for _, f in ipairs(collect_files(bufnr or vim.api.nvim_get_current_buf())) do
    for _, hl in ipairs(f.headlines) do
      local v = hl.properties[key]
      if v and not seen[v] then
        seen[v] = true
        out[#out + 1] = v
      end
    end
  end
  table.sort(out)
  return out
end

--- Prompt for a value, offering allowed values when defined.
local function prompt_value(hl, name, bufnr)
  local allowed = hl:get_allowed_values(name)
  local current = hl.properties[name:upper()]
  if allowed and #allowed > 0 then
    return utils.select(allowed, { prompt = name .. " value" .. (current and (" (current: " .. current .. ")") or "") })
  end
  return utils.input_complete(name .. ": ", M.known_values(name, bufnr), current or "")
end

--- Set a property (org-set-property).
---@param target? org.Target
---@param name? string
---@param value? string
function M.set_property(target, name, value)
  local bufnr, _, hl = edit.resolve_headline(target)
  if not bufnr then
    return nil
  end
  if not name then
    name = utils.input_complete("Property: ", M.known_names(bufnr))
    if not name or vim.trim(name) == "" then
      return nil
    end
    name = vim.trim(name)
  end
  if SPECIAL[name:upper()] then
    utils.warn("Special property cannot be set in a drawer: " .. name)
    return nil
  end
  if value == nil then
    value = prompt_value(hl, name, bufnr)
    if value == nil then
      return nil
    end
  end
  edit.set_property(bufnr, hl.line, name, value)
  return value
end

--- Delete a property (org-delete-property).
function M.delete_property(target, name)
  local bufnr, _, hl = edit.resolve_headline(target)
  if not bufnr then
    return nil
  end
  if not name then
    local names = {}
    if hl.properties_range then
      local lines = vim.api.nvim_buf_get_lines(bufnr, hl.properties_range[1], hl.properties_range[2] - 1, false)
      for _, l in ipairs(lines) do
        local k = l:match("^%s*:([^%s:]+):")
        if k then
          names[#names + 1] = k
        end
      end
    end
    if #names == 0 then
      utils.notify("No properties in this entry")
      return nil
    end
    name = utils.select(names, { prompt = "Delete property" })
    if not name then
      return nil
    end
  end
  edit.set_property(bufnr, hl.line, name, nil)
  return true
end

--- Remove a property from every entry of the buffer
--- (org-delete-property-globally). Returns the number of entries changed.
function M.delete_property_globally(bufnr, name)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local file = files.get_buffer(bufnr)
  if not name then
    local names, seen = {}, {}
    for _, hl in ipairs(file.headlines) do
      for k in pairs(hl.properties) do
        if not seen[k] then
          seen[k] = true
          names[#names + 1] = k
        end
      end
    end
    table.sort(names)
    if #names == 0 then
      utils.notify("No properties in this buffer")
      return nil
    end
    name = utils.input_complete("Globally remove property: ", names)
    if not name or vim.trim(name) == "" then
      return nil
    end
    name = vim.trim(name)
  end
  local lines = {}
  for i = #file.headlines, 1, -1 do
    local hl = file.headlines[i]
    if hl.properties[name:upper()] ~= nil then
      lines[#lines + 1] = hl.line
    end
  end
  -- bottom-up, so earlier line numbers stay valid
  for _, l in ipairs(lines) do
    edit.set_property(bufnr, l, name, nil)
  end
  utils.notify(string.format("Property %s removed from %d entries", name, #lines))
  return #lines
end

--- Property at line `lnum` when it is inside a headline's property
--- drawer (org-at-property-p).
---@return string|nil name, string|nil value, org.Headline|nil headline
function M.at_property_line(bufnr, lnum)
  bufnr = bufnr or 0
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
  local name, value = line:match("^%s*:([^%s:]+):%s*(.-)%s*$")
  if not name or name:upper() == "END" or name:upper() == "PROPERTIES" then
    return nil
  end
  local hl = files.get_buffer(bufnr):headline_at(lnum)
  local r = hl and hl.properties_range
  if not r or lnum <= r[1] or lnum >= r[2] then
    return nil
  end
  return name, value, hl
end

--- Replace the value of the property at `lnum` (keeps name and indentation).
local function set_value_at(bufnr, lnum, name, value)
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
  local indent = line:match("^(%s*)")
  vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum, false, { indent .. ":" .. name .. ": " .. value })
end

--- Switch the property at the cursor to the next (dir = 1) or previous
--- (dir = -1) allowed value (org-property-next-allowed-value). Returns
--- false when the cursor is not on a property line.
function M.next_allowed_value(dir)
  local bufnr = vim.api.nvim_get_current_buf()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local name, value, hl = M.at_property_line(bufnr, lnum)
  if not name then
    return false
  end
  local allowed = hl:get_allowed_values(name)
  if not allowed or #allowed == 0 then
    utils.warn("Allowed values for this property have not been defined")
    return
  end
  local idx
  for i, v in ipairs(allowed) do
    if v == value then
      idx = i
    end
  end
  local new
  if not idx then
    new = dir > 0 and allowed[1] or allowed[#allowed]
  else
    new = allowed[((idx - 1 + dir) % #allowed) + 1]
  end
  set_value_at(bufnr, lnum, name, new)
  return new
end

--- C-c C-c on a property line (org-property-action): set its value,
--- delete it here or delete it from every entry of the buffer.
function M.property_action()
  local bufnr = vim.api.nvim_get_current_buf()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local name, _, hl = M.at_property_line(bufnr, lnum)
  if not name then
    return false
  end
  local choice = require("org.ui").menu({
    title = "Property " .. name,
    items = {
      { key = "s", label = "Set value", value = "s" },
      { key = "d", label = "Delete from this entry", value = "d" },
      { key = "D", label = "Delete from all entries", value = "D" },
    },
  })
  if choice == "s" then
    return M.set_property({ bufnr = bufnr, lnum = hl.line }, name)
  elseif choice == "d" then
    return M.delete_property({ bufnr = bufnr, lnum = hl.line }, name)
  elseif choice == "D" then
    return M.delete_property_globally(bufnr, name)
  end
end

--- Set the effort estimate (org-set-effort).
function M.set_effort(target, value)
  local bufnr, _, hl = edit.resolve_headline(target)
  if not bufnr then
    return nil
  end
  local prop = config.opts.effort_property or "Effort"
  if value == nil then
    local allowed = hl:get_allowed_values(prop)
    local current = hl.properties[prop:upper()]
    if allowed and #allowed > 0 then
      value = utils.select(allowed, { prompt = "Effort" .. (current and (" (current: " .. current .. ")") or "") })
    else
      value = utils.input_complete("Effort: ", M.DEFAULT_EFFORTS, current or "")
    end
    if value == nil then
      return nil
    end
  end
  value = vim.trim(value)
  if value == "" then
    edit.set_property(bufnr, hl.line, prop, nil)
    require("org.clock").effort_changed(bufnr, hl.line)
    return false
  end
  local minutes = date.parse_duration(value)
  if not minutes then
    utils.warn("Invalid effort: " .. value)
    return nil
  end
  if not value:find(":") then
    value = date.format_duration(minutes)
  end
  edit.set_property(bufnr, hl.line, prop, value)
  -- the running clock shows the new effort (org-set-effort)
  require("org.clock").effort_changed(bufnr, hl.line)
  return value
end

--- Toggle the ORDERED property of the entry (org-toggle-ordered-property):
--- set it to `t`, or remove it when already set.
--- Returns true when handled (never false, so the key does not fall back).
function M.toggle_ordered(target)
  local bufnr, _, hl = edit.resolve_headline(target)
  if not bufnr then
    return nil
  end
  local v = hl.properties.ORDERED
  local ordered = not (v ~= nil and v ~= "" and v:lower() ~= "nil")
  edit.set_property(bufnr, hl.line, "ORDERED", ordered and "t" or nil)
  utils.notify(ordered and "Subtasks must be completed in sequence" or "Subtasks can be completed in arbitrary order")
  return true
end

--- Effort of a headline in minutes, or nil.
function M.effort_minutes(hl)
  local v = hl:get_property(config.opts.effort_property or "Effort", false)
  return v and date.parse_duration(v) or nil
end

return M
