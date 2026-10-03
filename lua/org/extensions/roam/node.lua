---@mod org.extensions.roam.node Finding, inserting and editing nodes

local db = require("org.extensions.roam.db")
local edit = require("org.edit")
local files = require("org.files")
local utils = require("org.utils")

local M = {}

local function ropts()
  return require("org.extensions").opts("roam") or require("org.extensions.roam").defaults
end

local function capture()
  return require("org.extensions.roam.capture")
end

---------------------------------------------------------------------------
-- Node at point
---------------------------------------------------------------------------

---@class org.roam.Here
---@field id string
---@field bufnr integer
---@field lnum? integer headline line, nil for the file node
---@field hl? org.Headline
---@field file org.File

--- The node containing the cursor (org-roam-node-at-point): the nearest
--- headline with an `:ID:` (and no `ROAM_EXCLUDE`), else the file node.
---@param bufnr? integer
---@param lnum? integer
---@return org.roam.Here|nil
function M.at_point(bufnr, lnum)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  if vim.bo[bufnr].filetype ~= "org" then
    return nil
  end
  lnum = lnum or (bufnr == vim.api.nvim_get_current_buf() and vim.api.nvim_win_get_cursor(0)[1] or 1)
  local file = files.get_buffer(bufnr)
  local hl = file:headline_at(lnum)
  while hl do
    local id = hl.properties.ID
    local ex = hl.properties.ROAM_EXCLUDE
    if id and id ~= "" and not (ex and ex ~= "" and ex ~= "nil") then
      return { id = id, bufnr = bufnr, lnum = hl.line, hl = hl, file = file }
    end
    hl = hl.parent
  end
  local id = file.properties.ID
  local ex = file.properties.ROAM_EXCLUDE
  if id and id ~= "" and not (ex and ex ~= "" and ex ~= "nil") then
    return { id = id, bufnr = bufnr, file = file }
  end
end

local function here_or_warn()
  local h = M.at_point()
  if not h then
    utils.warn("org-roam: no node at point")
  end
  return h
end

---------------------------------------------------------------------------
-- Choosing a node
---------------------------------------------------------------------------

local NEW = { new = true }

--- Default candidate text: the title (or alias) and the node's tags.
---@param node org.roam.Node
---@param name string title or alias
---@return string
function M.display(node, name)
  local fmt = ropts().node_display
  if type(fmt) == "function" then
    return fmt(node, name)
  end
  local s = name
  if #node.olp > 0 and ropts().display_olp then
    s = table.concat(node.olp, " > ") .. " > " .. s
  end
  if #node.tags > 0 then
    s = s .. "  :" .. table.concat(node.tags, ":") .. ":"
  end
  return s
end

