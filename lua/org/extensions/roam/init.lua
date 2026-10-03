---@mod org.extensions.roam org-roam: a network of linked notes
---
--- Enable with `setup({ extensions = { roam = { directory = "~/roam" } } })`.
--- Notes use org-roam v2's format (`:ID:` properties, `ROAM_ALIASES`,
--- `ROAM_REFS`, `ROAM_EXCLUDE`), so a directory can be shared with Emacs
--- org-roam. See `:h org-extensions-roam`.

local M = {}

local R = "org.extensions.roam"

M.defaults = {
  --- The notes directory (org-roam-directory); every `.org` file below it
  --- is indexed.
  directory = "~/org/roam",
  --- Emacs regexps (or `fun(relpath, path): boolean`); files whose path
  --- relative to `directory` matches one are not indexed
  --- (org-roam-file-exclude-regexp, default org-attach-id-dir). Hidden
  --- files and directories are always skipped.
  exclude = { "data/" },
  --- Where the index is cached (default stdpath("data")/org/roam-index.json).
  index_file = nil,
  --- Re-index a roam file when it is written (org-roam-db-autosync-mode).
  update_on_save = true,
  --- Order of the node candidates: "title", "mtime" (recently changed
  --- files first) or "none" (file order).
  sort = "mtime",
  --- How nodes are chosen (org-roam-node-read): "auto" (org's `picker`
  --- option: LazyVim's picker, else snacks.nvim's first), "snacks",
  --- "fzf-lua", "telescope", "mini", "select" (`vim.ui.select` with a
  --- "+ New node" entry) or "input" (type a title, <Tab> completes). With
  --- a fuzzy picker and "input", a title that matches no node creates one.
  picker = "auto",
  --- Show the outline path before headline nodes in the candidates.
  display_olp = false,
  --- `fun(node, name): string` formatting a candidate
  --- (org-roam-node-display-template); `name` is the title or an alias.
  node_display = nil,
  --- `fun(node, name): string` giving the description of an inserted link
  --- (org-roam-node-formatter); default the chosen title or alias.
  link_description = nil,
  --- Capture templates for new nodes (org-roam-capture-templates): capture
  --- templates whose `target` is a file relative to `directory`, with an
  --- optional `head` for a new file and `olp`. `${title}`, `${slug}`,
  --- `${id}` or any `${key=default}` are filled in.
  capture_templates = {
    d = {
      description = "default",
      type = "plain",
      template = "%?",
      target = "%<%Y%m%d%H%M%S>-${slug}.org",
      head = "#+title: ${title}\n",
      unnarrowed = true,
    },
  },
  --- Templates for `org-protocol://roam-ref` captures
  --- (org-roam-capture-ref-templates); `${ref}` and `${body}` come from
  --- the URL.
  capture_ref_templates = {
    r = {
      description = "ref",
      type = "plain",
      template = "%?",
      target = "${slug}.org",
      head = "#+title: ${title}\n",
      unnarrowed = true,
    },
  },
  --- Also store the page's link for `insert_link` on a roam-ref capture
  --- (org-roam-protocol-store-links).
  protocol_store_links = false,
  --- The file an extracted subtree goes to (org-roam-extract-new-file-path).
  extract_new_file_path = "%<%Y%m%d%H%M%S>-${slug}.org",
  --- Follow `roam:Title` links to the node with that title or alias, and
  --- offer to create it (org-roam-link).
  roam_links = true,
  --- Replace `roam:` links to existing nodes with `id:` links when a roam
  --- file is saved or the link followed (org-roam-link-auto-replace).
  link_auto_replace = true,
  --- The backlinks window (org-roam-buffer).
  buffer = {
    --- "right", "left" or "bottom".
    position = "right",
    width = 50,
    height = 15,
    --- Sections shown, in order: "backlinks", "reflinks" and "unlinked"
    --- (mentions of the title or an alias that aren't links).
    sections = { "backlinks", "reflinks" },
    --- Lines of context shown for each link.
    preview_lines = 5,
  },
  --- The node graph (org-roam-graph).
  graph = {
    --- Graphviz program (org-roam-graph-executable).
    executable = "dot",
    --- Output format (org-roam-graph-filetype).
    filetype = "svg",
    --- `fun(path)`, a program name, or false to only write the file; nil
    --- opens it with `vim.ui.open` (org-roam-graph-viewer).
    viewer = nil,
    --- Graph attributes, e.g. `{ rankdir = "LR" }` (org-roam-graph-extra-config).
    extra_config = {},
    --- Edge attributes (org-roam-graph-edge-extra-config).
    edge_extra_config = {},
    --- Node attributes by link type (org-roam-graph-node-extra-config).
    node_extra_config = {
      id = { style = "bold,rounded,filled", fillcolor = "#EEEEEE", color = "#C9C9C9", fontcolor = "#111111" },
      http = { style = "rounded,filled", fillcolor = "#EEEEEE", color = "#C9C9C9", fontcolor = "#0A97A6" },
      https = { style = "rounded,filled", fillcolor = "#EEEEEE", color = "#C9C9C9", fontcolor = "#0A97A6" },
    },
    --- Link types left out (org-roam-graph-link-hidden-types).
    link_hidden_types = { "file" },
    --- Longest title in a graph node (org-roam-graph-max-title-length).
    max_title_length = 100,
    --- "truncate", "wrap" or false (org-roam-graph-shorten-titles).
    shorten_titles = "truncate",
    --- `fun(node): string`, the URL of a graph node
    --- (org-roam-graph-link-builder); default org-protocol://roam-node.
    link_builder = nil,
  },
  --- Daily notes (org-roam-dailies).
  dailies = {
    --- Relative to `directory` (org-roam-dailies-directory).
    directory = "daily/",
    --- Templates for daily notes, targets relative to `dailies.directory`
    --- (org-roam-dailies-capture-templates).
    capture_templates = {
      d = {
        description = "default",
        type = "entry",
        template = "* %?",
        target = "%<%Y-%m-%d>.org",
        head = "#+title: %<%Y-%m-%d>\n",
      },
    },
  },
}

local function a(fn, desc, modes)
  local mod, name = fn:match("^(.-)%.([%w_]+)$")
  return { R .. "." .. mod, name, desc = desc, modes = modes }
end

M.actions = {
  roam_node_find = a("node.find", "Find or create a roam node"),
  roam_node_insert = a("node.insert", "Insert a link to a roam node", { "n", "x" }),
  roam_node_random = a("node.random", "Visit a random roam node"),
  roam_buffer_toggle = a("buffer.toggle", "Toggle the roam backlinks window"),
  roam_capture = a("capture.command", "Capture a roam node"),
  roam_alias_add = a("node.alias_add", "Add an alias to the roam node"),
  roam_alias_remove = a("node.alias_remove", "Remove an alias from the roam node"),
  roam_ref_add = a("node.ref_add", "Add a ref to the roam node"),
  roam_ref_remove = a("node.ref_remove", "Remove a ref from the roam node"),
  roam_tag_add = a("node.tag_add", "Add tags to the roam node"),
  roam_tag_remove = a("node.tag_remove", "Remove a tag from the roam node"),
  roam_extract_subtree = a("node.extract_subtree", "Extract the subtree into a roam file"),
  roam_refile = a("node.refile", "Refile the subtree to a roam node", { "n", "x" }),
  roam_db_sync = a("db.sync_command", "Update the roam index"),
  roam_graph = a("graph.show", "Show the roam node graph (count: around the node)"),
  roam_link_replace_all = a("node.link_replace_all", "Replace roam: links with id: links"),
  roam_dailies_goto_today = a("dailies.goto_today", "Open today's daily note"),
  roam_dailies_goto_yesterday = a("dailies.goto_yesterday", "Open yesterday's daily note"),
  roam_dailies_goto_tomorrow = a("dailies.goto_tomorrow", "Open tomorrow's daily note"),
  roam_dailies_goto_date = a("dailies.goto_date", "Open the daily note of a date"),
  roam_dailies_goto_next_note = a("dailies.goto_next_note", "Go to the next daily note"),
  roam_dailies_goto_previous_note = a("dailies.goto_previous_note", "Go to the previous daily note"),
  roam_dailies_capture_today = a("dailies.capture_today", "Capture into today's daily note"),
  roam_dailies_capture_yesterday = a("dailies.capture_yesterday", "Capture into yesterday's daily note"),
  roam_dailies_capture_tomorrow = a("dailies.capture_tomorrow", "Capture into tomorrow's daily note"),
  roam_dailies_capture_date = a("dailies.capture_date", "Capture into the daily note of a date"),
  roam_dailies_find_directory = a("dailies.find_directory", "Open the daily notes directory"),
}

local function c(fn, desc)
  local mod, name = fn:match("^(.-)%.([%w_]+)$")
  return { R .. "." .. mod, name, desc = desc }
end

-- subcommands that take an argument (the action of the same name runs
-- without one from a key)
M.commands = {
  roam_node_find = c("node.find", "Find or create a roam node: :Org roam_node_find [title]"),
  roam_capture = c("capture.command", "Capture a roam node: :Org roam_capture [title]"),
  roam_alias_add = c("node.alias_add", "Add an alias: :Org roam_alias_add [alias]"),
  roam_alias_remove = c("node.alias_remove", "Remove an alias: :Org roam_alias_remove [alias]"),
  roam_ref_add = c("node.ref_add", "Add a ref: :Org roam_ref_add [ref]"),
  roam_ref_remove = c("node.ref_remove", "Remove a ref: :Org roam_ref_remove [ref]"),
  roam_tag_add = c("node.tag_add", "Add tags: :Org roam_tag_add [tag ...]"),
  roam_tag_remove = c("node.tag_remove", "Remove tags: :Org roam_tag_remove [tag ...]"),
  roam_extract_subtree = c("node.extract_subtree", "Extract the subtree: :Org roam_extract_subtree [file]"),
  roam_db_sync = c("db.sync_command", "Update the roam index: :Org roam_db_sync [force]"),
  roam_graph = c("graph.show", "Show the node graph: :Org roam_graph [N|local] (N links around the node)"),
  roam_dailies_goto_date = c("dailies.goto_date", "Open a daily note: :Org roam_dailies_goto_date [date]"),
  roam_dailies_capture_date = c("dailies.capture_date", "Capture to a daily note: [date]"),
  roam_dailies_capture_today = c("dailies.capture_today", "Capture to today's note: [template key]"),
}

-- <prefix>r is refile, so the roam keys live under <prefix>m
M.mappings = {
  global = {
    roam_node_find = "<prefix>mf",
    roam_node_insert = "<prefix>mi",
    roam_buffer_toggle = "<prefix>ml",
    roam_capture = "<prefix>mc",
    roam_node_random = "<prefix>mr",
    roam_graph = "<prefix>mg",
    roam_dailies_goto_today = "<prefix>mdt",
    roam_dailies_goto_yesterday = "<prefix>mdy",
    roam_dailies_goto_tomorrow = "<prefix>mdT",
    roam_dailies_goto_date = "<prefix>mdd",
    roam_dailies_capture_today = "<prefix>mj",
    roam_dailies_goto_next_note = "<prefix>mdn",
    roam_dailies_goto_previous_note = "<prefix>mdp",
  },
  org = {
    roam_alias_add = "<prefix>ma",
    roam_ref_add = "<prefix>mR",
    roam_tag_add = "<prefix>mt",
    roam_extract_subtree = "<prefix>mx",
    roam_refile = "<prefix>mw",
  },
}

-- which-key labels
M.groups = { { "m", "roam" }, { "md", "roam dailies" } }

local augroup = vim.api.nvim_create_augroup("org.roam", { clear = true })

--- The resolved options.
---@return table
function M.opts()
  return require("org.extensions").opts("roam") or M.defaults
end

--- Follow a `roam:` link: visit the node with that title or alias, or
--- capture it (org-roam-link-follow-link).
local function follow_roam_link(path)
  local db = require(R .. ".db")
  db.sync()
  local title = vim.trim(path)
  local node = db.by_title(title)
  if node then
    if M.opts().link_auto_replace then
      local row = vim.api.nvim_win_get_cursor(0)[1]
      require(R .. ".node").link_replace_all(0, row, row)
    end
    return require(R .. ".node").visit(node)
  end
  require("org.utils").run(function()
    require(R .. ".capture").capture({ node = { title = title }, finalize = "find_file" })
  end)
end

function M.setup(opts)
  vim.api.nvim_clear_autocmds({ group = augroup })
  -- the index write that follows a save may still be waiting
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = augroup,
    callback = function()
      require(R .. ".db").flush()
    end,
  })
  -- Write hooks, so org's own saves (capture, refile, ...) count as well
  -- as :w
  local function roam_path(buf)
    local path = vim.fs.normalize(vim.api.nvim_buf_get_name(buf))
    if path:match("%.org$") and require(R .. ".db").is_roam_file(path) then
      return path
    end
  end
  local hooks = require("org.write_hooks")
  if opts.update_on_save or opts.link_auto_replace then
    hooks.register("roam", {
      order = 20,
      pre = opts.link_auto_replace and function(buf)
        if roam_path(buf) then
          require(R .. ".node").link_replace_all(buf)
        end
      end or nil,
      post = opts.update_on_save and function(buf, ctx)
        local path = ctx.ok and roam_path(buf)
        if path then
          require("org.files").invalidate(path)
          require(R .. ".db").update_file(path)
        end
      end or nil,
    })
  else
    hooks.unregister("roam")
  end
  if opts.roam_links then
    local types = require("org.config").opts.links.types
    if types.roam == nil then
      types.roam = {
        follow = follow_roam_link,
        complete = function()
          local titles = {}
          for _, c in ipairs(require(R .. ".node").candidates()) do
            titles[#titles + 1] = c.name
          end
          local t = require("org.utils").input_complete("Node: ", titles)
          return t and vim.trim(t) ~= "" and ("roam:" .. vim.trim(t)) or nil
        end,
      }
    end
  end
  require(R .. ".protocol").register(true)
  require(R .. ".db").reset()
end

--- Undo `setup` when the extension is turned off.
function M.teardown()
  vim.api.nvim_clear_autocmds({ group = augroup })
  require("org.write_hooks").unregister("roam")
  require(R .. ".protocol").register(false)
  require(R .. ".buffer").wipe()
  require(R .. ".db").flush()
end

function M.health(h, opts)
  local db = require(R .. ".db")
  local dir = db.directory()
  if require("org.utils").is_dir(dir) then
    h.ok("roam directory: " .. dir)
  else
    h.warn("roam directory does not exist: " .. dir, { "mkdir -p " .. dir })
    return
  end
  local parsed = db.sync()
  local s = db.stats()
  h.ok(string.format("roam index: %d nodes, %d links in %d files (%s)", s.nodes, s.links, s.files, s.path))
  if parsed > 0 then
    h.info(string.format("%d files were re-indexed by this check", parsed))
  end
  local dups = db.duplicates()
  local ids = vim.tbl_keys(dups)
  table.sort(ids)
  for _, id in ipairs(ids) do
    local where = vim.tbl_map(function(n)
      return require("org.utils").abbreviate(n.file) .. ":" .. n.lnum
    end, dups[id])
    h.warn(string.format("duplicate ID %s (only the first is a node): %s", id, table.concat(where, ", ")))
  end
  if not opts.update_on_save then
    h.info("update_on_save is off: run :Org roam_db_sync after editing notes")
  end
  h.info("node picker: " .. require(R .. ".node").picker())
  local exe = (opts.graph or {}).executable or "dot"
  if vim.fn.executable(exe) == 1 then
    h.ok("Graphviz found: roam_graph renders the node graph")
  else
    h.info("Graphviz (" .. exe .. ") not found: roam_graph only writes a .dot file")
  end
end

return M
