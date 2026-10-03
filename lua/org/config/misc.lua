-- Options: Encryption, org-protocol, pasting files, tags-file links, feeds,
-- timers and the mouse.
--
-- One part of `require("org.config").defaults`, merged in the order of
-- `M.parts` in lua/org/config/init.lua. Keys keep the indentation of the
-- full table: `:Org customize` reads these files for the options and the
-- `---` documentation above each one.

---@class org.config.Resolved
local defaults = {
  ---------------------------------------------------------------------------
  -- Encryption (org-crypt)
  ---------------------------------------------------------------------------
  crypt = {
    --- Match expression selecting the entries encrypt_entries,
    --- decrypt_entries and encrypt_on_save work on (org-crypt-tag-matcher).
    tag_matcher = "crypt",
    --- Key(s) to encrypt for, matched against the public keyring; the
    --- CRYPTKEY property overrides it. "" matches no key (symmetric unless
    --- CRYPTKEY is set), false always encrypts symmetrically (org-crypt-key).
    key = "",
    --- Encrypt matching entries before writing the buffer
    --- (org-crypt-use-before-save-magic).
    encrypt_on_save = false,
    --- Before decrypting in a buffer with a swap or undo file: "ask" to turn
    --- them off, true to turn them off, false to keep them
    --- (org-crypt-disable-auto-save). "encrypt" acts like true.
    disable_auto_save = "ask",
    --- The gpg executable (epg-gpg-program).
    gpg_program = "gpg",
  },

  ---------------------------------------------------------------------------
  -- org-protocol
  ---------------------------------------------------------------------------
  protocol = {
    --- Capture template of org-protocol://capture URLs without a template
    --- (org-protocol-default-template-key); nil = choose.
    default_template_key = nil,
    --- URL-to-file mappings for org-protocol://open-source
    --- (org-protocol-project-alist): list of { base_url, working_directory,
    --- online_suffix?, working_suffix?, rewrites? = { [vim regex] = path } }.
    projects = {},
    --- Extra sub-protocols (org-protocol-protocol-alist): list of
    --- { protocol = "name", fn = function(params) end, order? = { keys } }.
    handlers = {},
    --- Vim regex splitting the data of old-style URLs
    --- (`org-protocol://sub://a/b/c`) (org-protocol-data-separator).
    data_separator = [[/\+\|?]],
  },

  ---------------------------------------------------------------------------
  -- Pasting images and files (yank-media, drag and drop)
  ---------------------------------------------------------------------------
  yank = {
    --- Where `yank_media` puts a clipboard image (org-yank-image-save-method):
    --- "attach" (an attachment of the entry) | a directory (relative to the
    --- file's) | function() returning one.
    image_save_method = "attach",
    --- function() returning the image's name without extension
    --- (org-yank-image-file-name-function); nil = "clipboard-<time stamp>".
    image_file_name_function = nil,
    --- What a dropped or pasted file does (org-yank-dnd-method): "attach" |
    --- "open" | "file-link" | "ask".
    dnd_method = "ask",
    --- Attach method for dropped files (org-yank-dnd-default-attach-method):
    --- nil = `attach.method`, or "cp" | "mv" | "ln" | "lns".
    dnd_default_attach_method = nil,
    --- Treat a paste of existing file paths in an Org buffer (what a
    --- terminal sends for a file drop) as a drop.
    dnd_paste = true,
  },

  ---------------------------------------------------------------------------
  -- Plain links through tags files (org-ctags)
  ---------------------------------------------------------------------------
  ctags = {
    --- Look up plain links in the tags files (Emacs: org-ctags-enable).
    enabled = false,
    --- The ctags program (org-ctags-path-to-ctags); nil = ctags-exuberant
    --- when installed, else ctags.
    path_to_ctags = nil,
    --- Tried in order for a plain link until one returns true
    --- (org-ctags-open-link-functions): names from
    --- `require("org.ctags").link_functions` or function(name).
    open_link_functions = { "find_tag", "ask_rebuild_tags_file_then_find_tag", "ask_append_topic" },
    --- Text of a new topic, `%t` = the capitalized title
    --- (org-ctags-new-topic-template).
    new_topic_template = "* <<%t>>\n\n\n\n\n\n",
    --- The --regex-orgmode given to ctags (org-ctags-tag-regexp).
    tag_regexp = [[/<<([^<>]+)>>/\1/d,definition/]],
  },

  ---------------------------------------------------------------------------
  -- RSS / Atom feeds (org-feed)
  ---------------------------------------------------------------------------
  feed = {
    --- Feeds (org-feed-alist): list of { name = "", url = "", file = "",
    --- headline = "", ...options } or { name, url, file, headline, ... }.
    --- See |org-feed| for the options.
    feeds = {},
    --- Template of a new item (org-feed-default-template).
    default_template = "\n* %h\n  %U\n  %description\n  %a\n",
    --- Drawer holding the feed status (org-feed-drawer).
    drawer = "FEEDSTATUS",
    --- Save the file after adding items (org-feed-save-after-adding).
    save_after_adding = true,
    --- "curl", "wget" or a function(url) returning the feed text
    --- (org-feed-retrieve-method); file:// URLs are always read directly.
    retrieve_method = "curl",
  },

  ---------------------------------------------------------------------------
  -- Timers
  ---------------------------------------------------------------------------
  timer = {
    --- How timer_insert writes the value, "%s" is the value (org-timer-format).
    format = "%s ",
    --- Countdown suggested at the prompt, minutes or h:mm:ss; "0" = none
    --- (org-timer-default-timer).
    default_timer = "0",
  },

  --- org-mouse (see `:h org-mouse`).
  mouse = {
    --- Load org-mouse: context menus, dragging subtrees, clickable stars,
    --- bullets and checkboxes. Emacs loads it with (require 'org-mouse).
    org_mouse = false,
    --- Its parts (org-mouse-features): "context-menu", "move-tree",
    --- "yank-link", "activate-stars", "activate-bullets",
    --- "activate-checkboxes".
    features = { "context-menu", "yank-link", "activate-stars", "activate-bullets", "activate-checkboxes" },
  },
}

return defaults