--- Candidates for completion: one per node title and one per alias
--- (org-roam-node-read--completions).
---@param filter? fun(node: org.roam.Node): boolean
---@return { node: org.roam.Node, name: string }[]
function M.candidates(filter)
  db.sync()
  local out = {}
  for _, n in ipairs(db.nodes()) do
    if not filter or filter(n) then
      out[#out + 1] = { node = n, name = n.title }
      for _, a in ipairs(n.aliases) do
        out[#out + 1] = { node = n, name = a }
      end
    end
  end
  local sort = ropts().sort
  if sort == "title" or sort == "mtime" then
    -- sort keys made once, not in every comparison
    local key, mt = {}, {}
    for _, c in ipairs(out) do
      key[c] = c.name:lower()
      if sort == "mtime" then
        mt[c.node.file] = mt[c.node.file] or db.mtime(c.node.file) or 0
      end
    end
    table.sort(out, function(a, b)
      if sort == "mtime" and mt[a.node.file] ~= mt[b.node.file] then
        return mt[a.node.file] > mt[b.node.file]
      end
      return key[a] < key[b]
    end)
  end
  return out
end

local function has_snacks_picker()
  return require("org.pickers.backends.snacks").api() ~= nil
end

-- the picker plugins org.pickers drives
local GENERIC = { ["fzf-lua"] = true, telescope = true, mini = true }

--- Which picker `read` uses: the `picker` option, with "auto" resolved to
--- the backend of org's own `picker` option (`:h org-pickers`).
---@return "snacks"|"fzf-lua"|"telescope"|"mini"|"select"|"input"
function M.picker()
  local p = ropts().picker or "auto"
  if p == "auto" then
    if has_snacks_picker() and (require("org.config").opts.picker or "auto") == "auto" then
      return "snacks"
    end
    return require("org.pickers").backend()
  end
  if p == "snacks" then
    return has_snacks_picker() and "snacks" or "select"
  end
  if GENERIC[p] then
    return require("org.pickers").backend(p)
  end
  return p
end

-- snacks.picker: a node that matches nothing is created from the query
-- (like completing-read without require-match)
local function snacks_read(items, opts)
  return utils.await(function(cb)
    local finished = false
    local function finish(v)
      if not finished then
        finished = true
        cb(v)
      end
    end
    local list = {}
    for i, c in ipairs(items) do
      list[i] = {
        text = M.display(c.node, c.name),
        cand = c,
        idx = i,
        file = c.node.file,
        pos = { c.node.lnum or 1, 0 },
      }
    end
    require("org.pickers.backends.snacks").api().pick({
      source = "org_roam_node",
      title = opts.prompt or "Node",
      items = list,
      pattern = opts.default_title,
      format = "text",
      preview = "file",
      actions = {
        confirm = function(picker, item)
          local query = vim.trim(picker.input and picker.input.filter.pattern or "")
          -- answer before closing: closing runs on_close
          if item then
            finish(item.cand)
          elseif query ~= "" and opts.allow_new ~= false then
            finish({ title = query })
          else
            finish(nil)
          end
          picker:close()
        end,
      },
      on_close = function()
        finish(nil)
      end,
    })
  end)
end

-- fzf-lua, telescope or mini.pick through org.pickers, with a preview of
-- the node; a query that matches nothing creates a node (mini.pick: the
-- "+ New node" entry)
local function generic_read(items, opts, backend)
  local list = {}
  for i, c in ipairs(items) do
    list[i] = {
      display = { { M.display(c.node, c.name) } },
      filename = c.node.file,
      lnum = c.node.lnum or 1,
      value = c,
    }
  end
  local chosen, query = require("org.pickers").choose({
    title = opts.prompt or "Node",
    items = list,
    query = opts.default_title,
    allow_query = opts.allow_new ~= false,
    create_label = "+ New node",
  }, backend)
  if not chosen then
    return nil
  end
  if chosen[1] then
    return chosen[1].value
  end
  query = query and vim.trim(query) or ""
  return query ~= "" and { title = query } or nil
end

-- candidates of the running `input` read, for `M._complete`
local completing = {}

--- `customlist` completion for the input picker: titles and aliases
--- containing the whole typed text, ignoring case.
function M._complete(_, cmdline)
  local want = cmdline:lower()
  local starts, contains = {}, {}
  for _, name in ipairs(completing) do
    local at = name:lower():find(want, 1, true)
    if at == 1 then
      starts[#starts + 1] = name
    elseif at then
      contains[#contains + 1] = name
    end
  end
  return vim.list_extend(starts, contains)
end

-- input: type a title (<Tab> completes titles and aliases); one that isn't
-- a node's is a new node
local function input_read(items, opts)
  local by_name = {}
  completing = {}
  for _, c in ipairs(items) do
    if not by_name[c.name] then
      by_name[c.name] = c
      completing[#completing + 1] = c.name
    end
  end
  local ok, v = pcall(vim.fn.input, {
    prompt = (opts.prompt or "Node") .. ": ",
    default = opts.default_title or "",
    completion = "customlist,v:lua.require'org.extensions.roam.node'._complete",
    cancelreturn = vim.NIL,
  })
  completing = {}
  if not ok or v == vim.NIL then
    return nil
  end
  v = vim.trim(v or "")
  if v == "" then
    return nil
  end
  if by_name[v] then
    return by_name[v]
  end
  if opts.allow_new == false then
    utils.warn("org-roam: no node " .. v)
    return nil
  end
  return { title = v }
end

--- Choose a node (org-roam-node-read). Returns the candidate, or
--- `{ title = ... }` for a new node, or nil when cancelled. With the
--- snacks picker or `picker = "input"` a new node is named by typing its
--- title; with `vim.ui.select` by choosing "+ New node".
---@param opts? { prompt?: string, allow_new?: boolean, default_title?: string, filter?: fun(n: org.roam.Node): boolean }
---@return { node?: org.roam.Node, name?: string, title?: string }|nil
function M.read(opts)
  opts = opts or {}
  local items = M.candidates(opts.filter)
  local kind = M.picker()
  if kind == "input" then
    return input_read(items, opts)
  end
  if kind == "snacks" or GENERIC[kind] then
    if #items == 0 and opts.allow_new == false then
      utils.warn("org-roam: no nodes")
      return nil
    end
    if kind ~= "snacks" then
      return generic_read(items, opts, kind)
    end
    return snacks_read(items, opts)
  end
  if opts.allow_new ~= false then
    table.insert(items, 1, NEW)
  end
  if #items == 0 then
    utils.warn("org-roam: no nodes")
    return nil
  end
  local choice = utils.select(items, {
    prompt = opts.prompt or "Node",
    kind = "org_roam_node",
    format_item = function(c)
      if c == NEW then
        return "+ New node" .. (opts.default_title and (": " .. opts.default_title) or "…")
      end
      return M.display(c.node, c.name)
    end,
  })
  if not choice then
    return nil
  end
  if choice == NEW then
    local title = opts.default_title
    if not title or title == "" then
      title = utils.input({ prompt = "Title: " })
    end
    if not title or vim.trim(title) == "" then
      return nil
    end
    return { title = vim.trim(title) }
  end
  return choice
end

--- Open `path` at `lnum` like `utils.open_file`, reporting a failure (a
--- modified buffer that can't be left, E37) as a warning.
---@param path string
---@param lnum? integer
---@param o? table
---@return boolean ok
function M.open(path, lnum, o)
  local ok, err = pcall(utils.open_file, path, lnum, o)
  if not ok then
    utils.warn("org-roam: " .. tostring(err):gsub("^.-(E%d+:)", "%1"))
  end
  return ok
end

--- Go to `node` (org-roam-node-visit).
---@param node org.roam.Node
function M.visit(node)
  local path = node.file
  local lnum = node.lnum
  if node.level > 0 then
    -- the index may be older than the buffer: look the id up again
    local b = utils.find_buffer(path)
    local f = b and files.get_buffer(b) or files.get(path)
    local hl = f and f:find_by_id(node.id)
    lnum = hl and hl.line or lnum
  end
  vim.cmd("normal! m'")
  M.open(path, lnum)
end

--- Find a node by title or alias and visit it, capturing a new one when
--- there is none (org-roam-node-find). `title` skips the prompt.
---@param title? string
function M.find(title)
  title = title and vim.trim(title) or ""
  if title ~= "" then
    db.sync()
    local node = db.by_title(title)
    if node then
      return M.visit(node)
    end
    return capture().capture({ node = { title = title }, finalize = "find_file" })
  end
  local c = M.read({ prompt = "Find node" })
  if not c then
    return
  end
  if c.node then
    return M.visit(c.node)
  end
  return capture().capture({ node = { title = c.title }, finalize = "find_file" })
end

--- Visit a random node (org-roam-node-random).
function M.random()
  db.sync()
  local nodes = db.nodes()
  if #nodes == 0 then
    utils.warn("org-roam: no nodes")
    return
  end
  math.randomseed(os.time() + vim.uv.hrtime() % 1000)
  M.visit(nodes[math.random(#nodes)])
end

local ns = vim.api.nvim_create_namespace("org.roam.insert")

local function visual_region()
  local mode = vim.fn.mode()
  if mode ~= "v" and mode ~= "V" and mode ~= "\22" then
    return nil
  end
  local srow, scol, erow, ecol = utils.visual_range()
  vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
  local line = vim.api.nvim_buf_get_lines(0, erow - 1, erow, false)[1] or ""
  if mode == "V" then
    local first = vim.api.nvim_buf_get_lines(0, srow - 1, srow, false)[1] or ""
    scol = #first:match("^%s*") + 1
    ecol = #line
  else
    local ch = vim.fn.strcharpart(line:sub(ecol), 0, 1)
    ecol = math.min(#line, ecol + math.max(#ch, 1) - 1)
  end
  return { srow, scol, erow, ecol }
end

--- Put the cursor after a link inserted at 0-based `row` that ends before
--- byte `col`: on its last `]` in Normal mode, after it when the insert
--- started in Insert mode (which a picker may have left, so it is entered
--- again), so typing goes on after the link.
---@param row integer
---@param col integer
---@param insert? boolean
function M.cursor_after_link(row, col, insert)
  if not insert then
    pcall(vim.api.nvim_win_set_cursor, 0, { row + 1, math.max(0, col - 1) })
    return
  end
  pcall(vim.api.nvim_win_set_cursor, 0, { row + 1, col })
  if vim.fn.mode() ~= "i" then
    -- Normal mode can't put the cursor past the end of the line
    local at_end = col >= #(vim.api.nvim_buf_get_lines(0, row, row + 1, false)[1] or "")
    vim.cmd(at_end and "startinsert!" or "startinsert")
  end
end

--- Insert a link to a node, creating the node when it is new
--- (org-roam-node-insert). A Visual selection is the default title and the
--- link's description, and is replaced by the link.
function M.insert()
  local bufnr = vim.api.nvim_get_current_buf()
  local insert_mode = vim.fn.mode():sub(1, 1) == "i"
  local region = visual_region()
  local text
  if region then
    local parts = vim.api.nvim_buf_get_text(bufnr, region[1] - 1, region[2] - 1, region[3] - 1, region[4], {})
    text = vim.trim(table.concat(parts, " "))
  end
  -- where the link goes, tracked while prompts and captures run
  local mark
  if region then
    mark = vim.api.nvim_buf_set_extmark(bufnr, ns, region[1] - 1, region[2] - 1, {
      end_row = region[3] - 1,
      end_col = region[4],
      right_gravity = false,
      end_right_gravity = true,
    })
  else
    local row, col0 = unpack(vim.api.nvim_win_get_cursor(0))
    local line = vim.api.nvim_get_current_line()
    local at = line == "" and 0 or math.min(col0 + 1, #line)
    if insert_mode then
      at = col0
    end
    mark = vim.api.nvim_buf_set_extmark(bufnr, ns, row - 1, at, {})
  end
  local loc = { bufnr = bufnr, mark = mark, ns = ns }
  local c = M.read({ prompt = "Insert node", default_title = text })
  if not c then
    pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, mark)
    return
  end
  if c.node then
    local desc = text or c.name
    local fmt = ropts().link_description
    if type(fmt) == "function" and not text then
      desc = fmt(c.node, c.name)
    end
    local row, col = capture().insert_link_at({ call_location = loc, link_description = desc }, c.node.id)
    if row and vim.api.nvim_get_current_buf() == bufnr then
      M.cursor_after_link(row, col, insert_mode)
    end
    return
  end
  return capture().capture({
    node = { title = c.title },
    finalize = "insert_link",
    call_location = loc,
    link_description = text or c.title,
  })
end

---------------------------------------------------------------------------
-- Properties of the node at point
---------------------------------------------------------------------------

local function node_property(h, name)
  local props = h.hl and h.hl.properties or h.file.properties
  return props[name]
end

local function set_node_property(h, name, value)
  local lnum = h.lnum or (h.file.properties_range and h.file.properties_range[1]) or 1
  edit.set_property(h.bufnr, lnum, name, value)
end

--- Add `value` to a multi-valued property of the node `h` (see
--- `at_point`), first (org-roam-property-add).
---@param h org.roam.Here
---@param name string
---@param value string
function M.property_add(h, name, value)
  local list = db.split_quoted(node_property(h, name))
  local out = { value }
  for _, v in ipairs(list) do
    if v ~= value then
      out[#out + 1] = v
    end
  end
  set_node_property(h, name, db.join_quoted(out))
end

--- Remove one value of a multi-valued property, asking which
--- (org-roam-property-remove).
local function property_remove(h, name, value)
  local list = db.split_quoted(node_property(h, name))
  if #list == 0 then
    utils.warn("org-roam: no " .. name .. " to remove")
    return
  end
  if not value or value == "" then
    value = utils.select(list, { prompt = "Remove" })
    if not value then
      return
    end
  end
  local out = vim.tbl_filter(function(v)
    return v ~= value
  end, list)
  set_node_property(h, name, #out > 0 and db.join_quoted(out) or nil)
end

local function ask(prompt, given)
  if given and vim.trim(given) ~= "" then
    return vim.trim(given)
  end
  local v = utils.input({ prompt = prompt })
  if v and vim.trim(v) ~= "" then
    return vim.trim(v)
  end
end

--- Add an alias to the node at point (org-roam-alias-add).
---@param alias? string
function M.alias_add(alias)
  local h = here_or_warn()
  alias = h and ask("Alias: ", alias)
  if alias then
    M.property_add(h, "ROAM_ALIASES", alias)
  end
end

--- Remove an alias from the node at point (org-roam-alias-remove).
---@param alias? string
function M.alias_remove(alias)
  local h = here_or_warn()
  if h then
    property_remove(h, "ROAM_ALIASES", alias)
  end
end

--- Add a ref (a URL, `@citekey` or `[cite:@key]`) to the node at point
--- (org-roam-ref-add).
---@param ref? string
function M.ref_add(ref)
  local h = here_or_warn()
  ref = h and ask("Ref: ", ref)
  if ref then
    M.property_add(h, "ROAM_REFS", ref)
  end
end

--- Remove a ref from the node at point (org-roam-ref-remove).
---@param ref? string
function M.ref_remove(ref)
  local h = here_or_warn()
  if h then
    property_remove(h, "ROAM_REFS", ref)
  end
end

--- Tags used by roam nodes, sorted (org-roam-tag-completions).
---@return string[]
function M.all_tags()
  db.sync()
  local seen, out = {}, {}
  for _, n in ipairs(db.nodes()) do
    for _, t in ipairs(n.tags) do
      if not seen[t] then
        seen[t] = true
        out[#out + 1] = t
      end
    end
  end
  table.sort(out)
  return out
end

--- Replace (or add, or with no tags remove) the `#+filetags:` line.
local function set_filetags(bufnr, file, tags)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, file.preamble_end, false)
  local value = #tags > 0 and (":" .. table.concat(tags, ":") .. ":") or nil
  for i, l in ipairs(lines) do
    if l:match("^%s*#%+[Ff][Ii][Ll][Ee][Tt][Aa][Gg][Ss]:") then
      local new = value and { "#+filetags: " .. value } or {}
      vim.api.nvim_buf_set_lines(bufnr, i - 1, i, false, new)
      return
    end
  end
  if not value then
    return
  end
  -- after #+title, else after the file's property drawer
  local at = file.properties_range and file.properties_range[2] or 0
  for i, l in ipairs(lines) do
    if l:match("^%s*#%+[Tt][Ii][Tt][Ll][Ee]:") then
      at = i
    end
  end
  vim.api.nvim_buf_set_lines(bufnr, at, at, false, { "#+filetags: " .. value })
end

local function parse_tags(s)
  local out = {}
  for t in s:gmatch("[^%s,:]+") do
    out[#out + 1] = t
  end
  return out
end

local function own_tags(h)
  if h.hl then
    return vim.deepcopy(h.hl.tags)
  end
  return vim.deepcopy(h.file.settings.filetags or {})
end

local function set_own_tags(h, tags)
  if h.hl then
    require("org.tags").set_tags({ bufnr = h.bufnr, lnum = h.lnum }, tags, true)
  else
    set_filetags(h.bufnr, h.file, tags)
  end
end

--- Add tags to the node at point: `#+filetags` for a file node, the
--- headline's tags otherwise (org-roam-tag-add).
---@param tags? string|string[]
function M.tag_add(tags)
  local h = here_or_warn()
  if not h then
    return
  end
  if type(tags) ~= "table" then
    local s = tags and vim.trim(tags) ~= "" and tags or utils.input_complete("Tags: ", M.all_tags())
    if not s then
      return
    end
    tags = parse_tags(s)
  end
  if #tags == 0 then
    return
  end
  local cur = own_tags(h)
  for _, t in ipairs(tags) do
    if not vim.tbl_contains(cur, t) then
      cur[#cur + 1] = t
    end
  end
  set_own_tags(h, cur)
end

--- Remove tags from the node at point (org-roam-tag-remove).
---@param tags? string|string[]
function M.tag_remove(tags)
  local h = here_or_warn()
  if not h then
    return
  end
  local cur = own_tags(h)
  if #cur == 0 then
    utils.warn("org-roam: the node has no tags")
    return
  end
  if type(tags) ~= "table" then
    if tags and vim.trim(tags) ~= "" then
      tags = parse_tags(tags)
    else
      local t = utils.select(cur, { prompt = "Remove tag" })
      if not t then
        return
      end
      tags = { t }
    end
  end
  set_own_tags(
    h,
    vim.tbl_filter(function(t)
      return not vim.tbl_contains(tags, t)
    end, cur)
  )
end

---------------------------------------------------------------------------
-- Moving subtrees
---------------------------------------------------------------------------

--- The lines of a file made from a level-1 subtree
--- (org-roam-promote-entire-buffer): the headline's property drawer
--- becomes the file's, its title `#+title`, its tags `#+filetags`, and the
--- children move up a level.
---@param lines string[] the subtree, its headline at level 1
---@return string[]
function M.promote_subtree_lines(lines)
  local parser = require("org.parser")
  local p = parser.parse_headline_line(lines[1])
  local title = vim.trim(require("org.links").display_format(p and p.title or lines[1]:gsub("^%*+%s*", "")))
  local tags = p and p.tags or {}
  local rest = vim.list_slice(lines, 2)
  local out = {}
  -- planning and the property drawer directly under the headline
  local i = 1
  local planning = {}
  while rest[i] and rest[i]:match("^%s*[A-Z]+:%s") and rest[i]:match("^%s*(%u+):") ~= "PROPERTIES" do
    local kw = rest[i]:match("^%s*(%u+):")
    if kw ~= "SCHEDULED" and kw ~= "DEADLINE" and kw ~= "CLOSED" then
      break
    end
    planning[#planning + 1] = vim.trim(rest[i])
    i = i + 1
  end
  if rest[i] and rest[i]:match("^%s*:PROPERTIES:%s*$") then
    while rest[i] do
      out[#out + 1] = vim.trim(rest[i])
      local fin = rest[i]:match("^%s*:END:%s*$")
      i = i + 1
      if fin then
        break
      end
    end
  end
  out[#out + 1] = "#+title: " .. title
  if #tags > 0 then
    out[#out + 1] = "#+filetags: :" .. table.concat(tags, ":") .. ":"
  end
  vim.list_extend(out, planning)
  local body = vim.list_slice(rest, i)
  local adapt = require("org.config").opts.adapt_indentation
  for j, l in ipairs(body) do
    local stars = l:match("^(%*+)%s")
    if stars then
      body[j] = l:sub(2)
    elseif adapt then
      body[j] = l:gsub("^  ", "", 1)
    end
  end
  vim.list_extend(out, body)
  return out
end

--- Move the subtree at point into a new file of its own, as a file node
--- (org-roam-extract-subtree).
---@param path? string
function M.extract_subtree(path)
  local bufnr = vim.api.nvim_get_current_buf()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local file = files.get_buffer(bufnr)
  local hl = file:headline_at(lnum)
  if not hl then
    utils.warn("org-roam: already a top-level node")
    return
  end
  local id = require("org.id").get_create({ bufnr = bufnr, lnum = hl.line })
  file = files.get_buffer(bufnr)
  hl = file:find_by_id(id)
  local node = { id = id, title = vim.trim(require("org.links").display_format(hl:plain_title())) }
  if not path or vim.trim(path) == "" then
    local default = capture().fill(ropts().extract_new_file_path, node, {})
    default = require("org.capture").expand(default, {}):gsub("\30", "")
    default = utils.expand(vim.trim(default), db.directory())
    local ok, v = pcall(vim.fn.input, { prompt = "Extract node to: ", default = default, completion = "file" })
    if not ok or not v or vim.trim(v) == "" then
      return
    end
    path = v
  end
  path = utils.expand(vim.trim(path), db.directory())
  if utils.exists(path) or utils.find_buffer(path) then
    utils.warn("org-roam: " .. utils.abbreviate(path) .. " exists, not extracting")
    return
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, hl.line - 1, hl.end_line, false)
  while #lines > 1 and lines[#lines]:match("^%s*$") do
    table.remove(lines)
  end
  local new = M.promote_subtree_lines(edit.relevel(vim.deepcopy(lines), 1))
  utils.writefile(path, new)
  vim.api.nvim_buf_set_lines(bufnr, hl.line - 1, hl.end_line, false, {})
  utils.save_buffer_or_warn(bufnr)
  require("org.id").register(id, path)
  db.update_file(path)
  local src = vim.api.nvim_buf_get_name(bufnr)
  if src ~= "" then
    db.update_file(src)
  end
  utils.notify("org-roam: extracted to " .. utils.abbreviate(path))
end

--- Move the subtree at point (or the Visual lines) under a node
--- (org-roam-refile): as a top-level entry at the end of a file node, or a
--- child of a headline node.
function M.refile()
  local bufnr = vim.api.nvim_get_current_buf()
  local range
  local mode = vim.fn.mode()
  if mode == "v" or mode == "V" or mode == "\22" then
    local s, _, e = utils.visual_range()
    vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
    range = { s, e }
  end
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  if not range and not files.get_buffer(bufnr):headline_at(lnum) then
    utils.warn("org-roam: not in a subtree")
    return
  end
  local c = M.read({ prompt = "Refile to", allow_new = false })
  if not c or not c.node then
    return
  end
  local node = c.node
  local dbuf = utils.load_buffer(node.file)
  local dest = { bufnr = dbuf, filename = node.file }
  if node.level > 0 then
    local hl = files.get_buffer(dbuf):find_by_id(node.id)
    if not hl then
      utils.warn("org-roam: cannot find the target node, run :Org roam_db_sync")
      return
    end
    dest.lnum = hl.line
  end
  local ok, err = pcall(require("org.refile").move, { bufnr = bufnr, lnum = lnum, range = range }, dest)
  if not ok then
    utils.warn(tostring(err))
    return
  end
  utils.notify("Refiled to " .. c.name)
  M.delete_if_empty(bufnr)
end

--- After a refile: delete the file of a buffer left empty, and the buffer
--- (org-roam-refile).
---@param bufnr integer
---@return boolean deleted
function M.delete_if_empty(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.api.nvim_buf_line_count(bufnr) > 1 then
    return false
  end
  if (vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] or "") ~= "" then
    return false
  end
  local path = vim.api.nvim_buf_get_name(bufnr)
  if path ~= "" and utils.exists(path) then
    os.remove(path)
  end
  pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  if path ~= "" then
    db.update_file(path)
  end
  return true
end

---------------------------------------------------------------------------
-- roam: links
---------------------------------------------------------------------------

--- Replace `[[roam:Title]]` links to existing nodes with `id:` links, in
--- lines `s`..`e` (default the whole buffer; org-roam-link-replace-all).
--- Links in verbatim blocks are left alone. Returns the number replaced.
---@param bufnr? integer
---@param s? integer
---@param e? integer
---@return integer
function M.link_replace_all(bufnr, s, e)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  s, e = s or 1, math.min(e or #lines, #lines)
  local parser = require("org.parser")
  local links = require("org.links")
  local count, synced = 0, false
  local i = 1
  while i <= e do
    local block_end = parser.verbatim_block_end(lines, i, #lines)
    if block_end then
      i = block_end + 1
    else
      local line = lines[i]
      if i >= s and line:find("[[roam:", 1, true) then
        local new = line:gsub("%[%[roam:([^%]]+)%](%[?([^%]]*)%]?)%]", function(path, rest, desc)
          if not synced then
            db.sync()
            synced = true
          end
          local node = db.by_title(vim.trim(path))
          if not node then
            return nil
          end
          count = count + 1
          return links.format("id:" .. node.id, rest ~= "" and desc or path)
        end)
        if new ~= line then
          vim.api.nvim_buf_set_lines(bufnr, i - 1, i, false, { new })
        end
      end
      i = i + 1
    end
  end
  return count
end

return M
