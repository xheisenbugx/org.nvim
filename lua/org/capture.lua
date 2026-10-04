---@mod org.capture Capture (org-capture)
---
--- Templates live in `capture.templates`, keyed by their selection key:
---
---   templates = {
---     t = { description = "Task", template = "* TODO %?\n  %u", target = "~/org/inbox.org", headline = "Tasks" },
---     j = { description = "Journal", template = "* %<%H:%M> %?", target = "~/org/journal.org", datetree = true },
---     w = "Work",                                  -- group; its templates use keys "wX"
---     wm = { description = "Meeting", template = "* MEETING %? :meeting:\n  %T", olp = { "Work", "Meetings" } },
---   }
---
--- The target is resolved when the capture starts (like Emacs, which
--- inserts the template into the target right away): headlines and date
--- tree nodes are created then, and the location is tracked with an
--- extmark until the capture is finished. The text is edited in a separate
--- capture buffer and stored at that location on finalize, except with
--- `unnarrowed`: the text then goes into the target buffer right away and
--- is edited there, in a window showing the whole file.
---
--- Template fields: see `:h org-capture-templates`.
---
--- This file holds the capture state; the rest is loaded from
--- org/capture/: templates (selection menu), expand (%-escapes and
--- prompts), target (target resolution, date trees), place (inserting
--- the text at the target), session (store, finalize, kill, refile) and
--- buffer (the capture buffer and window, M.capture).

local M = {}
-- The parts in org/capture/ add their functions to this table and
-- require it back, so it must be in package.loaded before they load.
package.loaded["org.capture"] = M

local CURSOR = "\30"

--- Active capture sessions: bufnr -> session
M.sessions = {}

--- Functions that may rewrite the captured lines before they are stored,
--- by name: `fun(tpl, lines, ctx): string[]|nil, table|nil` (nil keeps the
--- lines). A second result is a template-like target (`target`,
--- `headline`, `location`...) the entry goes to instead. Empty unless an
--- extension adds one (quickadd's `quickadd = true`).
---@type table<string, fun(tpl: table, lines: string[], ctx: table): string[]|nil, table|nil>
M.store_filters = {}

-- Local values the parts below share
local shared = require("org.capture.shared")
shared.CURSOR = CURSOR

require("org.capture.templates")
require("org.capture.expand")
require("org.capture.target")
require("org.capture.place")
require("org.capture.session")
require("org.capture.buffer")

return M
