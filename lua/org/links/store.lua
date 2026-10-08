---@mod org.links.store Storing links (org-store-link)
---
--- The link to a location (link_to_location: id:, file: with a
--- search string, help:, man:, directories, custom types' `store`)
--- and the stored links list. Part of org.links, which loads it.

local config = require("org.config")
local files = require("org.files")
local utils = require("org.utils")
local shared = require("org.links.shared")

local M = require("org.links")

local lopts = shared.lopts

---------------------------------------------------------------------------
-- Storing
---------------------------------------------------------------------------

--- Add to the stored links (org-link--add-to-stored-links).
local function add_stored(link, desc, quiet)
  for i, s in ipairs(M.stored) do
    if s.link == link and s.desc == desc then
      if i == 1 then
        if not quiet then
          utils.notify("This link has already been stored")
        end
        return M.stored[1]
      end
      table.remove(M.stored, i)
      table.insert(M.stored, 1, { link = link, desc = desc })
      if not quiet then
        utils.notify("Link moved to front: " .. (desc or link))
      end
      return M.stored[1]
    end
  end
  table.insert(M.stored, 1, { link = link, desc = desc })
  if not quiet then
    utils.notify("Stored: " .. (desc or link))
  end
  return M.stored[1]
end

local function display_path(path)
  return utils.abbreviate(path)
end

--- Name of the element at `lnum` (its `#+NAME:` line, or a src block /
--- table / block below one) and the line of the element start.
local function named_element_at(bufnr, lnum)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local name_pat = "^%s*#%+[Nn][Aa][Mm][Ee]:%s*(.-)%s*$"
  local function name_above(l)
    local k = l - 1
    while k >= 1 and lines[k]:match("^%s*#%+[%w_]+:") do
      local nm = lines[k]:match(name_pat)
      if nm then
        -- the element starts at its first affiliated keyword
        local s = k
        while s > 1 and lines[s - 1]:match("^%s*#%+[%w_]+:") do
          s = s - 1
        end
        return nm, s
      end
      k = k - 1
    end
  end
  local line = lines[lnum] or ""
  local nm = line:match(name_pat)
  if nm and nm ~= "" then
    local s = lnum
    while s > 1 and lines[s - 1]:match("^%s*#%+[%w_]+:") do
      s = s - 1
    end
    return nm, s
  end
  if line:match("^%s*#%+[%w_]+:") then
    local k = lnum + 1
    while lines[k] and lines[k]:match("^%s*#%+[%w_]+:") and not lines[k]:lower():match("^%s*#%+begin_") do
      k = k + 1
    end
    return name_above(k)
  end
  if line:match("^%s*|") then
    local k = lnum
    while k > 1 and lines[k - 1]:match("^%s*|") do
      k = k - 1
    end
    return name_above(k)
  end
  -- inside a #+begin_ ... #+end_ block
  for k = lnum, 1, -1 do
    local l = lines[k]
    if k < lnum and l:lower():match("^%s*#%+end_") then
      return nil
    end
    if l:lower():match("^%s*#%+begin_") then
      return name_above(k)
    end
    if l:match("^%*+%s") then
      return nil
    end
  end
end

--- Link to a code line from a src / example edit buffer: `(label)`,
--- creating the `(ref:label)` when `interactive`.
local function coderef_link(bufnr, lnum, interactive)
  local src = vim.b[bufnr].org_special_source
  if not src or not vim.api.nvim_buf_is_valid(src) then
    return nil
  end
  local pat = require("org.babel.blocks").coderef_pattern(vim.b[bufnr].org_special_switches)
  local fmt = require("org.babel.blocks").coderef_format(vim.b[bufnr].org_special_switches)
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
  local label = line:match(pat)
  if not label then
    if not interactive then
      return nil
    end
    label = utils.input({ prompt = "Code line label: " })
    if not label or vim.trim(label) == "" then
      return nil
    end
    label = vim.trim(label)
    local ref = fmt:gsub("%%s", function()
      return label
    end)
    local pad = math.max(1, 79 - #ref - vim.fn.strdisplaywidth(line))
    vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum, false, { line .. string.rep(" ", pad) .. ref })
  end
  local name = vim.api.nvim_buf_get_name(src)
  if name == "" then
    return { link = "(" .. label .. ")", desc = nil }
  end
  return { link = "file:" .. display_path(name) .. "::(" .. label .. ")", desc = nil }
end

--- Selection of Visual mode { srow, scol, erow, ecol } (1-based,
--- inclusive), leaving Visual mode; nil in other modes.
local function visual_region()
  local mode = vim.fn.mode()
  if mode ~= "v" and mode ~= "V" and mode ~= "\22" then
    return nil
  end
  local srow, scol, erow, ecol = utils.visual_range()
  utils.exit_visual()
  if mode == "V" then
    scol = 1
    ecol = #(vim.api.nvim_buf_get_lines(0, erow - 1, erow, false)[1] or "")
  else
    local line = vim.api.nvim_buf_get_lines(0, erow - 1, erow, false)[1] or ""
    ecol = utils.char_end(line, ecol)
  end
  return { srow, scol, erow, ecol }
end

--- Search string, description and position for a link to `lnum`
--- (org-link-precise-link-target). `region` = { srow, scol, erow, ecol }.
local function precise_target(bufnr, lnum, region, ctx)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local result
  if region then
    local parts = vim.api.nvim_buf_get_text(bufnr, region[1] - 1, region[2] - 1, region[3] - 1, region[4], {})
    if type(ctx) == "number" and ctx > 0 then
      parts = vim.list_slice(parts, 1, ctx)
    end
    result = { search = M.normalize_string(table.concat(parts, "\n"), true), pos = { region[1], region[2] } }
  elseif vim.bo[bufnr].filetype == "org" then
    local file = files.get_buffer(bufnr)
    local name, name_line = named_element_at(bufnr, lnum)
    local hl = file:headline_at(lnum)
    if name then
      result = { search = name, desc = name, pos = { name_line, 1 } }
    elseif not hl then
      result = { search = M.normalize_string(lines[lnum] or "", true), pos = { lnum, 1 } }
    else
      local title = M.normalize_string(hl.title)
      local cid = hl.properties.CUSTOM_ID
      result = { search = cid and ("#" .. cid) or ("*" .. title), desc = title, pos = { hl.line, 0 }, hl = hl }
    end
  else
    result = { search = M.normalize_string(lines[lnum] or "", true), pos = { lnum, 1 } }
  end
  if result and result.search:match("%S") then
    return result
  end
end

--- `file:` link to `lnum` with a search string (org-link--file-link-to-here).
local function file_link_to_here(bufnr, lnum, region, ctx)
  local link = "file:" .. display_path(vim.api.nvim_buf_get_name(bufnr))
  local desc
  if ctx then
    local t = precise_target(bufnr, lnum, region, ctx)
    if t then
      link = link .. "::" .. t.search
      desc = t.desc
    end
  end
  return { link = link, desc = desc }
end

--- The ID to link to (org-id--get-id-to-store-link): the entry's, an
--- inherited one when `id.link_consider_parent_id`, created when `create`.
local function id_to_store(bufnr, hl, create, ctx)
  local idc = config.opts.id or {}
  local inherit = idc.link_consider_parent_id and idc.link_use_context ~= false and ctx
  if hl.properties.ID and hl.properties.ID ~= "" then
    return hl.properties.ID, hl
  end
  if inherit then
    local p = hl.parent
    while p do
      if p.properties.ID and p.properties.ID ~= "" then
        return p.properties.ID, p
      end
      p = p.parent
    end
  end
  if create then
    local id = require("org.id").get_create({ bufnr = bufnr, lnum = hl.line })
    return id, hl
  end
end

--- `id:` link to the file before its first headline: the ID lives in the
--- file-level property drawer, created at the top of the file (after
--- leading comments) like Emacs 9.8. The description is the #+TITLE, else
--- the file name.
local function file_id_store_link(bufnr, file, lnum, region, ctx, interactive, force)
  local use = config.opts.links.use_id
  local id = file.properties.ID
  if id == "" then
    id = nil
  end
  local create = force
    or use == true
    or (
      interactive
      and (
        use == "create-if-interactive"
        or (use == "create-if-interactive-and-no-custom-id" and not file.properties.CUSTOM_ID)
      )
    )
  if not create and not (use and id) then
    return nil
  end
  local idc = config.opts.id or {}
  -- the search string is computed before the drawer moves the lines
  local precise = ctx and idc.link_use_context ~= false and precise_target(bufnr, lnum, region, ctx) or nil
  id = id or require("org.id").get_create({ bufnr = bufnr, lnum = lnum })
  if not id then
    return nil
  end
  local link = "id:" .. id
  local desc = file.settings.title or vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":t")
  if precise and (precise.pos[1] > 1 or precise.pos[2] > 1) then
    link = link .. "::" .. precise.search
    desc = precise.desc
  end
  return { link = link, desc = desc }
