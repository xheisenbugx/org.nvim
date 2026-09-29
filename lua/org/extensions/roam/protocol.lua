---@mod org.extensions.roam.protocol org-protocol handlers (org-roam-protocol)
---
--- `org-protocol://roam-ref?template=r&ref=URL&title=TITLE&body=TEXT`
--- opens the node with that ref, or captures a new one with
--- `capture_ref_templates`; `org-protocol://roam-node?node=ID` visits a
--- node. Registered while the extension is enabled (see |org-protocol|).

local utils = require("org.utils")

local M = {}

local function ropts()
  return require("org.extensions.roam").opts()
end

--- roam-ref: capture to (or visit) the node of a web page
--- (org-roam-protocol-open-ref).
---@param params table
function M.open_ref(params)
  if not params.ref or params.ref == "" then
    utils.warn("org-roam: no ref key provided")
    return nil
  end
  local proto = require("org.protocol")
  local links = require("org.links")
  local ref = proto.sanitize_uri(params.ref)
  local title = params.title ~= "" and params.title or nil
  local body = params.body or ""
  if ropts().protocol_store_links then
    links.store(ref, title)
  end
  local annotation = links.format(ref, title or ref)
  local keywords = vim.tbl_extend("force", {}, params, {
    type = ref:match("^(%l[%w+%-]*):"),
    link = ref,
    description = title or "",
    annotation = annotation,
    initial = body,
    ref = ref,
  })
  local props = { link = ref, description = title or "", annotation = annotation, initial = body, keywords = keywords }
  local ok, err = pcall(utils.run, function()
    require("org.extensions.roam.capture").capture({
      templates = ropts().capture_ref_templates,
      keys = params.template,
      node = { title = title or ref },
      info = { ref = ref, body = body },
      link_props = props,
    })
  end)
  if not ok then
    utils.error("org-roam roam-ref: " .. tostring(err))
    return nil
  end
  return true
end

--- roam-node: visit the node with an id (org-roam-protocol-open-node).
---@param params table
function M.open_node(params)
  local id = params.node
  if not id or id == "" then
    return nil
  end
  local db = require("org.extensions.roam.db")
  db.sync()
  local node = db.node(id)
  if not node then
    utils.warn("org-roam: no node with id " .. id)
    return nil
  end
  require("org.extensions.roam.node").visit(node)
  return true
end

M.handlers = {
  ["org-roam-ref"] = { protocol = "roam-ref", fn = M.open_ref, order = { "template", "ref", "title", "body" } },
  ["org-roam-node"] = { protocol = "roam-node", fn = M.open_node, order = { "node" } },
}

--- Register (or with `enable` false, remove) the handlers.
---@param enable boolean
function M.register(enable)
  local ext = require("org.protocol").extension_handlers
  for name, h in pairs(M.handlers) do
    ext[name] = enable and h or nil
  end
end

return M
