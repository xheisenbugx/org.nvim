---@mod org.mobile MobileOrg staging and sync (org-mobile)
---
--- A port of org-mobile.el: the asymmetric sync with a MobileOrg-style
--- application through a staging directory (`mobile.directory`, usually a
--- WebDAV or file-sync folder).
---
--- `push` copies `mobile.files` there and writes `index.org` (the TODO
--- keywords, tags and priorities plus links to the files), `agendas.org`
--- (the agenda views, see `mobile.agendas`) and `checksums.dat`; agenda
--- entries get an ID first (`mobile.force_id_on_agenda_items`).
---
--- `pull` moves the entries the application wrote to `mobileorg.org` into
--- `mobile.inbox_for_pull` and applies the edits and flags found there
--- (`apply`): `* F(edit:todo) [[id:...][...]]` entries with `** Old value`
--- and `** New value` children change the TODO state, tags, priority,
--- heading or body of the entry when it still has the old value
--- (`mobile.force_mobile_change`); `* F() [[id:...]]` entries tag the entry
--- FLAGGED and keep their note in the THEFLAGGINGNOTE property. Entries
--- that could not be applied stay in the inbox with an error message. The
--- flagged entries are then shown in an agenda (the dispatcher's `?` key),
--- where `?` shows an entry's note and, pressed again, unflags it.
---
--- With `mobile.use_encryption`, the staged files are encrypted with
--- `openssl enc -md md5 -aes-256-cbc` and `mobile.encryption_password`.
---
--- This file holds MD5, the file helpers and encryption the parts share;
--- it loads the rest from org/mobile/: index (setup, file list,
--- index.org), agenda (agendas.org), push, edit (moving the captures,
--- applying one edit), pull (applying the inbox) and flagged (the flagged
--- entries agenda and notes).

local config = require("org.config")
local utils = require("org.utils")

local M = {}
-- The parts in org/mobile/ add their functions to this table and
-- require it back, so it must be in package.loaded before they load.
package.loaded["org.mobile"] = M

local function cfg()
  return config.opts.mobile or {}
end

--- The capture file written by the mobile application (org-mobile-capture-file).
M.capture_file = "mobileorg.org"

---------------------------------------------------------------------------
-- MD5 (Emacs's `md5` of the index, agenda and capture files)
---------------------------------------------------------------------------

local bit = require("bit")
local band, bor, bxor, bnot = bit.band, bit.bor, bit.bxor, bit.bnot
local lshift, rshift, rol, tobit = bit.lshift, bit.rshift, bit.rol, bit.tobit

-- per-round shift amounts, each group of four repeated four times
local MD5_S = {}
for round, shifts in ipairs({ { 7, 12, 17, 22 }, { 5, 9, 14, 20 }, { 4, 11, 16, 23 }, { 6, 10, 15, 21 } }) do
  for i = 0, 15 do
    MD5_S[(round - 1) * 16 + i + 1] = shifts[i % 4 + 1]
  end
end
local MD5_K = {}
for i = 0, 63 do
  MD5_K[i] = tobit(math.floor(math.abs(math.sin(i + 1)) * 2 ^ 32) % 2 ^ 32)
end

--- Hex MD5 digest of a string.
---@param s string
---@return string
function M.md5(s)
  local len = #s
  s = s .. "\128" .. string.rep("\0", (55 - len) % 64)
  local bits = len * 8
  for i = 0, 7 do
    s = s .. string.char(math.floor(bits / 2 ^ (8 * i)) % 256)
  end
  local a0, b0, c0, d0 = tobit(0x67452301), tobit(0xefcdab89), tobit(0x98badcfe), tobit(0x10325476)
  local w = {}
  for chunk = 1, #s, 64 do
    for i = 0, 15 do
      local p = chunk + i * 4
      local b1, b2, b3, b4 = s:byte(p, p + 3)
      w[i] = bor(b1, lshift(b2, 8), lshift(b3, 16), lshift(b4, 24))
    end
    local a, b, c, d = a0, b0, c0, d0
    for i = 0, 63 do
      local f, g
      if i < 16 then
        f, g = bor(band(b, c), band(bnot(b), d)), i
      elseif i < 32 then
        f, g = bor(band(d, b), band(bnot(d), c)), (5 * i + 1) % 16
      elseif i < 48 then
        f, g = bxor(b, c, d), (3 * i + 5) % 16
      else
        f, g = bxor(c, bor(b, bnot(d))), (7 * i) % 16
      end
      f = tobit(f + a + MD5_K[i] + w[g])
      a, d, c = d, c, b
      b = tobit(b + rol(f, MD5_S[i + 1]))
    end
    a0, b0, c0, d0 = tobit(a0 + a), tobit(b0 + b), tobit(c0 + c), tobit(d0 + d)
  end
  local out = {}
  for _, v in ipairs({ a0, b0, c0, d0 }) do
    for i = 0, 3 do
      out[#out + 1] = string.format("%02x", band(rshift(v, 8 * i), 0xff))
    end
  end
  return table.concat(out)
end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function read_raw(path)
  local fd = io.open(path, "rb")
  if not fd then
    return nil
  end
  local s = fd:read("*a")
  fd:close()
  return s
end

local function write_raw(path, s)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local fd, err = io.open(path, "wb")
  if not fd then
    error("org: cannot write " .. path .. ": " .. tostring(err), 0)
  end
  fd:write(s)
  fd:close()
end

local function text_of(lines)
  return #lines > 0 and (table.concat(lines, "\n") .. "\n") or ""
end

--- The org directory, absolute.
local function org_dir()
  return utils.expand(config.opts.org_directory or "~/org", vim.fn.getcwd())
end

local function staging_dir()
  local d = cfg().directory
  if type(d) ~= "string" or not d:match("%S") then
    return nil
  end
  return utils.expand(d, vim.fn.getcwd())
end

local function inbox_path()
  local p = cfg().inbox_for_pull
  if type(p) ~= "string" or not p:match("%S") then
    return nil
  end
  return utils.expand(p, org_dir())
end

--- Run a hook: the `mobile.<name>` function (or list of functions) and the
--- User autocmd `pattern`.
local function run_hook(name, pattern, data)
  local h = cfg()[name]
  local list = type(h) == "function" and { h } or (type(h) == "table" and h or {})
  for _, fn in ipairs(list) do
    if type(fn) == "function" then
      local ok, err = pcall(fn, data)
      if not ok then
        utils.error(string.format("mobile.%s: %s", name, tostring(err)))
      end
    end
  end
  pcall(vim.api.nvim_exec_autocmds, "User", { pattern = pattern, data = data or {}, modeline = false })
end

--- The executable computing file checksums (org-mobile-checksum-binary).
function M.checksum_binary()
  local b = cfg().checksum_binary
  if type(b) == "string" and b:match("%S") then
    return b
  end
  for _, name in ipairs({ "shasum", "sha1sum", "md5sum", "md5" }) do
    if vim.fn.executable(name) == 1 then
      return name
    end
  end
end

---------------------------------------------------------------------------
-- Encryption (openssl)
---------------------------------------------------------------------------

M._session_password = nil

--- The encryption password: `mobile.encryption_password`, else asked once
--- per session (org-mobile-encryption-password).
function M.encryption_password()
  local p = cfg().encryption_password
  if type(p) == "string" and p:match("%S") then
    return p
  end
  if M._session_password and M._session_password:match("%S") then
    return M._session_password
  end
  local ok, v = pcall(vim.fn.inputsecret, "Password for mobile application: ")
  M._session_password = ok and v or ""
  return M._session_password
end

local function openssl(decrypt, infile, outfile)
  local cmd = { "openssl", "enc", "-md", "md5" }
  if decrypt then
    cmd[#cmd + 1] = "-d"
  end
  -- the password goes on stdin: in argv (as Emacs passes it) any local
  -- user could read it from the process list
  vim.list_extend(cmd, { "-aes-256-cbc", "-salt", "-pass", "stdin", "-in", infile, "-out", outfile })
  local res = vim.system(cmd, { text = true, stdin = M.encryption_password() .. "\n" }):wait()
  if res.code ~= 0 then
    error("openssl failed: " .. vim.trim(res.stderr or ""), 0)
  end
end

--- Encrypt `infile` to `outfile` (org-mobile-encrypt-file).
function M.encrypt_file(infile, outfile)
  openssl(false, infile, outfile)
end

--- Decrypt `infile` to `outfile` (org-mobile-decrypt-file).
function M.decrypt_file(infile, outfile)
  openssl(true, infile, outfile)
end

--- Write `content` to the staged file `path`, encrypted when
--- `mobile.use_encryption` is set.
local function stage_write(path, content)
  if not cfg().use_encryption then
    write_raw(path, content)
    return
  end
  local tmp = vim.fn.tempname()
  write_raw(tmp, content)
  local ok, err = pcall(M.encrypt_file, tmp, path)
  os.remove(tmp)
  if not ok then
    error(err, 0)
  end
end

--- The plain contents of the staged file `path`.
local function stage_read(path)
  if not cfg().use_encryption then
    return read_raw(path)
  end
  if not utils.exists(path) then
    return nil
  end
  local tmp = vim.fn.tempname()
  local ok, err = pcall(M.decrypt_file, path, tmp)
  local s = ok and read_raw(tmp) or nil
  os.remove(tmp)
  if not ok then
    error(err, 0)
  end
  return s
end

-- Local functions the parts below share
local shared = require("org.mobile.shared")
shared.cfg = cfg
shared.inbox_path = inbox_path
shared.org_dir = org_dir
shared.read_raw = read_raw
shared.run_hook = run_hook
shared.stage_read = stage_read
shared.stage_write = stage_write
shared.staging_dir = staging_dir
shared.text_of = text_of
shared.write_raw = write_raw

require("org.mobile.index")
require("org.mobile.agenda")
require("org.mobile.push")
require("org.mobile.edit")
require("org.mobile.pull")
require("org.mobile.flagged")

return M