end

--- `id:` link to the entry at `lnum` when `links.use_id` asks for one
--- (org-id-store-link-maybe / org-id-store-link).
local function id_store_link(bufnr, lnum, region, ctx, interactive, force)
  if vim.bo[bufnr].filetype ~= "org" or vim.api.nvim_buf_get_name(bufnr) == "" then
    return nil
  end
  local file = files.get_buffer(bufnr)
  local hl = file:headline_at(lnum)
  if not hl then
    return file_id_store_link(bufnr, file, lnum, region, ctx, interactive, force)
  end
  local use = config.opts.links.use_id
  local create = force
    or use == true
    or (
      interactive
      and (
        use == "create-if-interactive"
        or (use == "create-if-interactive-and-no-custom-id" and not hl.properties.CUSTOM_ID)
      )
    )
  if not create and not (use and id_to_store(bufnr, hl, false, ctx)) then
    return nil
  end
  local idc = config.opts.id or {}
  local precise = ctx and idc.link_use_context ~= false and precise_target(bufnr, lnum, region, ctx) or nil
  local id, owner = id_to_store(bufnr, hl, true, ctx)
  if not id then
    return nil
  end
  owner = files.get_buffer(bufnr):headline_at(owner.line) or owner
  local link = "id:" .. id
  local desc = owner.title
  if precise and (precise.pos[1] > owner.line or (precise.pos[1] == owner.line and precise.pos[2] > 0)) then
    link = link .. "::" .. precise.search
    desc = precise.desc
  end
  return { link = link, desc = desc }
