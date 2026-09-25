---@mod org.special Edit a region of an org buffer in a separate buffer
---
--- Used by `edit_special` (src blocks, tables formulas) and narrowing.
--- The source range is tracked with extmarks, so edits elsewhere in the
--- source buffer while the special buffer is open are safe. `:w` in the
--- special buffer writes back; the configured `save_exit` / `abort`
--- mappings leave it.

local config = require("org.config")
local ui = require("org.ui")
local utils = require("org.utils")

local M = {}

local ns = vim.api.nvim_create_namespace("org.special")

---@class org.SpecialOpts
---@field source_buf integer
---@field start_line integer first line of the edited region (1-based)
---@field end_line integer last line (inclusive); may be start_line-1 for an empty region
---@field lines string[] initial content of the edit buffer
---@field filetype? string
---@field name? string buffer name suffix
---@field to_source? fun(lines: string[]): string[] transform before writing back
---@field on_close? fun()
---@field window? string
---@field start_col? integer edit an object: 0-based byte column of its start on `start_line`
---@field end_col? integer 0-based byte column after its end on `end_line`

---@param opts org.SpecialOpts
function M.open(opts)
  local src = opts.source_buf
  local object = opts.start_col ~= nil
  -- extmarks around the region: start mark before the first line,
  -- end mark at the end of the last line (or around an object)
  local sm = vim.api.nvim_buf_set_extmark(src, ns, opts.start_line - 1, opts.start_col or 0, { right_gravity = false })
  local end_row = math.max(opts.end_line, opts.start_line - 1)
  local em
  if object then
    em = vim.api.nvim_buf_set_extmark(src, ns, opts.end_line - 1, opts.end_col, { right_gravity = true })
  elseif opts.end_line >= opts.start_line then
    local last = vim.api.nvim_buf_get_lines(src, end_row - 1, end_row, false)[1] or ""
    em = vim.api.nvim_buf_set_extmark(src, ns, end_row - 1, #last, { right_gravity = true })
  end
  local empty_region = not object and opts.end_line < opts.start_line

  local buf = vim.api.nvim_create_buf(false, false)
  local base = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(src), ":t")
  pcall(vim.api.nvim_buf_set_name, buf, string.format("org-special://%s/%s#%d", base, opts.name or "edit", buf))
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, opts.lines)
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modified = false
  if opts.filetype and opts.filetype ~= "" then
    local ft = vim.filetype.match({ filename = "x." .. opts.filetype }) or opts.filetype
    vim.bo[buf].filetype = ft
  end

  local function region()
    local s = vim.api.nvim_buf_get_extmark_by_id(src, ns, sm, {})
    if empty_region then
      return s[1] + 1, s[1]
    end
    local e = vim.api.nvim_buf_get_extmark_by_id(src, ns, em, {})
    return s[1] + 1, e[1] + 1
  end

  local function write_back()
    if not vim.api.nvim_buf_is_valid(src) then
      utils.error("Source buffer no longer exists")
      return false
    end
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    if opts.to_source then
      lines = opts.to_source(lines)
      if lines == nil then
        return false
      end
    end
    if object then
      local s = vim.api.nvim_buf_get_extmark_by_id(src, ns, sm, {})
      local e = vim.api.nvim_buf_get_extmark_by_id(src, ns, em, {})
      vim.api.nvim_buf_set_text(src, s[1], s[2], e[1], e[2], lines)
      vim.api.nvim_buf_del_extmark(src, ns, sm)
      vim.api.nvim_buf_del_extmark(src, ns, em)
      sm = vim.api.nvim_buf_set_extmark(src, ns, s[1], s[2], { right_gravity = false })
      local erow = s[1] + #lines - 1
      local ecol = (#lines == 1 and s[2] or 0) + #lines[#lines]
      em = vim.api.nvim_buf_set_extmark(src, ns, erow, ecol, { right_gravity = true })
      vim.bo[buf].modified = false
      return true
    end
    local s, e = region()
    vim.api.nvim_buf_set_lines(src, s - 1, e, false, lines)
    -- re-anchor marks on the new region
    vim.api.nvim_buf_del_extmark(src, ns, sm)
    sm = vim.api.nvim_buf_set_extmark(src, ns, s - 1, 0, { right_gravity = false })
    if #lines > 0 then
      local last_row = s - 1 + #lines - 1
      local last = vim.api.nvim_buf_get_lines(src, last_row, last_row + 1, false)[1] or ""
      if em then
        vim.api.nvim_buf_del_extmark(src, ns, em)
      end
      em = vim.api.nvim_buf_set_extmark(src, ns, last_row, #last, { right_gravity = true })
      empty_region = false
    else
      empty_region = true
    end
    vim.bo[buf].modified = false
    return true
  end

  local closed = false
  local function cleanup()
    if closed then
      return
    end
    closed = true
    if vim.api.nvim_buf_is_valid(src) then
      pcall(vim.api.nvim_buf_del_extmark, src, ns, sm)
      if em then
        pcall(vim.api.nvim_buf_del_extmark, src, ns, em)
      end
    end
    if opts.on_close then
      opts.on_close()
    end
  end

  local win = ui.open_buffer_window(buf, opts.window or config.opts.win_split_mode, { title = opts.name })
  local prev_win = vim.fn.win_getid(vim.fn.winnr("#"))

  local function close()
    cleanup()
    if vim.api.nvim_win_is_valid(win) then
      if #vim.api.nvim_list_wins() > 1 then
        vim.api.nvim_win_close(win, true)
      else
        vim.api.nvim_set_current_buf(src)
      end
    end
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
    if prev_win and vim.api.nvim_win_is_valid(prev_win) then
      pcall(vim.api.nvim_set_current_win, prev_win)
    end
  end

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function()
      write_back()
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = cleanup,
  })

  local maps = config.opts.mappings.edit_src or {}
  for _, lhs in ipairs(config.lhs_list(maps.save_exit)) do
    vim.keymap.set("n", lhs, function()
      if vim.bo[buf].modified then
        write_back()
      end
      close()
    end, { buffer = buf, desc = "org: save and exit edit buffer" })
  end
  for _, lhs in ipairs(config.lhs_list(maps.abort)) do
    vim.keymap.set("n", lhs, function()
      vim.bo[buf].modified = false
      close()
    end, { buffer = buf, desc = "org: abort edit buffer" })
  end
  vim.b[buf].org_special = true
  vim.b[buf].org_special_source = src
  vim.b[buf].org_special_kind = opts.kind
  vim.b[buf].org_special_switches = opts.switches
  return buf, win
