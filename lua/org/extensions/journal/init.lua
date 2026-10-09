---@mod org.extensions.journal A dated journal (org-journal)
---
--- Enable with `setup({ extensions = { journal = { directory = "~/journal" } } })`.
--- Files and headings follow Emacs org-journal's format, so a journal can
--- be shared with it. See `:h org-extensions-journal`.

local M = {}

local R = "org.extensions.journal"

--- `:h org-extensions-stability`.
M.stability = "experimental"

M.defaults = {
  --- The journal directory (org-journal-dir), relative to `org_directory`
  --- unless absolute.
  directory = "~/org/journal",
  --- One file per "daily", "weekly", "monthly" or "yearly" period
  --- (org-journal-file-type).
  file_type = "daily",
  --- File names, a format-time-string of the period's first day, relative
  --- to `directory` (org-journal-file-format). It needs %Y, %m and %d for
  --- daily and weekly files (or %G and %V for weekly), %Y and %m for
  --- monthly ones and %Y for yearly ones.
  file_format = "%Y%m%d.org",
  --- First day of weekly files, 1 (Monday) to 7 (Sunday)
  --- (org-journal-start-on-weekday).
  start_on_weekday = 1,
  --- Text at the top of a new file, a format-time-string of the day or
  --- `fun(date): string` (org-journal-file-header).
  file_header = "",
  --- What comes before `date_format` in a day's heading
  --- (org-journal-date-prefix). For daily files only, a prefix that isn't
  --- a heading (like "#+title: ") makes the whole file the day.
  date_prefix = "* ",
  --- The day heading's text, a format-time-string or `fun(date): string`
  --- giving the whole line, prefix included (org-journal-date-format).
  date_format = "%A, %Y-%m-%d",
  --- What starts an entry (org-journal-time-prefix).
  time_prefix = "** ",
  --- The time after `time_prefix` in today's entries; "" for none
  --- (org-journal-time-format).
  time_format = "%R ",
  --- Lines added under a new entry's heading (a format-time-string of the
  --- day or `fun(date): string`); `%?` is where the cursor goes. nil: none.
  entry_template = nil,
  --- A tags/property match (as in the agenda's tags view): the items of the
  --- last day before today that match move to today when today's journal
  --- is opened (org-journal-carryover-items). false: none.
  carryover = 'TODO="TODO"',
  --- After a carry-over, delete the previous day (and its file when it was
  --- the only day in it) if nothing is left in it: false, true or "ask"
  --- (org-journal-carryover-delete-empty-journal).
  carryover_delete_empty = false,
  --- Text before the timestamp of a scheduled entry, e.g. "SCHEDULED:"
  --- (org-journal-scheduled-string).
  scheduled_string = "",
  --- Add journal files to the agenda files: true for the current and future
  --- ones (org-journal-enable-agenda-integration), "all" for every one.
  agenda = false,
  --- Date shown before search results (org-journal-search-result-date-format).
  search_date_format = "%a %Y-%m-%d",
  --- Order of search results: "asc" or "desc"
  --- (org-journal-search-results-order-by).
  search_order = "asc",
}

local function a(fn, desc)
  local mod, name = fn:match("^(.-)%.([%w_]+)$")
  return { R .. "." .. mod, name, desc = desc }
end

M.actions = {
  journal_new_entry = a("commands.new_entry", "Journal: new entry today"),
  journal_open = a("commands.open_today", "Journal: open today"),
  journal_new_date_entry = a("commands.new_date_entry", "Journal: new entry on a date"),
  journal_new_scheduled_entry = a("commands.new_scheduled_entry", "Journal: new scheduled entry on a future date"),
  journal_next = a("commands.next", "Journal: next day with entries"),
  journal_previous = a("commands.previous", "Journal: previous day with entries"),
  journal_search = a("commands.search", "Journal: search"),
  journal_calendar = a("commands.calendar", "Journal: calendar of days with entries"),
}

