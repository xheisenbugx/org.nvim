-- Options: Export.
--
-- One part of `require("org.config").defaults`, merged in the order of
-- `M.parts` in lua/org/config/init.lua. Keys keep the indentation of the
-- full table: `:Org customize` reads these files for the options and the
-- `---` documentation above each one.

---@class org.config.Resolved
local defaults = {
  ---------------------------------------------------------------------------
  -- Export
  ---------------------------------------------------------------------------
  export = {
    --- Directory for exported files (plugin option), relative to the
    --- source file unless absolute; nil = next to the source file.
    output_dir = nil,
    --- Open the exported file with the system opener (plugin option).
    open_after_export = false,
    -- The options below mirror Emacs org-export-* variables; #+OPTIONS,
    -- keywords and EXPORT_* properties override them.
    with_toc = true, -- org-export-with-toc (true, false or a depth)
    with_section_numbers = true, -- org-export-with-section-numbers (true, false or a depth)
    headline_levels = 3, -- org-export-headline-levels
    with_author = true, -- org-export-with-author
    with_date = true, -- org-export-with-date
    with_email = false, -- org-export-with-email
    with_creator = false, -- org-export-with-creator
    with_title = true, -- org-export-with-title
    with_todo_keywords = true, -- org-export-with-todo-keywords
    with_tags = true, -- org-export-with-tags (true, false or "not-in-toc")
    with_priority = false, -- org-export-with-priority
    --- org-export-with-drawers: true, false, a list of drawer names, or
    --- { not = { ... } } to export every drawer but those.
    with_drawers = { ["not"] = { "LOGBOOK" } },
    with_properties = false, -- org-export-with-properties (true, false or a list)
    with_planning = false, -- org-export-with-planning
    with_clocks = false, -- org-export-with-clocks
    --- org-export-with-timestamps: true, false, "active" or "inactive"
    --- (only paragraphs made of timestamps are affected, like Emacs).
    with_timestamps = true,
    with_tasks = true, -- org-export-with-tasks (true, false, "todo", "done" or a list)
    with_archived_trees = "headline", -- org-export-with-archived-trees (true, false, "headline")
    with_emphasize = true, -- org-export-with-emphasize
    with_entities = true, -- org-export-with-entities
    with_fixed_width = true, -- org-export-with-fixed-width
    with_footnotes = true, -- org-export-with-footnotes
    with_inlinetasks = true, -- org-export-with-inlinetasks
    with_latex = true, -- org-export-with-latex (true, false, "verbatim")
    with_smart_quotes = false, -- org-export-with-smart-quotes
    with_special_strings = true, -- org-export-with-special-strings
    with_statistics_cookies = true, -- org-export-with-statistics-cookies
    with_sub_superscripts = true, -- org-export-with-sub-superscripts (true, false, "{}")
    with_tables = true, -- org-export-with-tables
    --- org-export-with-broken-links: false = stop the export with an error,
    --- true = ignore broken links, "mark" = write [BROKEN LINK: path].
    with_broken_links = false,
    preserve_breaks = false, -- org-export-preserve-breaks
    timestamp_file = true, -- org-export-timestamp-file (creation time in the output)
    expand_links = true, -- org-export-expand-links ($VAR in file links)
    select_tags = { "export" }, -- org-export-select-tags
    exclude_tags = { "noexport" }, -- org-export-exclude-tags
    default_language = "en", -- org-export-default-language
    date_timestamp_format = nil, -- org-export-date-timestamp-format
    --- user-full-name: default #+AUTHOR; nil = the system user's full name.
    author = nil,
    email = nil, -- user-mail-address
    creator = nil, -- org-export-creator-string; nil = "Neovim X.Y.Z (org.nvim ...)"
    --- org-export-global-macros: { name = "template $1" | function(...) }.
    global_macros = {},
    --- org-export-allow-bind-keywords: honor #+BIND: (org-export-* and
    --- back-end variables become these options during the export).
    allow_bind_keywords = false,
    snippet_translation = {}, -- org-export-snippet-translation-alist
    inlinetask_min_level = 15, -- org-inlinetask-min-level
    table_number_fraction = 0.5, -- org-table-number-fraction
    --- org-export-before-processing-functions / -before-parsing-functions:
    --- { before_processing = fn, before_parsing = fn }, fn(backend, lines)
    --- returning new lines (or nil).
    hooks = {},
    --- org-export-filter-TYPE-functions as Lua functions:
    --- { [type] = fn | { fn, ... } }, fn(text, backend, info) returning the
    --- new text (nil keeps it). Types are element/object types
    --- ("paragraph", "plain-text", ...) plus "body", "final-output",
    --- "parse-tree" (fn(tree, backend, info)) and "options" (fn(info, backend)).
    filters = {},
    initial_scope = "buffer", -- org-export-initial-scope: dispatcher scope at start ("buffer" or "subtree")
    body_only = false, -- org-export-body-only: dispatcher "body only" at start
    visible_only = false, -- org-export-visible-only: dispatcher "visible only" at start
    force_publishing = false, -- org-export-force-publishing: dispatcher "force publishing" at start
    --- org-export-in-background: dispatcher "async" at start; results go to
    --- the export stack (:Org export_stack).
    in_background = false,
    --- org-export-async-init-file: a Lua file run by the Neovim that makes
    --- asynchronous exports (Lua functions of the options don't reach it).
    async_init_file = nil,
    dispatch_use_expert_ui = false, -- org-export-dispatch-use-expert-ui (a prompt instead of the menu)
    show_temporary_export_buffer = true, -- org-export-show-temporary-export-buffer
    copy_to_kill_ring = false, -- org-export-copy-to-kill-ring (true, "if-interactive" or false)
    coding_system = nil, -- org-export-coding-system (an iconv encoding of output files; nil = UTF-8)
    process_citations = true, -- org-export-process-citations
    replace_macros = true, -- org-export-replace-macros
    --- org-export-smart-quotes-alist: { [lang] = { primary_opening = { ["utf-8"] =,
    --- html =, latex =, texinfo = }, primary_closing, secondary_opening,
    --- secondary_closing, apostrophe } }; a language set here replaces its
    --- Emacs entry, the others keep the Emacs table.
    smart_quotes_alist = nil,
    html = {
      doctype = "xhtml-strict", -- org-html-doctype
      html5_fancy = false, -- org-html-html5-fancy
      container = "div", -- org-html-container-element
      content_class = "content", -- org-html-content-class
      extension = "html", -- org-html-extension
      head_include_default_style = true, -- org-html-head-include-default-style
      --- Extra CSS put after the default style (plugin option); false = no
      --- default style (like head_include_default_style = false).
      style = nil,
      head = "", -- org-html-head (string or function(info))
      head_extra = "", -- org-html-head-extra (string or function(info))
      head_include_scripts = false, -- org-html-head-include-scripts
      preamble = true, -- org-html-preamble (true, false, format string, function)
      postamble = "auto", -- org-html-postamble ("auto", true, false, format string, function)
      postamble_format = nil, -- org-html-postamble-format ({ en = "..." }; nil = Emacs default)
      preamble_format = nil, -- org-html-preamble-format
      validation_link = nil, -- org-html-validation-link (nil = Emacs default)
      creator_string = nil, -- org-html-creator-string
      link_home = "", -- org-html-link-home
      link_up = "", -- org-html-link-up
      link_use_abs_url = false, -- org-html-link-use-abs-url
      link_org_files_as_html = true, -- org-html-link-org-files-as-html
      metadata_timestamp_format = "%Y-%m-%d %a %H:%M", -- org-html-metadata-timestamp-format
      toplevel_hlevel = 2, -- org-html-toplevel-hlevel
      self_link_headlines = false, -- org-html-self-link-headlines
      prefer_user_labels = false, -- org-html-prefer-user-labels
      checkbox_type = "ascii", -- org-html-checkbox-type ("ascii", "unicode", "html")
      inline_images = true, -- org-html-inline-images
      table_caption_above = true, -- org-html-table-caption-above
      footnote_format = "<sup>%s</sup>", -- org-html-footnote-format
      footnote_separator = "<sup>, </sup>", -- org-html-footnote-separator
      equation_reference_format = "\\eqref{%s}", -- org-html-equation-reference-format
      use_infojs = "when-configured", -- org-html-use-infojs
      wrap_src_lines = false, -- org-html-wrap-src-lines
      --- Load MathJax for LaTeX fragments (org-html-with-latex = mathjax);
      --- false leaves the math as text.
      mathjax = true,
      --- org-html-with-latex: true/"mathjax", "html", "dvipng", "dvisvgm",
      --- "imagemagick" (pictures in ltximg/), "verbatim" or false; nil =
      --- export.with_latex. #+OPTIONS: tex: overrides it.
      with_latex = nil,
      --- org-latex-to-html-convert-command for tex:html, %i = the fragment
      --- (shell-quoted), e.g. "latexmlmath %i --presentationmathml=-".
      latex_to_html_convert_command = nil,
      mathjax_options = nil, -- org-html-mathjax-options ({ path = ..., scale = 1.0, ... })
      --- function(code, lang) -> HTML to highlight source code, used instead
      --- of the built-in highlighting (plugin option).
      fontify = nil,
      --- org-html-htmlize-output-type: how source code is coloured from its
      --- tree-sitter highlights (Emacs uses htmlize): "inline-css" (style
      --- attributes with the colour scheme's colours), "css" (classes, see
      --- :Org html_htmlize_generate_css) or false (plain text).
      htmlize_output_type = "inline-css",
      htmlize_font_prefix = "org-", -- org-html-htmlize-font-prefix (CSS class prefix)
      allow_name_attribute_in_anchors = false, -- org-html-allow-name-attribute-in-anchors
      coding_system = "utf-8", -- org-html-coding-system (charset of the <meta> and XML declaration)
      datetime_formats = { "%F", "%FT%T" }, -- org-html-datetime-formats ({ date, date and time })
      indent = false, -- org-html-indent (indent the generated HTML like Emacs' mhtml-mode)
      --- org-html-divs: { preamble = { "div", "preamble" }, content = { "div",
      --- "content" }, postamble = { "div", "postamble" } } (nil = that value).
      divs = nil,
      footnotes_section = nil, -- org-html-footnotes-section (nil = the Emacs format)
      format_drawer_function = nil, -- org-html-format-drawer-function: fn(name, contents)
      format_headline_function = nil, -- org-html-format-headline-function: fn(todo, todo_type, priority, text, tags, info)
      --- org-html-format-inlinetask-function:
      --- fn(todo, todo_type, priority, text, tags, contents, info)
      format_inlinetask_function = nil,
      home_up_format = nil, -- org-html-home/up-format (nil = the Emacs format)
      infojs_template = nil, -- org-html-infojs-template (nil = the Emacs template)
      inline_image_rules = nil, -- org-html-inline-image-rules (nil = the Emacs rules)
      klipsify_src = false, -- org-html-klipsify-src
      klipse_css = "https://storage.googleapis.com/app.klipse.tech/css/codemirror.css", -- org-html-klipse-css
      klipse_js = "https://storage.googleapis.com/app.klipse.tech/plugin_prod/js/klipse_plugin.min.js", -- org-html-klipse-js
      klipse_selection_script = nil, -- org-html-klipse-selection-script (nil = the Emacs script)
      mathjax_template = nil, -- org-html-mathjax-template (nil = the Emacs template)
      meta_tags = nil, -- org-html-meta-tags ({ { attr, name, content }, ... } or function(info); nil = Emacs)
      scripts = nil, -- org-html-scripts (nil = the Emacs script)
      table_align_individual_fields = true, -- org-html-table-align-individual-fields
      table_data_tags = { "<td%s>", "</td>" }, -- org-html-table-data-tags
      table_header_tags = { '<th scope="%s"%s>', "</th>" }, -- org-html-table-header-tags
      table_default_attributes = nil, -- org-html-table-default-attributes ({ { name, value }, ... }; nil = Emacs)
      table_row_open_tag = "<tr>", -- org-html-table-row-open-tag (string or function)
      table_row_close_tag = "</tr>", -- org-html-table-row-close-tag (string or function)
      table_use_header_tags_for_first_column = false, -- org-html-table-use-header-tags-for-first-column
      tag_class_prefix = "", -- org-html-tag-class-prefix
      todo_kwd_class_prefix = "", -- org-html-todo-kwd-class-prefix
      text_markup_alist = nil, -- org-html-text-markup-alist ({ bold = "<b>%s</b>", ... }; nil = Emacs)
      viewport = nil, -- org-html-viewport ({ { name, value }, ... }; nil = Emacs, false = no tag)
      xml_declaration = nil, -- org-html-xml-declaration ({ html = ..., php = ... }; nil = Emacs)
    },
    latex = {
      default_class = "article", -- org-latex-default-class
      classes = nil, -- org-latex-classes (nil = the Emacs list)
      default_packages = nil, -- org-latex-default-packages-alist (nil = the Emacs list)
      packages = {}, -- org-latex-packages-alist
      compiler = "pdflatex", -- org-latex-compiler
      pdf_process = nil, -- org-latex-pdf-process (nil = latexmk when available, else 3 x %latex)
      bib_compiler = "bibtex", -- org-latex-bib-compiler
      remove_logfiles = true, -- org-latex-remove-logfiles
      --- Compile PDFs in the background with vim.system (plugin option;
      --- Emacs blocks unless the export is asynchronous).
      async_compile = true,
      src_block_backend = "verbatim", -- org-latex-src-block-backend ("verbatim", "listings", "minted", "engraved")
      engraved_options = nil, -- org-latex-engraved-options ({ { key, value }, ... }; nil = the Emacs list)
      engraved_preamble = nil, -- org-latex-engraved-preamble (nil = the Emacs preamble)
      --- org-latex-engraved-theme (#+LATEX_ENGRAVED_THEME): nil/"default" = engrave-faces'
      --- default colours, true = the current colour scheme, a name = that colour scheme.
      engraved_theme = nil,
      caption_above = { "table" }, -- org-latex-caption-above
      prefer_user_labels = false, -- org-latex-prefer-user-labels
      reference_command = "\\ref{%s}", -- org-latex-reference-command
      tables_booktabs = false, -- org-latex-tables-booktabs
      tables_centered = true, -- org-latex-tables-centered
      images_centered = true, -- org-latex-images-centered
      image_default_width = ".9\\linewidth", -- org-latex-image-default-width
      default_figure_position = "htbp", -- org-latex-default-figure-position
      default_table_environment = "tabular", -- org-latex-default-table-environment
      default_table_mode = "table", -- org-latex-default-table-mode
      title_command = "\\maketitle", -- org-latex-title-command
      toc_command = "\\tableofcontents\n\n", -- org-latex-toc-command
      hyperref_template = nil, -- org-latex-hyperref-template (nil = the Emacs template)
      use_sans = false, -- org-latex-use-sans
      active_timestamp_format = "\\textit{%s}", -- org-latex-active-timestamp-format
      inactive_timestamp_format = "\\textit{%s}", -- org-latex-inactive-timestamp-format
      diary_timestamp_format = "\\textit{%s}", -- org-latex-diary-timestamp-format
      --- org-latex-compiler-file-string: the "Intended LaTeX compiler" line
      --- (%s = the compiler); false/"" = none.
      compiler_file_string = "%% Intended LaTeX compiler: %s\n",
      --- org-latex-known-warnings: { { vim_regex, message }, ... } reported
      --- after a compilation (nil = the Emacs list).
      known_warnings = nil,
      custom_lang_environments = {}, -- org-latex-custom-lang-environments ({ [lang] = env | { ... } })
      default_footnote_command = "\\footnote{%s%s}", -- org-latex-default-footnote-command
      default_quote_environment = "quote", -- org-latex-default-quote-environment
      footnote_defined_format = "\\textsuperscript{\\ref{%s}}", -- org-latex-footnote-defined-format
      footnote_separator = "\\textsuperscript{,}\\,", -- org-latex-footnote-separator
      format_drawer_function = nil, -- org-latex-format-drawer-function: fn(name, contents)
      format_headline_function = nil, -- org-latex-format-headline-function: fn(todo, todo_type, priority, text, tags, info)
      --- org-latex-format-inlinetask-function:
      --- fn(todo, todo_type, priority, name, tags, contents, info)
      format_inlinetask_function = nil,
      image_default_scale = "", -- org-latex-image-default-scale
      image_default_height = "", -- org-latex-image-default-height
      image_default_option = "", -- org-latex-image-default-option
      inline_image_rules = nil, -- org-latex-inline-image-rules (nil = the Emacs rules)
      inputenc_alist = {}, -- org-latex-inputenc-alist ({ [coding] = inputenc })
      link_with_unknown_path_format = "\\texttt{%s}", -- org-latex-link-with-unknown-path-format
      listings_langs = nil, -- org-latex-listings-langs ({ { lang, listings_lang }, ... }; nil = Emacs)
      listings_options = {}, -- org-latex-listings-options ({ { key, value }, ... })
      listings_src_omit_language = false, -- org-latex-listings-src-omit-language
      logfiles_extensions = nil, -- org-latex-logfiles-extensions (nil = the Emacs list)
      minted_langs = nil, -- org-latex-minted-langs ({ { lang, minted_lang }, ... }; nil = Emacs)
      minted_options = {}, -- org-latex-minted-options ({ { key, value }, ... })
      subtitle_format = "\\\\\\medskip\n\\large %s", -- org-latex-subtitle-format
      subtitle_separate = false, -- org-latex-subtitle-separate
      table_scientific_notation = nil, -- org-latex-table-scientific-notation (e.g. "%s\\,(%s)")
      text_markup_alist = nil, -- org-latex-text-markup-alist ({ bold = "\\textbf{%s}", ... }; nil = Emacs)
      toc_include_unnumbered = false, -- org-latex-toc-include-unnumbered
    },
    texinfo = {
      default_class = "info", -- org-texinfo-default-class
      classes = nil, -- org-texinfo-classes (nil = the Emacs list)
      coding_system = "UTF-8", -- org-texinfo-coding-system (@documentencoding)
      node_description_column = 32, -- org-texinfo-node-description-column
      table_default_markup = "@asis", -- org-texinfo-table-default-markup
      compact_itemx = false, -- org-texinfo-compact-itemx
      --- org-texinfo-with-latex: true, false or "detect" (@math when makeinfo
      --- supports it); nil = "detect" unless export.with_latex is false.
      with_latex = nil,
      info_process = nil, -- org-texinfo-info-process (nil = { "makeinfo --no-split %f" })
      remove_logfiles = true, -- org-texinfo-remove-logfiles
      logfiles_extensions = nil, -- org-texinfo-logfiles-extensions (nil = aux toc cp fn ky pg tp vr)
      active_timestamp_format = "@emph{%s}", -- org-texinfo-active-timestamp-format
      inactive_timestamp_format = "@emph{%s}", -- org-texinfo-inactive-timestamp-format
      diary_timestamp_format = "@emph{%s}", -- org-texinfo-diary-timestamp-format
      link_with_unknown_path_format = "@indicateurl{%s}", -- org-texinfo-link-with-unknown-path-format
      tables_verbatim = false, -- org-texinfo-tables-verbatim
      table_scientific_notation = nil, -- org-texinfo-table-scientific-notation
      --- org-texinfo-text-markup-alist: { bold = "@strong{%s}", code = "code",
      --- italic = "@emph{%s}", verbatim = "samp" } (nil = that value).
      text_markup_alist = nil,
      format_headline_function = nil, -- org-texinfo-format-headline-function: fn(todo, todo_type, priority, text, tags)
      format_drawer_function = nil, -- org-texinfo-format-drawer-function: fn(name, contents)
      --- org-texinfo-format-inlinetask-function:
      --- fn(todo, todo_type, priority, title, tags, contents)
      format_inlinetask_function = nil,
      --- Export Texinfo through pandoc instead of the native back-end.
      use_pandoc = false,
    },
    koma_letter = {
      default_class = "default-koma-letter", -- org-koma-letter-default-class
      class_option_file = "NF", -- org-koma-letter-class-option-file (#+LCO)
      --- org-koma-letter-author: a string, a function returning one, or false
      --- (nil = export.author / the user's full name)
      author = nil,
      --- org-koma-letter-email: a string, a function returning one, or false
      --- (nil = export.email)
      email = nil,
      from_address = "", -- org-koma-letter-from-address
      phone_number = "", -- org-koma-letter-phone-number
      url = "", -- org-koma-letter-url
      from_logo = "", -- org-koma-letter-from-logo
      place = "", -- org-koma-letter-place
      location = "", -- org-koma-letter-location
      opening = "", -- org-koma-letter-opening
      closing = "", -- org-koma-letter-closing
      signature = "", -- org-koma-letter-signature
      prefer_special_headings = false, -- org-koma-letter-prefer-special-headings
      --- org-koma-letter-subject-format: true, false or a list of
      --- "afteropening", "beforeopening", "centered", "left", "right",
      --- "titled", "underlined", "untitled"
      subject_format = true,
      use_backaddress = false, -- org-koma-letter-use-backaddress
      --- org-koma-letter-use-foldmarks: true, false or a list of marks
      --- ("B", "b", "H", "h", "L", "l", "M", "m", "P", "p", "T", "t", "V", "v")
      use_foldmarks = true,
      use_phone = false, -- org-koma-letter-use-phone
      use_url = false, -- org-koma-letter-use-url
      use_from_logo = false, -- org-koma-letter-use-from-logo
      use_email = false, -- org-koma-letter-use-email
      use_place = true, -- org-koma-letter-use-place
      headline_is_opening_maybe = true, -- org-koma-letter-headline-is-opening-maybe
      prefer_subject = false, -- org-koma-letter-prefer-subject
    },
    man = {
      tables_centered = true, -- org-man-tables-centered
      tables_verbatim = false, -- org-man-tables-verbatim
      table_scientific_notation = "%sE%s", -- org-man-table-scientific-notation (false = none)
      source_highlight = false, -- org-man-source-highlight (GNU source-highlight)
      source_highlight_langs = nil, -- org-man-source-highlight-langs (nil = the Emacs map)
      --- org-man-pdf-process: shell commands with %f %F %b %o %O, or a
      --- function(file) (nil = three runs of "tbl %f | eqn | groff -man | ps2pdf - > %b.pdf")
      pdf_process = nil,
      logfiles_extensions = { "log", "out", "toc" }, -- org-man-logfiles-extensions
      remove_logfiles = true, -- org-man-remove-logfiles
    },
    md = {
      headline_style = "atx", -- org-md-headline-style ("atx", "setext", "mixed")
      toplevel_hlevel = 1, -- org-md-toplevel-hlevel
      footnote_format = "<sup>%s</sup>", -- org-md-footnote-format
      footnotes_section = "%s%s", -- org-md-footnotes-section
      link_org_files_as_md = true, -- org-md-link-org-files-as-md
    },
    org = {
      with_special_rows = true, -- org-org-with-special-rows
      --- org-org-htmlized-css-url: stylesheet linked instead of the embedded
      --- one in FILE.org.html of `htmlized_source` publishing.
      htmlized_css_url = nil,
    },
    beamer = {
      frame_level = 1, -- org-beamer-frame-level
      frame_default_options = "", -- org-beamer-frame-default-options
      outline_frame_title = "Outline", -- org-beamer-outline-frame-title
      outline_frame_options = "", -- org-beamer-outline-frame-options
      subtitle_format = "\\subtitle{%s}", -- org-beamer-subtitle-format
      theme = "default", -- org-beamer-theme
      --- org-beamer-environments-extra: { { name, key, open, close }, ... }
      environments_extra = {},
      frame_environment = "orgframe", -- org-beamer-frame-environment
    },
    icalendar = {
      combined_agenda_file = "~/org.ics", -- org-icalendar-combined-agenda-file
      combined_name = "OrgMode", -- org-icalendar-combined-name
      combined_description = "", -- org-icalendar-combined-description
      alarm_time = 0, -- org-icalendar-alarm-time (minutes)
      force_alarm = false, -- org-icalendar-force-alarm
      exclude_tags = {}, -- org-icalendar-exclude-tags
      scheduled_summary_prefix = "S: ", -- org-icalendar-scheduled-summary-prefix
      deadline_summary_prefix = "DL: ", -- org-icalendar-deadline-summary-prefix
      use_deadline = { "event-if-not-todo", "todo-due" }, -- org-icalendar-use-deadline
      use_scheduled = { "todo-start" }, -- org-icalendar-use-scheduled
      categories = { "local-tags", "category" }, -- org-icalendar-categories
      with_timestamps = "active", -- org-icalendar-with-timestamps
      --- org-icalendar-include-todo: false, true, "unblocked", "all" or keywords.
      include_todo = false,
      todo_unscheduled_start = "recurring-deadline-warning", -- org-icalendar-todo-unscheduled-start
      include_sexps = true, -- org-icalendar-include-sexps (diary-anniversary, -block, -cyclic, -float, -date)
      include_body = true, -- org-icalendar-include-body (true or a number of characters)
      store_uid = false, -- org-icalendar-store-UID
      timezone = nil, -- org-icalendar-timezone (nil = $TZ)
      date_time_format = ":%Y%m%dT%H%M%S", -- org-icalendar-date-time-format
      ttl = nil, -- org-icalendar-ttl
      default_appointment_duration = nil, -- org-agenda-default-appointment-duration (minutes)
      after_save_hook = nil, -- org-icalendar-after-save-hook: function(path)
    },
    publish = {
      --- org-publish-project-alist: { name = { base_directory = ..., ... } }
      --- or a list of tables with a `name`.
      projects = {},
      --- org-publish-timestamp-directory (Emacs: ~/.org-timestamps/).
      timestamp_directory = vim.fn.stdpath("data") .. "/org-timestamps/",
      use_timestamps_flag = true, -- org-publish-use-timestamps-flag
      list_skipped_files = true, -- org-publish-list-skipped-files
      sitemap_sort_files = "alphabetically", -- org-publish-sitemap-sort-files
      sitemap_sort_folders = "ignore", -- org-publish-sitemap-sort-folders
      sitemap_sort_ignore_case = false, -- org-publish-sitemap-sort-ignore-case
      after_publishing_hook = nil, -- org-publish-after-publishing-hook: function(src, out)
    },
    cite = {
      --- org-cite-export-processors: { [backend] = { name, bibstyle, citestyle } | "name" };
      --- `t` is the fallback. #+CITE_EXPORT overrides it.
      export_processors = { t = { "basic" } },
      global_bibliography = {}, -- org-cite-global-bibliography
      adjust_note_numbers = true, -- org-cite-adjust-note-numbers
      note_rules = nil, -- org-cite-note-rules (nil = the Emacs rules)
      punctuation_marks = { ".", ",", ";", ":", "!", "?" }, -- org-cite-punctuation-marks
      basic_sorting_field = "author", -- org-cite-basic-sorting-field
      basic_author_year_separator = ", ", -- org-cite-basic-author-year-separator
      natbib_options = {}, -- org-cite-natbib-options
      biblatex_options = nil, -- org-cite-biblatex-options
      biblatex_styles = nil, -- org-cite-biblatex-styles (nil = the Emacs table)
      biblatex_style_shortcuts = nil, -- org-cite-biblatex-style-shortcuts (nil = the Emacs table)
      --- Processors of the buffer capabilities (false = none; for
      --- activation, false = highlighting without checking keys).
      activate_processor = "basic", -- org-cite-activate-processor
      follow_processor = "basic", -- org-cite-follow-processor
      insert_processor = "basic", -- org-cite-insert-processor
      basic_max_key_distance = 2, -- org-cite-basic-max-key-distance
      basic_author_column_end = 25, -- org-cite-basic-author-column-end
      basic_column_separator = "  ", -- org-cite-basic-column-separator
      --- org-cite-basic-complete-key-crm-separator: nil (one prompt per key),
      --- a Vim regexp separating keys typed at one prompt, or "dynamic".
      basic_complete_key_crm_separator = nil,
      --- Highlight group of the citation key under the mouse ("highlight",
      --- Emacs's face, is OrgCiteMouseOver); false = none. Turns
      --- 'mousemoveevent' on (org-cite-basic-mouse-over-key-face).
      basic_mouse_over_key_face = "highlight",
      -- csl processor (oc-csl)
      csl_styles_dir = nil, -- org-cite-csl-styles-dir
      csl_locales_dir = nil, -- org-cite-csl-locales-dir (nil: en-US only)
      csl_link_cites = true, -- org-cite-csl-link-cites
      csl_no_citelinks_backends = { "ascii" }, -- org-cite-csl-no-citelinks-backends
      csl_html_hanging_indent = "1.5em", -- org-cite-csl-html-hanging-indent
      csl_html_label_width_per_char = "0.6em", -- org-cite-csl-html-label-width-per-char
      csl_latex_hanging_indent = "1.5em", -- org-cite-csl-latex-hanging-indent
      csl_latex_label_separator = "0.6em", -- org-cite-csl-latex-label-separator
      csl_latex_label_width_per_char = "0.45em", -- org-cite-csl-latex-label-width-per-char
      csl_latex_preamble = nil, -- org-cite-csl-latex-preamble (nil = the Emacs preamble)
      csl_bibtex_titles_to_sentence_case = true, -- org-cite-csl-bibtex-titles-to-sentence-case
    },
    ascii = {
      charset = "ascii", -- org-ascii-charset ("ascii", "latin1", "utf-8")
      text_width = nil, -- org-ascii-text-width (nil = export.text_width, else 72)
      global_margin = 0, -- org-ascii-global-margin
      inner_margin = 2, -- org-ascii-inner-margin
      quote_margin = 6, -- org-ascii-quote-margin
      list_margin = 0, -- org-ascii-list-margin
      inlinetask_width = 30, -- org-ascii-inlinetask-width
      headline_spacing = { 1, 2 }, -- org-ascii-headline-spacing ({ before, after } or false)
      indented_line_width = "auto", -- org-ascii-indented-line-width
      paragraph_spacing = "auto", -- org-ascii-paragraph-spacing
      links_to_notes = true, -- org-ascii-links-to-notes
      table_keep_all_vertical_lines = false, -- org-ascii-table-keep-all-vertical-lines
      table_widen_columns = true, -- org-ascii-table-widen-columns
      table_use_ascii_art = false, -- org-ascii-table-use-ascii-art (box characters for table.el tables, UTF-8)
      caption_above = false, -- org-ascii-caption-above
      verbatim_format = "`%s'", -- org-ascii-verbatim-format
      bullets = nil, -- org-ascii-bullets ({ ascii = {...}, latin1 = {...}, ["utf-8"] = {...} }; nil = Emacs)
      underline = nil, -- org-ascii-underline (same shape; nil = Emacs)
      format_drawer_function = nil, -- org-ascii-format-drawer-function: fn(name, contents, width)
      --- org-ascii-format-inlinetask-function:
      --- fn(todo, todo_type, priority, name, tags, contents, width, inlinetask, info)
      format_inlinetask_function = nil,
    },
    odt = {
      --- Export ODT with pandoc instead of the native back-end (plugin option).
      use_pandoc = false,
      --- org-odt-styles-file: nil (factory styles), a styles.xml, .odt or
      --- .ott file, or { "file.ott", { "styles.xml", "image/hdr.png" } }.
      styles_file = nil,
      extra_styles = nil, -- XML added to <office:styles> (plugin option, also #+ODT_EXTRA_STYLES)
      content_template_file = nil, -- org-odt-content-template-file (nil = OrgOdtContentTemplate.xml)
      display_outline_level = 2, -- org-odt-display-outline-level
      fontify_srcblocks = true, -- org-odt-fontify-srcblocks (tree-sitter highlights)
      create_custom_styles_for_srcblocks = true, -- org-odt-create-custom-styles-for-srcblocks
      pixels_per_inch = 96, -- org-odt-pixels-per-inch
      use_date_fields = false, -- org-odt-use-date-fields
      with_forbidden_chars = "", -- org-odt-with-forbidden-chars (replacement, true = keep, false = error)
      with_latex = nil, -- org-odt-with-latex (nil = export.with_latex; true/"mathml", "dvipng", ..., "verbatim")
      --- org-latex-to-mathml-convert-command, e.g. "latexmlmath %i --presentationmathml=%o"
      --- (%i fragment, %I input file, %o output file, %j jar file).
      latex_to_mathml_convert_command = nil,
      latex_to_mathml_jar_file = nil, -- org-latex-to-mathml-jar-file
      latex_mathml_directory = "ltxmathml/", -- org-latex-mathml-directory (MathML cache, relative to the Org file)
      inline_image_rules = nil, -- org-odt-inline-image-rules ({ file = { "png", ... } })
      inline_formula_rules = nil, -- org-odt-inline-formula-rules ({ file = { "mathml", "mml", "odf" } })
      table_styles = nil, -- org-odt-table-styles ({ { name, template, { use_first_row_styles = true, ... } } })
      category_map_alist = nil, -- org-odt-category-map-alist ({ __Figure__ = { "Illustration", "value", "Figure" } })
      format_drawer_function = nil, -- org-odt-format-drawer-function: fn(name, contents)
      format_headline_function = nil, -- org-odt-format-headline-function: fn(todo, todo_type, priority, text, tags)
      format_inlinetask_function = nil, -- org-odt-format-inlinetask-function: fn(todo, type, pri, name, tags, contents)
      preferred_output_format = nil, -- org-odt-preferred-output-format (e.g. "pdf", "docx")
      convert_process = "LibreOffice", -- org-odt-convert-process
      convert_processes = nil, -- org-odt-convert-processes ({ { name, cmd }, ... }; nil = Emacs list)
      convert_capabilities = nil, -- org-odt-convert-capabilities (nil = Emacs list)
    },
    --- Legacy alias of ascii.text_width (org-ascii-text-width).
    text_width = 72,
    pandoc = { cmd = "pandoc", args = {} },
  },
}

return defaults
