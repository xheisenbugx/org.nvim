---@mod org.crypt Encrypting entries (org-crypt)
---
--- The text of an entry (not its headline, planning line, property drawer,
--- clock lines or LOGBOOK drawer) is replaced by an ASCII-armored PGP
--- message, like Emacs' org-crypt, using the `gpg` command line tool:
---   * Secret                   :crypt:
---   :PROPERTIES:
---   :CRYPTKEY: me@example.com
---   :END:
---   -----BEGIN PGP MESSAGE-----
---   ...
---   -----END PGP MESSAGE-----
--- The subtree below the entry is encrypted with it. `encrypt_entry` and
--- `decrypt_entry` work on the entry at the cursor, `encrypt_entries` and
--- `decrypt_entries` on every entry matching `crypt.tag_matcher`. With
--- `crypt.encrypt_on_save` matching entries are encrypted before the buffer
--- is written (org-crypt-use-before-save-magic).
---
--- Keys: `crypt.key = false` always encrypts symmetrically (Emacs
--- `org-crypt-key` nil). Otherwise the `CRYPTKEY` property (inherited per
--- `use_property_inheritance`; the value "nil" means no key), or else
--- `crypt.key`, is matched against the public keyring and every matching
--- key becomes a recipient. When nothing matches (`""` never does), the
--- entry is encrypted symmetrically. Passphrases are read with
--- |inputsecret()| and handed to gpg with `--pinentry-mode loopback`.

local config = require("org.config")
local edit = require("org.edit")
local files = require("org.files")
local utils = require("org.utils")

local M = {}

local BEGIN_RE = "^[ \t]*%-%-%-%-%-BEGIN PGP MESSAGE%-%-%-%-%-$"
local END_RE = "^[ \t]*%-%-%-%-%-END PGP MESSAGE%-%-%-%-%-$"

--- Ciphertext of decrypted entries, to re-insert unchanged text without
--- encrypting it again (the org-crypt-checksum text property in Emacs):
--- bufnr -> sha256(plain text) -> { key = string, text = string }.
local reuse = {}

--- Symmetric passphrase entered during one `*_entries` run or save, like
--- the gpg-agent cache Emacs relies on: nil outside of such a run.
local batch_passphrase

local function cfg()
  return config.opts.crypt or {}
end

---------------------------------------------------------------------------
-- gpg
---------------------------------------------------------------------------

--- Read a passphrase without echo. Returns nil when cancelled or empty.
--- Replaceable (tests stub it).
---@param prompt string
---@return string|nil
function M.read_passphrase(prompt)
  local ok, pw = pcall(vim.fn.inputsecret, prompt)
  vim.api.nvim_echo({ { "" } }, false, {})
  if not ok or pw == "" then
    return nil
  end
  return pw
end

--- Run gpg with `args`, feeding `input`. Returns ok, stdout, stderr.
local function gpg(args, input)
  local cmd = { cfg().gpg_program or "gpg", "--batch", "--no-tty", "--yes" }
  vim.list_extend(cmd, args)
  local ok, res = pcall(function()
    return vim.system(cmd, { stdin = input or "", text = true }):wait()
  end)
  if not ok then
    return false, "", tostring(res)
  end
  return res.code == 0, res.stdout or "", res.stderr or ""
end

--- Last meaningful line of gpg's stderr, for error messages.
local function gpg_error(stderr)
  local msg
  for line in vim.gsplit(stderr or "", "\n") do
    local l = vim.trim((line:gsub("^gpg: ", "")))
    if l ~= "" then
      msg = l
    end
  end
  return msg or "gpg failed"
end

