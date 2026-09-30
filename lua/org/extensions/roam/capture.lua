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

-- The same marks when the title has them as separate (decomposed)
-- characters, which org-roam drops too.
local MARKS = {}
for _, cp in ipairs({ 0x300, 0x301, 0x302, 0x303, 0x304, 0x306, 0x307, 0x308, 0x309, 0x30A, 0x30B, 0x30C }) do
  MARKS[#MARKS + 1] = vim.fn.nr2char(cp)
end
for _, cp in ipairs({ 0x31B, 0x323, 0x324, 0x325, 0x327, 0x32D, 0x32E, 0x330, 0x331 }) do
  MARKS[#MARKS + 1] = vim.fn.nr2char(cp)
end

-- Letter numbers (Unicode Nl: Ⅻ, 〇, ...) are [:alnum:] in Emacs but
-- punctuation to charclass().
local LETTER_NUMBERS = {
  { 0x16EE, 0x16F0 },
  { 0x2160, 0x2188 },
  { 0x3007, 0x3007 },
  { 0x3021, 0x3029 },
  { 0x3038, 0x303A },
}

local function letter_number(ch)
  local cp = vim.fn.char2nr(ch)
  for _, r in ipairs(LETTER_NUMBERS) do
    if cp >= r[1] and cp <= r[2] then
      return true
    end
  end
  return false
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
  if title:find("\204", 1, true) then
    -- decomposed marks (all encoded as \204\128-\204\177)
    for _, m in ipairs(MARKS) do
      title = title:gsub(m, "")
    end
  end
  for _, ch in ipairs(vim.fn.split(title, "\\zs")) do
    ch = STRIP[ch] or ch
    local alnum
    if #ch == 1 then
      alnum = ch:match("%w") ~= nil
    else
      -- 2 is a word character, above 3 a script (CJK, kana, ...); 1 is
      -- punctuation and 3 emoji
      local class = vim.fn.charclass(ch)
      alnum = class == 2 or class > 3 or letter_number(ch)
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

--- A template's target as its parts: `target` is a file relative to the
--- roam directory (with the template's `head`, `olp`, `datetree` and
--- `tree_type`), or an org-roam `:target` list: `{ "file", path }`,
--- `{ "file+head", path, head }`, `{ "file+olp", path, olp }`,
--- `{ "file+head+olp", path, head, olp }`,
--- `{ "file+datetree", path, tree_type? }` or `{ "node", title_or_id }`.
---@param tpl table
---@param node org.roam.NewNode
---@return { file?: string, head?: string, olp?: string|string[], datetree?: boolean, tree_type?: string, node?: string }|nil
---@return string|nil error
function M.target_parts(tpl, node)
  local t = value(tpl.target, node)
  local parts = {
    head = value(tpl.head, node),
    olp = value(tpl.olp, node),
    datetree = tpl.datetree and true or nil,
    tree_type = type(tpl.datetree) == "table" and tpl.datetree.tree_type or tpl.tree_type,
  }
  if type(t) == "table" then
    local kind = t[1]
    if kind == "file" then
      parts.file = t[2]
    elseif kind == "file+head" then
      parts.file, parts.head = t[2], t[3]
    elseif kind == "file+olp" then
      parts.file, parts.olp = t[2], t[3]
    elseif kind == "file+head+olp" then
      parts.file, parts.head, parts.olp = t[2], t[3], t[4]
    elseif kind == "file+datetree" then
      parts.file, parts.datetree, parts.tree_type = t[2], true, t[3] or parts.tree_type
    elseif kind == "node" then
      parts = { node = t[2] }
      if type(parts.node) ~= "string" or parts.node == "" then
        return nil, "the node target needs a title or id"
      end
      return parts
    else
      return nil, "unknown capture target " .. tostring(kind)
    end
  else
    parts.file = t
  end
  if type(parts.file) ~= "string" or parts.file == "" then
    return nil, "capture template needs a file `target`"
  end
  if type(parts.head) == "table" then
    parts.head = table.concat(parts.head, "\n")
  end
  return parts
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
---@field info? table<string, string> values for `${key}` (a protocol's `ref` and `body`)
---@field link_props? table link properties for org capture (org-link-store-props)

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
  -- `${key}` answers, and what the caller knows (a protocol's ref and body)
  local info = vim.deepcopy(opts.info or {})
  local parts, perr = M.target_parts(tpl, node)
  if not parts then
    utils.warn("org-roam: " .. perr)
    return nil
  end
  -- a ref that is already a node's: capture into that node
  -- (org-roam-capture--try-capture-to-ref-h)
  local ref_node = info.ref and db.by_ref(info.ref)
  if ref_node then
    parts = { node = ref_node.id }
  end
  local path, lnum, bufnr, new_file
  local target_node
  if parts.node then
    db.sync()
    target_node = db.node(parts.node) or db.by_title(parts.node)
    if not target_node then
      utils.warn(string.format('org-roam: no node with title or id "%s"', parts.node))
      return nil
    end
    path = target_node.file
    new_file = false
    bufnr = utils.load_buffer(path)
    if target_node.level > 0 then
      local thl = require("org.files").get_buffer(bufnr):find_by_id(target_node.id)
      if not thl then
        utils.warn("org-roam: cannot find the target node, run :Org roam_db_sync")
        return nil
      end
      lnum = thl.line
    end
  else
    path = node.file
    if not path then
      path = vim.trim(expand_escapes(M.fill(parts.file, node, info), opts.date))
      path = utils.expand(path, opts.directory or db.directory())
    end
    new_file = not utils.exists(path) and not utils.find_buffer(path)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    bufnr = utils.load_buffer(path)
  end
  local before = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local modified = vim.bo[bufnr].modified
  local head = parts.head
  if new_file and type(head) == "string" and head ~= "" then
    local text = expand_escapes(M.fill(head, node, info), opts.date)
    local lines = vim.split((text:gsub("\n$", "")), "\n", { plain = true })
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  end
  local olp = parts.olp
  if type(olp) == "string" then
    olp = vim.split(olp, "/", { trimempty = true })
  end
  if not parts.node and type(olp) == "table" and #olp > 0 then
    local filled = {}
    for i, name in ipairs(olp) do
      filled[i] = expand_escapes(M.fill(name, node, info), opts.date)
    end
    lnum = find_or_create_olp(bufnr, filled)
  end
  if parts.datetree then
    -- file+datetree: the day's (week's, month's) entry is the node
    local d = opts.date or require("org.date").today()
    lnum = require("org.capture").ensure_datetree(bufnr, lnum, d, parts.tree_type or "day")
  end
  -- the capture location becomes the node: keep its id, or give it one
  local file = require("org.files").get_buffer(bufnr)
  local hl = lnum and file:headline_at(lnum)
  local existing = hl and hl.properties.ID or (not hl and file.properties.ID)
  local new_node = false
  if target_node then
    node.id = target_node.id
    node.title = target_node.title
  elseif node.file then
    -- an existing node's file already holds its id
    node.id = node.id or existing or nil
  elseif existing and existing ~= "" then
    node.id = existing
  elseif hl then
    require("org.edit").set_property(bufnr, lnum, "ID", node.id)
    new_node = true
  else
    set_file_id(bufnr, node.id)
    new_node = true
  end
  if new_node and info.ref and info.ref ~= "" then
    -- org-roam-capture--insert-captured-ref-h
    local nd = require("org.extensions.roam.node")
    local here = nd.at_point(bufnr, hl and lnum or 1)
    if here then
      nd.property_add(here, "ROAM_REFS", info.ref)
    end
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
      local row, col = M.insert_link_at(opts, node.id)
      -- the capture window is closed: back where the link went
      if row and vim.api.nvim_get_current_buf() == opts.call_location.bufnr then
        require("org.extensions.roam.node").cursor_after_link(row, col)
      end
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
    require("org.extensions.roam.node").open(path, lnum)
    return node.id
  end

  local ctpl = {}
  for k, v in pairs(tpl) do
    if k ~= "head" and k ~= "olp" and k ~= "target" and k ~= "tree_type" then
      ctpl[k] = v
    end
  end
  ctpl.target = path
  ctpl.olp, ctpl.datetree = nil, nil
  if lnum then
    -- the node's headline, found or made above
    local line = lnum
    ctpl.func = function()
      return line
    end
  end
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
  if opts.link_props then
    -- a protocol's link, used by %a, %:link and friends instead of a
    -- link to the current buffer
    require("org.capture").link_store_props = opts.link_props
  end
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
