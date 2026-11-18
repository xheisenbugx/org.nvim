-- Capture compared with Emacs Org 9.8.12 (tests/fixtures/emacs/capture,
-- scripts/emacs-parity/capture.el): each case captures with a template
-- into a copy of the fixture files, through the capture actions (the
-- template menu answered with the case's key) and the capture buffer's
-- C-c C-c, and compares the template's file afterwards.

local P = require("tests.emacs_parity")
local actions = require("org.actions")
local capture = require("org.capture")
local config = require("org.config")
local utils = require("org.utils")

local dir = P.dir .. "/capture"

-- Cases that still differ from Emacs, with the reason. A case listed here
-- must keep failing (remove it once it matches).
local KNOWN = {}

-- The templates of scripts/emacs-parity/capture.el (`parity-capture-
-- templates`) in org.nvim's format, in the same order with the same keys:
-- keep the two tables in step. Files are relative to org_directory, the
-- directory of the copies.
local TEMPLATES = {
  { "e", { description = "Entry", target = "inbox.org", template = "* TODO %?" } },
  { "ep", { description = "Entry, prepended", target = "inbox.org", template = "* First %?", prepend = true } },
  { "h", { description = "Headline", target = "inbox.org", headline = "Tasks", template = "* TODO %?\n  %u" } },
  {
    "hp",
    {
      description = "Headline, prepended",
      target = "inbox.org",
      headline = "Tasks",
      template = "* Urgent %?",
      prepend = true,
    },
  },
  { "hn", { description = "New headline", target = "inbox.org", headline = "Later", template = "* Someday %?" } },
  {
    "hc",
    { description = "Headline in another case", target = "inbox.org", headline = "notes", template = "* Found %?" },
  },
  {
    "hd",
    {
      description = "Deeper levels",
      target = "inbox.org",
      headline = "Notes",
      template = "*** Deep :deep:\n**** Deeper %?",
    },
  },
  {
    "o",
    { description = "Outline path", target = "projects.org", olp = { "Projects", "Neovim" }, template = "* Idea %?" },
  },
  { "r", { description = "Regexp", target = "projects.org", regexp = "^\\*\\* Emacs", template = "* After match %?" } },
  { "d", { description = "Date tree", target = "journal.org", datetree = true, template = "* Today %?\n%U" } },
  {
    "dw",
    {
      description = "Week tree",
      target = "weeks.org",
      datetree = true,
      tree_type = "week",
      template = "* This week %?",
    },
  },
  {
    "dm",
    {
      description = "Month tree",
      target = "weeks.org",
      datetree = true,
      tree_type = "month",
      template = "* This month %?",
    },
  },
  {
    "do",
    {
      description = "Date tree under a path",
      target = "projects.org",
      olp = { "Someday" },
      datetree = true,
      template = "* Dated %?",
    },
  },
  { "dd", { description = "Date tree, existing day", target = "days.org", datetree = true, template = "* Now %?" } },
  {
    "dq",
    {
      description = "Quarter tree",
      target = "weeks.org",
      datetree = true,
      tree_type = { "year", "quarter", "month" },
      template = "* This quarter %?",
    },
  },
  { "x", { description = "No stars", target = "inbox.org", template = "No stars here %?" } },
  { "nl", { description = "No final newline", target = "nonl.org", template = "* Appended %?" } },
  {
    "np",
    {
      description = "No final newline, plain",
      type = "plain",
      target = "nonl.org",
      headline = "Inbox",
      template = "More text",
    },
  },
  { "i", { description = "Item", type = "item", target = "lists.org", headline = "Shopping", template = "eggs %?" } },
  {
    "ip",
    {
      description = "Item, prepended",
      type = "item",
      target = "lists.org",
      headline = "Shopping",
      template = "- butter",
      prepend = true,
    },
  },
  {
    "in",
    {
      description = "Item, ordered list",
      type = "item",
      target = "lists.org",
      headline = "Ordered",
      template = "three",
    },
  },
  {
    "il",
    {
      description = "Item, empty lines",
      type = "item",
      target = "lists.org",
      headline = "Todo",
      template = "- spaced",
      empty_lines = 1,
    },
  },
  {
    "iw",
    { description = "Item, no list", type = "item", target = "inbox.org", headline = "Notes", template = "first item" },
  },
  {
    "ii",
    { description = "Item, initial", type = "item", target = "lists.org", headline = "Shopping", template = "%i" },
  },
  {
    "c",
    {
      description = "Check item",
      type = "checkitem",
      target = "lists.org",
      headline = "Todo",
      template = "- [ ] read %?",
    },
  },
  {
    "co",
    {
      description = "Check item, ordered list",
      type = "checkitem",
      target = "lists.org",
      headline = "Ordered",
      template = "four",
    },
  },
  {
    "ce",
    {
      description = "Check item, default",
      type = "checkitem",
      target = "lists.org",
      headline = "Shopping",
      template = "",
    },
  },
  {
    "t",
    {
      description = "Table line",
      type = "table-line",
      target = "tables.org",
      headline = "Log",
      template = "| %t | %? |",
    },
  },
  {
    "tp",
    {
      description = "Table line, position",
      type = "table-line",
      target = "tables.org",
      headline = "Log",
      template = "| new | row |",
      table_line_pos = "II-1",
    },
  },
  {
    "tP",
    {
      description = "Table line, prepended",
      type = "table-line",
      target = "tables.org",
      headline = "Log",
      template = "| first | row |",
      prepend = true,
    },
  },
  {
    "tn",
    {
      description = "Table line, new table",
      type = "table-line",
      target = "tables.org",
      headline = "Empty",
      template = "| a | b |",
    },
  },
  { "p", { description = "Plain", type = "plain", target = "plain.org", headline = "Notes", template = "Plain %U" } },
  {
    "pp",
    {
      description = "Plain, prepended",
      type = "plain",
      target = "plain.org",
      headline = "Notes",
      template = "Plain first",
      prepend = true,
    },
  },
  { "pf", { description = "Plain, file", type = "plain", target = "plain.org", template = "At the end" } },
  {
    "el",
    {
      description = "Empty lines",
      target = "inbox.org",
      headline = "Tasks",
      template = "* Spaced %?",
      empty_lines = 1,
    },
  },
  {
    "eb",
    {
      description = "Empty lines before",
      target = "inbox.org",
      headline = "Notes",
      template = "* Before %?",
      empty_lines_before = 2,
    },
  },
  {
    "ea",
    {
      description = "Empty lines after",
      target = "inbox.org",
      headline = "Tasks",
      template = "* After %?",
      empty_lines_after = 1,
    },
  },
  { "T", { description = "Dates", target = "inbox.org", template = "* Dates %t %T\n  %u %U" } },
  { "L", { description = "Literal", target = "inbox.org", template = "* Literal 50% done \\%t\n  100%% sure" } },
  {
    "m",
    {
      description = "Text after the cursor",
      target = "inbox.org",
      headline = "Tasks",
      template = "* Meeting %? with the team",
    },
  },
  {
    "s",
    {
      description = "Planning",
      target = "inbox.org",
      headline = "Tasks",
      template = "* TODO Review %?\nSCHEDULED: %t",
    },
  },
  { "a", { description = "Link", target = "inbox.org", template = "* Link %a" } },
  { "f", { description = "Origin", target = "inbox.org", template = "* From %f\n  %F\n  %<%Y/%m/%d %H:%M>" } },
  { "I", { description = "Initial", target = "inbox.org", template = "* Initial %i" } },
  { "Ir", { description = "Initial, quoted", target = "inbox.org", template = "* Quote\n  > %i" } },
  {
    "P",
    {
      description = "Prompts",
      target = "inbox.org",
      template = "* %^{Title}\n  Owner: %^{Owner|alice|bob}\n  Again: %\\1",
    },
  },
  { "g", { description = "Tags", target = "inbox.org", template = "* Tagged %^g" } },
  { "pr", { description = "Property", target = "inbox.org", template = "* Estimated %^{Effort}p" } },
  {
    "if",
    {
      description = "Immediate",
      target = "inbox.org",
      headline = "Tasks",
      template = "* Quick",
      immediate_finish = true,
    },
  },
}

local BY_KEY = {}
for _, t in ipairs(TEMPLATES) do
  BY_KEY[t[1]] = t[2]
end

--- An answer of cases.txt: "_" for a space, "~" for an empty answer.
local function answer_text(a)
  return a == "~" and "" or (a:gsub("_", " "))
end

--- Run `fn` from a Visual-mode mapping after `keys` selected the region.
local function in_visual(keys, fn)
  _G.__org_capture_parity = fn
  vim.keymap.set("x", "<F13>", "<Cmd>lua __org_capture_parity()<CR>")
  vim.api.nvim_feedkeys(vim.keycode(keys .. "<F13>"), "x", false)
  vim.keymap.del("x", "<F13>")
  _G.__org_capture_parity = nil
end

--- The template's file after capturing with `key` from `origin` (see
--- cases.txt), the copies' directory written "@DIR@/".
local function run(key, origin, answers)
  local tpl = assert(BY_KEY[key], "no template " .. key)
  local tmp = vim.fs.normalize(vim.fn.tempname() .. "-capture")
  vim.fn.mkdir(tmp, "p")
  for name, kind in vim.fs.dir(dir) do
    if kind == "file" and name ~= "cases.txt" and name ~= "expected.txt" then
      utils.writefile(tmp .. "/" .. name, utils.readfile(dir .. "/" .. name))
    end
  end
  local templates = {}
  for _, t in ipairs(TEMPLATES) do
    templates[t[1]] = vim.deepcopy(t[2])
  end
  local opts = config.opts
  local ui = require("org.ui")
  local saved = {
    org_directory = opts.org_directory,
    templates = opts.capture.templates,
    menu = ui.menu,
    notify = vim.notify,
    input = vim.fn.input,
    uinput = vim.ui.input,
    select = vim.ui.select,
    confirm = vim.fn.confirm,
  }
  opts.org_directory = tmp
  opts.capture.templates = templates
  local queue = vim.tbl_map(answer_text, answers)
  local initial = origin:match("^string:(.*)$")
  if initial then
    -- capture_string asks for the text first
    table.insert(queue, 1, answer_text(initial))
  end
  local function pop()
    assert(#queue > 0, "prompted with no answer left")
    return table.remove(queue, 1)
  end
  -- the template menu, answered with the key
  ui.menu = function()
    return key
  end
  vim.fn.input = function()
    return pop()
  end
  vim.ui.input = function(_, cb)
    cb(pop())
  end
  local function prompted()
    error("prompted", 0)
  end
  vim.ui.select, vim.fn.confirm = prompted, prompted
  vim.notify = function() end
  local done = false
  local au = vim.api.nvim_create_autocmd("User", {
    pattern = "OrgCaptureAfterFinalize",
    callback = function()
      done = true
    end,
  })
  local okc, err = pcall(function()
    vim.cmd("silent! only!")
    vim.cmd("silent! %bwipeout!")
    local file, l1, l2 = origin:match("^(.-):(%d+)%-?(%d*)$")
    if initial or origin == "-" then
      vim.cmd("enew")
    else
      vim.cmd("edit " .. vim.fn.fnameescape(tmp .. "/" .. file))
      vim.api.nvim_win_set_cursor(0, { tonumber(l1), 0 })
    end
    if initial then
      actions.run("capture_string")
    elseif l2 and l2 ~= "" then
      in_visual(l1 .. "G0v" .. l2 .. "Gg_", function()
        actions.run("capture")
      end)
    else
      actions.run("capture")
    end
    -- prompts answer on the event loop
    vim.wait(5000, function()
      return done or next(capture.sessions) ~= nil
    end, 5)
    if not done then
      -- C-c C-c in the capture buffer
      local buf = assert(next(capture.sessions), "no capture started")
      vim.cmd("stopinsert")
      utils.run(capture.finalize, buf, { jump = false })
      vim.wait(5000, function()
        return done
      end, 5)
    end
    assert(done, "the capture did not finish")
    assert(#queue == 0, "answers left: " .. table.concat(queue, ", "))
  end)
  vim.api.nvim_del_autocmd(au)
  opts.org_directory, opts.capture.templates = saved.org_directory, saved.templates
  ui.menu, vim.notify = saved.menu, saved.notify
  vim.fn.input, vim.ui.input, vim.ui.select, vim.fn.confirm = saved.input, saved.uinput, saved.select, saved.confirm
  vim.cmd("stopinsert")
  local out
  if okc then
    local path = tmp .. "/" .. tpl.target
    local b = utils.find_buffer(path)
    out = b and vim.api.nvim_buf_get_lines(b, 0, -1, false) or utils.readfile(path)
    -- the directory as written in links and %F: as given, resolved
    -- (/private/var/... on macOS, the long name on Windows), under ~, with
    -- either separator; the longest first, as one may hold another
    local dirs = {}
    for _, d in ipairs({ tmp, vim.uv.fs_realpath(tmp) or tmp, vim.fn.fnamemodify(tmp, ":~") }) do
      dirs[#dirs + 1] = (d:gsub("\\", "/")) .. "/"
      dirs[#dirs + 1] = (d:gsub("/", "\\")) .. "\\"
    end
    table.sort(dirs, function(a, b)
      return #a > #b
    end)
    for i, l in ipairs(out) do
      for _, d in ipairs(dirs) do
        l = l:gsub(vim.pesc(d), "@DIR@/")
      end
      out[i] = l
    end
  end
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) then
      vim.bo[b].modified = false
    end
  end
  vim.cmd("silent! only!")
  vim.cmd("silent! %bwipeout!")
  vim.fn.delete(tmp, "rf")
  assert(okc, err)
  return out
end

--- The cases, with `capture.in_place` set to `in_place`: the text is
--- edited in a capture buffer (the default) or in the target itself, as
--- in Emacs; the file is the same either way.
local function cases(in_place)
  local saved
  before_each(function()
    saved = config.opts.capture.in_place
    config.opts.capture.in_place = in_place
  end)
  after_each(function()
    config.opts.capture.in_place = saved
  end)
  local expected = P.sections(dir .. "/expected.txt")
  for _, case in ipairs(P.cases(dir .. "/cases.txt")) do
    local name, key, origin = case[1], case[2], case[3]
    local answers = vim.list_slice(case, 4)
    it(name, function()
      ok(expected[name], "no Emacs output for " .. name .. " (run make parity-fixtures)")
      local e, o = P.normalise("capture", expected[name].lines, run(key, origin, answers))
      P.compare(e, o, KNOWN[name])
    end)
  end
end

describe("capture matches Emacs", function()
  P.freeze_time()
  cases(false)
end)

describe("capture in place matches Emacs", function()
  P.freeze_time()
  cases(true)
end)
