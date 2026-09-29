---@mod org.extensions.roam.capture Roam capture (org-roam-capture)
---
--- Roam capture templates are org.nvim capture templates (`:h
--- org-capture-templates`) with a file `target` relative to the roam
--- directory, an optional `head` written into a new file and an optional
--- `olp` created when missing. `${key}` (or `${key=default}`) in the
--- target, head, olp and template is replaced by the node's field (`title`,
--- `slug`, `id`, ...) or asked for; `%` escapes are expanded by org
--- capture. The capture location (the file, or the `olp` heading) gets the
--- node's `:ID:`, so the new text is a node.

local utils = require("org.utils")

local M = {}

-- Precomposed Latin letters and what org-roam's slug leaves of them: it
-- decomposes (NFD), drops these combining marks and recomposes (NFC):
-- U+0300-0304 0306-030C 031B 0323-0325 0327 032D 032E 0330 0331.
-- Generated from Unicode data; "abc=X" means a, b and c become X.
local STRIP = {}
for group in table.concat({
  "ÀÁÂÃÄÅĀĂǍǞǠǺȦḀẠẢẤẦẨẪẬẮẰẲẴẶ=A ḂḄḆ=B ÇĆĈĊČḈ=C ",
  "ĎḊḌḎḐḒ=D ÈÉÊËĒĔĖĚȨḔḖḘḚḜẸẺẼẾỀỂỄỆ=E Ḟ=F ",
  "ĜĞĠĢǦǴḠ=G ĤȞḢḤḦḨḪ=H ÌÍÎÏĨĪĬİǏḬḮỈỊ=I Ĵ=J ĶǨḰḲḴ=K ",
  "ĹĻĽḶḸḺḼ=L ḾṀṂ=M ÑŃŅŇǸṄṆṈṊ=N ",
  "ÒÓÔÕÖŌŎŐƠǑȪȬȮȰṌṎṐṒỌỎỐỒỔỖỘỚỜỞỠỢ=O ṔṖ=P ",
  "ŔŖŘṘṚṜṞ=R ŚŜŞŠṠṢṤṦṨ=S ŢŤṪṬṮṰ=T ",
  "ÙÚÛÜŨŪŬŮŰƯǓǕǗǙǛṲṴṶṸṺỤỦỨỪỬỮỰ=U ṼṾ=V ŴẀẂẄẆẈ=W ",
  "ẊẌ=X ÝŶŸȲẎỲỴỶỸ=Y ŹŻŽẐẒẔ=Z ",
  "àáâãäåāăǎǟǡǻȧḁạảấầẩẫậắằẳẵặ=a ḃḅḇ=b çćĉċčḉ=c ",
  "ďḋḍḏḑḓ=d èéêëēĕėěȩḕḗḙḛḝẹẻẽếềểễệ=e ḟ=f ",
  "ĝğġģǧǵḡ=g ĥȟḣḥḧḩḫẖ=h ìíîïĩīĭǐḭḯỉị=i ĵǰ=j ķǩḱḳḵ=k ",
  "ĺļľḷḹḻḽ=l ḿṁṃ=m ñńņňǹṅṇṉṋ=n ",
  "òóôõöōŏőơǒȫȭȯȱṍṏṑṓọỏốồổỗộớờởỡợ=o ṕṗ=p ",
  "ŕŗřṙṛṝṟ=r śŝşšṡṣṥṧṩ=s ţťṫṭṯṱẗ=t ",
  "ùúûüũūŭůűưǔǖǘǚǜṳṵṷṹṻụủứừửữự=u ṽṿ=v ŵẁẃẅẇẉẘ=w ",
  "ẋẍ=x ýÿŷȳẏẙỳỵỷỹ=y źżžẑẓẕ=z ǢǼ=Æ Ǿ=Ø ǣǽ=æ ǿ=ø ẛ=ſ Ǯ=Ʒ ",
  "Ǭ=Ǫ ǭ=ǫ ǯ=ʒ ",
}):gmatch("%S+") do
  local chars, base = group:match("^(.+)=(.-)$")
  for _, ch in ipairs(vim.fn.split(chars, "\\zs")) do
    STRIP[ch] = base
  end
