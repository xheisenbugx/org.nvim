---@mod org.migrate Converting an nvim-orgmode setup
---
--- `:Org migrate_config [file]` reads the setup of nvim-orgmode
--- (github.com/nvim-orgmode/orgmode) from a Lua file, or from the current
--- buffer when it holds Lua, and writes the org.nvim `setup()` that does
--- the same into a new scratch buffer, with `-- TODO` comments for what
--- can't be converted. The source is only read: nothing is written.
---
--- The file is run as Lua to get the options, in a sandbox: its
--- `require("orgmode").setup(opts)` (or the `opts` / `config` of a
--- lazy.nvim spec for nvim-orgmode, or a returned table of options) is
--- recorded, other `require`s get an inert stand-in, and keymaps,
--- autocommands, user commands, highlights and option changes are
--- ignored. See `:h org-migrate-nvim-orgmode`.

local M = {}

-- Values ----------------------------------------------------------------------

--- Lua source written as is by `serialize` (a value that is code).
local RAW = {}
RAW.__index = RAW

---@param code string
local function raw(code)
  return setmetatable({ code = code }, RAW)
end

local function is_raw(v)
  return type(v) == "table" and getmetatable(v) == RAW
end

local KEYWORDS = {}
for _, k in ipairs({
  "and",
  "break",
  "do",
  "else",
  "elseif",
  "end",
  "false",
  "for",
  "function",
  "goto",
  "if",
  "in",
  "local",
  "nil",
  "not",
  "or",
  "repeat",
  "return",
  "then",
  "true",
  "until",
  "while",
}) do
  KEYWORDS[k] = true
end

--- A Lua string literal in double quotes.
---@param s string
---@return string
local function quote(s)
  return '"'
    .. s:gsub('[%c"\\]', function(c)
      if c == "\n" then
        return "\\n"
      elseif c == "\t" then
        return "\\t"
      elseif c == '"' or c == "\\" then
        return "\\" .. c
      end
      return string.format("\\%03d", c:byte())
    end)
    .. '"'
end

---@param k any
---@return string
local function key_src(k)
  if type(k) == "string" and k:match("^[%a_][%w_]*$") and not KEYWORDS[k] then
    return k
  end
  return "[" .. (type(k) == "string" and quote(k) or tostring(k)) .. "]"
end

-- Functions -------------------------------------------------------------------

