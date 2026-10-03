---@mod org.babel.edit Block navigation and edit special
---
--- Part of org.babel: it adds its functions to that module, which it
--- requires back. Load it through `require("org.babel")`.

local blocks_mod = require("org.babel.blocks")
local langs = require("org.babel.langs")
local session_mod = require("org.babel.session")
local utils = require("org.utils")

local M = require("org.babel")
local P = require("org.babel.internal")

local buf_lines = M.buf_lines
local get_session = P.get_session

---------------------------------------------------------------------------
-- Navigation
---------------------------------------------------------------------------

local BEGIN = "^%s*#%+[Bb][Ee][Gg][Ii][Nn]_[Ss][Rr][Cc]"

function M.next_block()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local lines = buf_lines(0)
  for i = lnum + 1, #lines do
    if lines[i]:match(BEGIN) then
      vim.api.nvim_win_set_cursor(0, { i, 0 })
      return
    end
  end
  utils.notify("No next code block")
end

function M.prev_block()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local lines = buf_lines(0)
  for i = lnum - 1, 1, -1 do
    if lines[i]:match(BEGIN) then
      vim.api.nvim_win_set_cursor(0, { i, 0 })
      return
    end
  end
  utils.notify("No previous code block")
end

---------------------------------------------------------------------------
-- Edit special
---------------------------------------------------------------------------

