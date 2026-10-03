-- Options: Priorities, tags and properties.
--
-- One part of `require("org.config").defaults`, merged in the order of
-- `M.parts` in lua/org/config/init.lua. Keys keep the indentation of the
-- full table: `:Org customize` reads these files for the options and the
-- `---` documentation above each one.

---@class org.config.Resolved
local defaults = {
  ---------------------------------------------------------------------------
  -- Priorities & tags
  ---------------------------------------------------------------------------
  priority_highest = "A",
  priority_lowest = "C",
  priority_default = "B",
  --- `false` disables the priority commands (org-priority-enable-commands).
  priority_enable_commands = true,
  --- Shifting a headline without cookie starts at the default priority;
  --- `false` starts one step past it (org-priority-start-cycle-with-default).
  priority_start_cycle_with_default = true,
  --- fn(headline_line) -> number replacing the priority value used for
  --- sorting (org-priority-get-priority-function); nil uses the cookie.
  priority_get_priority_function = nil,
  --- Tag groups (`[ GTD : Control Persp ]` in #+TAGS / `tags`) also match
  --- their members in tag searches (org-group-tags); toggled by
  --- `toggle_tags_groups`.
  group_tags = true,
  --- Fast tag selection exits after one key (org-fast-tag-selection-single-key):
  --- `false`, `true`, or `"expert"` (no menu window).
  fast_tag_selection_single_key = false,
  --- Show the TODO keywords with fast keys in the fast tag selection menu
  --- (org-fast-tag-selection-include-todo).
  fast_tag_selection_include_todo = false,
  --- Fast tag selection (org-use-fast-tag-selection): `"auto"` when some
  --- tag has a key, `true` always, `false` never.
  use_fast_tag_selection = "auto",
  --- Tags without a key shown by fast selection, counting the tags with
  --- keys and the tags in groups (org-fast-tag-selection-maximum-tags).
  fast_tag_selection_maximum_tags = 56,
  --- Tag completion offers the tags of every agenda file instead of the
  --- current buffer's (org-complete-tags-always-offer-all-agenda-tags).
  complete_tags_always_offer_all_agenda_tags = false,
  --- Global tag list offered for completion. Strings may contain fast keys,
  --- e.g. `"work(w)"`, and `"{" ... "}"` for mutually exclusive groups.
  tags = {},
  --- Tags always available, like `tags` but not replaced by #+TAGS
  --- (org-tag-persistent-alist); `#+STARTUP: noptag` turns them off.
  tags_persistent = {},
  --- Comparator fn(a, b) -> boolean, or a list of them, sorting the tags
  --- set on a headline (org-tags-sort-function); "hierarchy", "string<"
  --- and "string>" name org-tags-sort-hierarchy, org-string< and
  --- org-string>. nil keeps their order.
  tags_sort_function = nil,
  --- Column tags are aligned to. Negative = right-align to that column.
  tags_column = -77,
  --- Realign tags after edits (org-auto-align-tags).
  auto_align_tags = true,
  --- Toggling ORDERED (C-c C-x o) also toggles a tag: `true` (ORDERED) or
  --- a tag name (org-track-ordered-property-with-tag).
  track_ordered_property_with_tag = false,
  --- Tag inheritance (org-use-tag-inheritance): true, false, a list of the
  --- tags that inherit, or a regexp matching them.
  use_tag_inheritance = true,
  --- Tags that never inherit (org-tags-exclude-from-inheritance).
  tags_exclude_from_inheritance = {},
  --- Property inheritance (org-use-property-inheritance): true, false, a
  --- list of property names, or a regexp matching them (ignoring case).
  use_property_inheritance = false,
  --- Format of `:NAME: value` lines in property drawers (org-property-format).
  property_format = "%-10s %s",
  --- Properties that apply to every entry (e.g. `Effort_ALL`).
  global_properties = {},
  --- Functions adjusting values set with set_property, by property name:
  --- `{ Remaining = function(value) return ... end }`
  --- (org-properties-postprocess-alist).
  properties_postprocess = {},
  --- Separators joining `PROP` and `PROP+` values: a list of
  --- `{ { "NAME", ... } or "regexp", "separator" }`; a space otherwise
  --- (org-property-separators).
  property_separators = {},
  --- Properties hidden and shown again by
  --- toggle_custom_properties_visibility (org-custom-properties).
  custom_properties = {},
}

return defaults