--- The text of a function value from its source (`lines` of the file or
--- buffer it was loaded from, by chunk name), when it is written as an
--- expression (`function(...) ... end`) on lines of its own. nil when the
--- text can't be found.
---@param fn function
---@param sources table<string, string[]>
---@return string[]?
local function function_text(fn, sources)
  local info = debug.getinfo(fn, "S")
  local lines = info and sources[info.source]
  if not lines or info.linedefined < 1 or info.lastlinedefined < info.linedefined then
    return nil
  end
  local first, last = info.linedefined, info.lastlinedefined
  local start = lines[first] and lines[first]:find("function%s*%(")
  if not start then
    return nil
  end
  local out = {}
  for l = first, last do
    out[#out + 1] = lines[l]
  end
  local tail = out[#out]
  -- the last `end` on the last line, and whatever follows it (`,` `}` `)`)
  local stop
  local from = 1
  if #out == 1 then
    from = start
  end
  while true do
    local s, e = tail:find("%f[%w_]end%f[^%w_]", from)
    if not s then
      break
    end
    stop, from = e, e + 1
  end
  if not stop then
    return nil
  end
  out[#out] = tail:sub(1, stop)
  out[1] = out[1]:sub(start)
  -- indentation of the body relative to the line the function starts on
  local indent = #(lines[first]:match("^%s*"))
  for i = 2, #out do
    local lead = #(out[i]:match("^%s*"))
    out[i] = out[i]:sub(math.min(lead, indent) + 1)
  end
  return out
end

--- Where a function was defined, "file:line", for the TODO comments.
---@param fn function
---@return string
local function where(fn)
  local info = debug.getinfo(fn, "S")
  if not info then
    return "?"
  end
  local src = info.source:gsub("^@", "")
  return vim.fn.fnamemodify(src, ":t") .. ":" .. info.linedefined
end

-- The result ------------------------------------------------------------------

---@class org.migrate.Result
---@field out table converted options
---@field notes table<string, string[]> comments on a converted option, by dotted path
---@field todos { name: string, text: string, value: any }[] options without an equivalent
---@field converted integer options converted
---@field defaults string[] lines suggested to keep nvim-orgmode's defaults
---@field mapping_defaults table<string, string[]> per mapping section: lines for its keys
---@field _set_maps? table the mappings the old config set, while converting

---@return org.migrate.Result
local function new_result()
  return { out = {}, notes = {}, todos = {}, converted = 0, defaults = {}, mapping_defaults = {} }
end

--- Set `path` ("agenda.span") in `res.out`.
---@param res org.migrate.Result
---@param path string
---@param value any
local function put(res, path, value)
  local parts = vim.split(path, ".", { plain = true })
  local t = res.out
  for i = 1, #parts - 1 do
    t[parts[i]] = t[parts[i]] or {}
    t = t[parts[i]]
  end
  t[parts[#parts]] = value
end

--- Add a `-- TODO:` comment above the option at `path`.
---@param res org.migrate.Result
---@param path string
---@param text string
local function note(res, path, text)
  res.notes[path] = res.notes[path] or {}
  table.insert(res.notes[path], text)
end

--- An option with no org.nvim equivalent: listed as a TODO with its value.
---@param res org.migrate.Result
---@param name string
---@param text string
---@param value any
local function todo(res, name, text, value)
  res.todos[#res.todos + 1] = { name = name, text = text, value = value }
end

-- Option conversions ------------------------------------------------------------

--- TODO keywords: nvim-orgmode lists keywords (or several such lists);
--- org.nvim takes one string per sequence, as Emacs does. With several
--- sequences nvim-orgmode gives every keyword without a key the first
--- letter of its name as fast-selection key; that key is written out.
local function convert_keywords(v, res, path)
  if type(v) ~= "table" then
    return v
  end
  local seqs = type(v[1]) == "table" and v or { v }
  local used = {}
  for _, seq in ipairs(seqs) do
    for _, kw in ipairs(seq) do
      local k = type(kw) == "string" and kw:match("%((.)[^%)]*%)$")
      if k then
        used[k] = true
      end
    end
  end
  local out = {}
  for _, seq in ipairs(seqs) do
    local words, has_bar = {}, false
    for _, kw in ipairs(seq) do
      if kw == "|" then
        has_bar = true
      elseif #seqs > 1 and not kw:match("%(.*%)$") then
        local k = kw:sub(1, 1):lower()
        if not used[k] then
          used[k] = true
          kw = kw .. "(" .. k .. ")"
        end
      end
      words[#words + 1] = kw
    end
    if not has_bar and #words > 1 then
      -- nvim-orgmode (like Emacs): the last keyword is the done state
      table.insert(words, #words, "|")
    end
    out[#out + 1] = table.concat(words, " ")
  end
  if #seqs > 1 then
    note(res, path, "fast-selection keys nvim-orgmode gave keywords without one are written out")
  end
  return out
end

--- `%(...)` in a template: nvim-orgmode runs the text as the body of a
--- function (`%(return os.date())`), org.nvim as an expression
--- (`%(os.date())`).
---@param s string
---@param warn fun(text: string)
---@return string
local function convert_template_text(s, warn)
  local out, i = {}, 1
  while true do
    local s0 = s:find("%(", i, true)
    if not s0 then
      out[#out + 1] = s:sub(i)
      break
    end
    out[#out + 1] = s:sub(i, s0 - 1)
    -- the matching parenthesis
    local depth, j = 0, s0 + 1
    local close
    while j <= #s do
      local c = s:sub(j, j)
      if c == "(" then
        depth = depth + 1
      elseif c == ")" then
        depth = depth - 1
        if depth == 0 then
          close = j
          break
        end
      end
      j = j + 1
    end
    if not close then
      out[#out + 1] = s:sub(s0)
      break
    end
    local body = s:sub(s0 + 2, close - 1)
    local expr = vim.trim(body):match("^return%s+(.-);?$")
    if expr and loadstring("return " .. expr) then
      out[#out + 1] = "%(" .. expr .. ")"
    else
      out[#out + 1] = "%(" .. body .. ")"
      warn("%(" .. body .. ") is a Lua function body in nvim-orgmode; org.nvim takes an expression or Emacs Lisp")
    end
    i = close + 1
  end
  local text = table.concat(out)
  if text:find("%%n") then
    warn("%n is your user name in nvim-orgmode ($USER) and your full name in org.nvim; use %(os.getenv('USER'))")
  end
  return text
end

local DATETREE_TYPES = { day = true, week = true, month = true }

--- One capture template (and its subtemplates) into `out`.
---@param res org.migrate.Result
---@param out table
---@param key string
---@param t any
---@param path string dotted path of the templates table
local function convert_template(res, out, key, t, path)
  local tpath = path .. "." .. key
  if type(t) ~= "table" then
    out[key] = t
    return
  end
  local function warn(text)
    note(res, tpath, text)
  end
  if t.subtemplates then
    out[key] = t.description or key
    for k, sub in pairs(t.subtemplates) do
      convert_template(res, out, key .. k, sub, path)
    end
    if not t.template then
      return
    end
    -- a template with subtemplates of its own can't also be selected
    warn("nvim-orgmode's template with subtemplates also had a template; it is the group label here")
    return
  end
  local o = {}
  for k, v in pairs(t) do
    if k == "description" or k == "prepend" or k == "regexp" then
      o[k] = v
    elseif k == "headline" then
      o.headline = v
    elseif k == "template" then
      if type(v) == "string" then
        o.template = convert_template_text(v, warn)
      elseif type(v) == "table" then
        o.template = vim.tbl_map(function(l)
          return type(l) == "string" and convert_template_text(l, warn) or l
        end, v)
      else
        o.template = v
      end
    elseif k == "target" then
      if type(v) == "string" and v:find("%<", 1, true) then
        -- nvim-orgmode expands %<...> date formats in the target path
        o.target =
          raw("function()\n  return ((" .. quote(v) .. '):gsub("%%<(.-)>", function(f) return os.date(f) end))\nend')
      else
        o.target = v
      end
    elseif k == "datetree" then
      if v == true then
        o.datetree = true
      elseif type(v) == "table" then
        o.datetree = true
        if v.time_prompt then
          o.time_prompt = true
        end
        if v.tree_type and DATETREE_TYPES[v.tree_type] then
          if v.tree_type ~= "day" then
            o.tree_type = v.tree_type
          end
        elseif v.tree_type then
          warn(
            'datetree tree_type "'
              .. tostring(v.tree_type)
              .. '": a custom tree is a function(date) returning { { title, compare } ... } in `tree_type`'
          )
        end
        if v.reversed then
          o.datetree = { reversed = true }
        end
      elseif v ~= nil and v ~= false then
        o.datetree = v
      end
    elseif k == "properties" and type(v) == "table" then
      for pk, pv in pairs(v) do
        if pk == "empty_lines" and type(pv) == "number" then
          o.empty_lines = pv
        elseif pk == "empty_lines" and type(pv) == "table" then
          o.empty_lines_before = pv.before
          o.empty_lines_after = pv.after
        else
          warn("properties." .. tostring(pk) .. " has no equivalent")
        end
      end
    else
      warn("`" .. tostring(k) .. "` has no equivalent and was left out")
    end
  end
  out[key] = o
end

local function convert_templates(v, res, path)
  if type(v) ~= "table" then
    return v
  end
  local out = {}
  for k, t in pairs(v) do
    convert_template(res, out, k, t, path)
  end
  return out
end

--- nvim-orgmode filter presets ("work-home", the agenda `/` prompt
--- syntax) as org.nvim's lists ({ "+work", "-home" }).
---@param v any
---@return any
local function convert_preset(v)
  if type(v) ~= "string" then
    return v
  end
  local out = {}
  for sign, word in v:gmatch("([+-]?)([^+-]+)") do
    out[#out + 1] = (sign == "" and "+" or sign) .. vim.trim(word)
  end
  return out
end

local SORTING = {}
for _, s in ipairs({
  "time-up",
  "time-down",
  "priority-up",
  "priority-down",
  "tag-up",
  "tag-down",
  "todo-state-up",
  "todo-state-down",
  "category-up",
  "category-down",
  "category-keep",
}) do
  SORTING[s] = true
end

--- A list of sorting strategies; unknown ones (clocked-up/-down) dropped.
local function convert_strategy(list, res, path)
  if type(list) ~= "table" then
    return list
  end
  local out = {}
  for _, s in ipairs(list) do
    if SORTING[s] then
      out[#out + 1] = s
    else
      note(res, path, 'sorting strategy "' .. tostring(s) .. '" has no equivalent and was left out')
    end
  end
  return out
end

local function convert_sorting(v, res, path)
  if type(v) ~= "table" then
    return v
  end
  local out = {}
  for view, list in pairs(v) do
    out[view] = convert_strategy(list, res, path)
  end
  return out
end

--- Block option names of nvim-orgmode custom commands.
local BLOCK_KEYS = {
  type = "type",
  match = "match",
  org_agenda_overriding_header = "header",
  org_agenda_files = "files",
  org_agenda_tag_filter_preset = "tag_filter_preset",
  org_agenda_category_filter_preset = "category_filter_preset",
  org_agenda_sorting_strategy = "sorting",
  org_agenda_remove_tags = "remove_tags",
  org_agenda_span = "span",
  org_agenda_start_on_weekday = "start_on_weekday",
  org_agenda_start_day = "start_day",
  org_agenda_todo_ignore_scheduled = "todo_ignore_scheduled",
  org_agenda_todo_ignore_deadlines = "todo_ignore_deadlines",
}

local function convert_block(b, res, path)
  local o = {}
  for k, v in pairs(b) do
    local to = BLOCK_KEYS[k]
    if to == "files" and type(v) == "string" then
      v = { v }
    elseif to == "tag_filter_preset" or to == "category_filter_preset" then
      v = convert_preset(v)
    elseif to == "sorting" then
      v = convert_strategy(v, res, path)
    end
    if to then
      o[to] = v
    elseif type(k) == "string" and k:match("^org_agenda_") then
      -- org.nvim also takes Emacs-style names in blocks
      o[k:gsub("^org_agenda_", "")] = v
      note(res, path, k .. " was renamed to " .. k:gsub("^org_agenda_", "") .. "; check it is an `agenda` option")
    else
      o[k] = v
      note(res, path, "`" .. tostring(k) .. "` is not an nvim-orgmode block option; kept as is")
    end
  end
  if o.type == "tags_todo" and (o.todo_ignore_scheduled ~= nil or o.todo_ignore_deadlines ~= nil) then
    -- nvim-orgmode applies them to tags_todo blocks; Emacs (and org.nvim)
    -- only with org-agenda-tags-todo-honor-ignore-options
    o.tags_todo_honor_ignore_options = true
  end
  return o
end

local function convert_custom_commands(v, res, path)
  if type(v) ~= "table" then
    return v
  end
  local out = {}
  for key, cmd in pairs(v) do
    local cpath = path .. "." .. key
    if type(cmd) ~= "table" then
      out[key] = cmd
    else
      local o = {}
      for k, x in pairs(cmd) do
        if k == "types" and type(x) == "table" then
          o.types = {}
          for i, b in ipairs(x) do
            o.types[i] = type(b) == "table" and convert_block(b, res, cpath) or b
          end
        elseif k == "description" then
          o.description = x
        else
          o[k] = x
          note(res, cpath, "`" .. tostring(k) .. "` is not an nvim-orgmode command field; kept as is")
        end
      end
      out[key] = o
    end
  end
  return out
end

local function convert_time_grid(v, res, path)
  if type(v) ~= "table" then
    return v
  end
  local out = {}
  for k, x in pairs(v) do
    if k == "type" or k == "times" then
      out[k] = x
    elseif k == "time_separator" and type(x) == "string" then
      -- nvim-orgmode puts a space on each side of it
      out.separator = " " .. x .. " "
    elseif k == "time_label" then
      out.time_string = x
    else
      note(res, path, "time grid `" .. tostring(k) .. "` has no equivalent")
    end
  end
  return out
end

--- nvim-orgmode's `win_split_mode` (agenda and capture windows) as the
--- `window` of org.nvim's agenda and capture.
local function split_mode(v)
  if v == "horizontal" or v == "auto" then
    return "split", v == "auto" and '"auto" has no equivalent; using "split" (or set "vsplit")' or nil
  elseif v == "vertical" then
    return "vsplit"
  elseif v == "float" then
    return "float"
  elseif type(v) == "table" and v[1] == "float" then
    return "float", "the float size (" .. tostring(v[2]) .. ") has no equivalent"
  elseif type(v) == "string" then
    if v:find("tab") then
      return "tab"
    elseif v:find("vs") or v:find("vert") or v:find("vnew") then
      return "vsplit", 'from the command "' .. v .. '"'
    elseif v:find("split") or v:find("new") then
      return "split", 'from the command "' .. v .. '"'
    end
  end
  return nil
end

--- Options whose value converts to more than one place, or needs the
--- result: function(value, res, name).
local SPECIAL = {}

SPECIAL.win_split_mode = function(v, res, name)
  local mode, why = split_mode(v)
  if not mode then
    todo(res, name, "a function or command; agenda.window and capture.window take a window kind", v)
    return
  end
  put(res, "agenda.window", mode)
  put(res, "capture.window", mode)
  if why then
    note(res, "agenda.window", why)
  end
  res.converted = res.converted + 1
end

SPECIAL.org_src_window_setup = function(v, res, name)
  local mode, why = split_mode(v)
  if not mode then
    todo(res, name, "win_split_mode sets the window of edit buffers: float, split, vsplit, tab or current", v)
    return
  end
  put(res, "win_split_mode", mode)
  if why then
    note(res, "win_split_mode", why)
  end
  res.converted = res.converted + 1
end

SPECIAL.org_time_stamp_rounding_minutes = function(v, res)
  put(res, "time_stamp_rounding_minutes", { 0, v })
  note(res, "time_stamp_rounding_minutes", "{ rounding of the time in date prompts, minutes <S-Up>/<S-Down> step }")
  res.converted = res.converted + 1
end

SPECIAL.org_agenda_show_future_repeats = function(v, res)
  if type(v) == "number" then
    put(res, "agenda.show_future_repeats", true)
    note(
      res,
      "agenda.show_future_repeats",
      "a number of repeats (" .. v .. ') has no equivalent: true, false or "next"'
    )
  else
    put(res, "agenda.show_future_repeats", v)
  end
  res.converted = res.converted + 1
end

SPECIAL.org_startup_folded = function(v, res, name)
  if v == "inherit" then
    todo(res, name, "\"inherit\" (Neovim's foldlevel) has no equivalent; startup_folded takes Emacs's values", v)
    return
  end
  put(res, "startup_folded", v)
  res.converted = res.converted + 1
end

SPECIAL.org_highlight_latex_and_related = function(v, res)
  if v == "native" then
    put(res, "ui.highlight_latex_and_related", { "native" })
  elseif v == "entities" then
    put(res, "ui.highlight_latex_and_related", { "latex", "entities" })
  elseif v ~= nil then
    put(res, "ui.highlight_latex_and_related", v)
  end
  res.converted = res.converted + 1
end

SPECIAL.org_indent_mode_turns_on_hiding_stars = function(v, res, name)
  if v == false then
    todo(res, name, "indent mode always hides leading stars, as in Emacs", v)
  end
end

SPECIAL.org_babel_default_header_args = function(v, res)
  if type(v) ~= "table" then
    return
  end
  local out = {}
  for k, x in pairs(v) do
    out[(tostring(k):gsub("^:", ""))] = x
  end
  put(res, "babel.default_header_args", out)
  res.converted = res.converted + 1
end

SPECIAL.org_agenda_files = function(v, res)
  if v == "" or v == nil then
    return
  end
  put(res, "agenda_files", type(v) == "string" and { v } or v)
  res.converted = res.converted + 1
end

SPECIAL.org_default_notes_file = function(v, res)
  if v == "" or v == nil then
    return
  end
  put(res, "default_notes_file", v)
  res.converted = res.converted + 1
end

SPECIAL.calendar_week_start_day = function(v, res, name)
  if v ~= 1 then
    todo(res, name, "the date prompt calendar always starts on Monday", v)
  end
end

SPECIAL.emacs_config = function(v, res, name)
  if type(v) ~= "table" then
    return
  end
  if v.executable_path and v.executable_path ~= "emacs" then
    put(res, "babel.emacs_lisp.command", v.executable_path)
    note(res, "babel.emacs_lisp", "export doesn't need Emacs; this Emacs runs Emacs Lisp (src blocks, %(sexp))")
    res.converted = res.converted + 1
  end
  if v.config_path then
    todo(res, name .. ".config_path", "export is built in and doesn't load an Emacs config", v.config_path)
  end
end

SPECIAL.notifications = function(v, res, name)
  if type(v) ~= "table" then
    return
  end
  for k, x in pairs(v) do
    local full = name .. "." .. k
    if k == "enabled" then
      put(res, "notifications.enabled", x)
      res.converted = res.converted + 1
    elseif k == "reminder_time" then
      put(res, "notifications.reminder_time", type(x) == "number" and { x } or x)
      res.converted = res.converted + 1
    elseif k == "notifier" then
      put(res, "notifications.notifier", x)
      note(
        res,
        "notifications.notifier",
        "org.nvim calls it once per reminder with { title, body, item, minutes }, not with a list of tasks"
      )
      res.converted = res.converted + 1
    elseif k == "cron_enabled" or k == "cron_notifier" then
      if x then
        todo(res, full, "reminders run inside Neovim (`:Org notifications_start`); there is no cron mode", x)
      end
    elseif k == "deadline_reminder" or k == "scheduled_reminder" then
      if x == false then
        todo(res, full, "reminders are given for both timed deadlines and scheduled entries", x)
      end
    elseif k == "repeater_reminder_time" or k == "deadline_warning_reminder_time" then
      if x then
        todo(res, full, "no equivalent", x)
      end
    else
      todo(res, full, "not an nvim-orgmode option", x)
    end
  end
end

SPECIAL.hyperlinks = function(v, res, name)
  if type(v) == "table" and v.sources and next(v.sources) then
    todo(
      res,
      name .. ".sources",
      "custom link types go in links.types: { name = { follow = fn(path), complete = fn() } } (:h org-links)",
      v.sources
    )
  end
end

SPECIAL.ui = function(v, res, name)
  if type(v) ~= "table" then
    return
  end
  local folds = type(v.folds) == "table" and v.folds or {}
  if folds.colored == false then
    todo(res, name .. ".folds.colored", "folded headlines keep their colours", false)
  end
  local menu = type(v.menu) == "table" and v.menu or {}
  if menu.handler then
    todo(
      res,
      name .. ".menu.handler",
      "menus are built in; ui.menus = false uses vim.ui.select (:h org-key-menus)",
      "function"
    )
  end
  local input = type(v.input) == "table" and v.input or {}
  if input.use_vim_ui ~= nil then
    todo(res, name .. ".input.use_vim_ui", "prompts use vim.ui.input / vim.ui.select already", input.use_vim_ui)
  end
  local agenda = type(v.agenda) == "table" and v.agenda or {}
  if agenda.preview_window then
    todo(
      res,
      name .. ".agenda.preview_window",
      "the agenda shows an entry in a normal window (<Space>)",
      agenda.preview_window
    )
  end
end

--- Plain renames: nvim-orgmode name -> org.nvim path, or a function
--- (value, res, path) -> value for a converted value.
local RENAMES = {
  org_todo_keywords = { "todo_keywords", convert_keywords },
  org_todo_repeat_to_state = "todo_repeat_to_state",
  org_todo_keyword_faces = "ui.todo_keyword_faces",
  org_deadline_warning_days = "deadline_warning_days",
  org_agenda_span = "agenda.span",
  org_agenda_start_on_weekday = "agenda.start_on_weekday",
  org_agenda_start_day = "agenda.start_day",
  org_capture_templates = { "capture.templates", convert_templates },
  org_agenda_skip_scheduled_if_done = "agenda.skip_scheduled_if_done",
  org_agenda_skip_deadline_if_done = "agenda.skip_deadline_if_done",
  org_agenda_text_search_extra_files = "agenda.text_search_extra_files",
  org_agenda_custom_commands = { "agenda.custom_commands", convert_custom_commands },
  org_agenda_block_separator = "agenda.block_separator",
  org_agenda_sorting_strategy = { "agenda.sorting", convert_sorting },
  org_agenda_remove_tags = "agenda.remove_tags",
  org_agenda_time_grid = { "agenda.time_grid", convert_time_grid },
  org_agenda_use_time_grid = "agenda.time_grid.enabled",
  org_agenda_current_time_string = "agenda.current_time_string",
  org_priority_highest = "priority_highest",
  org_priority_default = "priority_default",
  org_priority_lowest = "priority_lowest",
  org_priority_start_cycle_with_default = "priority_start_cycle_with_default",
  org_archive_location = "archive_location",
  org_tags_column = "tags_column",
  org_use_tag_inheritance = "use_tag_inheritance",
  org_tags_exclude_from_inheritance = "tags_exclude_from_inheritance",
  org_hide_leading_stars = "ui.hide_leading_stars",
  org_hide_emphasis_markers = "ui.hide_emphasis_markers",
  org_ellipsis = "ellipsis",
  org_log_done = "log_done",
  org_log_repeat = "log_repeat",
  org_log_into_drawer = "log_into_drawer",
  org_adapt_indentation = "adapt_indentation",
  org_startup_indented = "ui.indent_mode",
  org_indent_mode_turns_off_org_adapt_indentation = "ui.indent_mode_turns_off_adapt_indentation",
  org_cycle_separator_lines = "cycle_separator_lines",
  org_blank_before_new_entry = "blank_before_new_entry",
  org_edit_src_content_indentation = "edit_src_content_indentation",
  org_edit_src_filetype_map = "src_lang_modes",
  org_id_ts_format = "id.ts_format",
  org_id_method = "id.method",
  org_id_prefix = "id.prefix",
  org_id_link_to_org_use_id = "links.use_id",
  org_use_property_inheritance = "use_property_inheritance",
  win_border = "win_border",
}
M.RENAMES = RENAMES

--- Options with no equivalent, and why.
local NONE = {
  org_agenda_min_height = "the agenda window's height is between agenda.window_frame_fractions of the editor's",
  org_agenda_hide_empty_blocks = "empty blocks of custom commands are always shown, as in Emacs",
  org_custom_exports = "export is built in (:Org export): HTML, LaTeX/PDF, Markdown, ODT, ... and pandoc formats",
  calendar = "the date prompt calendar has no options for its minute steps",
}

--- Options org.nvim doesn't need.
local NOT_NEEDED = {
  org_id_uuid_program = true, -- UUIDs are made in Lua
}

M.SPECIAL = SPECIAL
M.NONE = NONE

-- Mappings ----------------------------------------------------------------------

--- nvim-orgmode mapping (section.name) -> { org.nvim section, action } or
--- a string: why there is no equivalent.
local MAPS = {
  global = {
    org_agenda = { "global", "agenda" },
    org_capture = { "global", "capture" },
  },
  agenda = {
    org_agenda_later = { "agenda", "later" },
    org_agenda_earlier = { "agenda", "earlier" },
    org_agenda_goto_today = { "agenda", "today" },
    org_agenda_day_view = { "agenda", "day_view" },
    org_agenda_week_view = { "agenda", "week_view" },
    org_agenda_month_view = { "agenda", "month_view" },
    org_agenda_year_view = { "agenda", "year_view" },
    org_agenda_quit = { "agenda", "quit" },
    org_agenda_switch_to = { "agenda", "switch_to" },
    org_agenda_goto = { "agenda", "goto" },
    org_agenda_goto_date = { "agenda", "goto_date" },
    org_agenda_redo = { "agenda", "redo" },
    org_agenda_todo = { "agenda", "todo" },
    org_agenda_open_at_point = { "agenda", "open_link" },
    org_agenda_clock_goto = { "agenda", "clock_goto" },
    org_agenda_set_effort = { "agenda", "set_effort" },
    org_agenda_clock_in = { "agenda", "clock_in" },
    org_agenda_clock_out = { "agenda", "clock_out" },
    org_agenda_clock_cancel = { "agenda", "clock_cancel" },
    org_agenda_clockreport_mode = { "agenda", "clockreport_mode" },
    org_agenda_priority = { "agenda", "priority" },
    org_agenda_priority_up = { "agenda", "priority_up" },
    org_agenda_priority_down = { "agenda", "priority_down" },
    org_agenda_archive = { "agenda", "archive" },
    org_agenda_toggle_archive_tag = { "agenda", "toggle_archive_tag" },
    org_agenda_set_tags = { "agenda", "set_tags" },
    org_agenda_deadline = { "agenda", "deadline" },
    org_agenda_schedule = { "agenda", "schedule" },
    org_agenda_filter = { "agenda", "filter" },
    org_agenda_refile = { "agenda", "refile" },
    org_agenda_add_note = { "agenda", "add_note" },
    org_agenda_preview = { "agenda", "show" },
    org_agenda_show_help = { "agenda", "help" },
  },
  capture = {
    org_capture_finalize = { "capture", "finalize" },
    org_capture_refile = { "capture", "refile" },
    org_capture_kill = { "capture", "kill" },
    org_capture_show_help = "g? lists the keys in every org buffer, capture buffers included",
  },
  note = {
    org_note_finalize = "the note buffer uses <C-c><C-c> (store) and <C-c><C-k> (cancel), as in Emacs",
    org_note_kill = "the note buffer uses <C-c><C-c> (store) and <C-c><C-k> (cancel), as in Emacs",
  },
  org = {
    org_refile = { "org", "refile" },
    org_timestamp_up_day = { "org", "shift_up" },
    org_timestamp_down_day = { "org", "shift_down" },
    org_timestamp_up = { "org", "increment" },
    org_timestamp_down = { "org", "decrement" },
    org_change_date = { "org", "timestamp" },
    org_priority = { "org", "priority" },
    org_priority_up = { "org", "shift_up" },
    org_priority_down = { "org", "shift_down" },
    org_todo = { "org", "todo_next" },
    org_todo_prev = { "org", "todo_prev" },
    org_toggle_checkbox = { "org", "toggle_checkbox" },
    org_toggle_heading = { "org", "toggle_heading" },
    org_open_at_point = { "org", "open_at_point" },
    org_edit_special = { "org", "edit_special" },
    org_add_note = { "org", "add_note" },
    org_cycle = { "org", "cycle" },
    org_global_cycle = { "org", "global_cycle" },
    org_archive_subtree = { "org", "archive_subtree" },
    org_set_tags_command = { "org", "set_tags" },
    org_toggle_archive_tag = { "org", "toggle_archive_tag" },
    org_do_promote = { "org", "promote_heading" },
    org_do_demote = { "org", "demote_heading" },
    org_promote_subtree = { "org", "promote_subtree" },
    org_demote_subtree = { "org", "demote_subtree" },
    org_meta_return = { "org", "meta_return" },
    org_return = "<CR> in Insert mode moves to the next table row; elsewhere it is Vim's",
    org_insert_heading_respect_content = { "org", "insert_heading" },
    org_insert_todo_heading = { "org", "meta_shift_return" },
    org_insert_todo_heading_respect_content = { "org", "insert_todo_heading" },
    org_move_subtree_up = { "org", "move_subtree_up" },
    org_move_subtree_down = { "org", "move_subtree_down" },
    org_export = { "org", "export" },
    org_next_visible_heading = { "org", "next_heading" },
    org_previous_visible_heading = { "org", "prev_heading" },
    org_forward_heading_same_level = { "org", "next_sibling" },
    org_backward_heading_same_level = { "org", "prev_sibling" },
    outline_up_heading = { "org", "goto_parent" },
    org_deadline = { "org", "deadline" },
    org_schedule = { "org", "schedule" },
    org_time_stamp = { "org", "timestamp" },
    org_time_stamp_inactive = { "org", "timestamp_inactive" },
    org_toggle_timestamp_type = { "org", "toggle_timestamp_type" },
    org_insert_link = { "org", "insert_link" },
    org_store_link = { "org", "store_link" },
    org_clock_in = { "org", "clock_in" },
    org_clock_out = { "org", "clock_out" },
    org_clock_cancel = { "org", "clock_cancel" },
    org_clock_goto = { "org", "clock_goto" },
    org_set_effort = { "org", "set_effort" },
    org_show_help = { "org", "help" },
    org_babel_tangle = { "org", "babel_tangle" },
  },
  edit_src = {
    org_edit_src_abort = { "edit_src", "abort" },
    org_edit_src_save = ":w in the edit buffer writes the block back",
    org_edit_src_save_exit = { "edit_src", "save_exit" },
    org_edit_src_show_help = "g? lists the keys",
  },
  text_objects = {
    inner_heading = { "text_objects", "inner_heading" },
    around_heading = { "text_objects", "around_heading" },
    inner_subtree = { "text_objects", "inner_subtree" },
    around_subtree = { "text_objects", "around_subtree" },
    inner_heading_from_root = "no text objects from the root heading",
    around_heading_from_root = "no text objects from the root heading",
    inner_subtree_from_root = "no text objects from the root heading",
    around_subtree_from_root = "no text objects from the root heading",
  },
}
M.MAPS = MAPS

--- nvim-orgmode's default keys, for the suggestions (from its
--- lua/orgmode/config/defaults.lua).
local THEIR_KEYS = {
  global = { org_agenda = "<prefix>a", org_capture = "<prefix>c" },
  agenda = {
    org_agenda_goto_date = "J",
    org_agenda_open_at_point = "<prefix>o",
    org_agenda_clock_goto = "<prefix>xj",
    org_agenda_set_effort = "<prefix>xe",
    org_agenda_clockreport_mode = "R",
    org_agenda_priority = "<prefix>,",
    org_agenda_archive = "<prefix>$",
    org_agenda_toggle_archive_tag = "<prefix>A",
    org_agenda_set_tags = "<prefix>t",
    org_agenda_deadline = "<prefix>id",
    org_agenda_schedule = "<prefix>is",
    org_agenda_refile = "<prefix>r",
    org_agenda_add_note = "<prefix>na",
    org_agenda_preview = "K",
  },
  org = {
    org_change_date = "cid",
    org_priority_up = "ciR",
    org_priority_down = "cir",
    org_add_note = "<prefix>na",
    org_toggle_archive_tag = "<prefix>A",
    org_meta_return = "<Leader><CR>",
    org_insert_todo_heading = "<prefix>iT",
    org_next_visible_heading = "}",
    org_previous_visible_heading = "{",
    org_forward_heading_same_level = "]]",
    org_backward_heading_same_level = "[[",
    org_deadline = "<prefix>id",
    org_schedule = "<prefix>is",
    org_toggle_timestamp_type = "<prefix>d!",
  },
}
M.THEIR_KEYS = THEIR_KEYS

--- `lhs` written the same way for comparing ("<Leader>" = "<leader>").
local function norm_lhs(lhs, prefix)
  lhs = lhs:gsub("<prefix>", function()
    return prefix
  end)
  return (lhs:gsub("<[^>]+>", string.lower))
end

--- The keys of a normalized lhs ("<leader>", "o", "x").
local function keys_of(lhs)
  local out, i = {}, 1
  while i <= #lhs do
    local special = lhs:match("^<[^<>]+>", i)
    local k = special or lhs:sub(i, i)
    out[#out + 1] = k
    i = i + #k
  end
  return out
end

--- Does `lhs` start with the keys of `start`?
local function starts_with_keys(lhs, start)
  local a, b = keys_of(lhs), keys_of(start)
  if #b > #a then
    return false
  end
  for i = 1, #b do
    if a[i] ~= b[i] then
      return false
    end
  end
  return true
end

--- The org.nvim defaults of a mapping section: normalized lhs -> action.
local function default_keys(section, prefix)
  local defaults = require("org.config").defaults.mappings[section]
  if type(defaults) ~= "table" then
    defaults = {}
  end
  local out = {}
  for name, value in pairs(defaults) do
    local list = type(value) == "table" and value or { value }
    for _, lhs in ipairs(list) do
      if type(lhs) == "string" then
        out[norm_lhs(lhs, prefix)] = name
      end
    end
  end
  return out
end

--- A mapping value without nvim-orgmode's `desc`.
local function lhs_value(v)
  if type(v) ~= "table" then
    return v
  end
  local out = {}
  for _, lhs in ipairs(v) do
    out[#out + 1] = lhs
  end
  if #out == 1 then
    return out[1]
  end
  return out
end

local function convert_mappings(v, res, name)
  if type(v) ~= "table" then
    return
  end
  local prefix = type(v.prefix) == "string" and v.prefix or "<Leader>o"
  if v.disable_all ~= nil then
    put(res, "mappings.disable_all", v.disable_all)
    res.converted = res.converted + 1
  end
  if v.prefix ~= nil then
    put(res, "mappings.prefix", v.prefix)
    res.converted = res.converted + 1
  end
  if v.org_return_uses_meta_return then
    todo(
      res,
      name .. ".org_return_uses_meta_return",
      "<M-CR> in Insert mode adds a heading / item / row (mappings.org_insert.meta_return)",
      true
    )
  end
  local set_by_user = {}
  for section, maps in pairs(v) do
    if type(maps) == "table" and MAPS[section] then
      for their, value in pairs(maps) do
        local to = MAPS[section][their]
        local full = name .. "." .. section .. "." .. their
        set_by_user[section .. "." .. their] = true
        if type(to) == "table" then
          local path = "mappings." .. to[1] .. "." .. to[2]
          local lhs = lhs_value(value)
          put(res, path, lhs)
          res.converted = res.converted + 1
          if type(value) == "table" and value.desc then
            note(res, path, "`desc` has no equivalent: org.nvim names the keys after their action")
          end
          -- the same key bound to another action by default
          local taken = default_keys(to[1], prefix)
          for _, l in ipairs(type(lhs) == "table" and lhs or { lhs }) do
            local other = type(l) == "string" and taken[norm_lhs(l, prefix)]
            if other and other ~= to[2] then
              note(
                res,
                path,
                string.format(
                  "%s is also org.nvim's default key for %s; set mappings.%s.%s to another key or false",
                  l,
                  other,
                  to[1],
                  other
                )
              )
            end
          end
        elseif type(to) == "string" then
          if value then
            todo(res, full, to, value)
          end
        else
          todo(res, full, "not an nvim-orgmode mapping", value)
        end
      end
    elseif section ~= "disable_all" and section ~= "prefix" and section ~= "org_return_uses_meta_return" then
      todo(res, name .. "." .. tostring(section), "not an nvim-orgmode mapping section", maps)
    end
  end
  return set_by_user
end

--- Suggestions keeping nvim-orgmode's default keys that differ, for the
--- mappings the user didn't set.
local function mapping_suggestions(res, set_by_user, prefix)
  local defaults = require("org.config").defaults.mappings
  -- section -> { action = lhs } suggested
  local suggested = {}
  for section, keys in pairs(THEIR_KEYS) do
    for their, lhs in pairs(keys) do
      local to = MAPS[section][their]
      if type(to) == "table" and not set_by_user[section .. "." .. their] then
        local cur = defaults[to[1]][to[2]]
        local list = type(cur) == "table" and cur or { cur }
        if not vim.tbl_contains(list, lhs) then
          suggested[to[1]] = suggested[to[1]] or {}
          suggested[to[1]][to[2]] = lhs
        end
      end
    end
  end
  for section, actions in pairs(suggested) do
    local taken = default_keys(section, prefix)
    res.mapping_defaults[section] = {}
    for action, lhs in pairs(actions) do
      local cur = defaults[section][action]
      local list = type(cur) == "table" and cur or { cur }
      local line = string.format(
        "%s = %s, -- org.nvim: %s",
        key_src(action),
        quote(lhs),
        cur and table.concat(vim.tbl_map(tostring, list), " ") or "no key"
      )
      -- the key is another action's default, and that one keeps it
      local n = norm_lhs(lhs, prefix)
      local other = taken[n]
      if other and other ~= action and not actions[other] then
        line = line .. "; also the key of " .. other
      else
        -- one key starts the other: Vim waits for 'timeoutlen'
        local over = {}
        for k, owner in pairs(taken) do
          if owner ~= action and not actions[owner] and (starts_with_keys(k, n) or starts_with_keys(n, k)) then
            over[#over + 1] = owner
          end
        end
        table.sort(over)
        if #over > 0 then
          line = line .. "; overlaps the key of " .. table.concat(over, ", ")
        end
      end
      table.insert(res.mapping_defaults[section], line)
    end
  end
  for _, lines in pairs(res.mapping_defaults) do
    table.sort(lines)
  end
end

SPECIAL.mappings = function(v, res, name)
  res._set_maps = convert_mappings(v, res, name) or {}
end

--- nvim-orgmode defaults that differ from org.nvim's: option, the
--- setting keeping nvim-orgmode's behaviour.
local THEIR_DEFAULTS = {
  { "org_adapt_indentation", "adapt_indentation = true," },
  { "org_startup_folded", 'startup_folded = "overview",' },
  { "org_log_done", 'log_done = "time",' },
  { "org_tags_column", "tags_column = -80," },
  { "org_blank_before_new_entry", "blank_before_new_entry = { heading = true, plain_list_item = false }," },
  { "org_edit_src_content_indentation", "edit_src_content_indentation = 0," },
  { "org_agenda_block_separator", 'agenda = { block_separator = "-" },' },
  {
    "org_agenda_sorting_strategy",
    'agenda = { sorting = { agenda = { "time-up", "priority-down", "category-keep" } } },',
  },
  { "win_border", 'win_border = "single",' },
}

-- Converting --------------------------------------------------------------------

--- Convert an nvim-orgmode options table.
---@param opts table nvim-orgmode's setup() options
---@return org.migrate.Result
function M.convert(opts)
  local res = new_result()
  local names = vim.tbl_keys(opts)
  table.sort(names, function(a, b)
    return tostring(a) < tostring(b)
  end)
  for _, name in ipairs(names) do
    local v = opts[name]
    local r = RENAMES[name]
    if SPECIAL[name] then
      SPECIAL[name](v, res, name)
    elseif r then
      local path, fn = r, nil
      if type(r) == "table" then
        path, fn = r[1], r[2]
      end
      if fn then
        v = fn(v, res, path)
      end
      put(res, path, v)
      res.converted = res.converted + 1
    elseif NONE[name] then
      todo(res, name, NONE[name], v)
    elseif not NOT_NEEDED[name] then
      todo(res, tostring(name), "not an nvim-orgmode option", v)
    end
  end
  for _, d in ipairs(THEIR_DEFAULTS) do
    if opts[d[1]] == nil then
      res.defaults[#res.defaults + 1] = d[2]
    end
  end
  local maps = type(opts.mappings) == "table" and opts.mappings or {}
  mapping_suggestions(res, res._set_maps or {}, type(maps.prefix) == "string" and maps.prefix or "<Leader>o")
  res._set_maps = nil
  return res
end

-- Writing -------------------------------------------------------------------------

---@class org.migrate.Writer
---@field lines string[]
---@field sources table<string, string[]>
---@field res org.migrate.Result

--- Is `t` a list of strings / numbers / booleans, short enough for one line?
local function inline_list(t)
  if not vim.islist(t) or is_raw(t) then
    return nil
  end
  local parts = {}
  for _, v in ipairs(t) do
    if type(v) == "string" then
      parts[#parts + 1] = quote(v)
    elseif type(v) == "number" or type(v) == "boolean" then
      parts[#parts + 1] = tostring(v)
    else
      return nil
    end
  end
  local s = #parts == 0 and "{}" or "{ " .. table.concat(parts, ", ") .. " }"
  return #s <= 80 and s or nil
end

local function sorted_keys(t)
  local keys = {}
  for k in pairs(t) do
    if not (type(k) == "number" and k >= 1 and k <= #t and k % 1 == 0) then
      keys[#keys + 1] = k
    end
  end
  table.sort(keys, function(a, b)
    if type(a) ~= type(b) then
      return type(a) == "number"
    end
    return a < b
  end)
  return keys
end

--- A `-- TODO: text` comment at `indent`, wrapped at 80 columns.
---@param indent string
---@param text string
---@return string[]
local function todo_comment(indent, text)
  local out, line = {}, indent .. "-- TODO:"
  for word in text:gmatch("%S+") do
    if #line + 1 + #word > 80 and not line:match("^%s*%-%-%s*%S*:?$") then
      out[#out + 1] = line
      line = indent .. "--      "
    end
    line = line .. " " .. word
  end
  out[#out + 1] = line
  return out
end

--- Write `value` after `head` ("key = ") at `indent`.
---@param w org.migrate.Writer
---@param indent string
---@param head string
---@param value any
---@param path string
local function write_value(w, indent, head, value, path)
  for _, n in ipairs(w.res.notes[path] or {}) do
    vim.list_extend(w.lines, todo_comment(indent, n))
  end
  local t = type(value)
  if t == "string" then
    table.insert(w.lines, indent .. head .. quote(value) .. ",")
  elseif t == "number" or t == "boolean" or t == "nil" then
    table.insert(w.lines, indent .. head .. tostring(value) .. ",")
  elseif t == "function" then
    local text = function_text(value, w.sources)
    if text then
      table.insert(w.lines, indent .. "-- TODO: copied from " .. where(value) .. "; check it works with org.nvim")
      table.insert(w.lines, indent .. head .. text[1])
      for i = 2, #text do
        table.insert(w.lines, indent .. text[i])
      end
      w.lines[#w.lines] = w.lines[#w.lines] .. ","
    else
      table.insert(w.lines, indent .. "-- TODO: a function in your config (" .. where(value) .. "); copy it here")
      table.insert(w.lines, indent .. head .. "nil,")
    end
  elseif is_raw(value) then
    local code = vim.split(value.code, "\n", { plain = true })
    table.insert(w.lines, indent .. head .. code[1])
    for i = 2, #code do
      table.insert(w.lines, indent .. code[i])
    end
    w.lines[#w.lines] = w.lines[#w.lines] .. ","
  elseif t == "table" then
    local one = inline_list(value)
    if one then
      table.insert(w.lines, indent .. head .. one .. ",")
      return
    end
    table.insert(w.lines, indent .. head .. "{")
    local inner = indent .. "  "
    for i, v in ipairs(value) do
      write_value(w, inner, "", v, path .. "." .. i)
    end
    for _, k in ipairs(sorted_keys(value)) do
      write_value(w, inner, key_src(k) .. " = ", value[k], path .. "." .. tostring(k))
    end
    table.insert(w.lines, indent .. "},")
  else
    table.insert(w.lines, indent .. "-- TODO: a " .. t .. " value can't be written here")
    table.insert(w.lines, indent .. head .. "nil,")
  end
end

--- `value` as Lua source lines, commented out.
local function commented(w, indent, name, value)
  local sub = { lines = {}, sources = w.sources, res = { notes = {} } }
  write_value(sub, "", key_src(name) .. " = ", value, "")
  for _, l in ipairs(sub.lines) do
    table.insert(w.lines, indent .. "-- " .. l)
  end
end

--- The converted setup as Lua source lines.
---@param res org.migrate.Result
---@param opts? { source?: string, sources?: table<string, string[]> }
---@return string[]
function M.render(res, opts)
  opts = opts or {}
  local w = { lines = {}, sources = opts.sources or {}, res = res }
  local function add(l)
    table.insert(w.lines, l)
  end
  add("-- org.nvim setup converted from nvim-orgmode by :Org migrate_config")
  if opts.source then
    -- (a full path with ~ for the home directory)
    local abs = opts.source:match("^/") or opts.source:match("^%a:[/\\]")
    add("-- from " .. (abs and vim.fn.fnamemodify(opts.source, ":~") or opts.source))
  end
  add("-- Review the TODO comments. :h org-migrate-nvim-orgmode explains each option.")
  add('require("org").setup({')
  -- a directory for relative paths (capture targets, ...)
  if res.out.org_directory == nil then
    add("  -- org.nvim resolves relative paths (capture targets, ...) from here")
    add('  org_directory = "~/org",')
  end
  for _, k in ipairs(sorted_keys(res.out)) do
    write_value(w, "  ", key_src(k) .. " = ", res.out[k], tostring(k))
  end
  if #res.todos > 0 then
    add("")
    add("  -- nvim-orgmode options without an org.nvim equivalent:")
    for _, t in ipairs(res.todos) do
      vim.list_extend(w.lines, todo_comment("  ", t.name .. ": " .. t.text))
      if t.value ~= nil then
        commented(w, "  ", t.name:match("[^.]+$"), t.value)
      end
    end
  end
  local has_maps = next(res.mapping_defaults) ~= nil
  if #res.defaults > 0 or has_maps then
    add("")
    add("  -- nvim-orgmode's defaults that differ from org.nvim's. Uncomment a line")
    add("  -- to keep nvim-orgmode's behaviour (merge tables you uncomment with the")
    add("  -- ones above):")
    for _, d in ipairs(res.defaults) do
      add("  -- " .. d)
    end
    if has_maps then
      add("  -- mappings = {")
      for _, section in ipairs(sorted_keys(res.mapping_defaults)) do
        add("  --   " .. section .. " = {")
        for _, l in ipairs(res.mapping_defaults[section]) do
          add("  --     " .. l)
        end
        add("  --   },")
      end
      add("  -- },")
    end
  end
  add("})")
  return w.lines
end

-- Reading the nvim-orgmode setup -------------------------------------------------

--- A value that accepts any use: indexing, calling, assigning.
local inert
inert = setmetatable({}, {
  __index = function()
    return inert
  end,
  __call = function()
    return inert
  end,
  __newindex = function() end,
})

--- A stand-in for `vim` that reads from Neovim but drops changes:
--- keymaps, autocommands, commands, highlights and options.
local function sandbox_vim()
  local function shadow(real)
    return setmetatable({}, {
      __index = function(_, k)
        local ok, v = pcall(function()
          return real[k]
        end)
        return ok and v or nil
      end,
      __newindex = function() end,
    })
  end
  local api = setmetatable({}, {
    __index = function(_, k)
      if type(k) == "string" and (k:match("^nvim_create_") or k:match("^nvim_set_") or k:match("^nvim_buf_set_")) then
        return function()
          return 0
        end
      elseif
        type(k) == "string"
        and (k:match("^nvim_del_") or k:match("^nvim_command") or k:match("^nvim_exec") or k:match("^nvim_buf_del"))
      then
        return function() end
      end
      return vim.api[k]
    end,
  })
  return setmetatable({
    api = api,
    keymap = inert,
    cmd = inert,
    opt = inert,
    opt_local = inert,
    opt_global = inert,
    o = shadow(vim.o),
    go = shadow(vim.go),
    bo = inert,
    wo = inert,
    g = shadow(vim.g),
    b = shadow(vim.b),
    w = shadow(vim.w),
    t = shadow(vim.t),
    env = shadow(vim.env),
    notify = function() end,
    schedule = function() end,
    defer_fn = function() end,
    on_key = function() end,
  }, { __index = vim })
end

local OPTION_KEYS = { mappings = true, notifications = true, win_split_mode = true, win_border = true, ui = true }

--- Does `t` look like nvim-orgmode options?
local function is_options(t)
  for k in pairs(t) do
    if type(k) == "string" and (k:match("^org_") or OPTION_KEYS[k]) then
      return true
    end
  end
  return false
end

--- The nvim-orgmode options of a Lua config.
---@param text string Lua source
---@param chunkname string
---@return table? opts
---@return string? err
function M.read_setup(text, chunkname)
  local found
  local function record(opts)
    if type(opts) == "table" then
      found = vim.tbl_deep_extend("force", found or {}, opts)
    end
  end
  local orgmode = setmetatable({
    setup = function(opts)
      record(opts or {})
      return inert
    end,
  }, {
    __index = function()
      return inert
    end,
  })
  local env = setmetatable({}, { __index = _G })
  env.vim = sandbox_vim()
  env.require = function(name)
    if name == "orgmode" then
      return orgmode
    end
    return inert
  end
  env._G = env
  local chunk, err = loadstring(text, chunkname)
  if not chunk then
    return nil, err
  end
  setfenv(chunk, env)
  local ok, ret = pcall(chunk)
  if not ok then
    return nil, tostring(ret)
  end
  -- a lazy.nvim spec (or list of specs) returned by the file
  local function spec(s, depth)
    if type(s) ~= "table" or depth > 3 then
      return
    end
    local name = type(s[1]) == "string" and s[1] or s.name or s.dir or ""
    if type(name) == "string" and name:find("orgmode", 1, true) then
      local opts = s.opts
      if type(opts) == "function" then
        local o = {}
        local ok2, r = pcall(setfenv(opts, env), s, o)
        opts = ok2 and (type(r) == "table" and r or o) or nil
      end
      if type(opts) == "table" then
        record(opts)
      end
      if type(s.config) == "function" then
        -- (the user's config function, run where only setup() is recorded: it may
        -- fail on what isn't there; the setup() calls made before it failed count)
        -- lint: allow pcall: the user's config function, in a sandbox that only records setup()
        pcall(setfenv(s.config, env), s, opts or {})
      end
      return
    end
    for _, sub in ipairs(s) do
      spec(sub, depth + 1)
    end
  end
  if type(ret) == "table" then
    if is_options(ret) and not found then
      record(ret)
    else
      spec(ret, 0)
    end
  end
  if not found then
    return nil,
      "no nvim-orgmode setup found: expected require('orgmode').setup({...}), a lazy.nvim spec "
        .. "for nvim-orgmode/orgmode, or a returned table of options"
  end
  return found
end

--- Convert the Lua config `text` and return the org.nvim setup lines.
---@param text string
---@param name string file name, for the chunk and the header
---@return string[]? lines
---@return string|org.migrate.Result err_or_result
function M.convert_source(text, name)
  local chunkname = "@" .. name
  local opts, err = M.read_setup(text, chunkname)
  if not opts then
    return nil, err or "?"
  end
  local res = M.convert(opts)
  local sources = { [chunkname] = vim.split(text, "\n", { plain = true }) }
  return M.render(res, { source = name, sources = sources }), res
end

--- `:Org migrate_config [file]`: convert a file (or the current buffer,
--- when it is Lua) and show the result in a new scratch buffer.
---@param args? string
function M.command(args)
  local utils = require("org.utils")
  args = vim.trim(args or "")
  local text, name
  if args ~= "" then
    local path = utils.expand(args)
    local fd = io.open(path, "r")
    if not fd then
      utils.error("migrate_config: can't read " .. path)
      return
    end
    text = fd:read("*a")
    fd:close()
    name = path
  else
    local buf = vim.api.nvim_get_current_buf()
    local bname = vim.api.nvim_buf_get_name(buf)
    if vim.bo[buf].filetype ~= "lua" and not bname:match("%.lua$") then
      utils.error("migrate_config: give the Lua file of your nvim-orgmode setup (:Org migrate_config FILE)")
      return
    end
    text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    name = bname ~= "" and bname or "[buffer " .. buf .. "]"
  end
  local lines, res = M.convert_source(text, name)
  if not lines then
    utils.error("migrate_config: " .. tostring(res))
    return
  end
  ---@cast res org.migrate.Result
  vim.cmd("new")
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  -- (a failing ftplugin, such as a missing tree-sitter parser, is no reason to stop)
  require("org.utils").try("migrate: set the filetype", function()
    vim.bo[buf].filetype = "lua"
  end)
  pcall(vim.api.nvim_buf_set_name, buf, "org-migrated-setup.lua")
  local todos = 0
  for _, l in ipairs(lines) do
    if l:match("^%s*%-%- TODO") then
      todos = todos + 1
    end
  end
  vim.notify(
    string.format(
      "org.nvim: converted %d option%s; %d TODO%s to review",
      res.converted,
      res.converted == 1 and "" or "s",
      todos,
      todos == 1 and "" or "s"
    )
  )
end

return M
