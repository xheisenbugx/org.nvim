-- Git merge driver for Org files (org.nvim's `merge` extension).
--
--   nvim --headless -u NONE -i NONE -l driver.lua [options] %O %A %B [%P]
--
-- Merges base (%O), ours (%A) and theirs (%B), writes the result to %A and
-- exits 0 when it is clean, 1 when it has conflict markers. Options:
--
--   --marker-size=N       length of the conflict markers (git's %L)
--   --ours-label=TEXT     text after <<<<<<< (git's %X; default "ours")
--   --theirs-label=TEXT   text after >>>>>>> (git's %Y; default "theirs")
--   --prefer=ours|theirs  side taken for headline, planning and property
--                         conflicts instead of markers
--   --no-sort-logbook     keep LOGBOOK items in file order
--   --todo=SEQUENCE       a TODO keyword sequence ("TODO NEXT | DONE"),
--                         repeatable; files' own #+TODO lines apply too
--   --config=FILE         a Lua file to run first (e.g. calling
--                         require("org.config").setup{...})
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local root = vim.fn.fnamemodify(here, ":h:h:h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local opts = { sort_logbook = true }
local todo, files, config_file = {}, {}, nil
for _, a in ipairs(arg or {}) do
  local k, v = a:match("^%-%-([%w-]+)=(.*)$")
  if k == "marker-size" then
    opts.marker_size = tonumber(v)
  elseif k == "ours-label" then
    opts.ours_label = v
  elseif k == "theirs-label" then
    opts.theirs_label = v
  elseif k == "prefer" then
    opts.prefer = (v == "ours" or v == "theirs") and v or nil
  elseif k == "todo" then
    todo[#todo + 1] = v
  elseif k == "config" then
    config_file = v
  elseif a == "--no-sort-logbook" then
    opts.sort_logbook = false
  elseif a:sub(1, 2) == "--" then
    io.stderr:write("org-merge: unknown option " .. a .. "\n")
  else
    files[#files + 1] = a
  end
end

if #files < 3 then
  io.stderr:write("usage: org-merge [options] BASE OURS THEIRS [PATH]\n")
  os.exit(2)
end

if config_file then
  local ok, err = pcall(dofile, vim.fn.expand(config_file))
  if not ok then
    io.stderr:write("org-merge: " .. tostring(err) .. "\n")
  end
end
if #todo > 0 then
  require("org.config").opts.todo_keywords = todo
end

local merge = require("org.extensions.merge.merge")
local ok, conflicts, err = pcall(merge.merge_files, files[1], files[2], files[3], opts)
if not ok then
  io.stderr:write("org-merge: " .. tostring(conflicts) .. "\n")
  os.exit(2)
end
if err then
  io.stderr:write("org-merge: " .. (files[4] or files[2]) .. ": line merge only: " .. tostring(err) .. "\n")
end
os.exit(conflicts > 0 and 1 or 0)