end

local function common_indent(lines)
  local min
  for _, l in ipairs(lines) do
    if l:match("%S") then
      local n = #l:match("^(%s*)")
      if not min or n < min then
        min = n
      end
    end
  end
  return min or 0
end

local EXPORT_FT = { html = "html", latex = "tex", tex = "tex", md = "markdown", markdown = "markdown", ascii = "text" }

--- LaTeX fragment of `line` covering byte column `col` (1-based):
--- `$x$`, `$$x$$`, `\(x\)`, `\[x\]`. Returns the 1-based start and end of
--- its contents (between the delimiters), or nil.
local function latex_fragment_at(line, col)
  local pats = {
    { "\\%(", "\\%)" },
    { "\\%[", "\\%]" },
    { "%$%$", "%$%$" },
  }
  for _, p in ipairs(pats) do
    local init = 1
    while true do
      local s, os_ = line:find(p[1], init)
      if not s then
        break
      end
      local cs, e = line:find(p[2], os_ + 1)
      if not cs then
        break
      end
      if col >= s and col <= e then
        return os_ + 1, cs - 1
      end
      init = e + 1
    end
  end
  -- $x$: no space after the opening / before the closing dollar
  local init = 1
  while true do
    local s = line:find("%$", init)
    if not s then
      break
    end
    local e = line:find("%$", s + 1)
    if not e then
      break
    end
    local inner = line:sub(s + 1, e - 1)
    if
      inner ~= ""
      and not inner:match("^%s")
      and not inner:match("%s$")
      and line:sub(s - 1, s - 1) ~= "$"
      and line:sub(e + 1, e + 1) ~= "$"
      and col >= s
      and col <= e
    then
      return s + 1, e - 1
    end
    init = e + 1
  end
end

