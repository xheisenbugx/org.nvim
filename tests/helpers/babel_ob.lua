-- Helpers for the specs of the ob-LANG ports (tests/spec/babel_ob_*_spec.lua).
local babel = require("org.babel")
local config = require("org.config")

local M = {}

function M.tmpdir()
  local dir = vim.fn.resolve(vim.fn.tempname())
  vim.fn.mkdir(dir, "p")
  return dir
end

--- An executable shell script `name` in `dir` with `body` (see fake_exe
--- in tests/run.lua); returns the path to run it by.
function M.fake(dir, name, body)
  return fake_exe(dir, name, body)
end

--- Execute the whole buffer (org-babel-execute-buffer) and return its
--- lines, the directory and the buffer.
function M.run(lines, dir, name)
  dir = dir or M.tmpdir()
  local buf = org_buffer(lines, { 1, 0 })
  vim.api.nvim_buf_set_name(buf, dir .. "/" .. (name or "t.org"))
  babel.execute_buffer({ bufnr = buf, skip_confirm = true, sync = true })
  vim.bo[buf].modified = false
  return buf_lines(buf), dir, buf
end

--- The expanded body of block `n` (default 1) of `lines` (C-c C-v v).
function M.expand(lines, n)
  local buf = org_buffer(lines, { 1, 0 })
  local blocks = require("org.babel.blocks")
  local b = blocks.parse_blocks(buf_lines(buf))[n or 1]
  local args = blocks.header_args(b, babel.get_file(buf))
  return table.concat(babel.expand_body(buf, b, args), "\n")
end

local saved
--- Override options of `lang` until `M.restore()`.
function M.set_lang(lang, opts)
  saved = saved or {}
  if saved[lang] == nil then
    saved[lang] = vim.deepcopy(config.opts.babel.languages[lang]) or false
  end
  config.opts.babel.languages[lang] =
    vim.tbl_deep_extend("force", vim.deepcopy(config.opts.babel.languages[lang] or {}), opts)
end

function M.restore()
  for lang, v in pairs(saved or {}) do
    config.opts.babel.languages[lang] = v or nil
  end
  saved = nil
end

--- Put `dir` first on $PATH while `fn` runs.
function M.with_path(dir, fn)
  local path = vim.env.PATH
  path_prepend(dir)
  local ok, err = pcall(fn)
  vim.env.PATH = path
  if not ok then
    error(err, 0)
  end
end

return M
