---@mod org.ui.highlight.headline Headlines
---
--- Part of org.ui.highlight (the parser highlighter): the level faces of headlines (and of the stars only with `ui.level_color_stars_only`), TODO keywords (`ui.todo_keyword_faces`), priority cookies (`ui.priority_faces`), tags (`ui.tag_faces`), COMMENT, the text of DONE / TODO headlines (`ui.fontify_done_headline`, `ui.fontify_todo_headline`), ARCHIVE headlines and inline tasks.

local M = {}

--- Paint the rows of `ctx` (see org.ui.highlight `Ctx`).
---@param ctx org.ui.highlight.Ctx
function M.paint(ctx)
  local _ = ctx
end

return M
