---@mod org.properties Property drawers, effort estimates

local config = require("org.config")
local date = require("org.date")
local edit = require("org.edit")
local files = require("org.files")
local utils = require("org.utils")

local M = {}

M.DEFAULT_EFFORTS = { "0:05", "0:10", "0:15", "0:30", "0:45", "1:00", "1:30", "2:00", "3:00", "4:00", "6:00", "8:00" }

local SPECIAL = {
  ITEM = true, TODO = true, PRIORITY = true, TAGS = true, ALLTAGS = true, CATEGORY = true,
  LEVEL = true, FILE = true, SCHEDULED = true, DEADLINE = true, CLOSED = true, TIMESTAMP = true,
  TIMESTAMP_IA = true, CLOCKSUM = true, CLOCKSUM_T = true, BLOCKED = true,
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
  return value
end

--- Effort of a headline in minutes, or nil.
function M.effort_minutes(hl)
  local v = hl:get_property(config.opts.effort_property or "Effort", false)
  return v and date.parse_duration(v) or nil
end

return M
