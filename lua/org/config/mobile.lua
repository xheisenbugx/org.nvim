-- Options: MobileOrg.
--
-- One part of `require("org.config").defaults`, merged in the order of
-- `M.parts` in lua/org/config/init.lua. Keys keep the indentation of the
-- full table: `:Org customize` reads these files for the options and the
-- `---` documentation above each one.

---@class org.config.Resolved
local defaults = {
  ---------------------------------------------------------------------------
  -- MobileOrg (org-mobile)
  ---------------------------------------------------------------------------
  mobile = {
    --- Staging directory shared with the mobile application
    --- (org-mobile-directory). Required by push and pull.
    directory = nil,
    --- Files to stage (org-mobile-files): "agenda_files",
    --- "text_search_extra_files", files and directories (their `*.org`).
    files = { "agenda_files" },
    --- Emacs regexp of files not to stage (org-mobile-files-exclude-regexp).
    files_exclude_regexp = "",
    --- File the captured entries and edit requests are moved to on pull
    --- (org-mobile-inbox-for-pull); relative to `org_directory`.
    inbox_for_pull = "~/org/from-mobile.org",
    --- Name of the index file (org-mobile-index-file).
    index_file = "index.org",
    --- The #+ALLPRIORITIES of the index file (org-mobile-allpriorities).
    allpriorities = "A B C",
    --- Agendas written to agendas.org (org-mobile-agendas): "default" (week
    --- agenda and TODO list), "custom" (`agenda.custom_commands`), "all",
    --- or a list of command keys.
    agendas = "all",
    --- Give every agenda entry an ID on push (org-mobile-force-id-on-agenda-items).
    force_id_on_agenda_items = true,
    --- Apply mobile edits even when the entry changed on the computer too
    --- (org-mobile-force-mobile-change): true, false or a list of
    --- "todo", "tags", "priority", "heading", "body".
    force_mobile_change = false,
    --- Encrypt the staged files with openssl (org-mobile-use-encryption).
    use_encryption = false,
    --- Password for the encryption; asked once per session when empty
    --- (org-mobile-encryption-password).
    encryption_password = "",
    --- Program for file checksums; nil finds shasum, sha1sum, md5sum or md5
    --- (org-mobile-checksum-binary).
    checksum_binary = nil,
    --- Extra `F(action:data)` actions (org-mobile-action-alist):
    --- `{ name = function(data, old, new, target) end }`.
    action_alist = {},
    --- Show the flagged entries in an agenda after a pull.
    show_flagged = true,
    --- Hooks (functions; the User autocmds OrgMobilePrePush, OrgMobilePostPush,
    --- OrgMobilePrePull, OrgMobileBeforeProcessCapture and OrgMobilePostPull
    --- fire too).
    pre_push_hook = nil,
    post_push_hook = nil,
    pre_pull_hook = nil,
    before_process_capture_hook = nil,
    post_pull_hook = nil,
  },
}

return defaults
