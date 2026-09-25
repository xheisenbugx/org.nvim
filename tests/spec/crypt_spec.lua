-- org-crypt: encrypting entries with gpg.

if vim.fn.executable("gpg") == 0 then
  describe("crypt", function()
    it("skipped: gpg not found", function() end)
  end)
  return
end

local config = require("org.config")
local crypt = require("org.crypt")

-- A throwaway keyring (short path: gpg-agent's socket lives in it).
local home = vim.fn.tempname()
vim.fn.mkdir(home, "p", "0700")
local saved_home = vim.env.GNUPGHOME
vim.env.GNUPGHOME = home
vim.api.nvim_create_autocmd("VimLeavePre", {
  callback = function()
    vim.system({ "gpgconf", "--kill", "gpg-agent" }):wait()
    vim.fn.delete(home, "rf")
    vim.env.GNUPGHOME = saved_home
  end,
})
local keygen_cmd = { "gpg", "--batch", "--passphrase", "", "--quick-gen-key", "test@example.com" }
vim.list_extend(keygen_cmd, { "default", "default", "never" })
local keygen = vim.system(keygen_cmd):wait()
local have_key = keygen.code == 0

local prompts
local passphrase
local read_passphrase = crypt.read_passphrase

local function setup(opts)
  config.opts.crypt = vim.tbl_extend("force", {
    tag_matcher = "crypt",
    key = false,
    encrypt_on_save = false,
    disable_auto_save = "ask",
    gpg_program = "gpg",
  }, opts or {})
  prompts = {}
  passphrase = "secret"
  crypt.read_passphrase = function(prompt)
    prompts[#prompts + 1] = prompt
    return passphrase
  end
end

local SAMPLE = {
  "#+TITLE: t",
  "* Top",
  "text",
  "* Secret :crypt:",
  "SCHEDULED: <2026-09-25 Fri>",
  ":PROPERTIES:",
  ":ID: abc",
  ":END:",
  ":LOGBOOK:",
  "CLOCK: [2026-09-25 Fri 10:00]--[2026-09-25 Fri 11:00] =>  1:00",
  ":END:",
  "",
  "  indented body",
  "more",
  "** Child",
  "child text",
  "",
  "",
  "* Other :crypt:",
  "* Empty :crypt:",
  ":PROPERTIES:",
  ":A: 1",
  ":END:",
  "",
  "",
  "* Last",
}

--- Line ranges of the PGP messages in a buffer: { {first, last}, ... }.
local function blocks(buf)
  local out, s = {}, nil
  for i, l in ipairs(buf_lines(buf)) do
    if l:match("^%s*%-%-%-%-%-BEGIN PGP MESSAGE") then
      s = i
    elseif l:match("^%s*%-%-%-%-%-END PGP MESSAGE") then
      out[#out + 1] = { s, i }
    end
  end
  return out
end

--- gpg's description of the packets of the message at lines [s, e].
local function packets(buf, s, e)
  local text = table.concat(vim.api.nvim_buf_get_lines(buf, s - 1, e, false), "\n") .. "\n"
  local res = vim.system({ "gpg", "--batch", "--list-packets" }, { stdin = text, text = true }):wait()
  return (res.stdout or "") .. (res.stderr or "")
end

describe("crypt", function()
  before_each(function()
    setup()
  end)

  it("encrypts the text after the meta data, like org-encrypt-entry", function()
    local buf = org_buffer(SAMPLE, { 4, 0 })
    ok(crypt.encrypt_entry())
    local lines = buf_lines(buf)
    -- heading, planning, properties, logbook and the blank line stay clear
    eq(vim.list_slice(SAMPLE, 1, 12), vim.list_slice(lines, 1, 12))
    eq("-----BEGIN PGP MESSAGE-----", lines[13])
    local b = blocks(buf)
    eq(1, #b)
    eq(13, b[1][1])
    -- the subtree is encrypted; trailing blank lines stay outside
    eq({ "", "", "* Other :crypt:" }, vim.list_slice(lines, b[1][2] + 1, b[1][2] + 3))
    ok(packets(buf, b[1][1], b[1][2]):find("symkey enc packet", 1, true))
    eq({ "Passphrase for symmetric encryption: ", "Confirm passphrase for symmetric encryption: " }, prompts)
    ok(crypt.at_encrypted_entry())
  end)

  it("round-trips the entry text exactly", function()
    local buf = org_buffer(SAMPLE, { 4, 0 })
    crypt.encrypt_entry()
    prompts = {}
    ok(crypt.decrypt_entry())
    eq(SAMPLE, buf_lines(buf))
    eq({ "Passphrase for symmetric encryption: " }, prompts)
    ok(not crypt.at_encrypted_entry())
  end)

  it("keeps UTF-8, tabs and trailing whitespace", function()
    local lines = { "* S", "  ünïcødé ✓\tx  ", "", "last" }
    local buf = org_buffer(lines, { 1, 0 })
    crypt.encrypt_entry()
    crypt.decrypt_entry()
    eq(lines, buf_lines(buf))
  end)

  it("leaves encrypted entries alone and reuses unchanged ciphertext", function()
    local buf = org_buffer(SAMPLE, { 4, 0 })
    crypt.encrypt_entry()
    local encrypted = buf_lines(buf)
    prompts = {}
    ok(crypt.encrypt_entry())
    eq(encrypted, buf_lines(buf))
    eq({}, prompts)
    crypt.decrypt_entry()
    prompts = {}
    crypt.encrypt_entry()
    eq(encrypted, buf_lines(buf), "same text, same key: same message")
    eq({}, prompts)
    crypt.decrypt_entry()
    vim.api.nvim_buf_set_lines(buf, 13, 14, false, { "changed" })
    crypt.encrypt_entry()
    ok(not vim.deep_equal(encrypted, buf_lines(buf)), "changed text is encrypted again")
    crypt.decrypt_entry()
    eq("changed", buf_lines(buf)[14])
  end)

  it("encrypts and decrypts all matching entries, like org-encrypt-entries", function()
    local buf = org_buffer(SAMPLE, { 1, 0 })
    ok(crypt.encrypt_entries())
    local lines = buf_lines(buf)
    local b = blocks(buf)
    eq(3, #b)
    -- an entry without text gets a message of the empty text
    eq("* Other :crypt:", lines[b[2][1] - 1])
    eq("* Empty :crypt:", lines[b[2][2] + 1])
    -- blank lines after a property drawer are swallowed, as in Emacs
    eq(":END:", lines[b[3][1] - 1])
    eq("* Last", lines[b[3][2] + 1])
    -- one passphrase (asked twice) for the whole run
    eq(2, #prompts)
    prompts = {}
    ok(crypt.decrypt_entries())
    eq(SAMPLE, buf_lines(buf))
    eq(1, #prompts)
  end)

  it("honours crypt.tag_matcher and skips archived and commented trees", function()
    config.opts.crypt.tag_matcher = "secret-skip"
    local lines = {
      "* A :secret:",
      "a",
      "* B :secret:skip:",
      "b",
      "* COMMENT C :secret:",
      "c",
      "* D :secret:ARCHIVE:",
      "d",
      "* E :crypt:",
      "e",
    }
    local buf = org_buffer(lines, { 1, 0 })
    crypt.encrypt_entries()
    local out = buf_lines(buf)
    eq("-----BEGIN PGP MESSAGE-----", out[2])
    eq(1, #blocks(buf))
    eq(vim.list_slice(lines, 3), vim.list_slice(out, #out - 7))
  end)

  it("decrypts messages written by Emacs org-crypt", function()
    -- org-encrypt-entry of the "Secret" entry of SAMPLE (Emacs 31, Org
    -- 9.8.10, org-crypt-key nil, passphrase "secret")
    local lines = vim.list_slice(SAMPLE, 1, 12)
    vim.list_extend(lines, {
      "-----BEGIN PGP MESSAGE-----",
      "",
      "jA0ECQMIkNjbrRrbvfn80mABVGV15nu5Iag/HgOzdDr3dtq1HTkNqHu2MN2nc6ow",
      "M20SCnXp+ms5M6XOfYFrfGbgQu0tfV3ABb+SCBxg0aVo7N7oLhE3ICsZ8oo6nP6q",
      "+j0WTVERc+Jp1FStpvp6rcs=",
      "=MaRQ",
      "-----END PGP MESSAGE-----",
    })
    vim.list_extend(lines, vim.list_slice(SAMPLE, 17))
    local buf = org_buffer(lines, { 4, 0 })
    ok(crypt.decrypt_entry())
    eq(SAMPLE, buf_lines(buf))
  end)

  it("ignores the indentation of the message", function()
    local buf = org_buffer({ "* S", "body", "* T" }, { 1, 0 })
    crypt.encrypt_entry()
    local lines = buf_lines(buf)
    for i = 2, #lines - 1 do
      lines[i] = "  " .. lines[i]
    end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    ok(crypt.at_encrypted_entry())
    crypt.decrypt_entry()
    eq({ "* S", "body", "* T" }, buf_lines(buf))
  end)

  it("demotes decrypted headings when the entry was demoted", function()
    local buf = org_buffer({ "** A", "text", "*** B", "b" }, { 1, 0 })
    crypt.encrypt_entry()
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "*** A" })
    crypt.decrypt_entry()
    eq({ "*** A", "text", "**** B", "b" }, buf_lines(buf))
  end)

  it("fails without a passphrase and keeps the text", function()
    local buf = org_buffer(SAMPLE, { 4, 0 })
    passphrase = nil
    local notify = vim.notify
    vim.notify = function() end
    local res = crypt.encrypt_entry()
    vim.notify = notify
    ok(not res)
    eq(SAMPLE, buf_lines(buf))
  end)

  it("asks again after a wrong passphrase", function()
    local buf = org_buffer({ "* S", "body" }, { 1, 0 })
    crypt.encrypt_entry()
    local answers = { "wrong", "secret" }
    prompts = {}
    crypt.read_passphrase = function(prompt)
      prompts[#prompts + 1] = prompt
      return table.remove(answers, 1)
    end
    local notify = vim.notify
    vim.notify = function() end
    local res = crypt.decrypt_entry()
    vim.notify = notify
    ok(not res, "one retry per prompt")
    eq(1, #prompts)
    ok(crypt.decrypt_entry())
    eq({ "* S", "body" }, buf_lines(buf))
  end)

  it("warns before the first headline", function()
    org_buffer({ "text", "* H" }, { 1, 0 })
    local notify = vim.notify
    vim.notify = function() end
    local res = crypt.encrypt_entry()
    vim.notify = notify
    ok(not res)
    eq(nil, crypt.decrypt_entry())
  end)

  it("decrypts on reveal (org-fold-reveal-start-hook)", function()
    local buf = org_buffer({ "* S", "body" }, { 1, 0 })
    crypt.encrypt_entry()
    require("org.fold").reveal(false)
    eq({ "* S", "body" }, buf_lines(buf))
  end)

  it("turns off swap and undo files before decrypting (disable_auto_save)", function()
    local buf = org_buffer({ "* S", "body" }, { 1, 0 })
    crypt.encrypt_entry()
    vim.bo[buf].undofile = true
    config.opts.crypt.disable_auto_save = false
    crypt.decrypt_entry()
    ok(vim.bo[buf].undofile, "false keeps them")
    crypt.encrypt_entry()
    config.opts.crypt.disable_auto_save = "ask"
    local confirm = require("org.utils").confirm
    local asked
    require("org.utils").confirm = function(msg)
      asked = msg
      return true
    end
    crypt.decrypt_entry()
    require("org.utils").confirm = confirm
    ok(asked and asked:find("leakage", 1, true))
    ok(not vim.bo[buf].undofile)
    eq({ "* S", "body" }, buf_lines(buf))
  end)

  it("encrypts before saving with encrypt_on_save", function()
    local path = vim.fn.tempname() .. ".org"
    local lines = { "* Plain", "visible", "* S :crypt:", "hidden" }
    local buf = org_buffer(lines, { 1, 0 })
    vim.api.nvim_buf_set_name(buf, path)
    require("org.buffer").attach(buf)
    vim.cmd("silent write")
    eq(lines, vim.fn.readfile(path), "off by default")
    config.opts.crypt.encrypt_on_save = true
    vim.cmd("silent write")
    local disk = vim.fn.readfile(path)
    eq("-----BEGIN PGP MESSAGE-----", disk[4])
    ok(not table.concat(disk, "\n"):find("hidden", 1, true))
    -- like Emacs, the buffer stays encrypted after saving
    eq(disk, buf_lines(buf))
    -- a failed encryption aborts the write
    crypt.decrypt_entries()
    vim.api.nvim_buf_set_lines(buf, 3, 4, false, { "hidden 2" })
    passphrase = nil
    local notify = vim.notify
    vim.notify = function() end
    local okw = pcall(vim.cmd, "silent write")
    vim.notify = notify
    ok(not okw)
    eq(disk, vim.fn.readfile(path))
    vim.bo[buf].modified = false
    vim.fn.delete(path)
  end)

  if have_key then
    it("encrypts for the CRYPTKEY property when crypt.key is a string", function()
      config.opts.crypt.key = ""
      local lines = { "* S", ":PROPERTIES:", ":CRYPTKEY: test@example.com", ":END:", "body" }
      local buf = org_buffer(lines, { 1, 0 })
      crypt.encrypt_entry()
      local b = blocks(buf)
      eq(5, b[1][1])
      ok(packets(buf, b[1][1], b[1][2]):find("pubkey enc packet", 1, true))
      crypt.decrypt_entry()
      eq(lines, buf_lines(buf))
      eq({}, prompts)
    end)

    it("ignores CRYPTKEY when crypt.key is false", function()
      local lines = { "* S", ":PROPERTIES:", ":CRYPTKEY: test@example.com", ":END:", "body" }
      local buf = org_buffer(lines, { 1, 0 })
      crypt.encrypt_entry()
      local b = blocks(buf)
      ok(packets(buf, b[1][1], b[1][2]):find("symkey enc packet", 1, true))
    end)

    it("uses crypt.key, CRYPTKEY nil and unknown keys fall back to symmetric", function()
      config.opts.crypt.key = "test@example.com"
      local buf = org_buffer({ "* A", "a", "* B", ":PROPERTIES:", ":CRYPTKEY: nil", ":END:", "b" }, { 1, 0 })
      crypt.encrypt_entry()
      local b = blocks(buf)
      ok(packets(buf, b[1][1], b[1][2]):find("pubkey enc packet", 1, true))
      eq({}, prompts)
      vim.api.nvim_win_set_cursor(0, { b[1][2] + 1, 0 })
      crypt.encrypt_entry()
      b = blocks(buf)
      ok(packets(buf, b[2][1], b[2][2]):find("symkey enc packet", 1, true))
      eq(2, #prompts)
      eq({}, crypt.list_keys("nobody@example.com"))
      eq({}, crypt.list_keys(""))
      eq(1, #crypt.list_keys("test@example.com"))
    end)
  end

  it("restores the prompt function", function()
    crypt.read_passphrase = read_passphrase
    ok(type(crypt.read_passphrase) == "function")
  end)
end)
