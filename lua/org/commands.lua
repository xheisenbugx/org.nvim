---@mod org.commands The :Org command
---
--- `:Org <action> [args]`. Every action from `org.actions` is available,
--- plus the extra subcommands below which accept arguments.

local actions = require("org.actions")
local utils = require("org.utils")

local M = {}

--- Extra subcommands: name -> { module, fn, desc, complete? }
--- The function receives the argument string (possibly "").
M.extra = {
  agenda = { "org.agenda", "command", desc = "Open agenda: :Org agenda [a|t|m|s|<custom key>|day|week|month]" },
  capture = { "org.capture", "command", desc = "Capture with template key: :Org capture [key]" },
  export = { "org.export", "command", desc = "Export: :Org export [html|md|txt|latex|pdf|docx|odt|...]" },
  tangle = { "org.babel", "tangle_command", desc = "Tangle current file" },
  clock_in_last = { "org.clock", "clock_in_last", desc = "Clock in the last clocked task" },
  timer_start = { "org.timer", "start", desc = "Start relative timer" },
  timer_stop = { "org.timer", "stop", desc = "Stop relative timer" },
  timer_pause = { "org.timer", "pause_or_continue", desc = "Pause/continue timer" },
  timer_insert = { "org.timer", "insert", desc = "Insert relative timer value" },
  timer_countdown = { "org.timer", "countdown", desc = "Start countdown timer: :Org timer_countdown [minutes]" },
  notifications_start = { "org.agenda.notifications", "start", desc = "Start appointment reminders" },
  notifications_stop = { "org.agenda.notifications", "stop", desc = "Stop appointment reminders" },
  id_update_locations = { "org.id", "update_locations", desc = "Rebuild ID locations database" },
  search = { "org.agenda", "search_command", desc = "Search agenda files: :Org search <text>" },
  tags_search = { "org.agenda", "tags_command", desc = "Tags/property match: :Org tags_search <match>" },
  todo_list = { "org.agenda", "todo_command", desc = "Global TODO list: :Org todo_list [KEYWORD]" },
  show_all = { "org.fold", "show_all", desc = "Expand everything" },
  overview = { "org.fold", "overview", desc = "Show overview" },
  content = { "org.fold", "content", desc = "Show contents (all headlines)" },
  align_tags = { "org.tags", "align_all", desc = "Align all tags in buffer" },
  refile_goto = { "org.refile", "goto", desc = "Jump to a refile target" },
  lint = { "org.lint", "command", desc = "Check the buffer for syntax problems: :Org lint [checker ...]" },
}

local function names()
  local out = {}
  for name in pairs(actions.list) do
    out[#out + 1] = name
  end
  for name in pairs(M.extra) do
    if not actions.list[name] then
      out[#out + 1] = name
    end
  end
  table.sort(out)
  return out
end

function M.run(opts)
  local args = opts.fargs
  local name = args[1]
  if not name then
    utils.run(function()
      local choice = utils.select(names(), { prompt = "Org command" })
      if choice then
        M.run({ fargs = { choice } })
      end
    end)
    return
  end
  local rest = table.concat(vim.list_slice(args, 2), " ")
  local extra = M.extra[name]
  if extra then
    local ok, mod = pcall(require, extra[1])
    if not ok or type(mod[extra[2]]) ~= "function" then
      utils.error(string.format("%s.%s is not available", extra[1], extra[2]))
      return
    end
    utils.run(mod[extra[2]], rest)
    return
  end
  if actions.list[name] then
    actions.run(name)
    return
  end
  utils.error("Unknown :Org subcommand: " .. name)
end

function M.complete(arglead, cmdline)
  local nargs = #vim.split(cmdline, "%s+", { trimempty = false })
  if nargs <= 2 then
    return vim.tbl_filter(function(n)
      return n:find(arglead, 1, true) == 1
    end, names())
  end
  local sub = cmdline:match("^%S+%s+(%S+)")
  if sub == "export" then
    return vim.tbl_filter(function(n)
      return n:find(arglead, 1, true) == 1
    end, { "html", "md", "markdown", "txt", "latex", "pdf", "docx", "odt", "rst", "epub", "org" })
  elseif sub == "agenda" then
    local out = { "a", "t", "T", "m", "M", "s", "#", "day", "week", "month", "year" }
    for key in pairs(require("org.config").opts.agenda.custom_commands or {}) do
      out[#out + 1] = key
    end
    return out
  elseif sub == "capture" then
    return vim.tbl_keys(require("org.config").opts.capture.templates or {})
  elseif sub == "lint" then
    local out = {}
    for _, c in ipairs(require("org.lint").checkers) do
      if c[1]:find(arglead, 1, true) == 1 then
        out[#out + 1] = c[1]
      end
    end
    return out
  end
  return {}
end

function M.setup()
  vim.api.nvim_create_user_command("Org", M.run, {
    nargs = "*",
    range = true,
    complete = M.complete,
    desc = "org.nvim commands",
  })
end

return M
