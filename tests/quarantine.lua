-- Spec files known to fail now and then for reasons outside the change
-- under test (a slow runner, a race with a child Neovim). With
-- ORG_TEST_RERUN_QUARANTINED=1 (set in CI), tests/run.lua runs a listed
-- file that failed once more, in a fresh Neovim: when the second run passes,
-- the file is reported as FLAKY instead of failed; when it fails again, its
-- failures count as usual. Files not listed here never get a second run, so
-- a flake can't hide a real failure elsewhere, and a listed file that fails
-- every time still fails the run.
--
-- Add a file only once CI history shows it failing on unrelated changes,
-- with the reason; take it out once the flake is fixed (CONTRIBUTING.md,
-- "Flaky specs"). `os` limits an entry to "windows", "macos" or "linux".
-- ORG_TEST_QUARANTINE="a_spec.lua,b_spec.lua" adds files for one run.
local M = {}

M.list = {
  {
    file = "capture_visual_spec.lua",
    reason = "the wait loop RPCs into a child Neovim that may still sit in the capture menu's getchar",
  },
  {
    file = "perf_budgets_spec.lua",
    reason = "a linear-growth check can fail when one measurement is slowed by the runner",
  },
  {
    file = "babel_ob_csharp_spec.lua",
    os = "windows",
    reason = "a dotnet step can exceed babel.timeout on Windows runners",
  },
}

--- The OS name entries use: "windows", "macos" or "linux".
function M.os()
  if vim.fn.has("win32") == 1 then
    return "windows"
  elseif vim.fn.has("mac") == 1 then
    return "macos"
  end
  return "linux"
end

--- The entry quarantining spec file `file` (a path; matched by its name)
--- on `os_name`, or nil. `list` defaults to M.list plus ORG_TEST_QUARANTINE.
---@param file string
---@param os_name? string
---@param list? table[]
---@return table?
function M.find(file, os_name, list)
  os_name = os_name or M.os()
  local name = file:match("[^/\\]+$") or file
  if not list then
    list = vim.list_extend({}, M.list)
    for extra in (vim.env.ORG_TEST_QUARANTINE or ""):gmatch("[^,%s]+") do
      list[#list + 1] = { file = extra, reason = "ORG_TEST_QUARANTINE" }
    end
  end
  for _, e in ipairs(list) do
    if e.file == name and (e.os == nil or e.os == os_name) then
      return e
    end
  end
  return nil
end

--- Whether failing quarantined files get a second run.
function M.enabled()
  return vim.env.ORG_TEST_RERUN_QUARANTINED == "1"
end

--- Whether a spec file's run failed: `entry` as tests/run.lua collects it
--- ({ result = { failed = n }, crash = reason? }).
function M.failed(entry)
  return entry.crash ~= nil or entry.result == nil or (entry.result.failed or 0) > 0
end

--- Whether the run `entry` of `file` gets a second one.
function M.should_rerun(file, entry, os_name)
  return M.enabled() and M.failed(entry) and M.find(file, os_name) ~= nil
end

return M
