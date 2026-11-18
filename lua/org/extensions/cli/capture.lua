---@mod org.extensions.cli.capture The capture and protocol commands
---
--- `org capture` stores an entry at once with a template, answering its
--- prompts from `--field` or `--input`; `org protocol` handles an
--- org-protocol URL. Part of org.extensions.cli.run, which loads it.

local data = require("org.extensions.cli.data")

local shared = require("org.extensions.cli.shared")

local M = require("org.extensions.cli.run")

local fail = M.fail
local state = shared.state
local cli_opts = shared.cli_opts
local arg_path = M.arg_path
local short_path = M.short_path

--- The template to capture `text` with: a copy of template `key` that
--- finishes at once and puts the text where `%?` was (unless the template
--- already uses `%i`).
function M.capture_template(key)
  local capture = require("org.capture")
  local tpl = capture.get_template(key)
  if not tpl then
    fail("no capture template " .. key .. " (org templates)", "bad_value", { template = key })
  end
  tpl.immediate_finish = true
  tpl.jump_to_captured = false
  tpl.clock_in = false
  tpl.clock_keep = false
  tpl.clock_resume = false
  if type(tpl.template) == "string" and not tpl.template:find("%%i") then
    local n
    tpl.template, n = tpl.template:gsub("%%%?", "%%i", 1)
    if n == 0 then
      tpl.template = tpl.template .. "%i"
    end
  elseif tpl.template == nil or tpl.template == "" then
    local empty = { entry = "* %i", item = "- %i", checkitem = "- [ ] %i", ["table-line"] = "| %i |" }
    tpl.template = empty[tpl.type or "entry"] or "%i"
  end
  return tpl
end

