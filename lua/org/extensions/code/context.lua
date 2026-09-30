---@mod org.extensions.code.context Code context for captures
---
--- `code_capture` gathers the context of a code buffer (the selection,
--- its language, a link back and the git branch) and captures it with the
--- `%(code-block)`, `%(code-link)`, `%(git-branch)`... template expansions,
--- which also work in any other capture template started from a code
--- buffer.

local git = require("org.extensions.code.git")
local link = require("org.extensions.code.link")
local utils = require("org.utils")

local M = {}

local function opts()
  return require("org.extensions").opts("code") or require("org.extensions.code").defaults
end

--- Babel language names of filetypes whose name differs.
M.LANGS = {
  sh = "sh",
  javascript = "js",
  javascriptreact = "jsx",
  typescriptreact = "tsx",
  cpp = "C++",
  c = "C",
  cs = "csharp",
  make = "makefile",
  tex = "latex",
  plaintex = "latex",
  r = "R",
  elisp = "emacs-lisp",
  text = "",
}

--- Babel language of filetype `ft` (`languages` overrides the defaults).
---@param ft string
---@return string
function M.lang(ft)
  local user = opts().languages or {}
  if user[ft] ~= nil then
    return user[ft]
  end
  if M.LANGS[ft] ~= nil then
    return M.LANGS[ft]
  end
  return ft
end

--- The context of the current capture from `code_capture` (cleared after
--- the template is expanded).
---@type table|nil
M.pending = nil

--- Gather the context of `buf`: the lines `first..last` (a selection) or
--- the cursor line `first` without one.
---@param buf integer
---@param first integer
---@param last? integer the selection's last line (nil: no selection)
---@param col? integer 0-based cursor column
---@param text? string the selected text (a characterwise selection)
---@return table
function M.gather(buf, first, last, col, text)
  local file = vim.fs.normalize(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":p"))
  local info = git.info(file)
  local c = {
    buf = buf,
    file = file,
    lnum = first,
    end_lnum = last or first,
    selection = last ~= nil,
    lang = M.lang(vim.bo[buf].filetype),
    root = info.root,
    repo = info.repo,
    branch = info.branch,
    commit = info.commit,
    relpath = info.relpath,
  }
  if last then
    if text then
      c.lines = vim.split(text, "\n", { plain = true })
    else
      c.lines = vim.api.nvim_buf_get_lines(buf, first - 1, last, false)
    end
  end
  local l = link.link_for(buf, first, col)
  c.link, c.desc, c.symbol = l.link, l.desc, l.symbol
  return c
end

-- The context an expansion works on: the pending one, or the capture's
-- origin buffer (a template chosen from the menu in a code buffer).
local function gather_for(ctx)
  local buf = ctx.origin_buf
  if not buf or not link.is_code_buffer(buf) then
    return nil
  end
  local cur = ctx.origin_cursor or { 1, 0 }
  if ctx.initial and ctx.initial ~= "" then
    -- the selection of a capture started in Visual mode
    local s, e = vim.api.nvim_buf_get_mark(buf, "<")[1], vim.api.nvim_buf_get_mark(buf, ">")[1]
    if s > 0 and e >= s then
      return M.gather(buf, s, e, 0, ctx.initial)
    end
  end
  return M.gather(buf, cur[1], nil, cur[2])
end

local function current(ctx)
  if M.pending then
    return M.pending
  end
  if not ctx then
    return nil
  end
  -- once per capture: gathering runs git and may ask a language server
  if ctx._code_context == nil then
    ctx._code_context = gather_for(ctx) or false
  end
  return ctx._code_context or nil
end

local function lines_label(c)
  if c.end_lnum and c.end_lnum ~= c.lnum then
    return c.lnum .. "-" .. c.end_lnum
  end
  return tostring(c.lnum)
end

