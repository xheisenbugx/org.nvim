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

local config = require("org.config")
local files = require("org.files")
local utils = require("org.utils")

local M = {}

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
  vim.list_extend(cmd, { "-aes-256-cbc", "-salt", "-pass", "pass:" .. M.encryption_password(), "-in", infile })
  vim.list_extend(cmd, { "-out", outfile })
  local res = vim.system(cmd, { text = true }):wait()
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

---------------------------------------------------------------------------
-- Setup and file list
---------------------------------------------------------------------------

--- Check the configuration (org-mobile-check-setup). Errors with a message.
function M.check_setup()
  if not utils.is_dir(org_dir()) then
    error("Please set `org_directory' to the directory where your org files live", 0)
  end
  if not staging_dir() or not utils.is_dir(staging_dir()) then
    error("Option `mobile.directory' must point to an existing directory", 0)
  end
  local inbox = inbox_path()
  if not inbox or not utils.is_dir(vim.fn.fnamemodify(inbox, ":h")) then
    error("Option `mobile.inbox_for_pull' must point to a file in an existing directory", 0)
  end
  if not M.checksum_binary() then
    error("No executable found to compute checksums", 0)
  end
  if cfg().use_encryption then
    if not M.encryption_password():match("%S") then
      error("To use encryption, you must set `mobile.encryption_password'", 0)
    end
    if vim.fn.executable("openssl") == 0 then
      error("OpenSSL is needed to encrypt files", 0)
    end
  end
end

local function emacs_match(re, s)
  local ok, vre = pcall(function()
    return vim.regex(require("org.agenda.search").emacs_regexp(re))
  end)
  if not ok then
    ok, vre = pcall(vim.regex, re)
  end
  return ok and vre:match_str(s) ~= nil
end

