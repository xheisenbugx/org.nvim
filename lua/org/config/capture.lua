-- Options: Capture and refile.
--
-- One part of `require("org.config").defaults`, merged in the order of
-- `M.parts` in lua/org/config/init.lua. Keys keep the indentation of the
-- full table: `:Org customize` reads these files for the options and the
-- `---` documentation above each one.

---@class org.config.Resolved
local defaults = {
  ---------------------------------------------------------------------------
  -- Capture
  ---------------------------------------------------------------------------
  capture = {
    --- Templates keyed by selection key (org-capture-templates). See
    --- `:h org-capture-templates`. When empty, the Emacs fallback
    --- `t = { description = "Task", target = "", headline = "Tasks",
    --- template = "* TODO %?\n  %u\n  %a" }` is used.
    templates = {},
    --- Rules making templates available only in some buffers
    --- (org-capture-templates-contexts), e.g.
    --- `{ { "p", { { in_mode = "markdown" } } } }`.
    templates_contexts = {},
    --- Window of the capture buffer: "split" (Emacs splits the frame) |
    --- "float" | "vsplit" | "tab" | "current".
    window = "split",
    --- Capturing from the agenda (the global capture key) uses the date at
    --- point as the default date; with count 1 also the time of the item
    --- at point or the current time (org-capture-use-agenda-date). The
    --- agenda's own capture key always does.
    use_agenda_date = false,
  },

  ---------------------------------------------------------------------------
  -- Refile
  ---------------------------------------------------------------------------
  refile = {
    --- Target specs (org-refile-targets). Empty = the level-1 headlines of
    --- the current buffer, like Emacs's nil. See `:h org-refile`.
    targets = {},
    --- When set (and `targets` is empty): the agenda files plus the current
    --- file, up to this level (a shortcut for
    --- `{ { files = "agenda", max_level = N }, { files = "current", max_level = N } }`).
    max_level = nil,
    --- With `max_level`: false leaves out the current file.
    include_current_file = nil,
    --- Target labels (org-refile-use-outline-path): false (the heading) |
    --- true (outline path) | "file" | "full-file-path" | "title" |
    --- "buffer-name" (outline path after that prefix; these also offer
    --- the files themselves).
    use_outline_path = false,
    --- With an outline path, choose it one level at a time
    --- (org-outline-path-complete-in-steps).
    outline_path_complete_in_steps = true,
    --- Allow new parent headlines ("Target/New"): false | true | "confirm"
    --- (org-refile-allow-creating-parent-nodes).
    allow_creating_parent_nodes = false,
    --- Refile a Visual selection that does not start at a headline, making
    --- its first line one (org-refile-active-region-within-subtree).
    active_region_within_subtree = false,
    --- function(headline) -> boolean, filters targets (org-refile-target-verify-function).
    verify = nil,
    --- Log refiling: false | "time" | "note" (org-log-refile).
    log = false,
    --- Refile as the first child instead of the last (org-reverse-note-order).
    reverse_note_order = false,
    --- Keep the targets between refiles (org-refile-use-cache); a count of
    --- 64 (C-u C-u C-u C-c C-w) or `:Org refile_cache_clear` clears it.
    use_cache = false,
  },
}

return defaults
