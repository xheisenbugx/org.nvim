---@mod org.extensions.cli.headless Headless safety: prompts and notifications
---
--- Prompts are answered from `--field` or fail with `input_needed`, and
--- notifications go to stderr and the JSON envelope (`headless`). Part of
--- org.extensions.cli.run, which loads it.

local shared = require("org.extensions.cli.shared")

local M = require("org.extensions.cli.run")

local fail = M.fail
local state = shared.state
local err = shared.err

--- The question a prompt asks, without its ": ", default and date hint:
--- "Title [x]: " -> "Title", "Deadline Date+time [2026-10-01]: " -> "Deadline".
function M.prompt_label(p)
  if type(p) == "table" then
    p = p.prompt
  end
  p = vim.trim(tostring(p or ""))
  p = p:gsub(":$", "")
  p = vim.trim(p)
  p = p:gsub("%s*%[[^%]]*%]$", "")
  p = p:gsub("%s*Date%+time$", "")
  return vim.trim(p)
end

--- The `--field` answer to a prompt, or a failure (exit 3).
local function ask(prompt)
  local label = M.prompt_label(prompt)
  local v = state.answers[label:lower()]
  if v == nil and label == "" then
    v = state.answers.date
  end
  if v ~= nil then
    return v
  end
  state.prompted = state.prompted or (label ~= "" and label or "input")
  fail(
    "interactive input needed ("
      .. state.prompted
      .. "); not available in the CLI"
      .. (label ~= "" and (" (answer it with --field '" .. label .. "=...')") or ""),
    "input_needed",
    { prompt = state.prompted }
  )
end

--- A prompt `--field` doesn't answer (a confirmation, a passphrase, a
--- key press): fail with `input_needed`, naming its question (else `what`).
local function no_input(what)
  return function(prompt)
    local label = type(prompt) == "string" and M.prompt_label(prompt) or ""
    label = label ~= "" and label or what
    state.prompted = state.prompted or label
    fail("interactive input needed (" .. label .. "); not available in the CLI", "input_needed", { prompt = label })
  end
end

--- Replace prompts with `--field` answers or errors, and route
--- notifications to stderr (and the JSON envelope). Returns a function
--- that puts the replaced functions back (the session server runs a
--- command and then restores them; `nvim -l` just exits).
---@return fun()
function M.headless()
  local utils = require("org.utils")
  local saved = {}
  -- replace functions of `tbl` by those of `fns`, keeping the originals
  local function replace(tbl, fns)
    for k, f in pairs(fns) do
      saved[#saved + 1] = { tbl, k, rawget(tbl, k) }
      rawset(tbl, k, f)
    end
  end
  local notify = vim.notify
  replace(vim.fn, {
    input = function(opts)
      return ask(opts)
    end,
    inputdialog = function(opts)
      return ask(opts)
    end,
    -- (under `nvim -l` an unanswered inputsecret() ends Neovim, exit 0)
    inputsecret = no_input("passphrase"),
    inputlist = no_input("inputlist"),
    confirm = no_input("confirm"),
    getchar = no_input("getchar"),
    getcharstr = no_input("getchar"),
  })
  replace(vim.ui, {
    input = function(opts, cb)
      cb(ask(opts))
    end,
    select = no_input("vim.ui.select"),
  })
  replace(utils, {
    input = function(opts)
      return ask(opts)
    end,
    input_complete = function(prompt)
      return ask(prompt)
    end,
    -- a log note the command records: --note, else an empty note (the
    -- entry is logged with its time only, as C-c C-c on an empty note)
    input_note = function()
      return state.note or ""
    end,
    confirm = no_input("confirm"),
    getchar = no_input("getchar"),
  })
  replace(vim, {
    notify = function(msg, level)
      level = level or vim.log.levels.INFO
      msg = tostring(msg)
      state.messages[#state.messages + 1] = { msg = msg, level = level }
      if state.disk_reason and msg:find(state.disk_reason, 1, true) then
        -- a write the file's change on disk stopped: the command fails
        -- with `file_changed`, which says so (what org.nvim says, such as
        -- "the text is kept in the capture buffer", is not so here)
        return
      end
      if level >= vim.log.levels.WARN then
        state.warnings[#state.warnings + 1] = msg
      end
      local show
      if state.machine then
        show = state.verbose
      else
        show = (level >= vim.log.levels.WARN and not state.quiet) or state.verbose
      end
      if show then
        err(msg)
      end
      if state.session and level >= vim.log.levels.INFO then
        -- the session's user sees what the command line did there
        pcall(notify, msg, level)
      end
    end,
  })
  -- nvim_echo() writes to stderr under `nvim -l`: make its messages
  -- notifications like the others (org-crypt's "No crypt key set, ...")
  replace(vim.api, {
    nvim_echo = function(chunks)
      local text, level = {}, vim.log.levels.INFO
      for _, c in ipairs(chunks or {}) do
        text[#text + 1] = c[1] or ""
        if c[2] == "ErrorMsg" then
          level = vim.log.levels.ERROR
        elseif c[2] == "WarningMsg" then
          level = math.max(level, vim.log.levels.WARN)
        end
      end
      local msg = table.concat(text)
      if msg ~= "" then
        vim.notify(msg, level)
      end
    end,
  })
  return function()
    for i = #saved, 1, -1 do
      local e = saved[i]
      rawset(e[1], e[2], e[3])
    end
  end
end
