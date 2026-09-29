---@mod org.mouse Following links with the mouse
---
--- Emacs's org-mouse-map: mouse-2 opens the link clicked
--- (org-open-at-mouse), mouse-3 opens it in Emacs (org-find-file-at-mouse)
--- and, with org-mouse-1-follows-link, a short mouse-1 click (or a double
--- click) follows it. Here <MiddleMouse> and <RightMouse> are the
--- `open_at_mouse` and `find_file_at_mouse` actions (away from a link they
--- do what the click normally does), and `links.mouse_1_follows_link`
--- adds the <LeftMouse> handling.

local config = require("org.config")

local M = {}

--- Move the cursor to the mouse click (mouse-set-point). Replaced in tests.
function M._mouse_set_point()
  local pos = vim.fn.getmousepos()
  if pos.winid == 0 or pos.line == 0 then
    return false
  end
  -- the native click places the cursor, concealed link text included
  vim.api.nvim_feedkeys(vim.keycode("<LeftMouse>"), "nx", false)
  return true
end

--- Follow the link under the cursor with the Emacs prefix `arg`; false
--- when there is none. Runs the follow hook (OrgFollowLink).
local function follow(arg)
  -- org-mouse's activated stars, bullets and checkboxes
  if require("org.org_mouse").open_at_point(true) then
    return true
  end
  local links = require("org.links")
  if not links.link_at_cursor() then
    return false
  end
  local r = links.open_at_point(arg)
  links.run_follow_hook()
  return r ~= false
end

--- <MiddleMouse>: open the link clicked (org-open-at-mouse). Returns false
--- away from a link (the click then pastes, as usual).
function M.open_at_mouse()
  if not M._mouse_set_point() then
    return false
  end
  return follow(0)
end

--- <RightMouse>: open the link clicked in Neovim, even when `file_apps`
--- names an external app, and internal links in another window
--- (org-find-file-at-mouse: org-open-at-point 'in-emacs).
function M.find_file_at_mouse()
  if not M._mouse_set_point() then
    return false
  end
  return follow(4)
end

-- The last <LeftMouse> press: { time (ms), row, col } (screen position).
M._press = nil

--- Should the <LeftRelease> after `p` (a press) at `r` follow a link?
--- `setting` is `links.mouse_1_follows_link`: true, or the longest click
--- in ms (org-mouse-1-follows-link); a moved mouse is a drag.
---@param setting any
---@param p? { time: number, row: integer, col: integer }
---@param r { time: number, row: integer, col: integer }
---@return boolean
function M.click_follows(setting, p, r)
  if not setting or setting == "double" or not p then
    return false
  end
  if p.row ~= r.row or p.col ~= r.col then
    return false
  end
  if type(setting) == "number" and r.time - p.time > setting then
    return false
  end
  return true
end

local function now_pos()
  local pos = vim.fn.getmousepos()
  return { time = vim.uv.hrtime() / 1e6, row = pos.screenrow, col = pos.screencol }
end

--- After a <LeftRelease> the cursor is on the click. A click on a citation
--- key acts on it whatever `mouse_1_follows_link` says (oc-basic binds
--- <mouse-1> on the key itself); otherwise a short click follows the link.
function M._after_release(released)
  if vim.fn.mode() == "n" and require("org.cite").mouse_click() then
    M._press = nil
    return
  end
  if M.click_follows(config.opts.links.mouse_1_follows_link, M._press, released or now_pos()) then
    M._press = nil
    if vim.fn.mode() == "n" then
      follow(0)
    end
  end
end

--- After a double click's first half placed the cursor: follow the link
--- there, or select the word as a double click does.
function M._after_double()
  if not follow(0) then
    vim.api.nvim_feedkeys(vim.keycode("<2-LeftMouse>"), "n", false)
  end
end

--- Buffer-local <LeftMouse> handling for `links.mouse_1_follows_link` and
--- citation keys, and the keys of org-mouse (`mouse.org_mouse`).
function M.attach(bufnr)
  require("org.org_mouse").attach(bufnr)
  require("org.cite_mouse").attach(bufnr)
  local setting = (config.opts.links or {}).mouse_1_follows_link
  local o = { buffer = bufnr, expr = true, replace_keycodes = true }
  local function on_release()
    local released = now_pos()
    M._released = released
    return "<LeftRelease><Cmd>lua require('org.mouse')._after_release(require('org.mouse')._released)<CR>"
  end
  if not setting or setting == "double" then
    -- a click on a citation key still acts on it
    vim.keymap.set("n", "<LeftRelease>", on_release, vim.tbl_extend("force", o, { desc = "org: citation key clicked" }))
  end
  if not setting then
    return
  end
  if setting == "double" then
    vim.keymap.set("n", "<2-LeftMouse>", function()
      return "<LeftMouse><Cmd>lua require('org.mouse')._after_double()<CR>"
    end, vim.tbl_extend("force", o, { desc = "org: follow the link clicked" }))
    return
  end
  vim.keymap.set("n", "<LeftMouse>", function()
    M._press = now_pos()
    return "<LeftMouse>"
  end, vim.tbl_extend("force", o, { desc = "org: set point (a short click follows a link)" }))
  vim.keymap.set(
    "n",
    "<LeftRelease>",
    on_release,
    vim.tbl_extend("force", o, { desc = "org: follow the link clicked" })
  )
end

return M