--- The files to stage (org-mobile-files-alist): `{ file, link }` pairs,
--- `link` being the name relative to `org_directory` (or the file name
--- when the file is elsewhere).
---@return { file: string, link: string }[]
function M.files_alist()
  local out_files = {}
  local extra = (config.opts.agenda or {}).text_search_extra_files or {}
  local spec = cfg().files or { "agenda_files" }
  if type(spec) == "string" then
    spec = { spec }
  end
  local with_archives = vim.tbl_contains(spec, "text_search_extra_files") and vim.tbl_contains(extra, "agenda-archives")
  for _, f in ipairs(spec) do
    if f == "agenda_files" or f == "org-agenda-files" then
      vim.list_extend(out_files, files.agenda_file_paths())
      if with_archives then
        for _, af in ipairs(require("org.agenda.view").archive_files(files.agenda_files())) do
          out_files[#out_files + 1] = af.filename
        end
      end
    elseif f == "text_search_extra_files" or f == "org-agenda-text-search-extra-files" then
      for _, e in ipairs(extra) do
        if e ~= "agenda-archives" then
          out_files[#out_files + 1] = e
        end
      end
    elseif type(f) == "string" then
      local p = utils.expand(f, org_dir())
      if utils.is_dir(p) then
        local names = {}
        for name, t in vim.fs.dir(p) do
          if t ~= "directory" and name:match("%.org$") then
            names[#names + 1] = name
          end
        end
        table.sort(names)
        for _, name in ipairs(names) do
          out_files[#out_files + 1] = p .. "/" .. name
        end
      elseif utils.exists(p) then
        out_files[#out_files + 1] = p
      end
    end
  end
  local exclude = cfg().files_exclude_regexp
  local base = org_dir()
  local base_real = (vim.uv.fs_realpath(base) or base):gsub("/$", "") .. "/"
  local seen, out = {}, {}
  for _, file in ipairs(out_files) do
    file = utils.expand(file, base)
    if not (type(exclude) == "string" and exclude ~= "" and emacs_match(exclude, file)) then
      local real = vim.uv.fs_realpath(file) or file
      if not seen[real] then
        seen[real] = true
        local link
        if real:sub(1, #base_real) == base_real then
          link = real:sub(#base_real + 1)
        else
          link = vim.fn.fnamemodify(real, ":t")
        end
        out[#out + 1] = { file = file, link = link }
      end
    end
  end
  return out
end

---------------------------------------------------------------------------
-- index.org
---------------------------------------------------------------------------

local function strip_key(kw)
  return (kw:gsub("%(.*$", ""))
end

local function delete_all(list, remove)
  local set = {}
  for _, x in ipairs(remove) do
    set[x] = true
  end
  return vim.tbl_filter(function(x)
    return not set[x]
  end, list)
end

local function uniq(list)
  local seen, out = {}, {}
  for _, x in ipairs(list) do
    if not seen[x] then
      seen[x] = true
      out[#out + 1] = x
    end
  end
  return out
end

--- The lines of index.org (org-mobile-create-index-file).
---@param alist { file: string, link: string }[]
---@param has_agendas boolean
function M.index_lines(alist, has_agendas)
  local sorted = vim.list_slice(alist)
  table.sort(sorted, function(a, b)
    return a.link < b.link
  end)
  local all_kw, done_kw, all_tags = {}, {}, {}
  for _, e in ipairs(sorted) do
    local f = files.get(e.file)
    if f then
      for _, kw in ipairs(f.settings.todo.keywords) do
        all_kw[#all_kw + 1] = kw.name
        if kw.done then
          done_kw[#done_kw + 1] = kw.name
        end
      end
      for _, d in ipairs(f:tag_definitions()) do
        if d.name then
          all_tags[#all_tags + 1] = d.name
        end
      end
      for _, t in ipairs(f.settings.filetags) do
        all_tags[#all_tags + 1] = t
      end
      for _, hl in ipairs(f.headlines) do
        vim.list_extend(all_tags, hl.tags)
      end
    end
  end
  local done_kwds = uniq(done_kw)
  local todo_kwds = delete_all(uniq(all_kw), done_kwds)
  local lines = { "#+READONLY" }
  for _, seq in ipairs(require("org.todo_keywords").normalize(config.opts.todo_keywords)) do
    local kwds = {}
    for tok in seq:gmatch("%S+") do
      kwds[#kwds + 1] = strip_key(tok)
    end
    lines[#lines + 1] = "#+TODO: " .. table.concat(kwds, " ")
    local dwds = {}
    local bar
    for i, k in ipairs(kwds) do
      if k == "|" then
        bar = i
      end
    end
    if bar then
      dwds = vim.list_slice(kwds, bar)
    elseif #kwds > 0 then
      dwds = { kwds[#kwds] }
    end
    local twds = delete_all(kwds, dwds)
    todo_kwds = delete_all(todo_kwds, twds)
    done_kwds = delete_all(done_kwds, dwds)
  end
  if #todo_kwds > 0 or #done_kwds > 0 then
    lines[#lines + 1] = "#+TODO: " .. table.concat(todo_kwds, " ") .. " | " .. table.concat(done_kwds, " ")
  end
  local def_tags = {}
  for _, spec in ipairs(config.opts.tags or {}) do
    for tok in spec:gmatch("%S+") do
      if tok ~= "\\n" then
        def_tags[#def_tags + 1] = strip_key(tok)
      end
    end
  end
  local tags = delete_all(uniq(all_tags), def_tags)
  table.sort(tags, function(a, b)
    return a:lower() < b:lower()
  end)
  local all = vim.list_extend(vim.list_slice(def_tags), tags)
  lines[#lines + 1] = "#+TAGS: " .. table.concat(all, " ")
  lines[#lines + 1] = "#+ALLPRIORITIES: " .. (cfg().allpriorities or "A B C")
  if has_agendas then
    lines[#lines + 1] = "* [[file:agendas.org][Agenda Views]]"
  end
  for _, e in ipairs(sorted) do
    lines[#lines + 1] = string.format("* [[file:%s][%s]]", e.link, e.link)
  end
  return lines
end

---------------------------------------------------------------------------
-- agendas.org
---------------------------------------------------------------------------

local SKIP_TYPES = {
  search = true,
  stuck = true,
  ["stuck-projects"] = true,
  stuck_projects = true,
  todo_tree = true,
  ["todo-tree"] = true,
  tags_tree = true,
  ["tags-tree"] = true,
  occur_tree = true,
  ["occur-tree"] = true,
}
local MATCH_TYPES = { todo = true, tags = true, tags_todo = true, ["tags-todo"] = true }
local BLOCK_TYPES = {
  agenda = true,
  alltodo = true,
  todo = true,
  tags = true,
  tags_todo = true,
  ["tags-todo"] = true,
  search = true,
  stuck = true,
}

local function match_of(b)
  if b.match and b.match ~= "" then
    return b.match
  end
  local kws = b.keywords
  if type(kws) == "table" then
    return table.concat(kws, "|")
  end
  return kws
end

--- The blocks of the agenda written to agendas.org
--- (org-mobile-sumo-agenda-command), each with its `<after>KEYS=... TITLE:
--- ...</after>` title in `mobile_title`.
---@return table[]
function M.sumo_blocks()
  local agenda = require("org.agenda")
  local custom = (config.opts.agenda or {}).custom_commands or {}
  local keys = vim.tbl_keys(custom)
  table.sort(keys)
  local custom_list = {}
  for _, k in ipairs(keys) do
    local cmd = custom[k]
    if type(cmd) == "table" and (cmd.blocks or cmd.types) then
      custom_list[#custom_list + 1] = {
        key = k,
        desc = cmd.description or "",
        blocks = cmd.blocks or cmd.types,
        settings = cmd.settings or cmd.options,
      }
    elseif type(cmd) == "table" and cmd.type then
      local block = vim.tbl_extend("force", {}, cmd)
      block.description, block.settings, block.options = nil, nil, nil
      custom_list[#custom_list + 1] = {
        key = k,
        desc = cmd.description or "",
        type = cmd.type,
        block = block,
        settings = cmd.settings or cmd.options,
      }
    end
  end
  local default_list = {
    { key = "a", desc = "Agenda", type = "agenda", block = { type = "agenda" } },
    { key = "t", desc = "All TODO", type = "alltodo", block = { type = "todo" } },
  }
  local function find(list, key)
    for _, e in ipairs(list) do
      if e.key == key then
        return e
      end
    end
  end
  local mode = cfg().agendas or "all"
  local list
  if mode == "custom" then
    list = custom_list
  elseif mode == "default" then
    list = default_list
  elseif mode == "all" then
    list = vim.list_slice(custom_list)
    if not find(list, "t") then
      table.insert(list, 1, { key = "t", desc = "ALL TODO", type = "alltodo", block = { type = "todo" } })
    end
    if not find(list, "a") then
      table.insert(list, 1, default_list[1])
    end
  elseif type(mode) == "table" then
    local both = vim.list_extend(vim.list_slice(custom_list), default_list)
    list = {}
    for _, k in ipairs(mode) do
      list[#list + 1] = find(both, k)
    end
  else
    list = {}
  end
  local mobile_files = vim.tbl_map(function(e)
    return e.file
  end, M.files_alist())
  local out = {}
  local function add(block, settings, title)
    local nb = agenda.normalize_block(block, settings)
    nb.files = nb.files or nb.org_agenda_files or mobile_files
    nb.mobile_title = "<after>" .. title .. "</after>"
    out[#out + 1] = nb
  end
  for _, e in ipairs(list) do
    local t = e.type
    if e.blocks then
      local n = 0
      for _, b in ipairs(e.blocks) do
        if type(b) == "table" and BLOCK_TYPES[b.type or "agenda"] then
          n = n + 1
          local atitle = e.desc ~= "" and e.desc or (match_of(b) or "")
          add(b, e.settings, string.format("KEYS=%s#%d TITLE: %s", e.key, n, atitle))
        end
      end
    elseif type(t) == "string" and not SKIP_TYPES[t] and BLOCK_TYPES[t] then
      if not (MATCH_TYPES[t] and not (match_of(e.block) or ""):match("%S")) then
        add(e.block, e.settings, string.format("KEYS=%s TITLE: %s", e.key, e.desc ~= "" and e.desc or t))
      end
    end
  end
  return out
end

local function escape_olp(s)
  return (
    s:gsub("[%%:/]", function(c)
      if c == "%" then
        return c
      end
      return string.format("%%%02X", c:byte())
    end)
  )
end

--- The olp: link of a headline (org-mobile-get-outline-path-link).
function M.outline_path_link(hl)
  local path = {}
  local p = hl.parent
  while p do
    table.insert(path, 1, escape_olp(p.title or ""))
    p = p.parent
  end
  return "olp:"
    .. escape_olp(vim.fn.fnamemodify(hl.file.filename or "", ":t"))
    .. ":"
    .. table.concat(path, "/")
    .. "/"
    .. escape_olp(hl.title or "")
end

--- The body of an entry for agendas.org (org-agenda-get-some-entry-text
--- with `planning` kept): drawers removed, common indentation stripped,
--- every line prefixed with `indent`, at most `max` lines.
function M.entry_text(hl, max, indent)
  local src = vim.list_slice(hl.file.lines, hl.line + 1, hl.body_end)
  local lines = {}
  local in_drawer = false
  for _, l in ipairs(src) do
    if in_drawer then
      if l:match("^%s*:END:") then
        in_drawer = false
      end
    elseif l:match("^%s*:[%w_%-]+:%s*$") then
      in_drawer = true
    else
      lines[#lines + 1] = (l:gsub("\t", "        "))
    end
  end
  -- trailing whitespace of the whole text
  while #lines > 0 and not lines[#lines]:match("%S") do
    table.remove(lines)
  end
  if #lines > 0 then
    lines[#lines] = lines[#lines]:gsub("%s+$", "")
  end
  local ind
  for _, l in ipairs(lines) do
    if l:match("%S") then
      local n = #l:match("^ *")
      ind = ind and math.min(ind, n) or n
    end
  end
  for i, l in ipairs(lines) do
    if l:match("%S") then
      lines[i] = l:sub((ind or 0) + 1)
    end
    lines[i] = indent .. lines[i]
  end
  while #lines > 0 and not lines[1]:match("%S") do
    table.remove(lines, 1)
  end
  while #lines > max do
    table.remove(lines)
  end
  return lines
end

local function block_kind(t)
  if t == "agenda" then
    return "agenda"
  elseif t == "todo" then
    return "todo"
  elseif t == "search" then
    return "search"
  end
  return "tags"
end

local function short_heading(block)
  if block.header ~= nil then
    return nil
  end
  if block.type == "todo" then
    local kws = block.keywords
    if type(kws) == "string" then
      kws = vim.split(kws, "[|%s]+", { trimempty = true })
    end
    return "ToDo: " .. ((kws and #kws > 0) and table.concat(kws, "|") or "ALL")
  elseif block.type == "tags" or block.type == "tags_todo" then
    return "Match: " .. (block.match or "")
  elseif block.type == "search" then
    return "Search words: " .. (block.match or "")
  end
end

--- Split a rendered item line into the heading part and its prefix.
local function split_item_line(line, it, kind)
  local ok, prefix = pcall(function()
    return require("org.agenda.render").prefix(it, kind)
  end)
  local pl
  if ok and type(prefix) == "string" and line:sub(1, #prefix) == prefix then
    pl = #prefix
  else
    local head = it.todo or it.title
    local s = head and line:find(head, 1, true)
    pl = s and s - 1 or 0
  end
  return vim.trim(line:sub(pl + 1)), vim.trim(line:sub(1, pl))
end

--- Convert the rendered SUMO agenda into agendas.org lines
--- (org-mobile-write-agenda-for-mobile).
local function agenda_file_lines(S, lines, blocks)
  local starts = S.block_starts or { 1 }
  local header_line, sep_line, block_at = {}, {}, {}
  for i, s in ipairs(starts) do
    if i > 1 then
      sep_line[s - 1] = true
    end
    if not S.day_lines[s] and not S.line_items[s] and lines[s] and lines[s]:match("%S") then
      header_line[s] = i
    end
  end
  local cur = 0
  for l = 1, #lines do
    if starts[cur + 1] and l >= starts[cur + 1] then
      cur = cur + 1
    end
    block_at[l] = cur
  end
  local out = { "#+READONLY" }
  local in_date = false
  for l, line in ipairs(lines) do
    local block = blocks[block_at[l]] or {}
    local it = S.line_items[l]
    if not line:match("%S") then
      out[#out + 1] = ""
    elseif sep_line[l] then
      out[#out + 1] = ""
    elseif header_line[l] then
      in_date = false
      out[#out + 1] = "* " .. (short_heading(block) or line) .. (block.mobile_title or "")
    elseif S.day_lines[l] then
      in_date = true
      out[#out + 1] = "** " .. line
    elseif it and it.headline then
      local text, prefix = split_item_line(line, it, block_kind(block.type))
      out[#out + 1] = (in_date and "***  " or "**  ") .. text .. "<before>" .. prefix .. "</before>"
      if it.type ~= "sexp" then
        local body = M.entry_text(it.headline, 10, "   ")
        if #body == 0 then
          body = { "" }
        end
        vim.list_extend(out, body)
        local hl = it.headline
        local id = hl.properties.ID
        if not (id and id:match("%S")) then
          id = M.outline_path_link(hl)
        end
        vim.list_extend(out, { "   :PROPERTIES:", "   :ORIGINAL_ID: " .. id, "   :END:" })
      end
      out[#out + 1] = ""
    else
      out[#out + 1] = line
    end
  end
  return out
end

--- Temporarily merge `overrides` into `config.opts.agenda` while `fn` runs.
local function with_agenda_options(overrides, fn)
  local acfg = config.opts.agenda
  local saved = {}
  for k, v in pairs(overrides) do
    saved[k] = { acfg[k] }
    acfg[k] = v
  end
  local ok, err = pcall(fn)
  for k, v in pairs(saved) do
    acfg[k] = v[1]
  end
  if not ok then
    error(err, 0)
  end
end

--- Give every entry of the open SUMO agenda an ID
--- (org-mobile-force-id-on-agenda-items). Returns the changed buffers.
local function force_ids(view)
  local S = view.state
  local by_buf = {}
  for _, it in pairs(S.line_items) do
    local hl = it.headline
    if hl and it.type ~= "sexp" and not (hl.properties.ID and hl.properties.ID:match("%S")) then
      local target = view.resolve_target(it)
      if target then
        by_buf[target.bufnr] = by_buf[target.bufnr] or {}
        by_buf[target.bufnr][target.lnum] = true
      end
    end
  end
  local id = require("org.id")
  local bufs = {}
  for bufnr, set in pairs(by_buf) do
    local lnums = vim.tbl_keys(set)
    table.sort(lnums, function(a, b)
      return a > b
    end)
    for _, lnum in ipairs(lnums) do
      id.get_create({ bufnr = bufnr, lnum = lnum })
    end
    bufs[#bufs + 1] = bufnr
  end
  return bufs
end

--- Create agendas.org in the staging directory (org-mobile-create-sumo-agenda).
--- Returns its checksum, or nil when there is no agenda to write.
function M.create_sumo_agenda()
  local blocks = M.sumo_blocks()
  if #blocks == 0 then
    return nil
  end
  require("org.agenda.highlights").setup()
  local view = require("org.agenda.view")
  local content
  with_agenda_options({ compact_blocks = false, sticky = true, window = "float" }, function()
    view.open({ blocks = blocks, multi = true, key = "mobile-sumo", title = "SUMO" }, {})
    local ok, err = pcall(function()
      if cfg().force_id_on_agenda_items ~= false then
        for _, b in ipairs(force_ids(view)) do
          utils.save_buffer_or_warn(b)
        end
        view.refresh()
      end
      local S = view.state
      local lines = vim.api.nvim_buf_get_lines(S.buf, 0, -1, false)
      content = text_of(agenda_file_lines(S, lines, blocks))
    end)
    pcall(view.quit, true)
    if not ok then
      error(err, 0)
    end
  end)
  stage_write(staging_dir() .. "/agendas.org", content)
  return M.md5(content)
end

---------------------------------------------------------------------------
-- Push
---------------------------------------------------------------------------

--- Checksum of a file with `mobile.checksum_binary`.
local function file_checksum(path)
  local res = vim.system({ M.checksum_binary(), path }, { text = true }):wait()
  for hex in (res.stdout or ""):gmatch("%x+") do
    if #hex >= 30 then
      return hex:sub(1, 40)
    end
  end
end

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

---------------------------------------------------------------------------
-- Pull
---------------------------------------------------------------------------

--- Set the checksum of mobileorg.org in checksums.dat to that of `content`
--- (org-mobile-update-checksum-for-capture-file).
local function update_capture_checksum(content)
  local path = staging_dir() .. "/checksums.dat"
  local lines = utils.readfile(path)
  if not lines then
    return
  end
  for i, l in ipairs(lines) do
    local pre, hex, rest = l:match("^(.-)(%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x+)(.*)$")
    if hex and vim.trim(rest):sub(-#M.capture_file) == M.capture_file then
      lines[i] = pre .. M.md5(content) .. rest
      write_raw(path, text_of(lines))
      return
    end
  end
end

--- Move the contents of mobileorg.org to the end of the inbox
--- (org-mobile-move-capture). Returns the inbox buffer and the first new
--- line, or nil when there was nothing new.
function M.move_capture()
  local capture = staging_dir() .. "/" .. M.capture_file
  local content = stage_read(capture) or ""
  content = content:gsub("\r\n", "\n")
  if not content:match("%S") then
    return nil
  end
  local bufnr = utils.load_buffer(inbox_path())
  local new = vim.split(content, "\n", { plain = true })
  if new[#new] == "" then
    table.remove(new)
  end
  local n = vim.api.nvim_buf_line_count(bufnr)
  local first = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1]
  local start
  if n == 1 and first == "" then
    vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, new)
    start = 1
  else
    vim.api.nvim_buf_set_lines(bufnr, n, n, false, new)
    start = n + 1
  end
  utils.save_buffer_or_warn(bufnr)
  stage_write(capture, "")
  update_capture_checksum("")
  return bufnr, start
end

--- Is `s` nil or blank?
local function blank(s)
  return s == nil or not s:match("%S")
end

--- Are two tag lists the same set (org-mobile-tags-same-p)?
function M.tags_same(a, b)
  a, b = a or {}, b or {}
  return #delete_all(a, b) == 0 and #delete_all(b, a) == 0
end

local function normalize_body(s)
  local out = {}
  for _, l in ipairs(vim.split(vim.trim(s), "\n", { plain = true })) do
    l = vim.trim(l)
    if l ~= "" then
      out[#out + 1] = l
    end
  end
  return table.concat(out, "\n")
end

--- Are two bodies visually equal (org-mobile-bodies-same-p)?
function M.bodies_same(a, b)
  if a == nil and b == nil then
    return true
  elseif a == nil or b == nil then
    return false
  end
  return normalize_body(a) == normalize_body(b)
end

local function forced(kind)
  local f = cfg().force_mobile_change
  return f == true or (type(f) == "table" and vim.tbl_contains(f, kind))
end

local function split_lines(s)
  local lines = vim.split(s, "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines)
  end
  return lines
end

--- The headline at target, only when target is on the headline line.
local function heading_at(target)
  local f = files.get_buffer(target.bufnr)
  local hl = f:headline_at(target.lnum)
  if hl and hl.line == target.lnum then
    return hl, f
  end
  return nil, f
end

--- End (exclusive) of the subtree starting at `lnum` of `lines`, trailing
--- blank lines included (org-end-of-subtree t t).
local function subtree_end(lines, lnum)
  local level = #(lines[lnum]:match("^(%*+)") or "*")
  for i = lnum + 1, #lines do
    local stars = lines[i]:match("^(%*+)%s")
    if stars and #stars <= level then
      return i
    end
  end
  return #lines + 1
end

--- Find the entry of a link from the mobile application
--- (org-mobile-locate-entry): `id:ID`, `olp:FILE:PATH/TO/HEADING` or
--- `olp:FILE` (a new line at the end of the file, for top-level additions).
--- Returns a target `{ bufnr, lnum }` or nil; errors when an outline path
--- does not exist.
---@param link string
---@return { bufnr: integer, lnum: integer }|nil
function M.locate_entry(link)
  local decode = require("org.protocol").decode
  local id = link:match("^id:(.*)$")
  if id then
    local r = require("org.id").find(id)
    if not r then
      return nil
    end
    local bufnr = r.bufnr or utils.load_buffer(r.filename)
    local hl = files.get_buffer(bufnr):find_by_id(id)
    return hl and { bufnr = bufnr, lnum = hl.line } or nil
  end
  local file, path = link:match("^olp:(.-):(.*)$")
  if not file then
    file = link:match("^olp:(.*)$")
    if not file then
      return nil
    end
    local bufnr = utils.load_buffer(utils.expand(decode(file), org_dir()))
    local n = vim.api.nvim_buf_line_count(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, n, n, false, { "" })
    return { bufnr = bufnr, lnum = n + 1 }
  end
  local fpath = utils.expand(decode(file), org_dir())
  if not utils.exists(fpath) then
    error("File not found: " .. fpath, 0)
  end
  local bufnr = utils.load_buffer(fpath)
  local nodes = files.get_buffer(bufnr).children
  local found
  local level = 0
  for part in path:gmatch("[^/]+") do
    part = decode(part)
    level = level + 1
    found = nil
    for _, hl in ipairs(nodes) do
      if vim.trim(hl.title or "") == vim.trim(part) then
        found = hl
        break
      end
    end
    if not found then
      error(string.format("Heading not found on level %d: %s", level, part), 0)
    end
    nodes = found.children
  end
  return found and { bufnr = bufnr, lnum = found.line } or nil
end

--- Apply an edit from the mobile application to the entry at target
--- (org-mobile-edit). `what` is "todo", "tags", "priority", "heading",
--- "body", "addheading", "refile", "delete", "archive" or
--- "archive-sibling". Errors (with a message) when the entry changed on
--- the computer too, unless `mobile.force_mobile_change` says otherwise.
---@param what string
---@param old string|nil
---@param new string|nil
---@param target { bufnr: integer, lnum: integer }
function M.edit(what, old, new, target)
  local hl = heading_at(target)
  local bufnr = target.bufnr
  if what == "todo" or what == "todostate" then
    local current = hl and hl.todo
    if new == "DONEARCHIVE" then
      local todo_cfg = files.get_buffer(bufnr).settings.todo
      require("org.todo").change_state(target, todo_cfg:first_done(current), { inhibit_note = true })
      require("org.archive").archive_subtree(target)
    elseif new == current then
      return true
    elseif current == old or forced("todo") then
      require("org.todo").change_state(target, new, { inhibit_note = true })
      return true
    else
      error(string.format('State before change was expected as "%s", but is "%s"', old or "nil", current or "nil"), 0)
    end
  elseif what == "tags" then
    local current = hl and hl.tags or {}
    local new1 = new and vim.split(new, ":+", { trimempty = true }) or {}
    local old1 = old and vim.split(old, ":+", { trimempty = true }) or {}
    if M.tags_same(current, new1) then
      return true
    elseif M.tags_same(current, old1) or forced("tags") then
      require("org.edit").update_headline(bufnr, target.lnum, { tags = new1 })
      return true
    else
      local msg = 'Tags before change were expected as "%s", but are "%s"'
      error(string.format(msg, old or "", table.concat(current, ":")), 0)
    end
  elseif what == "priority" then
    if not hl then
      return nil
    end
    local current = hl.priority
    if current == new then
      return true
    elseif current == old or forced("priority") then
      require("org.priority").set(target, new or " ")
      return true
    else
      error(string.format("Priority was expected to be %s, but is %s", old or "nil", current or "nil"), 0)
    end
  elseif what == "heading" then
    if not hl then
      return nil
    end
    local current = hl.title
    if current == new then
      return true
    elseif current == old or forced("heading") then
      require("org.edit").update_headline(bufnr, target.lnum, { title = new })
      return true
    else
      error("Heading changed in the mobile device and on the computer", 0)
    end
  elseif what == "addheading" then
    local new_lines = split_lines(new or "")
    if #new_lines == 0 then
      new_lines = { "" }
    end
    if hl then
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local e = subtree_end(lines, hl.line)
      while e - 1 > hl.line and not lines[e - 1]:match("%S") do
        e = e - 1
      end
      new_lines[1] = string.rep("*", hl.level + 1) .. " " .. new_lines[1]
      vim.api.nvim_buf_set_lines(bufnr, e - 1, e - 1, false, new_lines)
    else
      new_lines[1] = "* " .. new_lines[1]
      vim.api.nvim_buf_set_lines(bufnr, target.lnum - 1, target.lnum, false, new_lines)
    end
    return true
  elseif what == "refile" then
    if not hl then
      error("Not at a heading", 0)
    end
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local s, e = hl.line, subtree_end(lines, hl.line)
    local sub = vim.list_slice(lines, s, e - 1)
    local dest = M.locate_entry(new or "")
    if not dest then
      error("Refile target not found: " .. tostring(new), 0)
    end
    local edit = require("org.edit")
    local dhl = heading_at(dest)
    local at
    if dhl then
      local dlines = vim.api.nvim_buf_get_lines(dest.bufnr, 0, -1, false)
      at = subtree_end(dlines, dhl.line)
      sub = edit.relevel(sub, dhl.level + 1)
      vim.api.nvim_buf_set_lines(dest.bufnr, at - 1, at - 1, false, sub)
    else
      at = dest.lnum
      sub = edit.relevel(sub, 1)
      vim.api.nvim_buf_set_lines(dest.bufnr, at - 1, at, false, sub)
      at = at + 1
    end
    if dest.bufnr == bufnr and at <= s then
      local shift = dhl and #sub or #sub - 1
      s, e = s + shift, e + shift
    end
    vim.api.nvim_buf_set_lines(bufnr, s - 1, e - 1, false, {})
    return true
  elseif what == "delete" then
    if not hl then
      return nil
    end
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    vim.api.nvim_buf_set_lines(bufnr, hl.line - 1, subtree_end(lines, hl.line) - 1, false, {})
    return true
  elseif what == "archive" then
    require("org.archive").archive_subtree(target)
    return true
  elseif what == "archive-sibling" then
    require("org.archive").archive_to_sibling(target)
    return true
  elseif what == "body" then
    if not hl then
      return nil
    end
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local nxt = #lines + 1
    for i = hl.line + 1, #lines do
      if lines[i]:match("^%*+%s") then
        nxt = i
        break
      end
    end
    local current = text_of(vim.list_slice(lines, hl.line + 1, nxt - 1))
    if blank(current) then
      current = nil
    end
    if M.bodies_same(current, new) then
      return true
    elseif M.bodies_same(current, old) or forced("body") then
      vim.api.nvim_buf_set_lines(bufnr, hl.line, nxt - 1, false, split_lines(new or ""))
      return true
    else
      error("Body was changed in the mobile device and on the computer", 0)
    end
  end
end

--- Flag the entry at target with `note` (the `F()` action).
local function flag(target, note)
  local hl = heading_at(target)
  if not hl then
    error("No heading to flag", 0)
  end
  if not vim.tbl_contains(hl.tags, "FLAGGED") then
    local tags = vim.list_extend(vim.deepcopy(hl.tags), { "FLAGGED" })
    require("org.edit").update_headline(target.bufnr, target.lnum, { tags = tags })
  end
  require("org.edit").set_property(target.bufnr, target.lnum, "THEFLAGGINGNOTE", (note:gsub("\n", "\\n")))
end

--- Write `#+LAST_MOBILE_CHANGE:` at the top of buffer `bufnr`, so that its
--- checksum changes (org-mobile-timestamp-buffer). Returns the line number
--- of a newly inserted line, or nil.
local function timestamp_buffer(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local stamp = "#+LAST_MOBILE_CHANGE: " .. os.date("%Y-%m-%d %H:%M:%S")
  for i, l in ipairs(lines) do
    local ind = l:match("^([ \t]*)#%+[Ll][Aa][Ss][Tt]_[Mm][Oo][Bb][Ii][Ll][Ee]_[Cc][Hh][Aa][Nn][Gg][Ee]:")
    if ind then
      vim.api.nvim_buf_set_lines(bufnr, i - 1, i, false, { ind .. stamp })
      return nil
    end
  end
  local at = (lines[1] and lines[1]:match("%-%*%-.*%-%*%-")) and 1 or 0
  vim.api.nvim_buf_set_lines(bufnr, at, at, false, { stamp })
  return at + 1
end

--- The actions of `F(action:data)` entries (org-mobile-action-alist):
--- `mobile.action_alist` entries (functions `fun(data, old, new, target)`)
--- added to the built-in "edit".
local function actions()
  local out = { edit = M.edit }
  for k, v in pairs(cfg().action_alist or {}) do
    out[k] = v
  end
  return out
end

--- The text after the `** <label>` line inside [s, e), up to the next heading.
local function section_value(lines, s, e, label)
  for i = s, e - 1 do
    if lines[i]:match("^%** " .. label .. "[ \t]*$") then
      local j = i + 1
      while j < e and not lines[j]:match("^%*+%s") do
        j = j + 1
      end
      local last = j - 1
      if j >= #lines + 1 then
        while last > i and not lines[last]:match("%S") do
          last = last - 1
        end
      end
      return text_of(vim.list_slice(lines, i + 1, last)), j
    end
  end
end

--- Apply the change requests in lines [first, last] of buffer `bufnr`
--- (default: the whole buffer) (org-mobile-apply). Applied requests are
--- removed; failed ones keep an error message after their stars.
---@param bufnr? integer
---@param first? integer
---@return { new: integer, edits: integer, flags: integer, errors: integer, flagged_files: string[] }
function M.apply(bufnr, first)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  first = first or 1
  local counts = { new = 0, edits = 0, flags = 0, errors = 0, flagged_files = {} }
  local function get_lines()
    return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  end
  -- remove the Note IDs
  local lines = get_lines()
  for i = #lines, first, -1 do
    if lines[i]:match("^%*%* Note ID: [%-0-9A-F]+[ \t]*$") then
      vim.api.nvim_buf_set_lines(bufnr, i - 1, i, false, {})
    end
  end
  lines = get_lines()
  for i = first, #lines do
    local h = lines[i]:match("^%* (.*)")
    if h and #h >= 2 and h:sub(1, 2):lower() ~= "f(" then
      counts.new = counts.new + 1
    end
  end
  local stamped = {}
  local acts = actions()
  local pos = first
  while true do
    lines = get_lines()
    local bos, action, data, link
    for i = pos, #lines do
      local inner, rest = lines[i]:match("^%*+[ \t]+F%(([^()]*)%)[ \t]+%[%[(.*)$")
      if inner then
        local l = rest:match("^([^%]]+)")
        if l and (l:match("^id:") or l:match("^olp:")) then
          action, data = inner:match("^([^:]*):(.*)$")
          action = action or inner
          bos, link = i, l
          break
        end
      end
    end
    if not bos then
      break
    end
    local eos = subtree_end(lines, bos)
    -- an error message after the stars ("BAD FLAG" at the line start, as Emacs)
    local function mark(msg, col)
      col = col or 2
      local l = vim.api.nvim_buf_get_lines(bufnr, bos - 1, bos, false)[1]
      vim.api.nvim_buf_set_lines(bufnr, bos - 1, bos, false, { l:sub(1, col) .. msg .. l:sub(col + 1) })
      counts.errors = counts.errors + 1
      pos = bos + 1
    end
    local cmd
    if action == "" then
      local note = text_of(vim.list_slice(lines, bos + 1, eos - 1))
      cmd = function(_, _, _, target)
        counts.flags = counts.flags + 1
        flag(target, note)
      end
    else
      counts.edits = counts.edits + 1
      cmd = acts[action]
    end
    local ok, target = pcall(M.locate_entry, link)
    if not ok then
      target = tostring(target)
    end
    if type(target) == "table" and not stamped[target.bufnr] then
      stamped[target.bufnr] = true
      local at = timestamp_buffer(target.bufnr)
      if at and at <= target.lnum then
        target.lnum = target.lnum + 1
      end
    end
    if type(target) ~= "table" then
      mark(type(target) == "string" and (target .. " ") or "BAD REFERENCE ")
    elseif not cmd then
      mark("BAD FLAG ", 0)
    else
      lines = get_lines()
      local old, after = section_value(lines, bos, eos, "Old value")
      local new = section_value(lines, after or bos, eos, "New value")
      if blank(old) then
        old = nil
      end
      if blank(new) then
        new = nil
      end
      if data ~= "body" then
        old = old and vim.trim(old)
        new = new and vim.trim(new)
      end
      local cok, cerr = pcall(cmd, data, old, new, target)
      if not cok then
        mark(type(cerr) == "string" and (cerr .. " ") or "EXECUTION FAILED ")
      else
        if not vim.tbl_contains({ "delete", "archive", "archive-sibling", "addheading" }, data) then
          local hl = heading_at(target)
          if hl and vim.tbl_contains(hl.tags, "FLAGGED") then
            local name = vim.api.nvim_buf_get_name(target.bufnr)
            if not vim.tbl_contains(counts.flagged_files, name) then
              counts.flagged_files[#counts.flagged_files + 1] = name
            end
          end
        end
        -- applied: remove the request from the inbox
        lines = get_lines()
        vim.api.nvim_buf_set_lines(bufnr, bos - 1, subtree_end(lines, bos) - 1, false, {})
        pos = bos
      end
    end
  end
  if vim.api.nvim_buf_get_name(bufnr) ~= "" then
    utils.save_buffer_or_warn(bufnr)
  end
  utils.notify(
    string.format("%d new, %d edits, %d flags, %d errors", counts.new, counts.edits, counts.flags, counts.errors)
  )
  return counts
end

--- Pull the captured entries and edits from the mobile application and
--- apply them (org-mobile-pull). Shows the flagged entries of the changed
--- files in an agenda. Returns the counts of `apply`, or nil.
function M.pull()
  local ok, res = pcall(function()
    M.check_setup()
    run_hook("pre_pull_hook", "OrgMobilePrePull")
    local bufnr, start = M.move_capture()
    if not bufnr then
      utils.notify("No new items")
      return nil
    end
    run_hook("before_process_capture_hook", "OrgMobileBeforeProcessCapture", { bufnr = bufnr, line = start })
    local counts = M.apply(bufnr, start)
    run_hook("post_pull_hook", "OrgMobilePostPull")
    if #counts.flagged_files > 0 and cfg().show_flagged ~= false then
      M.flagged_agenda(counts.flagged_files)
    end
    return counts
  end)
  if not ok then
    utils.error(tostring(res))
    return nil
  end
  return res
end

--- Apply the change requests of the current buffer (org-mobile-apply).
function M.apply_command()
  return M.apply(0, 1)
end

--- Open the inbox file (mobile.inbox_for_pull).
function M.goto_inbox()
  local p = inbox_path()
  if not p then
    utils.warn("mobile.inbox_for_pull is not set")
    return
  end
  vim.cmd("edit " .. vim.fn.fnameescape(p))
end

---------------------------------------------------------------------------
-- Flagged entries in the agenda
---------------------------------------------------------------------------

local note_group = vim.api.nvim_create_augroup("org.mobile.note", { clear = true })

--- The FLAGGED entries (the agenda dispatcher's `?`), optionally only in
--- `restrict_files`; moving to an entry echoes its flagging note.
---@param restrict_files? string[]
function M.flagged_agenda(restrict_files)
  local block = { type = "tags", match = "+FLAGGED" }
  if restrict_files and #restrict_files > 0 then
    block.files = restrict_files
  end
  require("org.agenda").open(block)
  local view = require("org.agenda.view")
  local buf = view.state.buf
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  vim.api.nvim_clear_autocmds({ group = note_group, buffer = buf })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = note_group,
    buffer = buf,
    callback = function()
      local it = view.item_at_cursor()
      local note = it and it.headline and it.headline.properties.THEFLAGGINGNOTE
      if note then
        vim.api.nvim_echo(
          { { "FLAGGING-NOTE ([?] for more info): " }, { (note:gsub("\\n", "//")), "WarningMsg" } },
          false,
          {}
        )
      end
    end,
  })
end

M._last_note = nil

--- Remove the FLAGGED tag and the flagging note of the entry at target
--- (org-agenda-remove-flag).
function M.remove_flag(target)
  local hl = heading_at(target)
  if not hl then
    return
  end
  if vim.tbl_contains(hl.tags, "FLAGGED") then
    local tags = vim.tbl_filter(function(t)
      return t ~= "FLAGGED"
    end, hl.tags)
    require("org.edit").update_headline(target.bufnr, target.lnum, { tags = tags })
  end
  require("org.edit").set_property(target.bufnr, target.lnum, "THEFLAGGINGNOTE", nil)
  utils.notify("Entry unflagged")
end

--- The agenda `?` key (org-agenda-show-the-flagging-note): show the
--- flagging note of the entry in another window and copy it to the
--- unnamed register; pressed again without moving, offer to remove the
--- FLAGGED tag and the note.
function M.show_flagging_note()
  local view = require("org.agenda.view")
  local item = view.item_at_cursor()
  if not (item and item.headline) then
    utils.warn("No linked entry at point")
    return
  end
  local agenda_win = vim.api.nvim_get_current_win()
  -- "pressed again": same agenda line and entry as the last `?`
  local key = table.concat({
    vim.api.nvim_get_current_buf(),
    vim.api.nvim_win_get_cursor(0)[1],
    item.filename or tostring(item.bufnr),
    item.headline.line,
  }, ":")
  local target = view.resolve_target(item)
  if not target then
    return
  end
  if M._last_note == key and utils.confirm("Unflag and remove any flagging note?") then
    M._last_note = nil
    M.remove_flag(target)
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)):match("%*Flagging Note%*$") then
        pcall(vim.api.nvim_win_close, w, true)
      end
    end
    if vim.api.nvim_win_is_valid(agenda_win) then
      vim.api.nvim_set_current_win(agenda_win)
    end
    view.redo()
    return
  end
  local hl = heading_at(target)
  local note = hl and hl.properties.THEFLAGGINGNOTE
  if not note then
    M._last_note = nil
    utils.warn("No flagging note")
    return
  end
  vim.fn.setreg('"', note)
  local text = vim.split((note:gsub("\\n", "\n")), "\n", { plain = true })
  local buf
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b):match("%*Flagging Note%*$") then
      buf = b
    end
  end
  if not buf then
    buf = vim.api.nvim_create_buf(false, true)
    pcall(vim.api.nvim_buf_set_name, buf, "*Flagging Note*")
    vim.bo[buf].bufhidden = "hide"
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, text)
  if #vim.fn.win_findbuf(buf) == 0 then
    vim.cmd("rightbelow split")
    vim.api.nvim_win_set_buf(0, buf)
  end
  if vim.api.nvim_win_is_valid(agenda_win) then
    vim.api.nvim_set_current_win(agenda_win)
  end
  M._last_note = key
  utils.notify("Flagging note pushed to kill ring.  Press `?' again to remove tag and note")
end

return M
