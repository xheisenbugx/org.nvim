---@mod org.agenda.view.bulk Agenda bulk actions (org-agenda-bulk-action)
---
--- Part of org.agenda.view, which loads it.

local config = require("org.config")
local date = require("org.date")
local utils = require("org.utils")
local shared = require("org.agenda.view.shared")

local M = require("org.agenda.view")

local add_remove_tag = shared.add_remove_tag
local all_tags_in_view = shared.all_tags_in_view
local bulk = shared.bulk
local call = shared.call
local item_key = shared.item_key
local todo_names = shared.todo_names

---------------------------------------------------------------------------
-- Bulk actions (org-agenda-bulk-action)
---------------------------------------------------------------------------

--- Days from today for an entry scattered over `days` days; with
--- `skip_weekends`, weekend days are jumped over.
function M.scatter_distance(days, skip_weekends, rand)
  rand = rand or math.random
  local distance = 1 + (rand(days) - 1)
  if skip_weekends then
    local weekend = {}
    for _, w in ipairs(config.opts.agenda.weekend_days or { 6, 0 }) do
      weekend[w] = true
    end
    local dow = date.today():weekday() % 7
    for _ = 1, distance + 1 do
      while weekend[dow] do
        distance = distance + 1
        dow = (dow + 1) % 7
      end
      dow = (dow + 1) % 7
    end
  end
  return distance
end

--- Read a date for bulk (re)scheduling: a "++N[dwmy]" answer shifts each
--- entry's own date; an empty answer opens the calendar.
local function read_bulk_date(prompt)
  local input = utils.input({ prompt = prompt .. ": " })
  if input == nil then
    return nil
  end
  local n, unit = input:match("^%s*%+%+(%-?%d+)([hdwmy]?)%s*$")
  if n then
    return { shift = tonumber(n), unit = unit ~= "" and unit or "d" }
  end
  if vim.trim(input) == "" then
    local d = M.pick_date(date.today(), prompt)
    return d and { date = d:clone({ active = true }) } or nil
  end
  local d = date.read_date(input, date.today())
  if not d then
    utils.error("Invalid date: " .. input)
    return nil
  end
  return { date = d:clone({ active = true }) }
end

