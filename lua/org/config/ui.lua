-- Options: Notifications and UI.
--
-- One part of `require("org.config").defaults`, merged in the order of
-- `M.parts` in lua/org/config/init.lua. Keys keep the indentation of the
-- full table: `:Org customize` reads these files for the options and the
-- `---` documentation above each one.

---@class org.config.Resolved
local defaults = {
  ---------------------------------------------------------------------------
  -- Notifications (appointment reminders)
  ---------------------------------------------------------------------------
  notifications = {
    enabled = false,
    --- Minutes before a timed scheduled/deadline entry to notify.
    reminder_time = { 12, 9, 6, 3, 0 },
    check_interval = 60,
    --- Also use the OS notifier (osascript / notify-send / powershell.exe) when available.
    system_notification = true,
    --- Send reminders from one Neovim only, when several run with
    --- notifications on (a lock in stdpath("data")/org). Emacs usually
    --- runs as one process, so it has no option for this.
    single_instance = true,
    --- Custom notifier: function({ title, body, item, minutes }). nil = built-in.
    notifier = nil,
  },

  ---------------------------------------------------------------------------
  -- UI
  ---------------------------------------------------------------------------
  ui = {
    --- The Org, Table, Agenda, Column, Edit-Formulas and OrgTbl menus
    --- (Emacs's easymenus), added while a buffer they belong to is current;
    --- false = none. Emacs has no option for them.
    menus = true,
    --- How to ask for one of a fixed set of values (a table export format,
    --- a column summary type, …): "float" = a floating list picked with
    --- j/k and <CR> or a key; "input" = the command line with <Tab>
    --- completion, like Emacs's completing-read.
    choice_prompt = "float",
    --- Headline levels listed by `imenu` (gO) (org-imenu-depth).
    imenu_depth = 2,
    --- Conceal link brackets and show only descriptions (org-link-descriptive).
    conceal_links = true,
    --- Hide *, /, _, =, ~, + around emphasized text (org-hide-emphasis-markers).
    hide_emphasis_markers = false,
    --- Show only the last star of each headline (org-hide-leading-stars;
    --- #+STARTUP: hidestars / showstars).
    hide_leading_stars = false,
    --- Replace headline stars with symbols. false or list per level.
    bullets = false, -- e.g. { "◉", "○", "✸", "✿" }
    --- Replace checkboxes with icons. false or { unchecked, partial, checked }
    checkboxes = false, -- e.g. { " ", "◐", "✓" }
    --- Virtual indentation of body text (org-indent-mode, org-startup-indented;
    --- #+STARTUP: indent / noindent).
    indent_mode = false,
    --- Columns of virtual indentation per level in indent mode; 0 turns
    --- it off (org-indent-indentation-per-level).
    indent_indentation_per_level = 2,
    --- Indent mode turns adapt_indentation off in its buffer
    --- (org-indent-mode-turns-off-org-adapt-indentation).
    indent_mode_turns_off_adapt_indentation = true,
    --- Render \alpha etc. as unicode (org-pretty-entities; #+STARTUP:
    --- entitiespretty / entitiesplain, toggle with toggle_pretty_entities).
    pretty_entities = false,
    --- With pretty_entities, also show x^2 and a_{i} as super- and
    --- subscripts (org-pretty-entities-include-sub-superscripts).
    pretty_entities_include_sub_superscripts = true,
    --- Which `^` / `_` are sub/superscripts: true, "{}" (only with braces)
    --- or false (org-use-sub-superscripts; #+OPTIONS: ^:{}).
    use_sub_superscripts = true,
    --- Number headlines with virtual text (org-num-mode, org-startup-numerated;
    --- #+STARTUP: num / nonum). Toggle with num_mode.
    num = false,
    --- Deepest numbered level, nil = all (org-num-max-level).
    num_max_level = nil,
    --- Don't number COMMENT subtrees (org-num-skip-commented).
    num_skip_commented = false,
    --- Don't number the footnote section (org-num-skip-footnotes).
    num_skip_footnotes = false,
    --- Tags whose subtrees are not numbered (org-num-skip-tags).
    num_skip_tags = {},
    --- Don't number subtrees with an UNNUMBERED property (org-num-skip-unnumbered).
    num_skip_unnumbered = false,
    --- function(numbers) -> string, the text shown before the headline
    --- (org-num-format-function). nil = "1.2.3 ".
    num_format_function = nil,
    --- Dim the whole headline of DONE entries (org-fontify-done-headline).
    fontify_done_headline = true,
    --- Highlight the text of TODO headlines with OrgHeadlineTodo
    --- (org-fontify-todo-headline).
    fontify_todo_headline = false,
    --- The headline level color on the stars only (org-level-color-stars-only).
    level_color_stars_only = false,
    --- Keywords shown without their "#+KEYWORD:" part: any of "title",
    --- "subtitle", "author", "date", "email" (org-hidden-keywords).
    hidden_keywords = {},
    --- Hide the {{{ }}} around macro calls (org-hide-macro-markers).
    hide_macro_markers = false,
    --- LaTeX-related syntax highlighted: any of "latex" (fragments and
    --- environments, OrgLatex), "native" (the same with the tex syntax),
    --- "script" (sub/superscripts), "entities" (org-highlight-latex-and-related).
    highlight_latex_and_related = {},
    --- Syntax-include the languages of src blocks for highlighting
    --- (org-src-fontify-natively).
    src_highlight = true,
    --- Per-language face of src block bodies, like `todo_keyword_faces`:
    --- `{ python = { bg = "#e5ffb8" }, [""] = "CursorLine" }` ("" = blocks
    --- without a language) (org-src-block-faces).
    src_block_faces = {},
    --- Per-keyword faces: { WAITING = ":foreground orange :weight bold" }
    --- or a highlight definition table { fg = "#ff9e64", bold = true } or a group name.
    todo_keyword_faces = {},
    --- Faces of priority cookies, like `todo_keyword_faces`:
    --- `{ A = "ErrorMsg", ["10"] = { fg = "gray" } }` (org-priority-faces).
    priority_faces = {},
    --- Faces of tags, like `todo_keyword_faces`: `{ urgent = ":foreground red" }`
    --- (org-tag-faces).
    tag_faces = {},
    --- Inline image previews (org-link-preview, <C-c><C-x><C-v>). See
    --- `:h org-images`.
    images = {
      --- "auto" | "native" (vim.ui.img: Neovim 0.13+ in a terminal with the
      --- Kitty graphics protocol) | "snacks" (Snacks.image) | "image.nvim" |
      --- false. "auto" uses the first that works.
      backend = "auto",
      --- Where images go: "inline" draws them in place of the link or
      --- fragment (its text is hidden until the cursor is on the line, like
      --- Emacs), "below" under the line with the text left as it is.
      placement = "inline",
      --- Links previewed at once; the rest follow in batches every
      --- `preview_delay` seconds (org-link-preview-batch-size,
      --- org-link-preview-delay). 0 = all at once.
      batch_size = 6,
      preview_delay = 0.05,
      --- Images of http(s) links (org-display-remote-inline-images): "skip",
      --- "download" (fetched with curl on every preview) or "cache" (fetched
      --- once into stdpath("cache"), again on link_preview_refresh).
      remote = "skip",
      --- Width of images (org-image-actual-width): true = their own size;
      --- a number = that many pixels; false or { n } = the `:width` of
      --- #+ATTR_ORG (else of another #+ATTR_x), else n pixels. `:width`
      --- takes pixels (300, 300px), a percentage or a fraction (0.5) of the
      --- text width, or t. An ORG-IMAGE-ACTUAL-WIDTH property overrides it.
      actual_width = true,
      --- Widest image (org-image-max-width): "fill-column" ('textwidth',
      --- else 70), "window", a number of pixels, a fraction of the window,
      --- or false (the window).
      max_width = "fill-column",
      --- Tallest image, in rows.
      max_height = 24,
      --- Alignment of images alone in their paragraph (org-image-align):
      --- "left" | "center" | "right". #+ATTR_ORG: :align / :center t
      --- override it.
      align = "left",
      --- Preview image links when a file opens (org-startup-with-link-previews;
      --- #+STARTUP: linkpreviews / nolinkpreviews, inlineimages / noinlineimages).
      startup = false,
      --- Preview the links of an entry when TAB shows it, and remove them
      --- when it folds (org-cycle-link-previews-display).
      cycle_display = false,
      --- File extensions previewed (Emacs `image-file-name-regexp`).
      extensions = {
        "png",
        "jpg",
        "jpeg",
        "gif",
        "webp",
        "bmp",
        "svg",
        "tif",
        "tiff",
        "avif",
        "xbm",
        "xpm",
        "pbm",
        "pgm",
        "ppm",
        "pnm",
      },
    },
    --- LaTeX fragment previews (org-latex-preview, <C-c><C-x><C-l>), drawn by
    --- the `images` backend.
    latex_preview = {
      --- How fragments are rendered (org-preview-latex-default-process): a
      --- name from `processes`, or "auto" for the first one installed
      --- (dvipng, dvisvgm, tectonic, pdflatex, imagemagick).
      process = "auto",
      --- Extra or replaced processes (org-preview-latex-process-alist), e.g.
      --- { mine = { programs = { "latex", "dvipng" }, image_input_type = "dvi",
      --- image_output_type = "png", latex_compiler = { "latex %f" },
      --- image_converter = { "dvipng -D %D -T tight -o %O %f" } } }. Commands
      --- run in a shell; %f %F %b %o %O %D %S as in Emacs. See `:h org-images`.
      processes = {},
      --- Size of the formulas relative to the text (org-format-latex-options :scale).
      scale = 1.0,
      --- Color of the formulas (:foreground): "default" (the Normal text),
      --- "auto" (the text at the fragment), a color name or "#rrggbb".
      foreground = "default",
      --- Background (:background): "default" (Normal), "Transparent", a color
      --- name or "#rrggbb".
      background = "default",
      --- LaTeX preamble (org-format-latex-header), with [DEFAULT-PACKAGES] and
      --- [PACKAGES] replaced by `export.latex` packages and the file's
      --- #+LATEX_HEADER lines added. nil = the Emacs header.
      header = nil,
      --- Where rendered images go (org-preview-latex-image-directory): relative
      --- to the file's directory, or absolute. Buffers without a file use
      --- stdpath("cache") .. "/org/ltximg".
      image_directory = "ltximg/",
      --- An absolute directory used instead of `image_directory` for every file.
      cache_dir = nil,
      --- Preview every fragment when a file opens (org-startup-with-latex-preview;
      --- #+STARTUP: latexpreview / nolatexpreview).
      startup = false,
    },
  },
}

return defaults