--- The src block of the selection ("" without one).
---@param c table a gathered context
---@return string
function M.block(c)
  if not c.lines or #c.lines == 0 then
    return ""
  end
  local blocks = require("org.babel.blocks")
  local body = blocks.escape(blocks.dedent(c.lines))
  while #body > 0 and vim.trim(body[#body]) == "" do
    table.remove(body)
  end
  local lang = c.lang ~= "" and (" " .. c.lang) or ""
  local out = { "#+begin_src" .. lang }
  vim.list_extend(out, body)
  out[#out + 1] = "#+end_src"
  return table.concat(out, "\n")
end

--- `repo on branch @ commit` (the parts that are known), or "".
---@param c table
---@return string
function M.git_line(c)
  if not c.repo then
    return ""
  end
  local s = c.repo
  if c.branch then
    s = s .. " on " .. c.branch
  end
  if c.commit then
    s = s .. " @ " .. c.commit
  end
  return s
end

--- Template expansions, `%(name)` in capture templates.
M.expansions = {
  ["code-link"] = function(c)
    return require("org.links").format(c.link, c.desc)
  end,
  ["code-file-link"] = function(c)
    local line = lines_label(c):match("^%d+")
    return require("org.links").format(
      "file:" .. vim.fn.fnamemodify(c.file, ":~") .. "::" .. line,
      vim.fs.basename(c.file) .. ":" .. lines_label(c)
    )
  end,
  ["code-block"] = function(c)
    return M.block(c)
  end,
  ["code-lang"] = function(c)
    return c.lang
  end,
  ["code-file"] = function(c)
    return c.relpath or vim.fn.fnamemodify(c.file, ":~")
  end,
  ["code-line"] = function(c)
    return lines_label(c)
  end,
  ["code-symbol"] = function(c)
    return c.symbol or ""
  end,
  ["git-repo"] = function(c)
    return c.repo or ""
  end,
  ["git-branch"] = function(c)
    return c.branch or ""
  end,
  ["git-commit"] = function(c)
    return c.commit or ""
  end,
  ["git-info"] = function(c)
    return M.git_line(c)
  end,
}

--- Register the expansions with capture (`org.capture.expansions`).
function M.register()
  local capture = require("org.capture")
  for name, fn in pairs(M.expansions) do
    capture.expansions[name] = function(ctx)
      local c = current(ctx)
      if not c then
        return ""
      end
      return fn(c) or ""
    end
  end
end

function M.unregister()
  local ok, capture = pcall(require, "org.capture")
  if not ok then
    return
  end
  for name in pairs(M.expansions) do
    capture.expansions[name] = nil
  end
end

--- Where a `"project"` capture of repository `root` goes: the project
--- file (created when missing) under `project_headline`, or outside a
--- repository `fallback_target` (default: `default_notes_file`) under
--- `fallback_headline` (default: none, the end of the file).
---@param root? string
---@param headline? string the template's own headline
---@return string target, string|nil headline
function M.project_target(root, headline)
  local o = opts()
  local project = require("org.extensions.code.project")
  local pf = root and project.file(root) or nil
  if pf then
    project.ensure(pf, git.repo_name(root))
    return pf, headline or o.project_headline
  end
  return o.fallback_target or "", o.fallback_headline
end

--- The template `code_capture` uses: `capture_template` with the target
--- resolved (see `project_target`).
---@param c table the gathered context
---@return table
function M.template(c)
  local o = opts()
  local tpl = vim.deepcopy(o.capture_template or {})
  tpl.key = tpl.key or "code"
  tpl.description = tpl.description or "Code note"
  if tpl.target == nil or tpl.target == "project" then
    tpl.target, tpl.headline = M.project_target(c.root, tpl.headline)
  end
  return tpl
end

--- `code_capture`: capture the selection (Visual mode) or the cursor
--- position of a code buffer, with a src block, a link back and git facts.
function M.capture()
  local buf = vim.api.nvim_get_current_buf()
  if not link.is_code_buffer(buf) then
    utils.warn("code_capture works in code buffers (a file that is not org)")
    return
  end
  local mode = vim.fn.mode()
  local c
  if mode == "v" or mode == "V" or mode == "\22" then
    local srow, scol, erow, ecol = utils.visual_range()
    vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
    local text
    if mode == "v" then
      local lines = vim.api.nvim_buf_get_lines(buf, srow - 1, erow, false)
      -- ecol is the first byte of the last character: take all of it
      local last = lines[#lines]
      while ecol < #last and last:byte(ecol + 1) >= 0x80 and last:byte(ecol + 1) < 0xC0 do
        ecol = ecol + 1
      end
      lines[#lines] = last:sub(1, ecol)
      lines[1] = lines[1]:sub(scol)
      text = table.concat(lines, "\n")
    end
    c = M.gather(buf, srow, erow, scol - 1, text)
  else
    local cur = vim.api.nvim_win_get_cursor(0)
    c = M.gather(buf, cur[1], nil, cur[2])
  end
  require("org.extensions.code").remember_root(c.root)
  local tpl = M.template(c)
  local initial = c.lines and table.concat(c.lines, "\n") or ""
  M.pending = c
  local ok, res, extra = pcall(require("org.capture").capture, tpl, { initial = initial })
  M.pending = nil
  if not ok then
    error(res, 0)
  end
  return res, extra
end

return M
