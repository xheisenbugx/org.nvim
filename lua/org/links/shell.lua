---@mod org.links.shell shell: and elisp: links
---
--- Running shell: links (in a terminal or an *Org Shell Output*
--- buffer, shell_to_buffer) and elisp: links, after confirmation.
--- Part of org.links, which loads it.

local utils = require("org.utils")
local shared = require("org.links.shared")

local M = require("org.links")

local base_dir = shared.base_dir
local lopts = shared.lopts

---------------------------------------------------------------------------
-- Running shell: and elisp: links
---------------------------------------------------------------------------

local function run_in_terminal(argv, cwd)
  vim.cmd("botright new")
  return vim.fn.jobstart(argv, { term = true, cwd = cwd })
end

--- Run a `shell:` link in a terminal window, in the directory of the Org
--- file, after confirmation (org-link--open-shell).
local function open_shell(cmd, bufnr)
  local skip = lopts().shell_skip_confirm_regexp
  local skipped = false
  if type(skip) == "string" and skip ~= "" then
    local ok, re = pcall(vim.regex, skip)
    skipped = ok and re:match_str(cmd) ~= nil
  end
  local confirm = lopts().confirm_shell
  if not skipped and confirm ~= false then
    local yes
    if type(confirm) == "function" then
      yes = confirm(cmd)
    else
      yes = utils.confirm("Execute " .. cmd .. " in shell?")
    end
    if not yes then
      utils.warn("Abort")
      return false
    end
  end
  local argv = { vim.o.shell }
  vim.list_extend(argv, vim.split(vim.o.shellcmdflag, "%s+", { trimempty = true }))
  utils.notify("Executing " .. cmd)
  if lopts().shell_output == "terminal" then
    argv[#argv + 1] = cmd
    return run_in_terminal(argv, base_dir(bufnr))
  end
  local async = cmd:match("^(.-)%s*&%s*$")
  argv[#argv + 1] = async or cmd
  return M.shell_to_buffer(argv, base_dir(bufnr), async ~= nil)
end

--- A new `*Org Shell Output*` buffer (generate-new-buffer: `<2>`, `<3>`,
--- ... when the name is taken).
local function new_output_buffer()
  local buf = vim.api.nvim_create_buf(true, true)
  local name, n = "*Org Shell Output*", 1
  while not pcall(vim.api.nvim_buf_set_name, buf, name) do
    n = n + 1
    name = "*Org Shell Output*<" .. n .. ">"
  end
  return buf
end

local function show_buffer(buf)
  if vim.fn.bufwinid(buf) == -1 then
    vim.cmd("botright split")
    vim.api.nvim_win_set_buf(0, buf)
    vim.cmd("wincmd p")
  end
end

--- Run `argv` in `cwd` with stdout and stderr collected in a new
--- `*Org Shell Output*` buffer, like shell-command with an output buffer:
--- a one-line output is echoed (display-message-or-buffer), a longer one
--- shows the buffer. `async` (a command ending in `&`) shows the buffer
--- at once and appends the output as it arrives (async-shell-command).
--- Returns the buffer and the vim.system object.
function M.shell_to_buffer(argv, cwd, async)
  local buf = new_output_buffer()
  local got = false
  local function append(data)
    if not data or data == "" or not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    local lines = vim.split(data:gsub("\r\n", "\n"), "\n", { plain = true })
    local last = vim.api.nvim_buf_get_lines(buf, -2, -1, false)[1] or ""
    lines[1] = last .. lines[1]
    vim.api.nvim_buf_set_lines(buf, got and -2 or 0, -1, false, lines)
    got = true
  end
  if async then
    show_buffer(buf)
  end
  local on_data
  if async then
    on_data = function(_, data)
      vim.schedule(function()
        append(data)
      end)
    end
  end
  local proc = vim.system(argv, { cwd = cwd, text = true, stdout = on_data, stderr = on_data }, function(res)
    vim.schedule(function()
      if not async then
        -- without streaming callbacks, vim.system collects the output
        append(res.stdout)
        append(res.stderr)
      end
      -- the final newline of the output ends the last line
      if got and vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_lines(buf, -2, -1, false)[1] == "" then
        vim.api.nvim_buf_set_lines(buf, -2, -1, false, {})
      end
      if async then
        utils.notify(res.code == 0 and "Shell command finished" or ("Shell command exited with code " .. res.code))
        return
      end
      local lines = vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_lines(buf, 0, -1, false) or {}
      while #lines > 0 and lines[#lines] == "" do
        table.remove(lines)
      end
      if #lines == 0 then
        utils.notify(
          res.code == 0 and "(Shell command succeeded with no output)"
            or string.format("(Shell command failed with code %d and no output)", res.code)
        )
      elseif #lines == 1 then
        utils.notify(lines[1])
      else
        show_buffer(buf)
      end
    end)
  end)
  return buf, proc
end

--- Run an `elisp:` link after confirmation (org-link--open-elisp). The sexp
--- is evaluated in a separate `emacs --batch` (babel.emacs_lisp), not in
--- the editor; without Emacs, on the Lisp interpreter of table formulas.
local function open_elisp(sexp, bufnr)
  local skip = lopts().elisp_skip_confirm_regexp
  local skipped = false
  if type(skip) == "string" and skip ~= "" then
    local ok, re = pcall(vim.regex, skip)
    skipped = ok and re:match_str(sexp) ~= nil
  end
  local confirm = lopts().confirm_elisp
  if not skipped and confirm ~= false then
    local yes
    if type(confirm) == "function" then
      yes = confirm(sexp)
    else
      yes = utils.confirm("Execute " .. sexp .. " as Elisp?")
    end
    if not yes then
      utils.warn("Abort")
      return false
    end
  end
  if not sexp:match("^%s*%(") and not require("org.babel.elisp").command() then
    -- Emacs calls a command name interactively: there is no Emacs to call it in
    utils.warn("elisp: " .. sexp .. ": Emacs commands need an Emacs (babel.emacs_lisp)")
    return false
  end
  local value, err = require("org.babel.elisp").eval_link(sexp, base_dir(bufnr))
  if not value then
    utils.error("elisp: " .. tostring(err))
    return false
  end
  utils.notify(sexp .. " => " .. value)
  return true
end

-- for the parts loaded after this one
shared.open_elisp = open_elisp
shared.open_shell = open_shell
shared.run_in_terminal = run_in_terminal