end

--- Store an `id:` link to the entry at the cursor, creating the ID, with
--- a search string when `id.link_use_context` applies (org-id-store-link).
function M.store_id_link()
  local bufnr = vim.api.nvim_get_current_buf()
  local region = visual_region()
  local ctx = lopts().context_for_files
  if ctx == nil then
    ctx = true
  end
  local l = id_store_link(bufnr, vim.api.nvim_win_get_cursor(0)[1], region, ctx, true, true)
  if not l then
    return nil
  end
  return add_stored(l.link, l.desc and M.display_format(l.desc) or nil)
end

--- Link from a Vim help buffer: `help:tag` of the nearest tag above.
local function help_link(bufnr, lnum)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, lnum, false)
  for i = #lines, 1, -1 do
    local tag = (" " .. lines[i] .. " "):match("%s%*([^%s*|]+)%*%s")
    if tag then
      return { link = "help:" .. tag, desc = nil }
    end
  end
  local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":t:r")
  return { link = "help:" .. name, desc = nil }
end

--- Link from a directory listing (netrw, oil): the file at the cursor.
local function directory_link(bufnr, lnum)
  local ft = vim.bo[bufnr].filetype
  if ft == "oil" then
    local ok, oil = pcall(require, "oil")
    if ok then
      local dir = oil.get_current_dir(bufnr)
      local entry = oil.get_cursor_entry()
      if dir then
        return { link = "file:" .. display_path(dir .. (entry and entry.name or "")), desc = nil }
      end
    end
    return nil
  end
  local dir = vim.b[bufnr].netrw_curdir or vim.api.nvim_buf_get_name(bufnr)
  if dir == "" or not utils.is_dir(dir) then
    return nil
  end
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
  local name = vim.trim(line):gsub("[*@/=|]$", "")
  if name ~= "" and not name:match('^["=]') and utils.exists(dir .. "/" .. name) then
    return { link = "file:" .. display_path(vim.fs.normalize(dir .. "/" .. name)), desc = nil }
  end
  return { link = "file:" .. display_path(vim.fs.normalize(dir)) .. "/", desc = nil }