--- C-c ': edit the src block at the cursor in a buffer with the
--- language's filetype (org-edit-src-code). The common indentation is
--- removed and put back (plus `edit_src_content_indentation`) unless the
--- block has `-i` or `src_preserve_indentation` is set. With
--- `opts.session` (C-u C-c ') a block with a :session shows its session
--- instead.
---@param opts? { session?: boolean }
function M.edit_special(opts)
  opts = opts or {}
  local bufnr = vim.api.nvim_get_current_buf()
  local b = M.at_block(bufnr, vim.api.nvim_win_get_cursor(0)[1])
  if not b or b.call then
    return false
  end
  if opts.session and session_mod.name(b.args.session) then
    return M.switch_to_session({ no_register = true })
  end
  local raw = vim.api.nvim_buf_get_lines(bufnr, b.start, b.finish - 1, false)
  local body = blocks_mod.unescape(raw)
  local preserve = blocks_mod.preserve_indentation(b.switches)
  local dedented = preserve and body or blocks_mod.dedent(body)
  if #dedented == 0 then
    dedented = { "" }
  end
  local content_indent = require("org.config").opts.edit_src_content_indentation or 0
  local prefix = preserve and "" or ((b.indent or "") .. string.rep(" ", content_indent))
  local ft = langs.filetype(b.lang)
  local ebuf = require("org.special").open({
    source_buf = bufnr,
    start_line = b.start + 1,
    end_line = b.finish - 1,
    lines = dedented,
    filetype = ft,
    exact_filetype = true,
    name = "src-" .. (b.lang ~= "" and b.lang or "block"),
    kind = "src",
    switches = b.switches,
    to_source = function(lines)
      local out = {}
      for i, l in ipairs(blocks_mod.escape(lines)) do
        out[i] = l == "" and "" or prefix .. l
      end
      return out
    end,
  })
  if ebuf and vim.api.nvim_buf_is_valid(ebuf) then
    M.src_associate_babel_session(ebuf, bufnr, b)
  end
  return ebuf
end

--- Indentation of line `idx` of `lines` for filetype `ft`, computed like
--- Vim does: the filetype's 'indentexpr', else 'cindent' or 'lisp', else
--- the indentation of the previous non-blank line. Options not set by the
--- filetype come from buffer `like`.
local function native_indent(ft, lines, idx, like)
  local scratch = vim.api.nvim_create_buf(false, true)
  for _, o in ipairs({ "shiftwidth", "tabstop", "softtabstop", "expandtab" }) do
    vim.bo[scratch][o] = vim.bo[like][o]
  end
  vim.api.nvim_buf_set_lines(scratch, 0, -1, false, lines)
  if ft and ft ~= "" then
    pcall(function()
      vim.bo[scratch].filetype = ft
    end)
  end
  local amount
  vim.api.nvim_buf_call(scratch, function()
    pcall(vim.api.nvim_win_set_cursor, 0, { idx, 0 })
    local ie = vim.bo.indentexpr
    if ie ~= "" then
      local ok, v = pcall(function()
        vim.v.lnum = idx
        return vim.fn.eval(ie)
      end)
      amount = ok and tonumber(v) or nil
      if amount and amount < 0 then
        amount = nil
      end
    elseif vim.bo.cindent then
      amount = vim.fn.cindent(idx)
    elseif vim.bo.lisp then
      amount = vim.fn.lispindent(idx)
    end
  end)
  pcall(vim.api.nvim_buf_delete, scratch, { force = true })
  if not amount then
    -- like autoindent / Emacs indent-relative
    amount = 0
    for i = idx - 1, 1, -1 do
      if lines[i]:match("%S") then
        amount = vim.fn.strdisplaywidth(lines[i]:match("^%s*"))
        break
      end
    end
  end
  return amount
end

--- TAB on line `lnum` of a src block body (org-indent-line with
--- `src_tab_acts_natively`): the body gets the block's content indentation
--- (like a round trip through the edit buffer) and the line the
--- indentation of the block's language. Returns true when the line is in
--- the body of a src block.
function M.indent_line_natively(bufnr, lnum)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local b = M.at_block(bufnr, lnum)
  if not b or b.call or lnum <= b.start or lnum >= b.finish then
    return nil
  end
  local raw = vim.api.nvim_buf_get_lines(bufnr, b.start, b.finish - 1, false)
  local idx = lnum - b.start
  local preserve = blocks_mod.preserve_indentation(b.switches)
  local content_indent = require("org.config").opts.edit_src_content_indentation or 0
  local prefix = preserve and "" or ((b.indent or "") .. string.rep(" ", content_indent))
  local old_line = raw[idx]
  local old_ind = #old_line:match("^%s*")
  if not preserve then
    -- the line first gets the block's content indentation
    raw[idx] = prefix .. old_line:gsub("^%s+", "")
  end
  local body = blocks_mod.unescape(raw)
  local lines = preserve and body or blocks_mod.dedent(body)
  local text = lines[idx]:gsub("^%s+", "")
  local amount = native_indent(langs.filetype(b.lang), lines, idx, bufnr)
  lines[idx] = string.rep(" ", amount) .. text
  local out = {}
  for i, l in ipairs(blocks_mod.escape(lines)) do
    if l:match("^%s*$") then
      out[i] = i == idx and (prefix .. l) or ""
    else
      out[i] = prefix .. l
    end
  end
  local current = vim.api.nvim_buf_get_lines(bufnr, b.start, b.finish - 1, false)
  if not vim.deep_equal(out, current) then
    vim.api.nvim_buf_set_lines(bufnr, b.start, b.finish - 1, false, out)
  end
  if vim.api.nvim_get_current_buf() == bufnr then
    local pos = vim.api.nvim_win_get_cursor(0)
    if pos[1] == lnum then
      local new_ind = #out[idx]:match("^%s*")
      local col = pos[2] < old_ind and new_ind or math.min(pos[2] + new_ind - old_ind, math.max(#out[idx] - 1, 0))
      pcall(vim.api.nvim_win_set_cursor, 0, { lnum, col })
    end
  end
  return true
end

--- Edit buffers connected to the `:session` of their block:
--- edit buffer -> { bufnr, lang, args, name }.
local associated = {}

--- Connect the edit buffer `ebuf` of block `b` (of `bufnr`) to the block's
--- session (org-src-associate-babel-session): the `edit_src.send_to_session`
--- keys send the buffer (Visual: the selected lines) to that session,
--- started when needed. Returns true when the block has a session.
function M.src_associate_babel_session(ebuf, bufnr, b)
  local name = b and b.args and session_mod.name(b.args.session)
  if not name or not session_mod.supported(b.lang, langs.family(b.lang)) then
    return false
  end
  associated[ebuf] = { bufnr = bufnr, lang = b.lang, args = b.args, name = name }
  vim.b[ebuf].org_babel_session = name
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = ebuf,
    once = true,
    callback = function()
      associated[ebuf] = nil
    end,
  })
  local config = require("org.config")
  local maps = config.opts.mappings.edit_src or {}
  for _, lhs in ipairs(config.lhs_list(maps.send_to_session)) do
    vim.keymap.set("n", lhs, function()
      M.send_to_associated_session(ebuf)
    end, { buffer = ebuf, desc = "org: send the edit buffer to its session" })
    vim.keymap.set("x", lhs, function()
      local s, _, e = utils.visual_range()
      utils.exit_visual()
      M.send_to_associated_session(ebuf, s, e)
    end, { buffer = ebuf, desc = "org: send the selected lines to the session" })
  end
  return true
end

--- Send lines `s`..`e` (default: all) of the associated edit buffer `ebuf`
--- to its session and show the session.
function M.send_to_associated_session(ebuf, s, e)
  ebuf = (ebuf == nil or ebuf == 0) and vim.api.nvim_get_current_buf() or ebuf
  local a = associated[ebuf]
  if not a then
    utils.warn("This edit buffer is not associated with a session")
    return false
  end
  local code = table.concat(vim.api.nvim_buf_get_lines(ebuf, (s or 1) - 1, e or -1, false), "\n")
  local ok, sess = pcall(get_session, a.bufnr, a.lang, a.args, a.name)
  if not ok then
    utils.error("babel: " .. tostring(sess))
    return false
  end
  session_mod.eval(sess, code, "output", function(res)
    if res.error then
      utils.error("babel: " .. vim.trim(res.error))
    end
  end, { timeout = require("org.config").opts.babel.timeout })
  local win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_config(win).relative ~= "" then
    -- a float cannot be split: show the session from a normal window
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_get_config(w).relative == "" then
        vim.api.nvim_set_current_win(w)
        break
      end
    end
  end
  session_mod.show(sess)
  if vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
  end
  return sess
end
