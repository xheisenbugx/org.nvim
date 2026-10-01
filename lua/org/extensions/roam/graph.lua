---@mod org.extensions.roam.graph The node graph (org-roam-graph)
---
--- Builds a Graphviz graph of the nodes and the links between them, renders
--- it with `dot` (`graph.executable`) and opens the result. Each node links
--- to `org-protocol://roam-node?node=ID`, so with an org-protocol handler
--- (|org-protocol|) clicking a node in the SVG opens it in Neovim.

local db = require("org.extensions.roam.db")
local utils = require("org.utils")

local M = {}

local function gopts()
  return require("org.extensions.roam").opts().graph or {}
end

local function escape(s)
  return (tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

local function url_encode(s)
  return (s:gsub("[^%w%-%._~]", function(c)
    return string.format("%%%02X", c:byte())
  end))
end

local function title_of(title)
  local o = gopts()
  local max = o.max_title_length or 100
  title = title or ""
  if o.shorten_titles == "wrap" then
    -- break at word boundaries every `max` characters
    local out, len = {}, 0
    for word in title:gmatch("%S+") do
      local w = vim.fn.strchars(word)
      if len > 0 and len + 1 + w > max then
        out[#out + 1] = "\\n"
        len = 0
      elseif len > 0 then
        out[#out + 1] = " "
        len = len + 1
      end
      out[#out + 1] = word
      len = len + w
    end
    return table.concat(out)
  elseif o.shorten_titles ~= false and vim.fn.strchars(title) > max then
    return vim.fn.strcharpart(title, 0, max - 1) .. "…"
  end
  return title
end

local function option_list(t, quote)
  local keys = vim.tbl_keys(t or {})
  table.sort(keys)
  local out = {}
  for _, k in ipairs(keys) do
    out[#out + 1] = string.format("%s=%s%s%s", k, quote or '"', escape(t[k]), quote or '"')
  end
  return out
end

--- The edges `{ source, dest, type }` of the graph: every indexed link but
--- those of `graph.link_hidden_types`, once each.
---@return { [1]: string, [2]: string, [3]: string }[]
function M.edges()
  local hidden = {}
  for _, t in ipairs(gopts().link_hidden_types or { "file" }) do
    hidden[t] = true
  end
  local out, seen = {}, {}
  db.sync()
  for _, l in ipairs(db.links()) do
    if not hidden[l.type] and db.node(l.source) then
      local dest = l.type == "id" and l.path or (l.type .. ":" .. l.path)
      local key = l.source .. "\0" .. dest
      if not seen[key] then
        seen[key] = true
        out[#out + 1] = { l.source, dest, l.type }
      end
    end
  end
  return out
end

--- The ids within `distance` links of `id`, in either direction (0: the
--- whole connected component; org-roam-graph--connected-component).
---@param id string
---@param distance integer
---@param edges table
---@return table<string, boolean>
function M.component(id, distance, edges)
  local adj = {}
  for _, e in ipairs(edges) do
    adj[e[1]] = adj[e[1]] or {}
    adj[e[2]] = adj[e[2]] or {}
    table.insert(adj[e[1]], e[2])
    table.insert(adj[e[2]], e[1])
  end
  local keep, frontier, depth = { [id] = true }, { id }, 0
  while #frontier > 0 and (distance == 0 or depth < distance) do
    local next_frontier = {}
    for _, v in ipairs(frontier) do
      for _, w in ipairs(adj[v] or {}) do
        if not keep[w] then
          keep[w] = true
          next_frontier[#next_frontier + 1] = w
        end
      end
    end
    frontier = next_frontier
    depth = depth + 1
  end
  return keep
end

--- The graph in the Graphviz dot language (org-roam-graph--dot). With
--- `opts.id`, only the nodes within `opts.distance` links of it.
---@param opts? { id?: string, distance?: integer }
---@return string
function M.dot(opts)
  opts = opts or {}
  local o = gopts()
  local edges = M.edges()
  local keep
  if opts.id then
    keep = M.component(opts.id, opts.distance or 0, edges)
    edges = vim.tbl_filter(function(e)
      return keep[e[1]] and keep[e[2]]
    end, edges)
  end
  local lines = { 'digraph "org-roam" {' }
  for _, opt in ipairs(option_list(o.extra_config)) do
    lines[#lines + 1] = "  " .. opt .. ";"
  end
  lines[#lines + 1] = "  edge [" .. table.concat(option_list(o.edge_extra_config), ",") .. "];"
  local node_config = o.node_extra_config or {}
  local seen = {}
  local function add_node(key, ntype)
    if seen[key] then
      return
    end
    seen[key] = true
    local node = ntype == "id" and db.node(key) or nil
    local attrs = {}
    if node then
      local builder = o.link_builder
      local url = type(builder) == "function" and builder(node)
        or ("org-protocol://roam-node?node=" .. url_encode(node.id))
      attrs.label = title_of(node.title)
      attrs.tooltip = node.title
      attrs.URL = url
    else
      attrs.label = title_of(ntype == "id" and key or key:gsub("^[^:]+:", "", 1))
      attrs.tooltip = key
      if ntype == "http" or ntype == "https" then
        attrs.URL = key
      end
    end
    for k, v in pairs(node_config[ntype] or {}) do
      attrs[k] = v
    end
    lines[#lines + 1] = string.format('  "%s" [%s];', escape(key), table.concat(option_list(attrs), ","))
  end
  for _, e in ipairs(edges) do
    add_node(e[1], "id")
    add_node(e[2], e[3])
    lines[#lines + 1] = string.format('  "%s" -> "%s";', escape(e[1]), escape(e[2]))
  end
  -- the whole graph also shows nodes without links
  for _, n in ipairs(db.nodes()) do
    if not keep or keep[n.id] then
      add_node(n.id, "id")
    end
  end
  lines[#lines + 1] = "}"
  return table.concat(lines, "\n")
end

--- Show the graph (org-roam-graph): all nodes, or with a count (or `arg`
--- a number) the nodes within that many links of the node at point (0 its
--- whole connected component). Renders with `graph.executable` into
--- `graph.filetype` and opens it with `graph.viewer` (default
--- `vim.ui.open`); without Graphviz the `.dot` file is written instead.
---@param arg? string|integer
function M.show(arg)
  local distance = tonumber(arg) or (vim.v.count > 0 and vim.v.count or nil)
  if arg == "local" then
    distance = 0
  end
  local opts = {}
  if distance then
    local here = require("org.extensions.roam.node").at_point()
    if not here then
      utils.warn("org-roam: no node at point")
      return
    end
    opts = { id = here.id, distance = distance }
  end
  local o = gopts()
  local dir = vim.fn.stdpath("cache") .. "/org"
  vim.fn.mkdir(dir, "p")
  local base = dir .. "/roam-graph"
  local dot_file = base .. ".dot"
  utils.writefile(dot_file, vim.split(M.dot(opts), "\n", { plain = true }))
  local exe = o.executable or "dot"
  if vim.fn.executable(exe) ~= 1 then
    utils.warn("org-roam: " .. exe .. " (Graphviz) not found; wrote " .. vim.fn.fnamemodify(dot_file, ":~"))
    return dot_file
  end
  local ft = o.filetype or "svg"
  local out = base .. "." .. ft
  vim.system({ exe, dot_file, "-T" .. ft, "-o", out }, { text = true }, function(res)
    vim.schedule(function()
      if res.code ~= 0 then
        utils.error("org-roam: graph failed: " .. vim.trim(res.stderr or ""))
        return
      end
      local viewer = o.viewer
      if type(viewer) == "function" then
        viewer(out)
      elseif type(viewer) == "string" and viewer ~= "" then
        vim.system({ viewer, out }, { detach = true })
      elseif viewer ~= false then
        vim.ui.open(out)
      end
      utils.notify("org-roam: graph " .. vim.fn.fnamemodify(out, ":~"))
    end)
  end)
  return out
end

return M