--- Fingerprints of the public keys matching `name` (epg-list-keys). The
--- empty string matches no key.
---@param name string
---@return string[]
function M.list_keys(name)
  if name == "" then
    return {}
  end
  local ok, out = gpg({ "--with-colons", "--list-keys", "--", name })
  if not ok then
    return {}
  end
  local fprs, want = {}, false
  for line in vim.gsplit(out, "\n") do
    local kind = line:match("^(%w+):")
    if kind == "pub" then
      want = true
    elseif kind == "fpr" and want then
      fprs[#fprs + 1] = vim.split(line, ":", { plain = true })[10]
      want = false
    elseif kind == "sub" then
      want = false
    end
  end
  return fprs
end

--- Encryption keys for a headline (org-crypt-key-for-heading): a list of
--- fingerprints, or nil for symmetric encryption.
---@param hl org.Headline
---@return string[]|nil
function M.key_for_heading(hl)
  local key = cfg().key
  if key == nil or key == false then
    return nil
  end
  local prop = hl:get_property("CRYPTKEY")
  local name
  if prop == "nil" then
    name = ""
  else
    name = prop or key or ""
  end
  local keys = M.list_keys(name)
  if #keys > 0 then
    return keys
  end
  vim.api.nvim_echo({ { "No crypt key set, using symmetric encryption." } }, false, {})
  return nil
end

local function key_id(keys)
  return keys and table.concat(keys, ",") or ""
end

local function symmetric_passphrase()
  if batch_passphrase then
    return batch_passphrase
  end
  while true do
    local pw = M.read_passphrase("Passphrase for symmetric encryption: ")
    if not pw then
      return nil
    end
    local again = M.read_passphrase("Confirm passphrase for symmetric encryption: ")
    if not again then
      return nil
    end
    if pw == again then
      if batch_passphrase == false then
        batch_passphrase = pw
      end
      return pw
    end
    utils.warn("Passphrases don't match; please start over")
  end
end

--- Encrypt `text` for `keys` (nil = symmetric). Returns the armored
--- message or nil, error.
---@param text string
---@param keys string[]|nil
---@return string|nil, string|nil
function M.encrypt_string(text, keys)
  local args = { "--armor", "--textmode" }
  local input = text
  if keys then
    args[#args + 1] = "--encrypt"
    for _, k in ipairs(keys) do
      vim.list_extend(args, { "--recipient", k })
    end
  else
    local pw = symmetric_passphrase()
    if not pw then
      return nil, "No passphrase given"
    end
    vim.list_extend(args, { "--symmetric", "--pinentry-mode", "loopback", "--passphrase-fd", "0" })
    input = pw .. "\n" .. text
  end
  local ok, out, err = gpg(args, input)
  if not ok then
    return nil, gpg_error(err)
  end
  return out
end

local function needs_passphrase(stderr)
  return stderr:find("can't get input", 1, true)
    or stderr:find("Bad passphrase", 1, true)
    or stderr:find("Bad session key", 1, true)
    or stderr:find("No passphrase given", 1, true)
end

local function passphrase_prompt(stderr)
  local id = stderr:match("key, ID (%x+)")
  if not id then
    return "Passphrase for symmetric encryption: "
  end
  local uid = stderr:match('key, ID %x+[^\n]*\n%s*"([^"\n]*)"')
  return uid and string.format("Passphrase for %s %s: ", id, uid) or string.format("Passphrase for %s: ", id)
end

--- Decrypt an armored message. A passphrase is asked for only when gpg
--- (or its agent cache) can't do without one. Returns the text or nil, error.
---@param text string
---@return string|nil, string|nil
function M.decrypt_string(text)
  local base = { "--decrypt", "--pinentry-mode", "loopback" }
  local ok, out, err = gpg(base, text)
  if ok then
    return out
  end
  if not needs_passphrase(err) then
    return nil, gpg_error(err)
  end
  local symmetric = not err:find("key, ID %x+")
  local tried = {}
  if symmetric and batch_passphrase then
    tried[#tried + 1] = batch_passphrase
  end
  local prompt = passphrase_prompt(err)
  for attempt = 1, #tried + 1 do
    local pw = tried[attempt] or M.read_passphrase(prompt)
    if not pw then
      return nil, "No passphrase given"
    end
    local args = vim.list_extend(vim.deepcopy(base), { "--passphrase-fd", "0" })
    ok, out, err = gpg(args, pw .. "\n" .. text)
    if ok then
      if symmetric and batch_passphrase == false then
        batch_passphrase = pw
      end
      return out
    end
  end
  return nil, gpg_error(err)
end

---------------------------------------------------------------------------
-- Entry layout
---------------------------------------------------------------------------

local function is_heading(line)
  return line:match("^%*+ ") ~= nil
end

--- First line after the entry's meta data (org-end-of-meta-data 'standard):
--- planning line, property drawer, then blank and clock lines and LOGBOOK
--- drawers. May be the next headline or #lines + 1.
local function end_of_meta_data(lines, hl)
  local n = #lines
  local i = hl.line + 1
  local function planning(l)
    return l:match("^[ \t]*SCHEDULED:") or l:match("^[ \t]*DEADLINE:") or l:match("^[ \t]*CLOSED:")
  end
  if i <= n and planning(lines[i]) then
    i = i + 1
  end
  if i <= n and lines[i]:match("^[ \t]*:PROPERTIES:[ \t]*$") then
    local j = i + 1
    while j <= n and not lines[j]:match("^[ \t]*:END:[ \t]*$") and lines[j]:match("^[ \t]*:%S+:") do
      j = j + 1
    end
    if j <= n and lines[j]:match("^[ \t]*:END:[ \t]*$") then
      i = j + 1
    end
  end
  if i <= n and is_heading(lines[i]) then
    return i
  end
  while i <= n do
    local l = lines[i]
    if l:match("^[ \t]*$") or l:match("^[ \t]*CLOCK:") then
      i = i + 1
    elseif l:upper():match("^[ \t]*:LOGBOOK:[ \t]*$") then
      local j = i + 1
      while j <= n and not is_heading(lines[j]) and not lines[j]:match("^[ \t]*:END:[ \t]*$") do
        j = j + 1
      end
      if j <= n and lines[j]:match("^[ \t]*:END:[ \t]*$") then
        i = j + 1
      else
        break
      end
    else
      break
    end
  end
  return i
end

--- The PGP message of the entry `hl`: first and last line, or nil
--- (org-at-encrypted-entry-p).
local function encrypted_range(lines, hl)
  local s = end_of_meta_data(lines, hl)
  if s > #lines or not lines[s]:match(BEGIN_RE) then
    return nil
  end
  for j = s + 1, #lines do
    if lines[j]:match(END_RE) then
      return s, j
    elseif is_heading(lines[j]) then
      return nil
    end
  end
  return nil
end

--- Is the entry at `target` encrypted? Returns the first and last line of
--- its PGP message.
---@param target? org.Target
---@return integer|nil, integer|nil
function M.at_encrypted_entry(target)
  local bufnr, _, hl = edit.resolve(target)
  if not hl then
    return nil
  end
  return encrypted_range(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), hl)
end

local function split_text(text)
  if text == "" then
    return {}
  end
  return vim.split(text:gsub("\n$", ""), "\n", { plain = true })
end

---------------------------------------------------------------------------
-- Auto-save
---------------------------------------------------------------------------

--- Swap and undo files keep the buffer text on disk; decrypting would put
--- the clear text there (org-crypt-check-auto-save, with Neovim's swap and
--- undo files in place of Emacs' auto-save files).
local function check_auto_save(bufnr)
  local bo = vim.bo[bufnr]
  if not bo.swapfile and not bo.undofile then
    return
  end
  local mode = cfg().disable_auto_save
  if mode == nil then
    mode = "ask"
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  name = name ~= "" and name or ("buffer " .. bufnr)
  local question = "org-decrypt: swap and undo files may cause leakage. Disable them for the current buffer?"
  if mode == true or mode == "encrypt" or (mode == "ask" and utils.confirm(question)) then
    vim.api.nvim_echo({ { "org-decrypt: Disabling swap and undo files for " .. name } }, true, {})
    bo.swapfile = false
    bo.undofile = false
  elseif mode == false then
    vim.api.nvim_echo(
      { { "org-decrypt: Decrypting entry with swap/undo files enabled.  This may cause leakage.", "WarningMsg" } },
      true,
      {}
    )
  end
end

---------------------------------------------------------------------------
-- Commands
---------------------------------------------------------------------------

local function buf_cache(bufnr)
  if not reuse[bufnr] then
    reuse[bufnr] = {}
    vim.api.nvim_create_autocmd("BufWipeout", {
      buffer = bufnr,
      once = true,
      callback = function()
        reuse[bufnr] = nil
      end,
    })
  end
  return reuse[bufnr]
end

--- Encrypt the text of the entry at `target`, and its subtree
--- (org-encrypt-entry). Already encrypted entries are left alone.
---@param target? org.Target
---@return boolean|nil ok, string|nil err
function M.encrypt_entry(target)
  local bufnr, _, hl = edit.resolve(target)
  if not hl then
    utils.warn("Before first headline")
    return nil, "Before first headline"
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  if encrypted_range(lines, hl) then
    return true
  end
  local keys = M.key_for_heading(hl)
  local beg = end_of_meta_data(lines, hl)
  -- org-end-of-subtree, then org-back-over-empty-lines
  local stop = hl.end_line + 1
  local bb = config.opts.blank_before_new_entry
  if not (type(bb) == "table" and bb.heading == false) then
    stop = hl.end_line
    while stop > hl.line and lines[stop]:match("^[ \t\r]*$") do
      stop = stop - 1
    end
    stop = stop + 1
  end
  local first, last = math.min(beg, stop), math.max(beg, stop) - 1
  local plain = last >= first and (table.concat(lines, "\n", first, last) .. "\n") or ""
  local id = key_id(keys)
  local cached = (reuse[bufnr] or {})[vim.fn.sha256(plain)]
  local cipher, err
  if cached and cached.key == id then
    cipher = cached.text
  else
    cipher, err = M.encrypt_string(plain, keys)
    if not cipher then
      utils.error("org-encrypt-entry: " .. err)
      return nil, err
    end
  end
  vim.api.nvim_buf_set_lines(bufnr, first - 1, last, false, split_text(cipher))
  return true
end

--- Decrypt the PGP message of the entry at `target` (org-decrypt-entry).
--- Does nothing when the entry is not encrypted.
---@param target? org.Target
---@return boolean|nil ok, string|nil err
function M.decrypt_entry(target)
  local bufnr, _, hl = edit.resolve(target)
  if not hl then
    return nil
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local s, e = encrypted_range(lines, hl)
  if not s then
    return nil
  end
  check_auto_save(bufnr)
  local armored = {}
  for i = s, e do
    armored[#armored + 1] = (lines[i]:gsub("^[ \t]*", ""))
  end
  local cipher = table.concat(armored, "\n") .. "\n"
  local plain, err = M.decrypt_string(cipher)
  if not plain then
    utils.error("org-decrypt-entry: " .. err)
    return nil, err
  end
  local new = split_text(plain)
  -- Headings at or above the entry's level (it was promoted while
  -- encrypted): demote them all below the entry.
  local min_level, adjusted = hl.level, false
  for _, l in ipairs(new) do
    local stars = l:match("^(%*+) ")
    if stars and #stars <= hl.level then
      min_level = math.min(min_level, #stars)
      adjusted = true
    end
  end
  if adjusted then
    local extra = string.rep("*", 1 + hl.level - min_level)
    for i, l in ipairs(new) do
      if l:match("^%*+ ") then
        new[i] = extra .. l
      end
    end
  else
    buf_cache(bufnr)[vim.fn.sha256(plain)] = { key = key_id(M.key_for_heading(hl)), text = cipher }
  end
  local folded = bufnr == vim.api.nvim_get_current_buf() and vim.fn.foldclosed(hl.line) ~= -1
  vim.api.nvim_buf_set_lines(bufnr, s - 1, e, false, new)
  if folded and vim.fn.foldclosed(hl.line) == -1 then
    pcall(vim.cmd, hl.line .. "foldclose")
  end
  return true
end

--- Call `fn(target)` on every headline matching `crypt.tag_matcher`, top
--- to bottom, re-reading the buffer after each call. Archived and
--- commented trees are skipped (org-scan-tags).
local function map_matching(bufnr, fn)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local match, err = require("org.agenda.search").try_compile(cfg().tag_matcher or "crypt")
  if not match then
    utils.error("crypt.tag_matcher: " .. tostring(err))
    return nil, err
  end
  local outer = batch_passphrase
  if outer == nil then
    batch_passphrase = false
  end
  local failed
  local ok, perr = pcall(function()
    local from = 1
    while true do
      local file = files.get_buffer(bufnr)
      if vim.tbl_contains(file.settings.filetags or {}, "ARCHIVE") then
        return
      end
      local hl
      for _, h in ipairs(file.headlines) do
        if h.line >= from and not h:is_hidden_by_ancestor() and match(h) then
          hl = h
          break
        end
      end
      if not hl then
        return
      end
      local lnum = hl.line
      local res, e = fn({ bufnr = bufnr, lnum = lnum })
      if res == nil and e then
        failed = e
        return
      end
      from = lnum + 1
    end
  end)
  batch_passphrase = outer
  if not ok then
    error(perr, 0)
  end
  if failed then
    return nil, failed
  end
  return true
end

--- Encrypt every entry matching `crypt.tag_matcher` (org-encrypt-entries).
--- Stops at the first failure.
---@param bufnr? integer
---@return boolean|nil ok, string|nil err
function M.encrypt_entries(bufnr)
  return map_matching(bufnr, M.encrypt_entry)
end

--- Decrypt every entry matching `crypt.tag_matcher` (org-decrypt-entries).
---@param bufnr? integer
---@return boolean|nil ok, string|nil err
function M.decrypt_entries(bufnr)
  return map_matching(bufnr, M.decrypt_entry)
end

--- BufWritePre handler: encrypt matching entries when
--- `crypt.encrypt_on_save` is on. Returns 0 when encryption failed, so the
--- autocmd throws and the clear text is not written.
---@param bufnr integer
---@return integer
function M.before_save(bufnr)
  if not cfg().encrypt_on_save then
    return 1
  end
  local ok, res = pcall(M.encrypt_entries, bufnr)
  if not ok then
    utils.error("org-crypt: " .. tostring(res))
    return 0
  end
  return res and 1 or 0
end

--- Decrypt the entry at the cursor when it is encrypted: run by `reveal`
--- (org-crypt adds org-decrypt-entry to org-fold-reveal-start-hook).
function M.reveal_hook()
  if M.at_encrypted_entry() then
    M.decrypt_entry()
  end
end

--- Per-buffer setup: the before-save encryption
--- (org-crypt-use-before-save-magic, enabled by `crypt.encrypt_on_save`).
---@param bufnr integer
function M.attach(bufnr)
  vim.api.nvim_create_autocmd("BufWritePre", {
    buffer = bufnr,
    group = vim.api.nvim_create_augroup("org.crypt." .. bufnr, { clear = true }),
    -- A Vimscript exception (unlike a Lua error) aborts the write.
    command = string.format(
      [[if !v:lua.require'org.crypt'.before_save(%d) | throw "%s" | endif]],
      bufnr,
      "org-crypt: encryption failed, buffer not written"
    ),
  })
end

return M
