-- Options: Links, BibTeX, remote resources, IDs and attachments.
--
-- One part of `require("org.config").defaults`, merged in the order of
-- `M.parts` in lua/org/config/init.lua. Keys keep the indentation of the
-- full table: `:Org customize` reads these files for the options and the
-- `---` documentation above each one.

local data_dir = vim.fn.stdpath("data") .. "/org"

---@class org.config.Resolved
local defaults = {
  ---------------------------------------------------------------------------
  -- Links / IDs / attachments
  ---------------------------------------------------------------------------
  links = {
    --- `#+LINK` style abbreviations: { gh = "https://github.com/%s" }
    --- (org-link-abbrev-alist).
    abbreviations = {},
    --- Custom link types (org-link-parameters): a follow function, or a
    --- table { follow, complete, store, export, face, insert_description }.
    types = {},
    --- Ask before running shell: links: true, false or function(cmd) ->
    --- boolean (org-link-shell-confirm-function).
    confirm_shell = true,
    --- Vim regex: shell: links matching it run without asking; "" = none
    --- (org-link-shell-skip-confirm-regexp).
    shell_skip_confirm_regexp = "",
    --- Where shell: links run: "buffer" collects the output in a new
    --- `*Org Shell Output*` buffer like Emacs' shell-command (one line is
    --- only echoed; a command ending in `&` shows the buffer at once),
    --- "terminal" runs the command in a terminal window.
    shell_output = "buffer",
    --- Ask before running elisp: links: true, false or function(sexp) ->
    --- boolean (org-link-elisp-confirm-function).
    confirm_elisp = true,
    --- Vim regex: elisp: links matching it run without asking; "" = none
    --- (org-link-elisp-skip-confirm-regexp).
    elisp_skip_confirm_regexp = "",
    --- Store links to headlines as id: links (org-id-link-to-org-use-id):
    --- false | true | "create-if-interactive" |
    --- "create-if-interactive-and-no-custom-id" | "use-existing".
    use_id = false,
    --- Open files with an extension via external app: { pdf = "open" };
    --- "vim" forces Neovim (org-file-apps).
    file_apps = {},
    --- Add a search string (the heading, a name, the line or the
    --- selection) to stored file links: true, false, or the number of
    --- selected lines to keep (org-link-context-for-files).
    context_for_files = true,
    --- How inserted file links write paths: "adaptive" (relative below the
    --- file's directory, else absolute), "relative", "absolute",
    --- "noabbrev" or function(path) -> string (org-link-file-path-type).
    file_path_type = "adaptive",
    --- Keep a stored link after inserting it (org-link-keep-stored-after-insertion).
    keep_stored_after_insertion = false,
    --- Fuzzy links in Org files only match headlines, targets and names:
    --- "query-to-create" offers to create a missing heading, true reports
    --- it, false falls back to a text search
    --- (org-link-search-must-match-exact-headline).
    search_must_match_exact_headline = "query-to-create",
    --- Where file: and id: links open: "other-window", "current", "split",
    --- "vsplit", "tab" or function(path) (org-link-frame-setup, `file`).
    frame_setup = { file = "other-window" },
    --- Default description of inserted links: function(link, desc) ->
    --- string|nil (org-link-make-description-function).
    make_description = nil,
    --- Server for doi: links (org-link-doi-server-url).
    doi_server_url = "https://doi.org/",
    --- Functions tried first on a file search string: function(search) ->
    --- true when handled (org-execute-file-search-functions).
    search_functions = {},
    --- function(type, path) -> type, path applied before following a link
    --- (org-link-translation-function).
    translation_function = nil,
    --- A mouse click on a link follows it: true, "double" (a double click)
    --- or the longest click in ms that still follows it; false = never
    --- (org-mouse-1-follows-link). Middle click opens the link, right
    --- click opens it in Neovim (org-open-at-mouse, org-find-file-at-mouse).
    mouse_1_follows_link = 450,
    --- <Tab> on a link follows it instead of cycling (org-tab-follows-link).
    tab_follows_link = false,
    --- Links to a directory open its index.org
    --- (org-open-directory-means-index-dot-org).
    open_directory_means_index_dot_org = false,
    --- Let external apps (file_apps) open files that don't exist; false =
    --- an error (org-open-non-existing-files).
    open_non_existing_files = false,
    --- URLs of Texinfo manuals for info: links exported to HTML, by manual
    --- name (org-info-other-documents).
    info_other_documents = {
      dir = "https://www.gnu.org/manual/manual.html",
      libc = "https://www.gnu.org/software/libc/manual/html_mono/libc.html",
      make = "https://www.gnu.org/software/make/manual/make.html",
    },
  },
  --- BibTeX entries as headlines (ol-bibtex, `:h org-bibtex`).
  bibtex = {
    --- Generate the keys of new entries (org-bibtex-autogen-keys).
    autogen_keys = false,
    --- Prefix of the field properties, e.g. "BIB_" (org-bibtex-prefix).
    prefix = nil,
    --- The headline is the title when there is no TITLE property
    --- (org-bibtex-treat-headline-as-title).
    treat_headline_as_title = true,
    --- function(fields) -> headline text of written entries; nil = the
    --- title (org-bibtex-headline-format-function).
    headline_format_function = nil,
    --- Export every prefixed property, not only BibTeX fields; needs
    --- `prefix` (org-bibtex-export-arbitrary-fields).
    export_arbitrary_fields = false,
    --- Property holding the key (org-bibtex-key-property).
    key_property = "CUSTOM_ID",
    --- Tags added to new entries (org-bibtex-tags).
    tags = {},
    --- keywords field <-> tags (org-bibtex-tags-are-keywords).
    tags_are_keywords = false,
    --- Tags not exported as keywords (org-bibtex-no-export-tags).
    no_export_tags = {},
    --- Export inherited tags as keywords too (org-bibtex-inherit-tags).
    inherit_tags = false,
    --- Property holding the entry type (org-bibtex-type-property-name).
    type_property_name = "btype",
  },
  --- Downloading remote resources (a URL in #+INCLUDE on export)
  --- (org-resource-download-policy): "prompt" asks for URLs that are not
  --- safe, "safe" only fetches safe ones, true always fetches (dangerous),
  --- false never does.
  resource_download_policy = "prompt",
  --- Vim regexes of safe URLs, matched against the URL and against
  --- "file://" .. the requesting file (org-safe-remote-resources). Answers
  --- `!`, `d` and `f` at the prompt add to it and are remembered in
  --- stdpath("data")/org/safe-remote-resources.json.
  safe_remote_resources = {},
  id = {
    --- Where the ID -> file database is kept (org-id-locations-file). Point
    --- it at Emacs's file (`~/.emacs.d/.org-id-locations`) to share it.
    locations_file = data_dir .. "/id-locations.json",
    --- Format of `locations_file`: "auto" (what the file holds; else JSON
    --- for a `.json` name and Emacs's `print`ed alist otherwise), "json"
    --- or "emacs".
    locations_format = "auto",
    --- Emacs format: store file names relative to the database's
    --- directory (org-id-locations-file-relative).
    locations_file_relative = false,
    --- How new IDs are made (org-id-method): "uuid" | "ts" | "org".
    method = "uuid",
    --- Add "@" and the host name to new "ts" and "org" IDs
    --- (org-id-include-domain).
    include_domain = false,
    --- Headings offered when completing an id: link, as refile target specs
    --- (`:h org-refile`; `files = "id"` = the files holding known IDs); the
    --- chosen heading gets an ID when it has none (org-id-completion-targets).
    completion_targets = { { files = "current" }, { files = "id" } },
    --- Prefix of new IDs (org-id-prefix), e.g. "Org".
    prefix = nil,
    --- Time stamp format of "ts" IDs (org-id-ts-format; %6N = microseconds).
    ts_format = "%Y%m%dT%H%M%S.%6N",
    --- Also scan the archive files of the agenda files (org-id-search-archives).
    search_archives = true,
    --- More files (paths or globs) scanned for IDs (org-id-extra-files).
    extra_files = {},
    --- Add a search string to id: links for a named element or selection
    --- inside the entry (org-id-link-use-context).
    link_use_context = true,
    --- Store id: links using an ancestor's ID plus a search string
    --- (org-id-link-consider-parent-id).
    link_consider_parent_id = false,
  },
  attach = {
    --- Base directory of ID-based attachment directories (org-attach-id-dir).
    dir = "data/",
    --- Default attach method (org-attach-method): "cp" | "mv" | "ln" (hard
    --- link) | "lns" (symbolic link).
    method = "cp",
    --- ID -> subdirectory of `dir` (org-attach-id-to-path-function-list):
    --- functions or the built-ins "uuid" (`ab/cdef...`), "ts"
    --- (`202609/...` for time stamp IDs) and "fallback" (`__/a/abcdef...`). The first result
    --- that exists is used, else the first one.
    id_to_path = { "uuid", "ts", "fallback" },
    --- Inherit the attachment directory from a parent: "selective" (follow
    --- `use_property_inheritance`) | true | false (org-attach-use-inheritance).
    use_inheritance = "selective",
    --- Store DIR relative to the file (org-attach-dir-relative).
    dir_relative = false,
    --- How an entry without a directory gets one
    --- (org-attach-preferred-new-method): "id" | "dir" | "ask" | false.
    preferred_new_method = "id",
    --- Store a link after attaching (org-attach-store-link-p): "attached"
    --- (attachment: link) | "file" (file: link to the attachment) | true
    --- (file: link to the source) | false.
    store_link = "attached",
    --- Delete an empty attachment directory on sync: "query" | true | false
    --- (org-attach-sync-delete-empty-dir).
    sync_delete_empty_dir = "query",
    --- Delete the attachments of archived entries: false | true | "query"
    --- (org-attach-archive-delete).
    archive_delete = false,
    --- Tag of entries with attachments; false for none (org-attach-auto-tag).
    auto_tag = "ATTACH",
    --- Extra dispatcher commands (org-attach-commands), by key:
    --- `{ fn = function(target) end, desc = "..." }`; `false` removes a
    --- built-in command.
    commands = {},
    --- Ask for the dispatcher key at a one-line prompt instead of showing
    --- the command menu (org-attach-expert).
    expert = false,
    --- Commit attachment changes to git (org-attach-git; Emacs turns it on
    --- with `(require 'org-attach-git)`).
    git = false,
    --- Files of at least this many bytes go to git-annex when the
    --- repository uses it; false never annexes (org-attach-git-annex-cutoff).
    git_annex_cutoff = 32 * 1024,
    --- Fetch missing git-annex content when opening an attachment:
    --- "ask" | true | false (org-attach-git-annex-auto-get).
    git_annex_auto_get = "ask",
    --- Repository used: "default" (the one containing `dir`) or
    --- "individual-repository" (the entry's attachment directory)
    --- (org-attach-git-dir).
    git_dir = "default",
  },
}

return defaults