local function c(fn, desc, complete)
  local mod, name = fn:match("^(.-)%.([%w_]+)$")
  return { R .. "." .. mod, name, desc = desc, complete = complete }
end

M.commands = {
  journal_new_entry = c("commands.new_entry", "Journal entry: :Org journal_new_entry [date]"),
  journal_new_date_entry = c("commands.new_date_entry", "Journal entry on a date: [date]"),
  journal_new_scheduled_entry = c("commands.new_scheduled_entry", "Scheduled journal entry: [date]"),
  journal_next = c("commands.next", "Next journal day: [count]"),
  journal_previous = c("commands.previous", "Previous journal day: [count]"),
  journal_search = c(
    "commands.search",
    "Search the journal: :Org journal_search [week|month|year|future|past|all|FROM..TO] [text]",
    function(arglead)
      return require(R .. ".commands").complete_search(arglead)
    end
  ),
}

-- <prefix>j is the code extension's, <prefix>J moves subtrees: the journal
-- lives under <prefix>L ("log")
M.mappings = {
  global = {
    journal_new_entry = "<prefix>Lj",
    journal_open = "<prefix>Lo",
    journal_new_date_entry = "<prefix>Ld",
    journal_new_scheduled_entry = "<prefix>LS",
    journal_next = "<prefix>Ln",
    journal_previous = "<prefix>Lp",
    journal_search = "<prefix>Ls",
    journal_calendar = "<prefix>Lc",
  },
}

M.groups = { { "L", "journal" } }

--- The resolved options.
---@return table
function M.opts()
  return require("org.extensions").opts("journal") or M.defaults
end

function M.setup(opts)
  local files = require("org.files")
  if opts.agenda then
    files.agenda_sources.journal = function()
      return require(R .. ".commands").agenda_files()
    end
  else
    files.agenda_sources.journal = nil
  end
end

function M.teardown()
  require("org.files").agenda_sources.journal = nil
end

-- what file_format needs for each file_type (org-journal-file-format)
local NEEDS = {
  daily = { { "Y", "m", "d" } },
  weekly = { { "Y", "m", "d" }, { "G", "V" } },
  monthly = { { "Y", "m" } },
  yearly = { { "Y" } },
}

function M.health(h, opts)
  local core = require(R .. ".core")
  local utils = require("org.utils")
  local dir = core.directory()
  if utils.is_dir(dir) then
    h.ok("journal directory: " .. dir)
  else
    h.info("journal directory does not exist yet (made by the first entry): " .. dir)
  end
  local needs = NEEDS[opts.file_type]
  if not needs then
    h.error("file_type must be daily, weekly, monthly or yearly, not " .. tostring(opts.file_type))
  else
    local fmt = (opts.file_format or ""):gsub("%%F", "%%Y-%%m-%%d")
    local okfmt = false
    for _, set in ipairs(needs) do
      local all = true
      for _, k in ipairs(set) do
        if not fmt:find("%" .. k, 1, true) then
          all = false
        end
      end
      okfmt = okfmt or all
    end
    if okfmt then
      h.ok(string.format("file_format %q names %s files", opts.file_format, opts.file_type))
    else
      h.error(string.format("file_format %q can't name %s files apart", opts.file_format, opts.file_type))
    end
  end
  if not tostring(opts.file_format):match("%.org$") then
    h.warn("file_format doesn't end in .org: journal files won't open as org files or be agenda files")
  end
  if opts.file_type ~= "daily" and core.day_level() == 0 then
    h.error('date_prefix must be a heading ("* ") for ' .. tostring(opts.file_type) .. " files")
  end
  if opts.carryover and opts.carryover ~= "" then
    local pred, err = require("org.agenda.search").try_compile(opts.carryover, { groups = false })
    if pred then
      h.ok("carryover: " .. opts.carryover)
    else
      h.error("carryover is not a valid match: " .. tostring(err))
    end
  end
  local n = #core.files()
  h.info(string.format("%d journal file%s", n, n == 1 and "" or "s"))
end

return M
