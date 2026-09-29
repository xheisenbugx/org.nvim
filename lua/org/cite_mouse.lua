---@mod org.cite_mouse Highlighting the citation key under the mouse
---
--- oc-basic gives citation keys a mouse-face
--- (org-cite-basic-mouse-over-key-face): the key under the mouse is
--- highlighted. Here a <MouseMove> mapping does it, with 'mousemoveevent'
--- turned on for org buffers while `export.cite.basic_mouse_over_key_face`
--- is set (Emacs's default: the `highlight` face, the OrgCiteMouseOver
--- highlight group, linked to Visual).

local config = require("org.config")

local M = {}

local ns = vim.api.nvim_create_namespace("org.cite_mouse")

vim.api.nvim_set_hl(0, "OrgCiteMouseOver", { link = "Visual", default = true })

--- The highlight group of the option: "highlight" (Emacs's face) is
--- OrgCiteMouseOver, anything else a highlight group; nil when off.
---@return string|nil
function M.face()
  local cite = ((config.opts.export or {}).cite or {})
  local face = cite.basic_mouse_over_key_face
  if face == nil or face == false or face == "" then
    return nil
  end
  if face == "highlight" then
    return "OrgCiteMouseOver"
  end
  return face
end

--- The buffer where a key is highlighted, or nil.
M._buf = nil

local function clear()
  if M._buf and vim.api.nvim_buf_is_valid(M._buf) then
    vim.api.nvim_buf_clear_namespace(M._buf, ns, 0, -1)
  end
  M._buf = nil
end

--- The citation key at (row, col0) of `bufnr`: its start and end
--- positions { row, col0 }, or nil.
function M.key_at(bufnr, row, col)
  local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
  if col >= #line or not line:find("[cite", 1, true) and not line:find("@", 1, true) then
    return nil
  end
  local cite = require("org.cite")
  local ok, ctx = pcall(cite.at_cursor, bufnr, row, col)
  if not ok or not ctx or ctx.type ~= "citation-reference" then
    return nil
  end
  local r = ctx.reference
  if ctx.point < r.key_begin or ctx.point >= r.key_end then
    return nil
  end
  local r1, c1 = cite.position(ctx.region, r.key_begin)
  local r2, c2 = cite.position(ctx.region, r.key_end)
  return { r1, c1 }, { r2, c2 }
end

--- <MouseMove>: highlight the key under the mouse, clear the previous one.
function M.on_move()
  local face = M.face()
  local pos = vim.fn.getmousepos()
  if not face or pos.winid == 0 or pos.line == 0 then
    clear()
    return
  end
  local bufnr = vim.api.nvim_win_get_buf(pos.winid)
  if vim.bo[bufnr].filetype ~= "org" then
    clear()
    return
  end
  local s, e = M.key_at(bufnr, pos.line, pos.column - 1)
  if not s then
    clear()
    return
  end
  if M._buf ~= bufnr then
    clear()
  else
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  end
  M._buf = bufnr
  pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, s[1] - 1, s[2], {
    end_row = e[1] - 1,
    end_col = e[2],
    hl_group = face,
    priority = 250,
  })
end

M.ns = ns

--- Map <MouseMove> in an org buffer (and turn 'mousemoveevent' on) when
--- the option is set.
function M.attach(bufnr)
  if not M.face() or vim.o.mouse == "" then
    return
  end
  vim.o.mousemoveevent = true
  vim.keymap.set({ "n", "i", "x" }, "<MouseMove>", function()
    M.on_move()
  end, { buffer = bufnr, desc = "org: highlight the citation key under the mouse" })
end

return M
