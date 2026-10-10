-- Options: Buffer behaviour: startup, structure editing, source blocks, lists,
-- cycling, footnotes, dates and archiving.
--
-- One part of `require("org.config").defaults`, merged in the order of
-- `M.parts` in lua/org/config/init.lua. Keys keep the indentation of the
-- full table: `:Org customize` reads these files for the options and the
-- `---` documentation above each one.

---@class org.config.Resolved
local defaults = {
  ---------------------------------------------------------------------------
  -- Buffer behaviour
  ---------------------------------------------------------------------------
  --- "overview" | "content" | "showall" | "showeverything" | "nofold"
  --- | "show2levels" .. "show5levels" (org-startup-folded)
  startup_folded = "showeverything",
  --- Fold drawers when the file is opened (org-hide-drawer-startup;
  --- #+STARTUP: hidedrawers / nohidedrawers).
  hide_drawer_startup = true,
  --- Fold `#+begin_...` blocks when the file is opened (org-hide-block-startup;
  --- #+STARTUP: hideblocks).
  hide_block_startup = false,
  --- Turn on the Beamer editing mode when a file is opened
  --- (org-startup-with-beamer-mode; #+STARTUP: beamer).
  startup_with_beamer_mode = false,
  --- Let visibility cycling open subtrees tagged :ARCHIVE:
  --- (org-cycle-open-archived-trees).
  cycle_open_archived_trees = false,
  --- Sparse trees open subtrees tagged :ARCHIVE: to show matches in them;
  --- false keeps them folded (org-sparse-tree-open-archived-trees).
  sparse_tree_open_archived_trees = false,
  --- Dates the before/after/range sparse trees look at: nil (SCHEDULED and
  --- DEADLINE), "all", "active", "inactive", "scheduled", "deadline" or
  --- "closed"; `c` in the sparse-tree menu cycles them
  --- (org-sparse-tree-default-date-type).
  sparse_tree_default_date_type = nil,
  --- Heading that collects footnote definitions (created when missing)
  --- (org-footnote-section; #+STARTUP: fnlocal).
  --- false = put each definition at the end of the reference's section.
  footnote_section = "Footnotes",
  --- Indent body text to the headline level (org-adapt-indentation).
  adapt_indentation = false,
  --- A new day node of a date tree gets a time stamp of its date
  --- (org-datetree-add-timestamp): false | "active" | "inactive".
  datetree_add_timestamp = false,
  --- Indentation added to src block contents in the edit buffer
  --- (org-src-content-indentation).
  edit_src_content_indentation = 2,
  --- Keep the indentation of src block lines as written: no common
  --- indentation is removed for evaluation, tangling or editing
  --- (org-src-preserve-indentation). The `-i` switch does it per block.
  src_preserve_indentation = false,
  --- Show "Edit, then exit with ... or abort with ..." in the winbar of
  --- edit buffers (org-edit-src-persistent-message).
  edit_src_persistent_message = true,
  --- Write an edit buffer back to the Org buffer after this many seconds
  --- without changes; 0 = never (org-edit-src-auto-save-idle-delay).
  edit_src_auto_save_idle_delay = 0,
  --- Auto-save the contents of edit buffers to an org-src-XXXXXX-%Y-%d-%m.txt
  --- file next to the Org file (org-edit-src-turn-on-auto-save).
  edit_src_turn_on_auto_save = false,
  --- C-c ' on a block that already has an edit buffer asks before going back
  --- to it ("n" discards it and opens a new one); false = go back at once
  --- (org-src-ask-before-returning-to-edit-buffer).
  src_ask_before_returning_to_edit_buffer = true,
  --- Filetype (or function(bufnr)) of the edit buffer of `: ` fixed-width
  --- areas; nil = none (org-edit-fixed-width-region-mode; Emacs: artist-mode).
  edit_fixed_width_region_mode = nil,
  --- Filetype of the edit buffer and highlighting of src blocks by language;
  --- "" = none (org-src-lang-modes). Other languages use the filetype of
  --- their extension.
  src_lang_modes = {
    C = "c",
    ["C++"] = "cpp",
    asymptote = "asy",
    beamer = "tex",
    calc = "",
    cpp = "cpp",
    ditaa = "",
    desktop = "desktop",
    dot = "dot",
    elisp = "lisp",
    ocaml = "ocaml",
    screen = "sh",
    sqlite = "sql",
    toml = "toml",
    shell = "sh",
    ash = "sh",
    sh = "sh",
    bash = "sh",
    jsh = "sh",
    bash2 = "sh",
    dash = "sh",
    dtksh = "sh",
    ksh = "sh",
    es = "sh",
    rc = "sh",
    itcsh = "tcsh",
    tcsh = "tcsh",
    jcsh = "csh",
    csh = "csh",
    ksh88 = "sh",
    oash = "sh",
    pdksh = "sh",
    mksh = "sh",
    posix = "sh",
    wksh = "sh",
    wsh = "sh",
    zsh = "zsh",
    rpm = "sh",
  },
  --- TAB on a line of a src block indents it with the language's indentation
  --- (indentexpr of its filetype) (org-src-tab-acts-natively).
  src_tab_acts_natively = true,
  --- Default format of coderef labels in src and example blocks; `-l "fmt"`
  --- overrides it per block (org-coderef-label-format).
  coderef_label_format = "(ref:%s)",
  --- Text appended to folded headlines (org-ellipsis).
  ellipsis = "...",
  --- Entities of your own, before the built-in ones (org-entities-user):
  --- `{ { name, latex, latex_math, html, ascii, latin1, utf8 } }`, e.g.
  --- `{ { "snowman", "\\diamond", true, "&#9731;", "[snowman]", "", "☃" } }`.
  entities_user = {},
  --- Blank line handling before new headlines and list items: true | false |
  --- "auto" (org-blank-before-new-entry).
  blank_before_new_entry = { heading = "auto", plain_list_item = "auto" },
  --- M-RET in Insert mode splits the line at the cursor
  --- (org-M-RET-may-split-line): true, false, or per context
  --- `{ headline = false, item = true, default = true }`.
  meta_return_split_line = true,
  --- Clones made by clone_subtree lose their ID instead of getting a new
  --- one (org-clone-delete-id).
  clone_delete_id = false,
  --- Only odd levels: promotion and demotion add or remove two stars
  --- (org-odd-levels-only; #+STARTUP: odd / oddeven).
  odd_levels_only = false,
  --- Named key functions for sorting by function (`f` in sort), called
  --- with the headline (or list item) and its lines:
  --- `{ by_length = function(h, lines) return #lines end }`.
  sort_functions = {},
  --- Names of the bookmarks capture and refile set, saved across sessions
  --- (org-bookmark-names-plist); false for none.
  bookmark_names = {
    last_capture = "org-capture-last-stored",
    last_refile = "org-refile-last-stored",
    last_capture_marker = "org-capture-last-stored-marker",
  },
  --- buffer_goto (org-goto-interface): "outline" (browse a copy of the
  --- buffer in overview, <CR> jumps) or "outline-path-completion".
  goto_interface = "outline",
  --- Deepest headlines offered by the completion interface of buffer_goto
  --- (org-goto-max-level).
  goto_max_level = 5,
  --- In the outline interface, typing searches the headlines
  --- (org-goto-auto-isearch); else n p f b u move and q quits.
  goto_auto_isearch = true,
  --- The picker of the `pick_*` actions (`:h org-pickers`): "auto" (LazyVim's
  --- picker extra when LazyVim is installed, else the first installed of
  --- snacks.nvim, fzf-lua, telescope.nvim and mini.pick, else
  --- vim.ui.select), "snacks", "fzf-lua", "telescope", "mini" or "select".
  picker = "auto",
  --- Options for the picker plugin, by picker: { ["fzf-lua"] = { winopts =
  --- ... }, snacks = { layout = ... }, telescope = { layout_strategy = ...
  --- }, mini = { window = ... } }, merged over org.nvim's own (`:h
  --- org-pickers`).
  picker_opts = {},
  --- Keys of the pickers that go to a place (headlines, agenda entries,
  --- files) opening it in a split, a vertical split or a tab page, or
  --- putting the selected entries (every matching one when none is
  --- selected) in the quickfix list; false for none. `query`, in pickers
  --- that can take a new entry (a roam node, tags), confirms the text typed
  --- even when entries match it (Emacs' vertico-exit-input).
  picker_keys = { split = "<C-s>", vsplit = "<C-v>", tab = "<C-t>", qflist = "<C-q>", query = "<M-CR>" },
  --- How sorting compares text (org-sort-function): "collate" (the
  --- collation locale, like string-collate-lessp), "fallback" (character
  --- codes, org-sort-function-fallback) or function(a, b, ignore_case).
  --- On macOS "collate" compares character codes, like Emacs there.
  sort_function = "collate",
  --- TAB on a list item folds its children and text
  --- (org-cycle-include-plain-lists); "integrate" also treats items as
  --- children of their headline when cycling it; false never folds items.
  cycle_include_plain_lists = true,
  --- Plain lists (org-list-*).
  lists = {
    --- Single-letter bullets `a.`, `B)` and counters `[@c]`
    --- (org-list-allow-alphabetical).
    allow_alphabetical = false,
    --- Ordered bullet terminators: true (both), "." or ")"
    --- (org-plain-list-ordered-item-terminator).
    ordered_item_terminator = true,
    --- Bullet given to items when they are demoted, e.g.
    --- `{ ["-"] = "+", ["+"] = "-" }` (org-list-demote-modify-bullet).
    demote_modify_bullet = {},
    --- Emacs regexp matching bullets followed by two spaces, or nil
    --- (org-list-two-spaces-after-bullet-regexp).
    two_spaces_after_bullet_regexp = nil,
    --- Extra indentation of sub-lists (org-list-indent-offset).
    indent_offset = 0,
    --- Automatic rules (org-list-automatic-rules): `checkbox` updates
    --- statistics cookies after checkbox changes, `indent` lets the first
    --- item move the whole list and turns `*` into `-` at column 0.
    automatic_rules = { checkbox = true, indent = true },
    --- Item motions and moves wrap around the list (org-list-use-circular-motion).
    use_circular_motion = false,
    --- Checkbox cookies count direct children only; false counts every box
    --- below (org-checkbox-hierarchical-statistics).
    checkbox_hierarchical_statistics = true,
  },
  --- Where TAB outside headlines, items, drawers and blocks indents the
  --- line (org-cycle-emulate-tab): true (everywhere), "white" (blank
  --- lines only), "whitestart" (before the first non-blank character),
  --- "exc-hl-bol" (everywhere except at the start of a headline) or false.
  cycle_emulate_tab = true,
  --- Blank lines needed at the end of a subtree for one of them to stay
  --- visible when it is folded (org-cycle-separator-lines).
  cycle_separator_lines = 2,
  --- Edits inside folded text: false (allow), "error", "show" (unfold
  --- first), "show-and-error" or "smart" (unfold, and refuse edits in
  --- text that was hidden) (org-fold-catch-invisible-edits).
  catch_invisible_edits = "smart",
  --- The edits catch_invisible_edits checks, by command: `self_insert`
  --- (typed text), `delete_backward_char` (<BS> in Insert mode),
  --- `delete_char` (<Del>), `return` (<CR>) or any action name, each
  --- "insert", "delete" or "delete-backward"; false removes one
  --- (org-fold-catch-invisible-edits-commands).
  catch_invisible_edits_commands = {
    self_insert = "insert",
    delete_backward_char = "delete-backward",
    delete_char = "delete",
    meta_return = "insert",
    ["return"] = "insert",
  },
  --- TAB at the very start of the buffer, not on a headline, cycles the
  --- global visibility (org-cycle-global-at-bob).
  cycle_global_at_bob = false,
  --- Deepest level cycled as a headline; deeper ones are text for TAB.
  --- nil = all (org-cycle-max-level).
  cycle_max_level = nil,
  --- TAB on an entry without children goes from FOLDED straight to
  --- SUBTREE (org-cycle-skip-children-state-if-no-children).
  cycle_skip_children_state_if_no_children = true,
  --- How much is shown around a location reached by a jump, per context
  --- (agenda, org-goto, occur-tree, tags-tree, link-search, mark-goto,
  --- bookmark-jump, isearch, default): "minimal", "local", "ancestors",
  --- "ancestors-full", "lineage", "tree" or "canonical"; or one of them
  --- for every context (org-fold-show-context-detail).
  fold_show_context_detail = {
    agenda = "local",
    ["bookmark-jump"] = "lineage",
    isearch = "lineage",
    default = "ancestors",
  },
  --- Sparse-tree regexp searches ignore case: true, false or "smart"
  --- (only when the regexp has no upper case) (org-occur-case-fold-search).
  occur_case_fold_search = true,
  --- Any change to the buffer removes the highlights of sparse-tree
  --- searches and clock_display; else C-c C-c does
  --- (org-remove-highlights-with-change).
  remove_highlights_with_change = true,
  --- `beginning_of_line` / `end_of_line` (C-a / C-e) on headlines and
  --- items (org-special-ctrl-a/e): false, true (first to the title start /
  --- before the tags), "reversed" (there on a repeated key), or
  --- `{ a = ..., e = ... }` per key.
  special_ctrl_a_e = false,
  --- `kill_line` (C-k) in a headline title kills up to the tags, on the
  --- tags the tags (org-special-ctrl-k).
  special_ctrl_k = false,
  --- `kill_line` on a folded headline kills its hidden subtree: false
  --- (allow), true (ask) or "error" (org-ctrl-k-protect-subtree).
  ctrl_k_protect_subtree = false,
  --- Setting the org filetype on an empty file that is not named *.org
  --- inserts the Emacs mode line `#    -*- mode: org -*-`, which makes it
  --- open as org from then on (org-insert-mode-line-in-empty-file).
  insert_mode_line_in_empty_file = false,
  --- <M-CR> and the other heading insertions put the new headline after
  --- the current subtree, like <C-CR> (org-insert-heading-respect-content).
  insert_heading_respect_content = false,
  --- Promoting a level-1 headline turns its `* ` into `# ` (a comment)
  --- instead of refusing (org-allow-promoting-top-level-subtree).
  allow_promoting_top_level_subtree = false,
  --- Keep the Visual selection after <M-h> / <M-l> / <M-k> / <M-j>
  --- (org-edit-keep-region): true, false, or per command.
  edit_keep_region = { meta_left = true, meta_right = true, meta_up = true, meta_down = true },
  --- `p` / `P` of whole subtrees folds them, unless that would hide the
  --- text after them (org-yank-folded-subtrees).
  yank_folded_subtrees = true,
  --- `p` / `P` of whole subtrees adjusts their level to the visible
  --- headlines around, like paste_subtree (org-yank-adjusted-subtrees).
  yank_adjusted_subtrees = false,
  --- Single-letter commands at the start of a headline
  --- (org-use-speed-commands). See `:h org-speed-commands`.
  use_speed_commands = false,
  --- Extra or changed speed commands: `{ key = action name | function | false }`.
  speed_commands = {},
  --- Functions(key) deciding which speed command a key runs, tried in
  --- order until one returns a command (an action name or a function); the
  --- names of the built-in ones: headline commands and the Babel keys at a
  --- `#+begin_src` line (org-speed-command-hook).
  speed_command_hook = { "org-speed-command-activate", "org-babel-speed-command-activate" },
  --- Headlines of this level or deeper are inline tasks
  --- (org-inlinetask-min-level). false turns inline tasks off, like Emacs
  --- without the org-inlinetask module; Emacs uses 15 once it is loaded.
  inlinetask_min_level = false,
  --- Show the first star of inline tasks as a marker
  --- (org-inlinetask-show-first-star).
  inlinetask_show_first_star = false,
  --- TODO keyword of new inline tasks (org-inlinetask-default-state).
  inlinetask_default_state = nil,
  --- Block types offered by insert_structure_template, by key
  --- (org-structure-template-alist). `false` removes one.
  structure_template_alist = {
    a = "export ascii",
    c = "center",
    C = "comment",
    e = "example",
    E = "export",
    h = "export html",
    l = "export latex",
    q = "quote",
    s = "src",
    v = "verse",
  },
  --- Expand `<s` + TAB (Insert mode) into a block and `<L` + TAB into a
  --- `#+latex: ` keyword (the org-tempo module, off by default like in
  --- Emacs). Blocks come from `structure_template_alist`.
  tempo = false,
  --- Keywords for tempo expansion (org-tempo-keywords-alist).
  tempo_keywords = { L = "latex", H = "html", A = "ascii", i = "index" },
  --- Labels of new footnotes (org-footnote-auto-label): true (fn:N),
  --- false (prompt), "confirm" (prompt with fn:N as default), "random" or
  --- "plain" (like true), "anonymous" (`[fn:: text]`). #+STARTUP: fnauto,
  --- fnprompt, fnconfirm, fnplain, fnanon; fnlocal sets footnote_section = false.
  footnote_auto_label = true,
  --- Renumber and / or sort footnotes after inserting or deleting one
  --- (org-footnote-auto-adjust): false, true, "sort" or "renumber".
  --- #+STARTUP: fnadjust / nofnadjust.
  footnote_auto_adjust = false,
  --- Define new footnotes inline, `[fn:N: text]` at the reference
  --- (org-footnote-define-inline). #+STARTUP: fninline / nofninline.
  footnote_define_inline = false,
  --- Refill the paragraphs that lost an inline footnote when normalizing
  --- (org-footnote-fill-after-inline-note-extraction), at `textwidth`
  --- (70 when 0).
  footnote_fill_after_inline_note_extraction = false,
  --- Days before a deadline it starts showing up in the agenda.
  deadline_warning_days = 14,
  --- Days a scheduled entry is hidden after its date unless it has its own
  --- `-Nd` delay; a negative value applies even then
  --- (org-scheduled-delay-days).
  scheduled_delay_days = 0,
  --- { rounding of the current time in date prompts, minute step of
  --- <S-Up>/<S-Down> } (org-time-stamp-rounding-minutes). A count steps by
  --- exactly that many minutes.
  time_stamp_rounding_minutes = { 0, 5 },
  --- Date prompts interpret incomplete dates in the future: `true` (a past
  --- day/month means next month/year), `"time"` (also a past time today
  --- means tomorrow) or `false` (org-read-date-prefer-future).
  read_date_prefer_future = true,
  --- Date prompts show the calendar; false = only a "Date+time [default]: "
  --- prompt (org-read-date-popup-calendar; the Emacs alias
  --- `popup_calendar_for_date_prompt = false` works too).
  read_date_popup_calendar = true,
  --- Show what a typed date means while typing it in the calendar
  --- (org-read-date-display-live).
  read_date_display_live = true,
  --- Key of the calendar opened by `goto_calendar` that shows the agenda of
  --- its date: "default" (`c`), another key, or false
  --- (org-calendar-to-agenda-key).
  calendar_to_agenda_key = "default",
  --- Key of that calendar adding a diary entry for its date to
  --- `agenda.diary_entry_file`, when that is an Org file
  --- (org-calendar-insert-diary-entry-key).
  calendar_insert_diary_entry_key = "i",
  --- <S-Down> makes timestamps later and <S-Up> earlier
  --- (org-edit-timestamp-down-means-later).
  edit_timestamp_down_means_later = false,
  --- Display timestamps with `time_stamp_custom_formats` (format-time-string
  --- formats for dates and date+time; brackets around them are dropped in
  --- the buffer and kept in exports); toggled by `toggle_time_stamp_overlays`
  --- (org-display-custom-times, org-timestamp-custom-formats). Exports of a
  --- buffer with the display on use the formats (org-timestamp-translate).
  display_custom_times = false,
  time_stamp_custom_formats = { "%m/%d/%y %a", "%m/%d/%y %a %H:%M" },
  --- Where `archive_subtree` sends entries. `%s` = current file name
  --- (org-archive-location).
  archive_location = "%s_archive::",
  --- Context saved as ARCHIVE_* properties (org-archive-save-context-info):
  --- "time", "file", "olpath", "olid", "category", "todo", "itags", "ltags".
  archive_save_context_info = { "time", "file", "olpath", "category", "todo", "itags" },
  --- Heading of the sibling used by `archive_to_sibling` (org-archive-sibling-heading).
  archive_sibling_heading = "Archive",
  --- Add inherited tags to archived entries: "infile" | true | false
  --- (org-archive-subtree-add-inherited-tags).
  archive_subtree_add_inherited_tags = "infile",
  --- Archive as the first child of the archive heading instead of the last
  --- (org-archive-reversed-order).
  archive_reversed_order = false,
  --- What `archive_subtree_default` (C-c C-x C-a, the agenda's `a`) does
  --- (org-archive-default-command): "archive_subtree" | "archive_to_sibling"
  --- | "set_tag" | function(target).
  archive_default_command = "archive_subtree",
  --- Save the archive file after `archive_subtree` (org-archive-subtree-save-file-p):
  --- true | false | "from_org" (not from the agenda) | "from_agenda" (only
  --- from the agenda). A location in the same buffer is never saved.
  archive_subtree_save_file = "from_org",
  --- Mark archived entries done: false | true (first done keyword) | a done
  --- keyword (org-archive-mark-done).
  archive_mark_done = false,
  --- Text put at the top of a new archive file, `%s` = the source file;
  --- false for none (org-archive-file-header-format).
  archive_file_header_format = "\nArchived entries from file %s\n\n",
  --- Window used for special buffers: "float" | "split" | "vsplit" | "tab" | "current"
  win_split_mode = "float",
  --- Where indirect_subtree shows the subtree (org-indirect-buffer-display):
  --- "other-window" (a split: `win_split_mode` when it is "split", "vsplit"
  --- or "tab"), "current-window", "new-frame" (a new tab) or
  --- "dedicated-frame" (one tab, reused).
  indirect_buffer_display = "other-window",
  win_border = "rounded",
}

return defaults
