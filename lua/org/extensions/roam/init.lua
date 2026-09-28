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
  --- Lua patterns; files whose path relative to `directory` matches one
  --- are not indexed (org-roam-file-exclude-regexp). Hidden files and
  --- directories are always skipped.
  exclude = { "^data/" },
  --- Where the index is cached (default stdpath("data")/org/roam-index.json).
  index_file = nil,
  --- Re-index a roam file when it is written (org-roam-db-autosync-mode).
  update_on_save = true,
  --- Order of the node candidates: "title", "mtime" (recently changed
  --- files first) or "none" (file order).
  sort = "mtime",
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
  --- The file an extracted subtree goes to (org-roam-extract-new-file-path).
  extract_new_file_path = "%<%Y%m%d%H%M%S>-${slug}.org",
  --- Follow `roam:Title` links to the node with that title or alias, and
  --- offer to create it (org-roam-link).
  roam_links = true,
  --- The backlinks window (org-roam-buffer).
  buffer = {
    --- "right", "left" or "bottom".
    position = "right",
    width = 50,
    height = 15,
    --- Sections shown, in order: "backlinks", "reflinks".
    sections = { "backlinks", "reflinks" },
    --- Lines of context shown for each link.
    preview_lines = 5,
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

local augroup = vim.api.nvim_create_augroup("org.roam", { clear = true })

--- Follow a `roam:` link: visit the node with that title or alias, or
--- capture it (org-roam-link-follow-link).
local function follow_roam_link(path)
  local db = require(R .. ".db")
  db.sync()
  local title = vim.trim(path)
  local node = db.by_title(title)
  if node then
    return require(R .. ".node").visit(node)
  end
  require("org.utils").run(function()
    require(R .. ".capture").capture({ node = { title = title }, finalize = "find_file" })
  end)
end

function M.setup(opts)
  vim.api.nvim_clear_autocmds({ group = augroup })
  if opts.update_on_save then
    vim.api.nvim_create_autocmd("BufWritePost", {
      group = augroup,
      pattern = "*.org",
      callback = function(ev)
        local db = require(R .. ".db")
        local path = vim.fs.normalize(vim.api.nvim_buf_get_name(ev.buf))
        if db.is_roam_file(path) then
          require("org.files").invalidate(path)
          db.update_file(path)
        end
      end,
    })
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
  require(R .. ".db").reset()
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
  if not opts.update_on_save then
    h.info("update_on_save is off: run :Org roam_db_sync after editing notes")
  end
end

return M