function M.bulk_action()
  if not next(M.state.marks) then
    local item = M.item_at_cursor()
    if not item then
      utils.warn("No entries are marked")
      return
    end
    M.state.marks[item_key(item)] = item
  end
  local acfg = config.opts.agenda
  local persistent = acfg.persistent_marks or false
  local custom = acfg.bulk_custom_functions or {}
  local choice
  while true do
    local items = {
      { key = "p", label = (persistent and "Don't persist" or "Persist") .. " marks", value = "p" },
      { key = "$", label = "Archive", value = "$" },
      { key = "A", label = "Archive to archive sibling", value = "A" },
      { key = "t", label = "Change TODO state", value = "t" },
      { key = "+", label = "Add tag", value = "+" },
      { key = "-", label = "Remove tag", value = "-" },
      { key = "s", label = '(Re)schedule ("++2d" shifts each date)', value = "s" },
      { key = "d", label = '(Re)set deadline ("++2d" shifts each date)', value = "d" },
      { key = "r", label = "Refile", value = "r" },
      { key = "S", label = "Scatter over N days (count: skip weekends)", value = "S" },
      { key = "f", label = "Apply a Lua function", value = "f" },
    }
    local ckeys = vim.tbl_keys(custom)
    table.sort(ckeys)
    for _, k in ipairs(ckeys) do
      local c = custom[k]
      local label = type(c) == "table" and (c.desc or c.description or "Custom") or "Custom"
      items[#items + 1] = { key = k, label = label, value = { custom = k } }
    end
    choice = require("org.ui").menu({
      title = string.format("Bulk (%d marked)", vim.tbl_count(M.state.marks)),
      items = items,
    })
    if choice == "p" then
      persistent = not persistent
    else
      break
    end
  end
  if not choice then
    return
  end
  local count = vim.v.count
  if choice == "t" then
    local kw = utils.select(vim.list_extend(todo_names(), { "(none)" }), { prompt = "Todo state" })
    if not kw then
      return
    end
    bulk(function(target)
      call("org.todo", "change_state", target, kw ~= "(none)" and kw or nil)
    end, persistent)
  elseif choice == "s" or choice == "d" then
    local kind = choice == "s" and "scheduled" or "deadline"
    local ans = read_bulk_date(choice == "s" and "(Re)Schedule to" or "(Re)Set Deadline to")
    if not ans then
      return
    end
    bulk(function(target)
      if ans.shift then
        local _, _, hl = require("org.edit").resolve_headline(target)
        if hl and hl.planning[kind] then
          call("org.timestamps", "shift", target, kind, ans.shift, ans.unit)
        else
          local d = date.today():add(ans.shift, ans.unit):clone({ active = true })
          call("org.timestamps", "set_date", target, kind, d)
        end
      else
        call("org.timestamps", "set_date", target, kind, ans.date)
      end
    end, persistent)
  elseif choice == "S" then
    local b = M.state.view and M.state.view.blocks[1]
    if b and b.type ~= "agenda" and b.type ~= "todo" then
      utils.error(string.format('Can\'t scatter tasks in "%s" agenda view', b.type))
      return
    end
    local prompt = string.format("Scatter tasks across how many %sdays: ", count > 0 and "week" or "")
    local days = tonumber(utils.input({ prompt = prompt, default = "7" }) or "")
    if not days or days < 1 then
      return
    end
    local today = date.today()
    bulk(function(target, item)
      if item.sexp then
        return
      end
      local d = today:add(M.scatter_distance(days, count > 0), "d"):clone({ active = true })
      call("org.timestamps", "set_date", target, "scheduled", d)
    end, persistent)
  elseif choice == "+" or choice == "-" then
    local tag = utils.input_complete(choice == "+" and "Tag to add: " or "Tag to remove: ", all_tags_in_view())
    if not tag or vim.trim(tag) == "" then
      return
    end
    tag = vim.trim(tag):gsub(":", "")
    bulk(function(target)
      add_remove_tag(target, tag, choice == "+")
    end, persistent)
  elseif choice == "r" then
    local ok, refile = pcall(require, "org.refile")
    local dest = ok and refile.pick_target and refile.pick_target({ prompt = "Refile to" })
    if ok and not dest then
      return
    end
    bulk(function(target)
      call("org.refile", "refile", target, { dest = dest })
    end, persistent)
  elseif choice == "$" then
    bulk(function(target)
      call("org.archive", "archive_subtree", target, { from_agenda = true })
    end, persistent)
  elseif choice == "A" then
    bulk(function(target)
      call("org.archive", "archive_to_sibling", target)
    end, persistent)
  elseif choice == "f" then
    local expr = utils.input({ prompt = "Function (Lua, receives target { bufnr, lnum } and the item): " })
    if not expr or vim.trim(expr) == "" then
      return
    end
    local chunk = loadstring("return " .. expr)
    local ok, fn = pcall(chunk or error)
    if not ok or type(fn) ~= "function" then
      utils.error("Not a function: " .. expr)
      return
    end
    bulk(function(target, item)
      fn(target, item)
    end, persistent)
  elseif type(choice) == "table" and choice.custom then
    local c = custom[choice.custom]
    local fn = type(c) == "function" and c or (type(c) == "table" and (c.fn or c[1]))
    if type(fn) ~= "function" then
      utils.error("Invalid bulk action: " .. choice.custom)
      return
    end
    local args = {}
    if type(c) == "table" and type(c.args) == "function" then
      args = c.args() or {}
    end
    bulk(function(target, item)
      fn(target, item, unpack(args))
    end, persistent)
  end
end