end

---@class org.roam.NewNode
---@field id? string
---@field title? string
---@field file? string

--- A slug for `title` (org-roam-node-slug): marks dropped from accented
--- letters, runs of anything but letters and digits turned into one `_`,
--- lower-cased.
---@param title string
---@return string
function M.slug(title)
  local out = {}
  for _, ch in ipairs(vim.fn.split(title, "\\zs")) do
    ch = STRIP[ch] or ch
    local alnum
    if #ch == 1 then
      alnum = ch:match("%w") ~= nil
    else
      -- 2 is a word character, above 3 a script (CJK, kana, ...); 1 is
      -- punctuation and 3 emoji
      local class = vim.fn.charclass(ch)
      alnum = class == 2 or class > 3
    end
    out[#out + 1] = alnum and ch or "_"
  end
  local s = table.concat(out):gsub("_+", "_"):gsub("^_", ""):gsub("_$", "")
  return vim.fn.tolower(s)
end

--- Expand `${key}` and `${key=default}` in `text` from `node` (and the
--- slug of its title), then `info`, else by asking (the answer is kept in
--- `info` for the rest of the capture).
---@param text string
---@param node org.roam.NewNode
---@param info table<string, string>
---@return string
function M.fill(text, node, info)
  local out, init = {}, 1
  while true do
    local s, e, spec = text:find("%${([^}]*)}", init)
    if not s then
      out[#out + 1] = text:sub(init)
      break
    end
    out[#out + 1] = text:sub(init, s - 1)
    local key, default = spec:match("^([^=]*)=(.*)$")
    key = key or spec
    local v = node[key]
    if v == nil and key == "slug" then
      v = M.slug(node.title or "")
    end
    if type(v) == "table" then
      v = table.concat(v, " ")
    end
    if v == nil then
      v = info[key]
    end
    if v == nil then
      v = utils.input({ prompt = key .. ": ", default = default })
      if v == nil then
        utils.abort()
      end
      info[key] = v
    end
    out[#out + 1] = tostring(v)
    init = e + 1
  end
  return table.concat(out)
end

--- `%` escapes of a path, head or olp entry, expanded like a capture
--- template (for `%<%Y-%m-%d>` and friends) at `date`.
local function expand_escapes(text, date)
  if not text:find("%", 1, true) then
    return text
  end
  return (require("org.capture").expand(text, { date = date }):gsub("\30", ""))
end

--- A hook option (a function, a list of them or nil) as a list.
local function hooks(v)
  if type(v) == "function" then
    return { v }
  end
  return type(v) == "table" and vim.list_slice(v) or {}
end

local function value(v, node)
  if type(v) == "function" then
    return v(node)
  end
  return v
end

--- Insert a file-level property drawer with `ID` at the top of the buffer
--- (after leading comments), or set `ID` in the one already there.
local function set_file_id(bufnr, id)
  local file = require("org.files").get_buffer(bufnr)
  if file.properties_range then
    require("org.edit").set_property(bufnr, file.properties_range[1], "ID", id)
    return
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local at = 0
  while lines[at + 1] and lines[at + 1]:match("^%s*#%s") do
    at = at + 1
  end
  local drawer = { ":PROPERTIES:", ":ID:       " .. id, ":END:" }
  if #lines == 1 and lines[1] == "" then
    vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, drawer)
  else
    vim.api.nvim_buf_set_lines(bufnr, at, at, false, drawer)
  end
end

--- Find or create the headlines of `olp` (org-roam-capture-find-or-create-olp).
--- Returns the line of the last one.
local function find_or_create_olp(bufnr, olp)
  local files = require("org.files")
  local parent
  for _, name in ipairs(olp) do
    local file = files.get_buffer(bufnr)
    local nodes = parent and file:headline_at(parent).children or file.children
    local found
    for _, h in ipairs(nodes) do
      if h:plain_title() == name or h.title == name then
        found = h
        break
      end
    end
    if found then
      parent = found.line
    else
      local level = parent and (file:headline_at(parent).level + 1) or 1
      local at = parent and file:headline_at(parent).end_line or #file.lines
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local line = string.rep("*", level) .. " " .. name
      if #lines == 1 and lines[1] == "" then
        vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { line })
        parent = 1
      else
        vim.api.nvim_buf_set_lines(bufnr, at, at, false, { line })
        parent = at + 1
      end
    end
  end
  return parent
end

--- Choose a template from `templates` (a key -> template table; one
--- template is used directly).
local function choose(templates, key)
  if key and key ~= "" then
    local t = templates[key]
    if not t then
      utils.warn("org-roam: no capture template for key " .. key)
    end
    return t
  end
  local keys = vim.tbl_keys(templates)
  table.sort(keys)
  if #keys == 1 then
    return templates[keys[1]]
  end
  local choice = utils.select(keys, {
    prompt = "Roam capture template",
    format_item = function(k)
      local t = templates[k]
      return k .. "  " .. (type(t) == "table" and t.description or "")
    end,
  })
  return choice and templates[choice] or nil
end

---@class org.roam.CaptureOpts
---@field node? org.roam.NewNode the node being captured (a new id is made when it has none)
---@field templates? table<string, table> defaults to `capture_templates`
---@field keys? string template key
---@field visit? boolean only visit the target (org-capture's goto)
---@field directory? string what relative targets resolve against (default the roam directory)
---@field date? table capture date (dailies)
---@field finalize? "find_file"|"insert_link"|fun(id: string, bufnr: integer, lnum: integer)
---@field link_description? string
---@field call_location? { bufnr: integer, mark: integer, ns: integer }
---@field region? { bufnr: integer, s: integer, e: integer, ns: integer }

--- Capture a roam node (org-roam-capture-). Returns the id of the node.
---@param opts? org.roam.CaptureOpts
---@return string|nil id
function M.capture(opts)
  opts = opts or {}
  local ropts = require("org.extensions").opts("roam") or require("org.extensions.roam").defaults
  local db = require("org.extensions.roam.db")
  local tpl = choose(opts.templates or ropts.capture_templates, opts.keys)
  if not tpl then
    return nil
  end
  local node = vim.deepcopy(opts.node or {})
  node.title = node.title or ""
  node.id = node.id or require("org.id").new_id()
  local info = {}
  local target = value(tpl.target, node)
  if type(target) ~= "string" or target == "" then
    utils.warn("org-roam: capture template needs a file `target`")
    return nil
  end
  local path = node.file
  if not path then
    path = vim.trim(expand_escapes(M.fill(target, node, info), opts.date))
    path = utils.expand(path, opts.directory or db.directory())
  end
  local new_file = not utils.exists(path) and not utils.find_buffer(path)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local bufnr = utils.load_buffer(path)
  local before = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local modified = vim.bo[bufnr].modified
  local head = value(tpl.head, node)
  if new_file and type(head) == "string" and head ~= "" then
    local text = expand_escapes(M.fill(head, node, info), opts.date)
    local lines = vim.split((text:gsub("\n$", "")), "\n", { plain = true })
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  end
  local olp = value(tpl.olp, node)
  if type(olp) == "string" then
    olp = vim.split(olp, "/", { trimempty = true })
  end
  local lnum
  if type(olp) == "table" and #olp > 0 then
    local filled = {}
    for i, name in ipairs(olp) do
      filled[i] = expand_escapes(M.fill(name, node, info), opts.date)
    end
    olp = filled
    lnum = find_or_create_olp(bufnr, olp)
  else
    olp = nil
  end
  -- the capture location becomes the node: keep its id, or give it one
  local file = require("org.files").get_buffer(bufnr)
  local hl = lnum and file:headline_at(lnum)
  local existing = hl and hl.properties.ID or (not hl and file.properties.ID)
  -- an existing node's file already holds its id
  if node.file then
    node.id = node.id or existing or nil
  elseif existing and existing ~= "" then
    node.id = existing
  elseif hl then
    require("org.edit").set_property(bufnr, lnum, "ID", node.id)
  else
    set_file_id(bufnr, node.id)
  end
  require("org.id").register(node.id, path)

  local function cleanup()
    if new_file then
      if vim.api.nvim_buf_is_valid(bufnr) and not utils.exists(path) then
        pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      end
    elseif vim.api.nvim_buf_is_valid(bufnr) then
      utils.restore_buffer(bufnr, before, modified)
    end
    if opts.call_location then
      pcall(vim.api.nvim_buf_del_extmark, opts.call_location.bufnr, opts.call_location.ns, opts.call_location.mark)
    end
  end

  local function done(dbuf, dline)
    db.update_file(path)
    local fin = opts.finalize
    if type(fin) == "function" then
      fin(node.id, dbuf, dline)
    elseif fin == "insert_link" then
      M.insert_link_at(opts, node.id)
    elseif fin == "find_file" then
      local b = vim.api.nvim_buf_is_valid(dbuf or -1) and dbuf or bufnr
      local target_line = dline
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(b) then
          vim.api.nvim_set_current_buf(b)
          if target_line then
            pcall(vim.api.nvim_win_set_cursor, 0, { target_line, 0 })
          end
        end
      end)
    end
  end

  if opts.visit then
    utils.open_file(path, lnum)
    return node.id
  end

  local ctpl = {}
  for k, v in pairs(tpl) do
    if k ~= "head" and k ~= "olp" and k ~= "target" then
      ctpl[k] = v
    end
  end
  ctpl.target = path
  ctpl.olp = olp
  ctpl.type = tpl.type or "plain"
  -- a node with only its head is a valid note (org-capture stores it)
  if ctpl.allow_empty == nil then
    ctpl.allow_empty = true
  end
  local body = value(tpl.template, node) or ""
  if type(body) == "table" then
    body = table.concat(body, "\n")
  end
  ctpl.template = M.fill(body, node, info)
  -- the template's own hooks run first
  ctpl.after_finalize = vim.list_extend(hooks(tpl.after_finalize), { done })
  ctpl.on_abort = vim.list_extend(hooks(tpl.on_abort), { cleanup })
  local ok, err = pcall(require("org.capture").capture, ctpl, { date = opts.date })
  if not ok then
    cleanup()
    error(err, 0)
  end
  return node.id
end

--- Choose a node, or name a new one, and capture into it with a template
--- (org-roam-capture). `arg` is the title of the node, skipping the prompt.
---@param arg? string
function M.command(arg)
  local db = require("org.extensions.roam.db")
  local nd = require("org.extensions.roam.node")
  local node
  if arg and vim.trim(arg) ~= "" then
    db.sync()
    local found = db.by_title(vim.trim(arg))
    node = found and { id = found.id, title = found.title, file = found.file } or { title = vim.trim(arg) }
  else
    local c = nd.read({ prompt = "Capture to node" })
    if not c then
      return
    end
    node = c.node and { id = c.node.id, title = c.node.title, file = c.node.file } or { title = c.title }
  end
  return M.capture({ node = node })
end

--- After a capture from `node_insert`: replace the region, or insert at
--- the call location, a link to `id`. Returns the 0-based row and the
--- column after the link.
---@param opts org.roam.CaptureOpts
---@param id string
---@return integer|nil row, integer|nil col
function M.insert_link_at(opts, id)
  local loc = opts.call_location
  if not loc or not vim.api.nvim_buf_is_valid(loc.bufnr) then
    return
  end
  local pos = vim.api.nvim_buf_get_extmark_by_id(loc.bufnr, loc.ns, loc.mark, { details = true })
  if not pos or not pos[1] then
    return
  end
  local text = require("org.links").format("id:" .. id, opts.link_description)
  local srow, scol = pos[1], pos[2]
  local erow, ecol = srow, scol
  if pos[3] and pos[3].end_row then
    erow, ecol = pos[3].end_row, pos[3].end_col
  end
  vim.api.nvim_buf_set_text(loc.bufnr, srow, scol, erow, ecol, { text })
  pcall(vim.api.nvim_buf_del_extmark, loc.bufnr, loc.ns, loc.mark)
  return srow, scol + #text
end

return M
