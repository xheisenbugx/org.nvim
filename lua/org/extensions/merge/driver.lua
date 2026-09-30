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
--   --base-label=TEXT     git's %S (shown with merge.conflictStyle diff3)
--   --name=NAME           the driver's name in git (default "org"): its
--                         options are read from `merge.NAME.*` in the git
--                         config at merge time (prefer, sortLogbook, todo,
--                         config, setDrawers, renameSimilarity)
--   --no-git-config       don't read `merge.NAME.*`
--   --prefer=ours|theirs  side taken for headline, planning, property and
--                         move conflicts instead of markers
--   --no-sort-logbook     keep LOGBOOK items in file order
--   --todo=SEQUENCE       a TODO keyword sequence ("TODO NEXT | DONE"),
--                         repeatable; files' own #+TODO lines apply too
--   --set-drawer=NAME     another drawer merged item by item, repeatable
--   --rename-similarity=X how alike (0..1) the text of an entry renamed
--                         and edited must be to be matched (0.6; 2: off)
--   --config=FILE         a Lua file to run first (e.g. calling
--                         require("org.config").setup{...})
--
-- Options given on the command line win over the git config. Git before
-- 2.44 passes %S, %X and %Y through unexpanded; such labels are ignored.
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local root = vim.fn.fnamemodify(here, ":h:h:h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local cli = {}
local todo, drawers, files, config_file = nil, nil, {}, nil
local name, use_git = "org", true

-- a label git did not expand (%X from an older git) or left empty
local function label(v)
  if v == nil or v == "" or v:match("^%%%a$") then
    return nil
  end
  return v
end

for _, a in ipairs(arg or {}) do
  local k, v = a:match("^%-%-([%w-]+)=(.*)$")
  if k == "marker-size" then
    cli.marker_size = tonumber(v)
  elseif k == "ours-label" then
    cli.ours_label = label(v)
  elseif k == "theirs-label" then
    cli.theirs_label = label(v)
  elseif k == "base-label" then
    cli.base_label = label(v)
  elseif k == "name" then
    name = v
  elseif k == "prefer" then
    cli.prefer = (v == "ours" or v == "theirs") and v or nil
  elseif k == "todo" then
    todo = todo or {}
    todo[#todo + 1] = v
  elseif k == "set-drawer" then
    drawers = drawers or {}
    drawers[#drawers + 1] = v
  elseif k == "rename-similarity" then
    cli.rename_similarity = tonumber(v)
  elseif k == "config" then
    config_file = v
  elseif a == "--no-sort-logbook" then
    cli.sort_logbook = false
  elseif a == "--no-git-config" then
    use_git = false
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

-- `merge.NAME.*` of the repository git runs the driver in: key (lower
-- case, as git prints it) -> list of values
local function git_config()
  if not use_git or vim.fn.executable("git") == 0 or not vim.system then
    return {}
  end
  local ok, res = pcall(function()
    return vim.system({ "git", "config", "--list" }, { text = true }):wait(5000)
  end)
  if not ok or not res or res.code ~= 0 then
    return {}
  end
  local out = {}
  local prefix = ("merge." .. name .. "."):lower()
  for line in (res.stdout or ""):gmatch("[^\n]+") do
    local key, value = line:match("^([^=]+)=(.*)$")
    if key and key:lower() == "merge.conflictstyle" then
      out.conflictstyle = { value }
    elseif key and key:lower():sub(1, #prefix) == prefix then
      key = key:lower():sub(#prefix + 1)
      out[key] = out[key] or {}
      table.insert(out[key], value)
    end
  end
  return out
end

local gc = git_config()
local function last(key)
  local l = gc[key]
  return l and l[#l] or nil
end
local function bool(v)
  if v == nil then
    return nil
  end
  v = v:lower()
  return not (v == "false" or v == "no" or v == "off" or v == "0")
end

local opts = { sort_logbook = true }
local gp = last("prefer")
if gp == "ours" or gp == "theirs" then
  opts.prefer = gp
end
if bool(last("sortlogbook")) == false then
  opts.sort_logbook = false
end
-- git's merge.conflictStyle: diff3 / zdiff3 also show the base text
local style = last("conflictstyle")
if style == "diff3" or style == "zdiff3" then
  opts.style = "diff3"
end
if last("renamesimilarity") then
  opts.rename_similarity = tonumber(last("renamesimilarity"))
end
opts.set_drawers = drawers or gc.setdrawers
todo = todo or gc.todo
config_file = config_file or last("config")
for k, v in pairs(cli) do
  opts[k] = v
end

if config_file then
  local ok, err = pcall(dofile, vim.fn.expand(config_file))
  if not ok then
    io.stderr:write("org-merge: " .. tostring(err) .. "\n")
  end
end
if todo and #todo > 0 then
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
