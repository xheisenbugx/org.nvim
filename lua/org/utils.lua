---@mod org.utils Helpers
---
--- Shared internal utilities split by domain across `org/utils/`:
--- - `async`: notifications, session log (`try`, `user_event`), non-interactive
---   calls, coroutines (`run`, `async`, `await`, `abort`) and prompts
--- - `string`: whitespace, Unicode case, escaping, float formatting, width,
---   UUID, SHA-256 and collation (`string_lessp`)
--- - `fs`: PowerShell quoting, path expansion/normalization, file & JSON I/O,
---   directory scanning and safe globbing
--- - `buffer`: buffer lookup/loading, diff/restore, `file_lines`, `save_buffer`,
---   file opening and cursor/visual helpers

local M = {}
-- The parts in org/utils/ add their functions to this table and require it
-- back, so it must be in package.loaded before they load.
package.loaded["org.utils"] = M

M.augroup = vim.api.nvim_create_augroup("org.nvim", { clear = false })

require("org.utils.async")
require("org.utils.string")
require("org.utils.fs")
require("org.utils.buffer")

return M
