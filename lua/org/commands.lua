---@mod org.commands The :Org command
---
--- `:Org <action> [args]`. Every action from `org.actions` is available,
--- plus the extra subcommands below which accept arguments.

local actions = require("org.actions")
local utils = require("org.utils")

local M = {}

--- Extra subcommands: name -> { module, fn, desc, complete? }
--- The function receives the argument string (possibly "").
--- `complete(arglead, cmdline)` returns candidates for the arguments; they
--- are filtered by `arglead`.
M.extra = {
  agenda = { "org.agenda", "command", desc = "Open agenda: :Org agenda [a|t|m|s|<custom key>|day|week|month]" },
  capture = { "org.capture", "command", desc = "Capture with template key: :Org capture [key]" },
  export = {
    "org.export",
    "command",
    desc = "Export: :Org export [html|md|gfm|ascii|latex|pdf|beamer|org|ics|docx|...]",
  },
  publish = { "org.export", "publish_command", desc = "Publish: :Org publish [project|file|current|all] [force]" },
  convert_region = {
    "org.export",
    "convert_region_command",
    desc = "Replace lines by their export: :[range]Org convert_region html|latex|md|ascii|utf8|texinfo",
  },
  export_region_to_html = { "org.export", "export_region_to_html", desc = "Alias: :[range]Org convert_region html" },
  export_region_to_latex = { "org.export", "export_region_to_latex", desc = "Alias: :[range]Org convert_region latex" },
  export_region_to_md = { "org.export", "export_region_to_md", desc = "Alias: :[range]Org convert_region md" },
  export_region_to_ascii = { "org.export", "export_region_to_ascii", desc = "Alias: :[range]Org convert_region ascii" },
  export_region_to_utf8 = { "org.export", "export_region_to_utf8", desc = "Alias: :[range]Org convert_region utf8" },
  export_region_to_texinfo = {
    "org.export",
    "export_region_to_texinfo",
    desc = "Alias: :[range]Org convert_region texinfo",
  },
  tangle = { "org.babel", "tangle_command", desc = "Tangle current file" },
  detangle = { "org.babel", "detangle_command", desc = "Send tangled file edits back to Org: :Org detangle [file]" },
  tangle_jump = { "org.babel", "jump_to_org", desc = "From a tangled file, jump to its Org src block" },
  tangle_clean = { "org.babel", "tangle_clean", desc = "Remove tangle link comments from the buffer" },
  babel_load_file = { "org.babel", "load_file_command", desc = "Tangle an Org file's Lua blocks and run them" },
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
  protocol = { "org.protocol", "handle", desc = "Handle an org-protocol:// URL: :Org protocol <url>" },
  link_open_from_string = {
    "org.links",
    "open_from_string_command",
    desc = "Open a link: :Org link_open_from_string [link]",
  },
  lint = { "org.lint", "command", desc = "Check the buffer for syntax problems: :Org lint [checker ...]" },
  feed_update = { "org.feed", "update_command", desc = "Update a feed: :Org feed_update [name]" },
  feed_goto_inbox = { "org.feed", "goto_inbox", desc = "Go to a feed's inbox: :Org feed_goto_inbox [name]" },
  feed_show_raw = { "org.feed", "show_raw", desc = "Show a feed's raw XML: :Org feed_show_raw [name]" },
  mobile_push = { "org.mobile", "push", desc = "Stage files and agendas for MobileOrg (org-mobile-push)" },
  mobile_pull = { "org.mobile", "pull", desc = "Get captured and flagged entries from MobileOrg (org-mobile-pull)" },
  mobile_apply = { "org.mobile", "apply_command", desc = "Apply the MobileOrg change requests in the buffer" },
  mobile_goto_inbox = { "org.mobile", "goto_inbox", desc = "Open the MobileOrg inbox (mobile.inbox_for_pull)" },
  mobile_flagged = { "org.mobile", "flagged_agenda", desc = "Agenda of FLAGGED entries (dispatcher key ?)" },
  -- image and LaTeX previews: a range limits them, a number is the prefix count
  link_preview = {
    "org.ui.images",
    "ex_link_preview",
    desc = "Toggle image previews: :[range]Org link_preview [4|16|64|1|11]",
  },
  link_preview_region = {
    "org.ui.images",
    "ex_link_preview_region",
    desc = "Preview image links (default the buffer): :[range]Org link_preview_region [linked]",
  },
  link_preview_clear = {
    "org.ui.images",
    "ex_link_preview_clear",
    desc = "Remove image previews (default the buffer): :[range]Org link_preview_clear",
  },
  link_preview_refresh = { "org.ui.images", "ex_link_preview_refresh", desc = "Refresh image previews in the buffer" },
  latex_preview = {
    "org.ui.images",
    "ex_latex_preview",
    desc = "Toggle LaTeX previews: :[range]Org latex_preview [4|16|64]",
  },
  clear_latex_preview = {
    "org.ui.images",
    "ex_clear_latex_preview",
    desc = "Remove LaTeX previews (default the buffer): :[range]Org clear_latex_preview",
  },
  -- obsolete Emacs names
  toggle_inline_images = { "org.ui.images", "ex_toggle_inline_images", desc = "Obsolete: link_preview" },
  remove_inline_images = { "org.ui.images", "ex_remove_inline_images", desc = "Obsolete: link_preview_clear" },
  redisplay_inline_images = {
    "org.ui.images",
    "ex_redisplay_inline_images",
    desc = "Obsolete: link_preview_refresh",
  },
  toggle_latex_fragment = { "org.ui.images", "ex_toggle_latex_fragment", desc = "Obsolete: latex_preview" },
  preview_latex_fragment = { "org.ui.images", "ex_preview_latex_fragment", desc = "Obsolete: latex_preview" },
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
    utils.run(mod[extra[2]], rest, opts)
    return
  end
  if actions.list[name] then
    actions.run(name)
    return
  end
  utils.error("Unknown :Org subcommand: " .. name)
end

function M.complete(arglead, cmdline)
  -- customlist completion: Vim doesn't filter the candidates itself
  local function filter(list)
    return vim.tbl_filter(function(n)
      return n:find(arglead, 1, true) == 1
    end, list)
  end
  -- the words after `Org` (the command line may start with a range or
  -- modifiers such as `:silent`)
  local args = vim.split(cmdline:match("^.-%f[%a]Org!?%s+(.*)$") or "", "%s+", { trimempty = false })
  if #args <= 1 then
    return filter(names())
  end
  local sub = args[1]
  if sub == "export" or sub == "convert_region" then
    return vim.tbl_filter(function(n)
      return n:find(arglead, 1, true) == 1
    end, {
      "html",
      "md",
      "gfm",
      "ascii",
      "latin1",
      "utf8",
      "txt",
      "latex",
      "pdf",
      "beamer",
      "beamer-pdf",
      "org",
      "ics",
      "texinfo",
      "info",
      "koma-letter",
      "koma-pdf",
      "man",
      "man-pdf",
      "docx",
      "odt",
      "rst",
      "epub",
    })
  elseif sub == "publish" then
    local out = { "all", "file", "current", "force" }
    for _, p in ipairs(require("org.export.publish").projects()) do
      out[#out + 1] = p[1]
    end
    return vim.tbl_filter(function(n)
      return n:find(arglead, 1, true) == 1
    end, out)
  elseif sub == "agenda" then
    -- the keys `org.agenda.command` takes, then the custom commands
    local out = { "a", "t", "T", "m", "M", "s", "S", "n", "#", "/", "day", "week", "fortnight", "month", "year" }
    local custom = {}
    for key in pairs(require("org.config").opts.agenda.custom_commands or {}) do
      if type(key) == "string" and not vim.tbl_contains(out, key) then
        custom[#custom + 1] = key
      end
    end
    table.sort(custom)
    return filter(vim.list_extend(out, custom))
  elseif sub == "capture" then
    local keys = {}
    for key in pairs(require("org.config").opts.capture.templates or {}) do
      if type(key) == "string" then
        keys[#keys + 1] = key
      end
    end
    table.sort(keys)
    return filter(keys)
  elseif sub == "feed_update" or sub == "feed_goto_inbox" or sub == "feed_show_raw" then
    return vim.tbl_filter(function(n)
      return n:find(arglead, 1, true) == 1
    end, require("org.feed").names())
  elseif sub == "lint" then
    local out = {}
    for _, c in ipairs(require("org.lint").checkers) do
      if c[1]:find(arglead, 1, true) == 1 then
        out[#out + 1] = c[1]
      end
    end
    return out
  end
  local extra = sub and M.extra[sub]
  if extra and extra.complete then
    local ok, items = pcall(extra.complete, arglead, cmdline)
    if ok and type(items) == "table" then
      return vim.tbl_filter(function(n)
        return type(n) == "string" and n:find(arglead, 1, true) == 1
      end, items)
    end
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