end

--- Links from the `store` functions of custom link types.
local function custom_store(interactive)
  local found = {}
  local names = vim.tbl_keys(lopts().types or {})
  table.sort(names)
  for _, name in ipairs(names) do
    local t = M.link_type(name)
    if t and t.store then
      local r = t.store(interactive)
      if type(r) == "string" then
        r = { link = r }
      end
      if type(r) == "table" and r.link then
        found[#found + 1] = { name = name, link = r.link, desc = r.desc or r.description }
      end
    end
  end
  return found
end

local function in_coroutine()
  local _, main = coroutine.running()
  return not main
end

--- Compute a link to the current location without storing it.
---@param opts? { interactive?: boolean, bufnr?: integer, lnum?: integer, col?: integer, region?: integer[],
---  negate_context?: boolean, skip_custom?: boolean }
---@return { link: string, desc: string|nil, extra?: table }|nil
function M.link_to_location(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local is_cur = bufnr == vim.api.nvim_get_current_buf()
  local lnum = opts.lnum or (is_cur and vim.api.nvim_win_get_cursor(0)[1]) or 1
  local ctx = lopts().context_for_files
  if ctx == nil then
    ctx = true
  end
  if opts.negate_context then
    ctx = not ctx
  end
  local region = opts.region

  local function finish(r)
    if not r then
      return nil
    end
    if r.desc == "NONE" then
      r.desc = nil
    elseif r.desc then
      r.desc = M.display_format(r.desc)
    end
    return r
  end

  if not opts.skip_custom then
    local found = custom_store(opts.interactive)
    local idl
    if vim.bo[bufnr].filetype == "org" then
      idl = id_store_link(bufnr, lnum, region, ctx, opts.interactive)
      if idl then
        found[#found + 1] = { name = "id", link = idl.link, desc = idl.desc }
      end
    end
    if #found == 1 then
      return finish({ link = found[1].link, desc = found[1].desc, id = found[1].name == "id" })
    elseif #found > 1 then
      local pick = found[1]
      if opts.interactive and in_coroutine() then
        local _, idx = utils.select(
          vim.tbl_map(function(f)
            return f.name
          end, found),
          { prompt = "Store link with" }
        )
        if not idx then
          return nil
        end
        pick = found[idx]
      end
      return finish({ link = pick.link, desc = pick.desc, id = pick.name == "id" })
    end
  end

  if vim.bo[bufnr].filetype == "orgagenda" then
    -- in the agenda: a link to the entry of the item at the cursor
    local view = require("org.agenda.view")
    local item = view.item_at_cursor()
    local target = item and view.resolve_target(item)
    if not target then
      return nil
    end
    return M.link_to_location({
      bufnr = target.bufnr,
      lnum = target.lnum,
      interactive = opts.interactive,
      negate_context = opts.negate_context,
      skip_custom = opts.skip_custom,
    })
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name:match("^org%-special://") then
    return coderef_link(bufnr, lnum, opts.interactive)
  end
  local bt = vim.bo[bufnr].buftype
  if bt == "help" then
    return help_link(bufnr, lnum)
  end
  if vim.bo[bufnr].filetype == "bib" or name:match("%.bib$") then
    -- the BibTeX entry at the cursor (org-bibtex-store-link)
    local r = require("org.bibtex").store_link(bufnr, lnum)
    if r then
      return finish(r)
    end
  end
  if vim.bo[bufnr].filetype == "man" then
    local page = name:match("^man://(.+)$")
    if page then
      return { link = "man:" .. page, desc = "Manpage for " .. page }
    end
  end
  if vim.bo[bufnr].filetype == "netrw" or vim.bo[bufnr].filetype == "oil" or (name ~= "" and utils.is_dir(name)) then
    return directory_link(bufnr, lnum)
  end
  if name == "" or bt ~= "" and bt ~= "acwrite" then
    return nil
  end
  if name:match("CAPTURE%-") then
    return nil
  end
  local path = display_path(name)
  if vim.bo[bufnr].filetype == "org" then
    -- a dedicated <<target>> under the cursor: Emacs's
    -- (org-in-regexp "[^<]<<\\([^<>]+\\)>>[^>]" 1) searches from the start
    -- of the line above to the end of the line below, so the line break
    -- before or after a target at the start or end of a line counts as
    -- the character around it that isn't < or >
    local col = opts.col or (is_cur and not opts.lnum and (vim.api.nvim_win_get_cursor(0)[2] + 1)) or nil
    if col and not region then
      local first = math.max(lnum - 1, 1)
      local lines = vim.api.nvim_buf_get_lines(bufnr, first - 1, lnum + 1, false)
      local text = table.concat(lines, "\n")
      if lnum + 1 > vim.api.nvim_buf_line_count(bufnr) and (vim.bo[bufnr].eol or vim.bo[bufnr].fixeol) then
        -- the file's final newline
        text = text .. "\n"
      end
      -- point: 0-based offset of the cursor in `text`
      local pos = col - 1
      for i = first, lnum - 1 do
        pos = pos + #lines[i - first + 1] + 1
      end
      local init = 1
      while true do
        local s, e, target = text:find("[^<]<<([^<>]+)>>[^>]", init)
        if not s or s - 1 > pos then
          break
        end
        if e >= pos then
          return { link = "file:" .. path .. "::" .. target, desc = nil }
        end
        init = e + 1
      end
    end
  end
  return finish(file_link_to_here(bufnr, lnum, region, ctx))
end

--- Store a link to the current location (org-store-link). In Visual mode
--- the selection is the search string. A count stands for the prefix
--- argument: 4 negates `links.context_for_files`, 16 skips the `store`
--- functions of custom link types, 64 stores one link per selected line.
function M.store_link(arg)
  arg = arg or vim.v.count
  local region = visual_region()
  if region and arg >= 64 then
    local last
    for l = region[1], region[3] do
      local len = #(vim.api.nvim_buf_get_lines(0, l - 1, l, false)[1] or "")
      if len > 0 then
        last = M.store_link_at({ region = { l, 1, l, len }, interactive = true }) or last
      end
    end
    return last
  end
  return M.store_link_at({
    region = region,
    interactive = true,
    negate_context = arg > 0 and arg < 16,
    skip_custom = arg >= 16,
  })
end

--- Store a link computed by `link_to_location(opts)`; in Org buffers an
--- extra `file:…::#custom-id` link is stored when the entry has one.
function M.store_link_at(opts)
  local l = M.link_to_location(opts)
  if not l then
    utils.warn("No method for storing a link from this buffer")
    return
  end
  add_stored(l.link, l.desc)
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.bo[bufnr].filetype == "org" and vim.api.nvim_buf_get_name(bufnr) ~= "" and opts.interactive then
    local hl = files.get_buffer(bufnr):headline_at(vim.api.nvim_win_get_cursor(0)[1])
    if hl and hl.properties.CUSTOM_ID then
      local ctx = lopts().context_for_files
      if ctx == nil then
        ctx = true
      end
      if opts.negate_context then
        ctx = not ctx
      end
      local here = file_link_to_here(bufnr, vim.api.nvim_win_get_cursor(0)[1], opts.region, ctx)
      if here.desc then
        here.desc = M.display_format(here.desc)
      end
      if not (M.stored[1].link == here.link and M.stored[1].desc == here.desc) then
        add_stored(here.link, here.desc, true)
      end
    end
  end
  return M.stored[1]
end

--- Store a link programmatically.
function M.store(link, desc)
  return add_stored(link, desc, true)
end

-- for the parts loaded after this one
shared.visual_region = visual_region
