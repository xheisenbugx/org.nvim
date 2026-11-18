---@mod org.extensions.transclusion.watch Debouncing and watching source files
---
--- `later` runs a function once after the last of a burst of changes, and
--- the directories of the source files shown are watched for changes made
--- outside Neovim. Part of org.extensions.transclusion, which loads it.

local shared = require("org.extensions.transclusion.shared")
local utils = require("org.utils")

local M = require("org.extensions.transclusion")

local opts = shared.opts
local enabled = shared.enabled
local valid = shared.valid
local report_once = shared.report_once

local timers = {}

local function close_handle(h)
  -- lint: allow pcall: the handle may be closed already
  pcall(function()
    h:stop()
    if not h:is_closing() then
      h:close()
    end
  end)
end

-- Run `fn` once, `debounce` ms after the last call with the same key.
local function later(key, fn)
  local t = timers[key]
  if not t then
    t = vim.uv.new_timer()
    if not t then
      return
    end
    timers[key] = t
  end
  t:stop()
  t:start(
    opts().debounce or 150,
    0,
    vim.schedule_wrap(function()
      if timers[key] == t then
        timers[key] = nil
      end
      close_handle(t)
      if enabled() then
        local ok, err = pcall(fn)
        if not ok then
          report_once(err)
        end
      end
    end)
  )
end

M.later = later

-- directory -> { handle, files = { [basename] = path } }. Directories are
-- watched rather than files: that also sees files saved by renaming.
local watchers = {}
local MAX_WATCHED = 64

--- Number of directories being watched.
function M.watch_count()
  local n = 0
  for _ in pairs(watchers) do
    n = n + 1
  end
  return n
end

local function update_watchers()
  local want, n = {}, 0
  if opts().watch then
    for buf, st in pairs(M.buffers) do
      if valid(buf) then
        for p in pairs(st.sources) do
          local d, name = p:match("^(.*)/([^/]+)$")
          if d then
            d = d == "" and "/" or d
            if not want[d] then
              n = n + 1
              want[d] = {}
            end
            want[d][name] = p
          end
        end
      end
    end
  end
  for d, w in pairs(watchers) do
    if not want[d] then
      close_handle(w.handle)
      watchers[d] = nil
    end
  end
  local open = M.watch_count()
  for d, names in pairs(want) do
    if watchers[d] then
      watchers[d].files = names
    elseif open >= MAX_WATCHED then
      report_once("watching at most " .. MAX_WATCHED .. " directories; refresh the others by hand")
      break
    elseif utils.is_dir(d) then
      local h = vim.uv.new_fs_event()
      local entry = { handle = h, files = names }
      local ok = h
        and h:start(d, {}, function(err, fname)
          if err then
            return
          end
          -- a fast callback: no vim.fn or vim.api here
          local tail = fname and fname:match("[^/]+$")
          for name, p in pairs(entry.files) do
            if not tail or tail == name then
              later("watch:" .. p, function()
                require("org.files").invalidate(p)
                M.refresh_dependents(p)
              end)
            end
          end
        end)
      if ok == 0 then
        watchers[d] = entry
        open = open + 1
      elseif h then
        close_handle(h)
      end
    end
  end
end

local function stop_all()
  for _, t in pairs(timers) do
    close_handle(t)
  end
  timers = {}
  for _, w in pairs(watchers) do
    close_handle(w.handle)
  end
  watchers = {}
end

-- Stop the timer of `key` before it runs.
local function cancel_timer(key)
  local t = timers[key]
  if t then
    timers[key] = nil
    close_handle(t)
  end
end

shared.later = later
shared.update_watchers = update_watchers
shared.stop_all = stop_all
shared.cancel_timer = cancel_timer