--- C-c ' on an object or line that is not a block (org-edit-special):
--- inline src block, footnote reference, LaTeX fragment, INCLUDE /
--- SETUPFILE / BIBLIOGRAPHY keyword, planning line, timestamp or link.
--- Returns true when something was done.
function M.edit_object(bufnr, lnum, col)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
  -- keywords that name a file: visit it
  local key, value = line:match("^%s*#%+(%w+):%s*(.-)%s*$")
  if key then
    key = key:upper()
    if key == "INCLUDE" or key == "SETUPFILE" or key == "BIBLIOGRAPHY" then
      if value == "" then
        utils.error("No file to edit")
        return true
      end
      local f = value:match('^"(.-)"') or value:match("^(%S+)")
      if f:match("^%a[%w+.-]*://") then
        utils.error("Files located with a URL cannot be edited")
        return true
      end
      f = f:gsub("::.*$", "")
      local dir = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":p:h")
      utils.open_file(utils.expand(f, dir))
      return true
    end
  end
  -- planning line: org-deadline and/or org-schedule
  if line:match("^%s*SCHEDULED:") or line:match("^%s*DEADLINE:") or line:match("^%s*CLOSED:") then
    local ts = require("org.timestamps")
    local done = false
    if line:find("DEADLINE:", 1, true) then
      ts.deadline()
      done = true
    end
    if line:find("SCHEDULED:", 1, true) then
      ts.schedule()
      done = true
    end
    if done then
      return true
    end
  end
  local babel = require("org.babel")
  -- inline src block: edit its body (kept on one line)
  local ib = babel.inline_at(line, col)
  if ib and not ib.call then
    local open = line:find("{", ib.s, true)
    M.open({
      source_buf = bufnr,
      start_line = lnum,
      end_line = lnum,
      start_col = open,
      end_col = ib.e - 1,
      lines = { ib.body },
      filetype = ib.lang,
      name = "inline-" .. ib.lang,
      kind = "inline-src",
      to_source = function(new)
        local text = table.concat(new, "\n"):gsub("\n[ \t]*", " ")
        return { vim.trim(text) }
      end,
    })
    return true
  end
  -- footnote reference: edit its definition
  local fn = require("org.footnotes").at_point(bufnr, lnum, col)
  if fn and (fn.kind == "reference" or fn.kind == "inline") then
    if not fn.label then
      utils.error("Cannot edit remotely anonymous footnotes")
      return true
    end
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local function inline_def(l, row)
      local s = l:find("[fn:" .. fn.label .. ":", 1, true)
      if not s then
        return nil
      end
      local depth, e = 0, nil
      for i = s, #l do
        local c = l:sub(i, i)
        if c == "[" then
          depth = depth + 1
        elseif c == "]" then
          depth = depth - 1
          if depth == 0 then
            e = i
            break
          end
        end
      end
      if e then
        return { row = row, s = s + 5 + #fn.label, e = e }
      end
    end
    local target
    if fn.kind == "inline" then
      target = inline_def(line, lnum)
    else
      for _, d in ipairs(require("org.footnotes").collect_definitions(lines)) do
        if d.label == fn.label then
          target = { def = d }
        end
      end
      if not target then
        for i, l in ipairs(lines) do
          local t = inline_def(l, i)
          if t then
            target = t
            break
          end
        end
      end
    end
    if not target then
      utils.error("No definition for footnote " .. fn.label)
      return true
    end
    if target.def then
      local d = target.def
      local first = lines[d.start]
      local prefix = first:match("^%[fn:[^%]]+%]%s?") or ""
      local content = { first:sub(#prefix + 1) }
      vim.list_extend(content, vim.list_slice(lines, d.start + 1, d.stop))
      M.open({
        source_buf = bufnr,
        start_line = d.start,
        end_line = d.stop,
        start_col = #prefix,
        end_col = #lines[d.stop],
        lines = content,
        filetype = "org",
        name = "footnote-" .. fn.label,
        kind = "footnote",
      })
    else
      local l = lines[target.row]
      M.open({
        source_buf = bufnr,
        start_line = target.row,
        end_line = target.row,
        start_col = target.s - 1,
        end_col = target.e - 1,
        lines = vim.split(l:sub(target.s, target.e - 1), "\n", { plain = true }),
        filetype = "org",
        name = "footnote-" .. fn.label,
        kind = "footnote",
        to_source = function(new)
          local text = table.concat(new, "\n")
          if text:find("\n[ \t]*\n") then
            utils.error("Inline definitions cannot contain blank lines")
            return nil
          end
          return { (text:gsub("\n", " ")) }
        end,
      })
    end
    return true
  end
  -- LaTeX fragment
  local fs, fe = latex_fragment_at(line, col)
  if fs then
    local in_table = line:match("^%s*|") ~= nil
    M.open({
      source_buf = bufnr,
      start_line = lnum,
      end_line = lnum,
      start_col = fs - 1,
      end_col = fe,
      lines = { line:sub(fs, fe) },
      filetype = "tex",
      name = "latex-fragment",
      kind = "latex-fragment",
      to_source = function(new)
        local text = table.concat(new, "\n"):gsub("\n[ \t]*\n", "\n")
        if in_table then
          text = text:gsub("\n", " ")
        end
        return vim.split(text, "\n", { plain = true })
      end,
    })
    return true
  end
  -- timestamp: org-timestamp / org-timestamp-inactive
  local ts = require("org.date").at_col(line, col)
  if ts then
    local t = require("org.timestamps")
    if ts.date and ts.date.active == false then
      t.insert_inactive()
    else
      t.insert_active()
    end
    return true
  end
  -- link: visit it (ffap)
  local links = require("org.links")
  if links.link_at_cursor and links.link_at_cursor() then
    links.open_at_point()
    return true
  end
  return false
end

--- Edit the element at the cursor in a separate buffer (org-edit-special
--- for elements other than src blocks and tables): example, export and
--- comment blocks, LaTeX environments and fixed-width (`: `) areas.
--- Returns false when there is nothing to edit.
function M.edit_element(bufnr, lnum)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  lnum = lnum or vim.api.nvim_win_get_cursor(0)[1]
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local blocks = require("org.babel.blocks")
  if lnum < 1 or lnum > #lines then
    return false
  end
  local line = lines[lnum]
  -- fixed-width area
  local function fixed(l)
    return l and (l:match("^%s*:%s") or l:match("^%s*:$"))
  end
  if fixed(line) then
    local s, e = lnum, lnum
    while fixed(lines[s - 1]) do
      s = s - 1
    end
    while fixed(lines[e + 1]) do
      e = e + 1
    end
    local indent = lines[s]:match("^(%s*)")
    local content = {}
    for i = s, e do
      content[#content + 1] = lines[i]:match("^%s*: (.*)$") or ""
    end
    M.open({
      source_buf = bufnr,
      start_line = s,
      end_line = e,
      lines = content,
      name = "fixed-width",
      to_source = function(new)
        local out = {}
        for i, l in ipairs(new) do
          out[i] = indent .. (l == "" and ":" or (": " .. l))
        end
        return out
      end,
    })
    return
  end
  -- LaTeX environment
  for s = lnum, 1, -1 do
    local env = lines[s]:match("^%s*\\begin{([^}]+)}")
    if env then
      local e = s
      while e <= #lines and not lines[e]:find("\\end{" .. env .. "}", 1, true) do
        e = e + 1
      end
      if e <= #lines and e >= lnum then
        M.open({
          source_buf = bufnr,
          start_line = s,
          end_line = e,
          lines = vim.list_slice(lines, s, e),
          filetype = "tex",
          name = "latex-" .. env,
        })
        return
      end
      break
    end
    if s < lnum and (lines[s]:match("^%s*$") or lines[s]:match("^%*+%s")) then
      break
    end
  end
  -- example / export / comment blocks
  for s = lnum, 1, -1 do
    local l = lines[s]:lower()
    if s < lnum and (l:match("^%s*#%+end_") or l:match("^%*+%s")) then
      break
    end
    local kind, rest = l:match("^%s*#%+begin_(%S+)%s*(.*)$")
    if kind then
      if kind ~= "example" and kind ~= "export" and kind ~= "comment" then
        break
      end
      local e = s + 1
      while e <= #lines and not lines[e]:lower():match("^%s*#%+end_" .. vim.pesc(kind)) do
        e = e + 1
      end
      if e > #lines or e < lnum then
        break
      end
      local body = blocks.unescape(vim.list_slice(lines, s + 1, e - 1))
      local n = common_indent(body)
      local ded = {}
      for i, x in ipairs(body) do
        ded[i] = x:sub(n + 1)
      end
      local prefix = lines[s]:match("^(%s*)")
      local ft = kind == "comment" and "org" or nil
      if kind == "export" then
        local backend = rest:match("^(%S+)") or ""
        ft = EXPORT_FT[backend] or backend
      end
      M.open({
        source_buf = bufnr,
        start_line = s + 1,
        end_line = e - 1,
        lines = #ded > 0 and ded or { "" },
        filetype = ft,
        name = kind,
        kind = kind,
        switches = kind == "example" and lines[s]:match("^%s*#%+%a+_%a+%s*(.*)$") or nil,
        to_source = function(new)
          local out = {}
          for i, x in ipairs(blocks.escape(new)) do
            out[i] = x == "" and "" or prefix .. x
          end
          return out
        end,
      })
      return
    end
  end
  return false
end

return M
