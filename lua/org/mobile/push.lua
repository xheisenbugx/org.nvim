---@mod org.mobile.push Push
---
--- Checksums and org-mobile-push.
--- Part of org.mobile, which loads it.

local utils = require("org.utils")
local shared = require("org.mobile.shared")

local M = require("org.mobile")

local cfg = shared.cfg
local read_raw = shared.read_raw
local run_hook = shared.run_hook
local stage_write = shared.stage_write
local staging_dir = shared.staging_dir
local text_of = shared.text_of
local write_raw = shared.write_raw

---------------------------------------------------------------------------
-- Push
---------------------------------------------------------------------------

--- Checksum of a file with `mobile.checksum_binary`.
--- Checksum of the file at `path`: from `mobile.checksum_binary`, else MD5.
function M.file_checksum(path)
  local bin = M.checksum_binary()
  local ok, res = pcall(function()
    return bin and vim.system({ bin, path }, { text = true }):wait()
  end)
  for hex in (ok and res and res.stdout or ""):gmatch("%x+") do
    if #hex >= 30 then
      return hex:sub(1, 40)
    end
  end
  -- no checksum program that runs (e.g. Git for Windows' Perl shasum):
  -- the MD5 computed here, which MobileOrg takes as well
  local data = read_raw(path)
  return data and M.md5(data) or nil
end
local file_checksum = M.file_checksum

--- Save the modified buffers of `paths` (org-save-all-org-buffers for the
--- staged files).
local function save_buffers(paths)
  for _, p in ipairs(paths) do
    local b = utils.find_buffer(p)
    if b and vim.bo[b].modified then
      utils.save_buffer_or_warn(b)
    end
  end
end

--- Stage the files, agendas, index and checksums for the mobile
--- application (org-mobile-push).
function M.push()
  local ok, err = pcall(function()
    run_hook("pre_push_hook", "OrgMobilePrePush")
    M.check_setup()
    local alist = M.files_alist()
    local paths = vim.tbl_map(function(e)
      return e.file
    end, alist)
    save_buffers(paths)
    local checksums = {}
    local function push_sum(name, sum)
      if sum then
        table.insert(checksums, 1, { name, sum })
      end
    end
    local dir = staging_dir()
    utils.notify("Creating agendas...")
    push_sum("agendas.org", M.create_sumo_agenda())
    save_buffers(paths)
    utils.notify("Copying files...")
    for _, e in ipairs(alist) do
      if utils.exists(e.file) then
        local target = dir .. "/" .. e.link
        vim.fn.mkdir(vim.fn.fnamemodify(target, ":h"), "p")
        if cfg().use_encryption then
          M.encrypt_file(e.file, target)
        else
          local cok, cerr = vim.uv.fs_copyfile(e.file, target)
          if not cok then
            error("Cannot copy " .. e.file .. ": " .. tostring(cerr), 0)
          end
        end
        push_sum(e.link, file_checksum(e.file))
      end
    end
    local capture = dir .. "/" .. M.capture_file
    local ccontent = read_raw(capture) or ""
    if ccontent == "" then
      ccontent = "\n"
      stage_write(capture, ccontent)
    end
    push_sum(M.capture_file, M.md5(ccontent))
    utils.notify("Writing index file...")
    local index = text_of(M.index_lines(alist, utils.exists(dir .. "/agendas.org")))
    stage_write(dir .. "/" .. (cfg().index_file or "index.org"), index)
    push_sum(cfg().index_file or "index.org", M.md5(index))
    utils.notify("Writing checksums...")
    local sums = {}
    for _, c in ipairs(checksums) do
      sums[#sums + 1] = string.format("%s  %s", c[2], c[1])
    end
    write_raw(dir .. "/checksums.dat", text_of(sums))
    run_hook("post_push_hook", "OrgMobilePostPush")
  end)
  if not ok then
    utils.error(tostring(err))
    return false
  end
  utils.notify("Files for mobile viewer staged")
  return true
end