local function default_template_key()
  local key = cli_opts().capture_template
  if key then
    return key
  end
  local templates = require("org.capture").templates()
  if templates.t then
    return "t"
  end
  local keys = {}
  for k, t in pairs(templates) do
    if type(t) == "table" and (t.template or t.target or t.type) then
      keys[#keys + 1] = k
    end
  end
  table.sort(keys)
  if #keys == 0 then
    fail("no capture templates", "bad_value")
  end
  return keys[1]
end

local function read_stdin()
  return io.stdin:read("*a") or ""
end
M.read_stdin = function()
  return read_stdin()
end

--- `NAME=VALUE` pairs of `--field` (and an `--input` object's `fields`)
--- as prompt answers, by lowercased name.
local function set_answers(fields, input_fields)
  for k, v in pairs(input_fields or {}) do
    state.answers[tostring(k):lower()] = tostring(v)
  end
  for _, f in ipairs(fields or {}) do
    local k, v = f:match("^([^=]+)=(.*)$")
    if not k then
      fail("--field needs NAME=VALUE, not " .. f, "bad_value", { field = f })
    end
    state.answers[vim.trim(k):lower()] = v
  end
end

--- Store a capture with template `tpl` (finishing at once): the buffer
--- and line of the entry, or a failure.
---@return integer bufnr, integer line
local function store_capture(tpl, opts)
  local capture = require("org.capture")
  -- a capture that can't be saved is taken out of the target buffer again:
  -- the caller still has the text, and a retry must not store it twice
  opts.rollback = true
  local done, bufnr, line, stored
  local co = coroutine.create(function()
    bufnr, line, stored = capture.capture(tpl, opts)
    done = true
  end)
  local ok, e = coroutine.resume(co)
  if not ok then
    error(e, 0)
  end
  if not done then
    vim.wait(5000, function()
      return done or state.prompted ~= nil
    end, 10)
  end
  M.check_prompted()
  if not done or not bufnr then
    M.fail_with_messages("capture failed")
  end
  -- a template's kill_buffer wipes the buffer the entry went to: it's
  -- saved, so read it back from its file
  if not (vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr)) then
    if not stored then
      M.fail_with_messages("capture failed")
    end
    bufnr = require("org.utils").load_buffer(stored)
  end
  return bufnr, line
end

--- Keep the session's unsaved changes in the target of `tpl` unsaved, and
--- refuse a target another Neovim has unsaved changes in.
local function capture_target_guard(tpl, flags)
  local ok_target, target = pcall(require("org.capture").target_path, tpl)
  if ok_target and target then
    M.guard(target, flags)
    local b = state.session and require("org.utils").find_buffer(target)
    if b and vim.bo[b].modified then
      tpl.no_save = true
    end
  end
end

function M.cmd_capture(words, flags)
  if flags.list then
    return M.cmd_templates()
  end
  local input = {}
  if flags.input then
    local text = flags.input == "-" and M.read_stdin() or nil
    if not text then
      local p = arg_path(flags.input)
      local lines = vim.fn.filereadable(p) == 1 and vim.fn.readfile(p) or nil
      if not lines then
        fail("no such file: " .. p, "bad_value", { file = p })
      end
      ---@cast lines -nil
      text = table.concat(lines, "\n")
    end
    local ok, obj = pcall(vim.json.decode, text, { luanil = { object = true, array = true } })
    if not ok or type(obj) ~= "table" or vim.islist(obj) and next(obj) ~= nil then
      fail("--input needs a JSON object { template, text, fields }", "bad_value")
    end
    input = obj
  end
  set_answers(flags.field, type(input.fields) == "table" and input.fields or nil)
  local text = table.concat(words, " ")
  if text == "-" then
    text = M.read_stdin()
  elseif text == "" and input.text then
    text = tostring(input.text)
  end
  text = vim.trim(text)
  local key = flags.template or input.template or default_template_key()
  local tpl = M.capture_template(tostring(key))
  local prompts = type(tpl.template) == "string" and tpl.template:find("%^", 1, true)
  if text == "" and next(state.answers) == nil and not prompts then
    fail("nothing to capture (org capture [-t KEY] TEXT)", "usage")
  end
  capture_target_guard(tpl, flags)
  -- The template's prompts are answered by their names as the template
  -- writes them (%^{Size [cm]} by "Size [cm]"), ignoring case; any other
  -- prompt through `ask`, by its question.
  local answers = setmetatable({}, {
    __index = function(_, k)
      return type(k) == "string" and state.answers[k:lower()] or nil
    end,
  })
  M.mark_messages()
  local bufnr, line = store_capture(tpl, { initial = text, answers = answers })
  local hl = (tpl.type or "entry") == "entry" and M.headline_at(bufnr, line) or nil
  local id
  if hl then
    id = hl.properties.ID
    if flags.id and not id then
      id = require("org.id").get_create({ bufnr = bufnr, lnum = hl.line })
      hl = M.headline_at(bufnr, hl.line)
    end
  end
  -- the capture saved its target itself: a running Neovim rereads it too
  state.touched = true
  M.save_all(flags)
  local path = data.path(vim.api.nvim_buf_get_name(bufnr))
  return {
    data = {
      file = path,
      line = line,
      template = tpl.key or tostring(key),
      type = tpl.type or "entry",
      id = data.nn(id),
      headline = hl and data.headline(hl) or vim.NIL,
    },
    text = { string.format("Captured to %s:%d", short_path(path), line or 0) },
  }
end

---------------------------------------------------------------------------
-- protocol
---------------------------------------------------------------------------

--- `org protocol URL`: an org-protocol URL for a URL handler. Sent to the
--- session server, which handles it as `:Org protocol` does (a capture
--- opens its window there); without one, a capture is stored at once with
--- its template, as `org capture` does, and the other sub-protocols fail.
function M.cmd_protocol(words, flags)
  local url = vim.trim(table.concat(words, " "))
  if url == "" then
    fail("usage: org protocol URL", "usage")
  end
  local protocol = require("org.protocol")
  local h, params = protocol.parse(url)
  if not h or type(params) ~= "table" then
    fail(tostring(params), "bad_value", { url = url })
  end
  ---@cast h -nil
  ---@cast params table
  if state.session then
    -- after the request returns, with this Neovim's own prompts back
    vim.schedule(function()
      protocol.handle(url)
    end)
    return {
      data = { url = url, protocol = h.protocol, session = true, file = vim.NIL, line = vim.NIL },
      text = { "Sent to Neovim: org-protocol " .. h.protocol },
    }
  end
  if h.fn ~= protocol.capture then
    fail(
      "org-protocol " .. h.protocol .. " needs a running Neovim (remote.enabled, see :h org-remote)",
      "failed",
      { protocol = h.protocol }
    )
  end
  set_answers(flags.field)
  M.mark_messages()
  local res = protocol.capture(params, {
    run = function(key, initial)
      local tpl = M.capture_template(key or default_template_key())
      capture_target_guard(tpl, flags)
      local bufnr, line = store_capture(tpl, { initial = initial })
      return { bufnr = bufnr, line = line }
    end,
  }) --[[@as { bufnr: integer, line: integer|nil }]]
  state.touched = true
  M.save_all(flags)
  local path = data.path(vim.api.nvim_buf_get_name(res.bufnr))
  return {
    data = { url = url, protocol = h.protocol, session = false, file = path, line = res.line },
    text = { string.format("Captured to %s:%d", short_path(path), res.line or 0) },
  }
end
