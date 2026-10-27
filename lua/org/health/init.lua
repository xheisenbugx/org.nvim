--- :checkhealth org
local M = {}

--- Option classes of the LuaLS annotations in lua/org/_meta/:
--- class -> { fields = { name -> type }, parent?, open? (any key) }.
local function meta_classes()
  local classes = {}
  for _, f in ipairs(vim.fn.glob(require("org.version").lua_dir() .. "/org/_meta/*.lua", false, true)) do
    local cur
    for _, line in ipairs(vim.fn.readfile(f)) do
      local cls, parent = line:match("^%-%-%-@class%s+([%w%._]+)%s*:?%s*([%w%._]*)")
      if cls then
        cur = cls
        classes[cls] = classes[cls] or { fields = {} }
        if parent ~= "" then
          classes[cls].parent = parent
        end
      elseif cur then
        -- `name` or `["name"]` (a Lua keyword such as goto)
        local name, ty = line:match("^%-%-%-@field%s+([%w_]+)%??%s+(.*)$")
        if not name then
          name, ty = line:match('^%-%-%-@field%s+%["([%w_]+)"%]%??%s+(.*)$')
        end
        if name then
          classes[cur].fields[name] = ty
        elseif line:match('^%-%-%-@field%s+%[[^"]') then
          -- `[string]` keys: any name is valid
          classes[cur].open = true
        elseif not line:match("^%-%-%-") then
          cur = nil
        end
      end
    end
  end
  return classes
end

--- Keys of the options given to setup() that org.nvim doesn't know (typos,
--- removed options), as dotted paths. Free-form tables (`log_note_headings`,
--- `babel.languages`, `extensions`, ...) aren't checked; the action-backed
--- `mappings` sections are checked against the action names.
---@param user table options passed to setup()
---@return string[]
function M.unknown_options(user)
  local classes = meta_classes()
  local actions = require("org.actions").list
  local action_sections = {
    global = true,
    org = true,
    org_insert = true,
    emacs_global = true,
    emacs = true,
    emacs_insert = true,
  }
  local out = {}
  local function field(cls, name)
    while cls and classes[cls] do
      local ty = classes[cls].fields[name]
      if ty then
        return ty
      end
      cls = classes[cls].parent
    end
  end
  local function walk(tbl, defaults, cls, path)
    for k, v in pairs(tbl) do
      if type(k) == "string" then
        local def = type(defaults) == "table" and defaults[k] or nil
        local ty = field(cls, k)
        if def == nil and not ty and not (k == "enabled" and path:match("^extensions%.[%w_]+%.$")) then
          out[#out + 1] = path .. k
        elseif path .. k == "extensions" and type(v) == "table" then
          -- the built-in extensions' options, against their defaults;
          -- third-party extensions aren't known
          for name, value in pairs(v) do
            local ety = type(name) == "string" and type(value) == "table" and field("org.Config.Extensions", name)
            local sub = ety and ety:match("^(org%.Config%.Extensions%.[%w_]+)")
            local mok, mod = pcall(require, "org.extensions." .. tostring(name))
            if sub and classes[sub] and not classes[sub].open and mok and type(mod) == "table" then
              walk(value, mod.defaults or {}, sub, "extensions." .. name .. ".")
            end
          end
        elseif type(v) == "table" and not vim.islist(v) and path .. k ~= "extensions" then
          if path == "mappings." and action_sections[k] then
            for name in pairs(v) do
              if type(name) == "string" and not actions[name] then
                out[#out + 1] = path .. k .. "." .. name
              end
            end
          else
            local sub = ty and ty:match("^(org%.Config[%w%._]*)")
            if sub and classes[sub] and not classes[sub].open then
              walk(v, def, sub, path .. k .. ".")
            end
          end
        end
      end
    end
  end
  if next(classes) and type(user) == "table" then
    walk(user, require("org.config").defaults, "org.Config", "")
  end
  table.sort(out)
  return out
end

--- A path for a message: under the home directory as ~/..., with forward
--- slashes on Windows too (fnamemodify(":~") gives backslashes there)
local function tilde(p)
  return require("org.utils").abbreviate(p)
end

--- Options Emacs reads once per agenda (org-agenda-finalize), under the
--- let-bound options of the command: in a block of a composite command
--- they have no effect.
local COMMAND_ONLY = {
  overriding_columns_format = true,
  org_overriding_columns_format = true,
  view_columns_initially = true,
  org_agenda_view_columns_initially = true,
}

--- Options set on a block of a composite custom command that only take
--- effect in the command's `settings` (the column view options), as
--- "KEY.types[i].option" strings.
---@param cmds? table `agenda.custom_commands`
---@return string[]
function M.ignored_block_options(cmds)
  local out = {}
  for key, cmd in pairs(type(cmds) == "table" and cmds or {}) do
    local field = type(cmd) == "table" and (cmd.types and "types" or cmd.blocks and "blocks") or nil
    for i, b in ipairs(field and type(cmd[field]) == "table" and cmd[field] or {}) do
      for k in pairs(type(b) == "table" and b or {}) do
        if COMMAND_ONLY[k] then
          out[#out + 1] = string.format("%s.%s[%d].%s", tostring(key), field, i, k)
        end
      end
    end
  end
  table.sort(out)
  return out
end

--- The agenda index (:h org-agenda-index): on or off, its file, what the
--- background is doing.
function M.check_agenda_index()
  local h = vim.health
  local s = require("org.agenda.index").status()
  if not s.enabled then
    h.info("agenda index: off (agenda.index.enabled)")
    return
  end
  local parts = {}
  if not s.cache then
    parts[#parts + 1] = s.string_buffer and "not kept on disk (agenda.index.cache)"
      or "not kept on disk (Neovim built without LuaJIT's string.buffer)"
  elseif s.size then
    parts[#parts + 1] = ("%s (%.1f MB)"):format(tilde(s.path), s.size / 1048576)
  else
    parts[#parts + 1] = tilde(s.path) .. " (not written yet)"
  end
  if s.entries then
    parts[#parts + 1] = ("%d files indexed"):format(s.entries)
  end
  if not s.background then
    parts[#parts + 1] = "no background parsing"
  elseif s.warming then
    parts[#parts + 1] = ("parsing in the background, %d files to go"):format(s.queued)
  end
  if s.background then
    parts[#parts + 1] = s.threads > 0 and ("%d worker threads"):format(s.threads)
      or s.thread_error and "worker threads off after a failure"
      or "no worker threads"
  end
  if s.watchers > 0 or s.polled > 0 then
    parts[#parts + 1] = ("%d directories watched, %d polled"):format(s.watchers, s.polled)
  end
  parts[#parts + 1] = ("this session: %d from the index, %d parsed"):format(s.hits, s.misses)
  h.ok("agenda index: " .. table.concat(parts, "; "))
  if s.error then
    h.warn("agenda index: " .. s.error, { ":Org agenda_index_rebuild" })
  end
end

--- Real path of `p`, normalized (a symlinked plugin directory compares
--- equal to its target).
local function real(p)
  return vim.fs.normalize(vim.uv.fs_realpath(p) or p)
end

--- Whether `path` is `dir` or inside it.
local function inside(path, dir)
  return dir ~= nil and dir ~= "" and (path == dir or path:sub(1, #dir + 1) == dir .. "/")
end

-- runtime files of the org filetype that another plugin could also ship
local FT_FILES = {
  "ftplugin/org.vim",
  "ftplugin/org.lua",
  "ftplugin/org_*.vim",
  "ftplugin/org_*.lua",
  "ftplugin/org/*.vim",
  "ftplugin/org/*.lua",
  "syntax/org.vim",
  "syntax/org.lua",
  "indent/org.vim",
  "indent/org.lua",
}

--- Runtime files for the org filetype (ftplugin, syntax, indent, `after/`
--- included) that come from neither org.nvim nor Neovim's own runtime, as
--- { path, own } where `own` is true for files in the user's config.
---@return { path: string, own: boolean }[]
function M.foreign_runtime_files()
  local root = real(require("org.version").root())
  local vimruntime = vim.env.VIMRUNTIME and real(vim.env.VIMRUNTIME) or nil
  local config = real(vim.fn.stdpath("config"))
  local out, seen = {}, {}
  for _, pat in ipairs(FT_FILES) do
    for _, f in ipairs(vim.api.nvim_get_runtime_file(pat, true)) do
      local p = real(f)
      if not seen[p] and not inside(p, root) and not inside(p, vimruntime) then
        seen[p] = true
        out[#out + 1] = { path = p, own = inside(p, config) }
      end
    end
  end
  table.sort(out, function(a, b)
    return a.path < b.path
  end)
  return out
end

-- plugins that also act on org buffers: module -> what it does
local OTHER_PLUGINS = {
  orgmode = {
    "warn",
    "nvim-orgmode is also loaded: both plugins handle *.org files",
    "remove one of them; to move from nvim-orgmode, run `:Org migrate_config` on the file of its setup()"
      .. " to convert it to org.nvim's options; see :h org-migrate",
  },
  headlines = {
    "info",
    "headlines.nvim is loaded: it also decorates org headlines and blocks",
    "turn it off for org (`require('headlines').setup({ org = false })`) if the two draw over each other",
  },
}

--- Neovim, the org filetype and the plugins that would fight over it.
function M.check_core(h)
  h.start("org.nvim")
  if vim.fn.has("nvim-0.11") == 1 then
    h.ok("Neovim " .. tostring(vim.version()))
  else
    h.error("Neovim >= 0.11 is required, this is " .. tostring(vim.version()), { "upgrade Neovim" })
  end
  h.info("org.nvim " .. require("org.version").string() .. " in " .. require("org.version").root())
  local ft = vim.filetype.match({ filename = "notes.org" })
  if ft == "org" then
    h.ok("*.org files get the org filetype")
  else
    h.error(
      string.format("*.org files get the filetype %s, not org", tostring(ft)),
      { "a vim.filetype.add() or autocommand in your config overrides it" }
    )
  end
  local names = vim.tbl_keys(OTHER_PLUGINS)
  table.sort(names)
  for _, mod in ipairs(names) do
    if package.loaded[mod] then
      local p = OTHER_PLUGINS[mod]
      h[p[1]](p[2], { p[3] })
    end
  end
  local foreign = M.foreign_runtime_files()
  local plugin, own = {}, {}
  for _, f in ipairs(foreign) do
    if f.own then
      own[#own + 1] = tilde(f.path)
    else
      plugin[#plugin + 1] = tilde(f.path)
    end
  end
  if #plugin > 0 then
    h.warn("other plugins have runtime files for the org filetype: " .. table.concat(plugin, ", "), {
      "they run in org buffers too and can undo org.nvim's settings, syntax or indent: remove the plugin",
    })
  end
  if #own > 0 then
    h.info("your config has runtime files for the org filetype: " .. table.concat(own, ", "))
  end
end

--- What is wrong with the entries of `agenda_files` that give no agenda
--- file: missing files, empty directories, globs that match nothing,
--- unreadable or non-org files. One message per entry.
---@param patterns string[]
---@return string[]
function M.agenda_problems(patterns)
  local utils = require("org.utils")
  local out = {}
  for _, pattern in ipairs(patterns) do
    if type(pattern) ~= "string" then
      out[#out + 1] = vim.inspect(pattern) .. ": not a path"
    else
      local path = utils.expand(pattern)
      if utils.is_dir(path) then
        if #utils.glob_org_files({ path }) == 0 then
          out[#out + 1] = tilde(pattern)
            .. ": no .org files in this directory (subdirectories aren't searched: use dir/**/*.org)"
        end
      elseif path:find("[%*%?%[]") then
        if #utils.glob_org_files({ path }) == 0 then
          out[#out + 1] = tilde(pattern) .. ": the glob matches no .org file"
        end
      elseif not utils.exists(path) then
        out[#out + 1] = tilde(pattern) .. ": no such file"
      elseif not (path:match("%.org$") or path:match("%.org_archive$")) then
        out[#out + 1] = tilde(pattern) .. ": not an .org file"
      elseif vim.fn.filereadable(path) == 0 then
        out[#out + 1] = tilde(pattern) .. ": not readable"
      end
    end
  end
  return out
end

--- Real path of `p`, which may not exist yet: its nearest existing
--- ancestor resolved, the rest kept.
local function real_file(p)
  p = vim.fs.normalize(p)
  local rest = ""
  while true do
    local resolved = vim.uv.fs_realpath(p)
    if resolved then
      return vim.fs.normalize(resolved) .. rest
    end
    local parent = vim.fs.dirname(p)
    if not parent or parent == p then
      return p .. rest
    end
    rest = "/" .. vim.fs.basename(p) .. rest
    p = parent
  end
end

--- Whether the notes file (expanded) lies outside the org directory
--- (expanded), symlinks resolved. Neither has to exist.
---@param notes string
---@param dir string
---@return boolean
function M.notes_outside(notes, dir)
  if not notes or notes == "" or not dir or dir == "" then
    return false
  end
  return not inside(real_file(notes), real_file(dir))
end

--- org_directory, the agenda files, the notes file, the MobileOrg
--- directory and the session server.
function M.check_files(h)
  h.start("org.nvim files")
  local cfg = require("org.config").opts
  local utils = require("org.utils")
  local files = require("org.files")
  local dir = utils.expand(cfg.org_directory, vim.fn.getcwd())
  if utils.is_dir(dir) then
    h.ok("org_directory: " .. tilde(dir))
  else
    h.warn("org_directory does not exist: " .. dir, { "mkdir -p " .. dir, "or set org_directory; see :h org-config" })
  end

  local list = files.agenda_list_file()
  local patterns = files.agenda_patterns()
  if list then
    h.info(string.format("agenda_files lists them in %s (%d entries)", tilde(list), #patterns))
  end
  local paths = files.agenda_file_paths()
  local problems = M.agenda_problems(patterns)
  if #paths > 0 then
    h.ok(string.format("%d agenda file(s) found", #paths))
  elseif #patterns == 0 then
    h.info("agenda_files is empty: the agenda sees only the current file (set agenda_files, or <C-c>[ adds one)")
  elseif #problems == 0 then
    h.warn("No agenda files match `agenda_files`", { vim.inspect(cfg.agenda_files) })
  end
  for _, problem in ipairs(problems) do
    h.warn("agenda_files: " .. problem, { "fix or remove the entry; see :h org-agenda" })
  end
  local unreadable = {}
  for _, p in ipairs(paths) do
    if vim.fn.filereadable(p) == 0 then
      unreadable[#unreadable + 1] = p
    end
  end
  if #unreadable > 0 then
    h.error("agenda files that can't be read: " .. table.concat(unreadable, ", "), { "check their permissions" })
  end
  M.check_agenda_index()

  local notes = utils.expand(cfg.default_notes_file)
  if utils.exists(notes) then
    if vim.fn.filewritable(notes) == 1 then
      h.ok("default_notes_file: " .. tilde(notes))
    else
      h.warn("default_notes_file is not writable: " .. notes, { "captures without a target file go there" })
    end
  else
    h.info("default_notes_file will be created on first capture: " .. tilde(notes))
  end
  if M.notes_outside(notes, dir) then
    h.warn(
      string.format(
        "default_notes_file %s is outside org_directory %s: captures without a target go there",
        tilde(notes),
        tilde(dir)
      ),
      {
        string.format('set default_notes_file = "%s/refile.org" (or another file in org_directory)', tilde(dir)),
        "see :h org-capture",
      }
    )
  else
    h.ok("default_notes_file is in org_directory")
  end

  local mobile = cfg.mobile or {}
  if mobile.directory and mobile.directory ~= "" then
    local mdir = utils.expand(mobile.directory)
    if utils.is_dir(mdir) then
      h.ok("mobile.directory: " .. tilde(mdir))
    else
      h.warn("mobile.directory does not exist: " .. mdir, { "mkdir -p " .. mdir, "see :h org-mobile" })
    end
  end

  if (cfg.remote or {}).enabled then
    local remote = require("org.remote")
    if remote.is_server() then
      h.ok("session server: listening on " .. tostring(remote.serving))
    else
      h.info("session server: another Neovim listens on " .. remote.address() .. " (or none); see :h org-remote")
    end
  end
end

--- Options given to setup(): unknown names, ignored settings, the TODO
--- keywords.
function M.check_options(h)
  h.start("org.nvim configuration")
  local config = require("org.config")
  local cfg = config.opts
  local unknown, removed = {}, 0
  for _, path in ipairs(M.unknown_options(config.user_opts)) do
    if config.REMOVED[path] then
      removed = removed + 1
      h.warn(string.format("Removed option passed to setup() (ignored): %s", path), { config.REMOVED[path] })
    else
      unknown[#unknown + 1] = path
    end
  end
  if #unknown > 0 then
    h.warn("Unknown options passed to setup() (ignored): " .. table.concat(unknown, ", "), {
      "see :h org-config and :h org-keymaps",
      "an extension's options: see :h org-extensions",
    })
  elseif config.user_opts and removed == 0 then
    h.ok("every option passed to setup() is known")
  elseif not config.user_opts then
    h.info("setup() wasn't called: the defaults are used; see :h org-config")
  end

  local ignored = M.ignored_block_options(cfg.agenda.custom_commands)
  if #ignored > 0 then
    h.warn("Column view options in a block of a composite custom command (ignored): " .. table.concat(ignored, ", "), {
      "set them in the command's `settings`, as in Emacs; see :h org-agenda-command-columns",
    })
  end

  local ok, err = pcall(function()
    local t = require("org.todo_keywords").global()
    assert(#t.keywords > 0, "no keywords")
  end)
  if ok then
    h.ok("todo_keywords: " .. table.concat(require("org.todo_keywords").global():names(), " "))
  else
    h.error("todo_keywords invalid: " .. tostring(err), { "see :h org-todo" })
  end
end

local function size_str(bytes)
  if bytes >= 1048576 then
    return ("%.1f MB"):format(bytes / 1048576)
  end
  return ("%.1f KB"):format(bytes / 1024)
end

--- The files org.nvim keeps its own state in: the ID database and the
--- persisted clock.
function M.check_state(h)
  h.start("org.nvim state files")
  local cfg = require("org.config").opts
  local utils = require("org.utils")
  local s = require("org.id").status()
  if not s.size then
    h.info(("ID database: %s not written yet; see :h org-id"):format(tilde(s.path)))
  elseif vim.fn.filereadable(s.path) == 0 then
    h.error("ID database can't be read: " .. tilde(s.path), { "check its permissions (id.locations_file)" })
  else
    h.ok(
      ("ID database: %s (%s, %s): %d IDs in %d files"):format(tilde(s.path), s.format, size_str(s.size), s.ids, s.files)
    )
    if s.missing > 0 then
      h.warn(
        ("ID database: %d of the%s %d files it lists no longer exist"):format(
          s.missing,
          s.checked < s.files and " first" or "",
          s.checked
        ),
        { ":Org id_update_locations rebuilds it; see :h org-id" }
      )
    end
  end

  local clock = cfg.clock or {}
  if not clock.persist then
    h.info("clock.persist is off: a running clock is lost when Neovim exits (org-clock-persist); see :h org-config")
  elseif not clock.persist_file then
    h.warn("clock.persist is on but clock.persist_file is not set: nothing is saved")
  else
    local path = utils.expand(clock.persist_file)
    if not utils.exists(path) then
      h.ok(("clock.persist = %s: %s (written when Neovim exits)"):format(vim.inspect(clock.persist), tilde(path)))
    else
      local data = utils.read_json(path)
      if type(data) ~= "table" then
        h.warn("clock.persist_file is not valid JSON: " .. tilde(path), { "delete it; it is written again on exit" })
      else
        local running = type(data.state) == "table" and data.state.title
        h.ok(
          ("clock.persist = %s: %s%s"):format(
            vim.inspect(clock.persist),
            tilde(path),
            running and (" (saved clock: " .. tostring(running) .. ")") or ""
          )
        )
      end
    end
  end
end

--- The picker the pick_* actions use, and the installed ones.
function M.check_picker(h)
  h.start("org.nvim picker")
  local pickers = require("org.pickers")
  local name = require("org.config").opts.picker or "auto"
  local installed = {}
  for _, b in ipairs(pickers.backends) do
    if b ~= "select" and pickers.available(b) then
      installed[#installed + 1] = b
    end
  end
  local known = name == "auto" or vim.tbl_contains(pickers.backends, name)
  if not known then
    h.warn(("picker = %s is not a picker: vim.ui.select is used"):format(vim.inspect(name)), {
      'set picker to "auto", "snacks", "fzf-lua", "telescope", "mini" or "select"; see :h org-pickers',
    })
  elseif name ~= "auto" and name ~= "select" and not vim.tbl_contains(installed, name) then
    h.warn(("picker = %q, but %s is not installed: vim.ui.select is used"):format(name, name), {
      'install it, or set picker = "auto"; see :h org-pickers',
    })
  else
    local used = pickers.resolve(name)
    h.ok(
      ("pickers use %s%s"):format(
        used == "select" and "vim.ui.select" or used,
        name == "auto" and ' (picker = "auto")' or ""
      )
    )
  end
  h.info(
    "installed pickers: "
      .. (#installed > 0 and table.concat(installed, ", ") or "none (snacks.nvim, fzf-lua, telescope.nvim, mini.pick)")
  )
end

--- gpg for org-crypt, openssl for MobileOrg encryption.
function M.check_crypto(h)
  local cfg = require("org.config").opts
  local crypt = cfg.crypt or {}
  local gpg = crypt.gpg_program or "gpg"
  if vim.fn.executable(gpg) == 1 then
    h.ok(gpg .. " found for encrypted entries; see :h org-crypt")
  elseif crypt.encrypt_on_save then
    h.warn(gpg .. " not found, but crypt.encrypt_on_save is on: entries tagged :crypt: are saved unencrypted", {
      "install GnuPG, or set crypt.gpg_program; see :h org-crypt",
    })
  else
    h.info(gpg .. " not found: entries tagged :crypt: can't be encrypted or decrypted (crypt.gpg_program)")
  end
  local mobile = cfg.mobile or {}
  if mobile.use_encryption then
    if vim.fn.executable("openssl") == 1 then
      h.ok("openssl found (mobile.use_encryption)")
    else
      h.warn("mobile.use_encryption is on, but openssl is not found", { "install OpenSSL; see :h org-mobile" })
    end
  end
end

--- The Org release of an Org lisp directory, from its org-version.el.
---@param dir string
---@return string|nil
function M.org_lisp_version(dir)
  local lines = require("org.utils").readfile(vim.fs.joinpath(dir, "org-version.el"))
  for _, l in ipairs(lines or {}) do
    local v = l:match('%(org%-release%s+"([^"]+)"%)')
    if v then
      return v
    end
  end
end

--- The Org release the parity scripts measure against (ORG_VERSION in
--- .github/workflows/difftest.yml).
M.ORG_VERSION = "9.8.12"

--- Emacs and Org 9.8.12, for the maintainers' `make difftest` and
--- `make parity-fixtures` (shown only when Emacs is around). Emacs isn't
--- started: that takes seconds.
function M.check_emacs(h)
  local env = vim.env
  local emacs = env.ORG_EMACS or env.EMACS or "emacs"
  local lisp = env.ORG_LISP_DIR or env.ORG_DIR
  if vim.fn.executable(emacs) == 0 and not env.ORG_EMACS and not lisp then
    return
  end
  h.start("org.nvim development (Emacs parity)")
  if vim.fn.executable(emacs) == 1 then
    h.info("Emacs: " .. vim.fn.exepath(emacs) .. " (for make difftest and make parity-fixtures; users don't need it)")
  else
    h.info(emacs .. " not found (ORG_EMACS): make difftest and make parity-fixtures need Emacs")
  end
  if not lisp then
    h.info("ORG_LISP_DIR is not set: Emacs's bundled Org is used, and the parity scripts need Org " .. M.ORG_VERSION)
    return
  end
  local v = M.org_lisp_version(lisp)
  if v == M.ORG_VERSION then
    h.info("Org " .. v .. " in " .. lisp)
  else
    h.info(
      ("ORG_LISP_DIR %s holds Org %s, the parity scripts need %s"):format(
        lisp,
        v or "(no org-version.el)",
        M.ORG_VERSION
      )
    )
  end
end

--- The viewer docview:FILE::PAGE links open a page with
--- (`links.docview_command`): a warning only when the option names a
--- program that isn't installed.
function M.check_docview(h)
  local docview = (require("org.config").opts.links or {}).docview_command
  if type(docview) == "function" then
    h.ok("docview: links open pages with links.docview_command")
  elseif type(docview) == "string" then
    local exe = vim.split(docview, "%s+", { trimempty = true })[1] or ""
    if vim.fn.executable(exe) == 1 then
      h.ok(string.format("docview: links open pages with %s", exe))
    else
      h.warn(string.format("%s not found (links.docview_command): docview: links can't open their page", exe))
    end
  elseif docview == nil then
    local found = require("org.links").docview_command()
    if type(found) == "string" then
      h.ok(string.format("docview: links open pages with %s", vim.split(found, " ")[1]))
    else
      h.info(
        "no document viewer (zathura, okular, evince, ...): docview: links open the file without going to the page"
      )
    end
  end
end

function M.check()
  local h = vim.health
  local cfg = require("org.config").opts
  M.check_core(h)
  M.check_options(h)
  M.check_files(h)
  M.check_state(h)
  M.check_picker(h)

  h.start("org.nvim external tools")
  local pandoc = (cfg.export.pandoc or {}).cmd or "pandoc"
  if type(pandoc) == "table" then
    pandoc = pandoc[1]
  end
  if vim.fn.executable(pandoc) == 1 then
    h.ok("pandoc found (DOCX, EPUB and the other formats without a native back-end)")
  else
    -- HTML, LaTeX/PDF, ODT, Texinfo and the rest are native back-ends
    h.info("pandoc not found: DOCX, EPUB and the other pandoc formats can't be exported (the native back-ends work)")
  end
  if vim.fn.executable("makeinfo") == 1 then
    h.ok("makeinfo found (Texinfo to Info export)")
  else
    h.info("makeinfo not found: Texinfo export works, Info files can't be built")
  end
  -- LaTeX and Beamer to PDF (org-latex-pdf-process; export/latex.lua pdf_process)
  local latex = cfg.export.latex or {}
  if latex.pdf_process then
    h.ok("PDF export uses export.latex.pdf_process")
  else
    local compiler = latex.compiler or "pdflatex"
    if vim.fn.executable(compiler) == 1 then
      local latexmk = vim.fn.executable("latexmk") == 1 and vim.fn.executable("perl") == 1
      h.ok(string.format("%s found (LaTeX to PDF export%s)", compiler, latexmk and ", through latexmk" or ""))
    else
      h.info(string.format("%s not found: LaTeX export works, PDFs can't be built (export.latex.compiler)", compiler))
    end
  end
  local seen = {}
  local langs = vim.tbl_keys(cfg.babel.languages or {})
  table.sort(langs, function(x, y)
    return x:lower() < y:lower()
  end)
  for _, lang in ipairs(langs) do
    local spec = cfg.babel.languages[lang]
    local cmd = type(spec) == "table" and spec.cmd
    local exe = type(cmd) == "table" and cmd[1] or type(cmd) == "string" and vim.split(cmd, "%s+")[1] or nil
    if exe and not seen[exe] then
      seen[exe] = true
      if exe == "nvim" or vim.fn.executable(exe) == 1 then
        h.ok(string.format("babel: %s (%s)", exe, lang))
      else
        h.info(string.format("babel: %s not found (src blocks in %s can't run)", exe, lang))
      end
    end
  end
  M.check_docview(h)
  local ncfg = cfg.notifications or {}
  local notifier = require("org.agenda.notifications").desktop_backend()
  if ncfg.notifier then
    h.ok("reminders use notifications.notifier")
  elseif ncfg.system_notification == false then
    h.info("desktop notifications off (notifications.system_notification): reminders only use vim.notify")
  elseif notifier then
    h.ok(string.format("desktop notifications use %s", notifier))
  else
    h.info("no desktop notifier (osascript, notify-send or powershell.exe): reminders only use vim.notify")
  end

  M.check_crypto(h)

  h.start("org.nvim image and LaTeX previews")
  local images = require("org.ui.images")
  -- what sits between Neovim and the terminal (:h org-images-troubleshooting)
  local between = {}
  if vim.env.TMUX then
    between[#between + 1] = "tmux"
  end
  if vim.env.ZELLIJ then
    between[#between + 1] = "zellij"
  end
  if vim.env.SSH_CONNECTION or vim.env.SSH_CLIENT then
    between[#between + 1] = "SSH"
  end
  local native = pcall(function()
    return assert(vim.ui.img)
  end)
  h.info(
    string.format(
      "Neovim %s (%s), running %s",
      tostring(vim.version()),
      native and "has vim.ui.img" or "no vim.ui.img: needs 0.13+",
      #between > 0 and ("inside " .. table.concat(between, ", ")) or "directly in the terminal"
    )
  )
  local backend, why = images.status()
  if backend then
    h.ok("image backend: " .. backend)
  elseif cfg.ui.images and cfg.ui.images.backend == false then
    h.info(why)
  else
    local advice = {}
    if vim.env.ZELLIJ then
      advice[#advice + 1] = "zellij does not pass images through: run Neovim outside it"
    elseif not native then
      advice[#advice + 1] =
        "Neovim 0.13+ draws images itself (vim.ui.img) in terminals with the Kitty graphics protocol"
    elseif vim.env.TMUX then
      advice[#advice + 1] = "vim.ui.img can't reach the terminal through tmux: run Neovim outside tmux"
    elseif vim.env.TERM_PROGRAM == "Apple_Terminal" then
      advice[#advice + 1] = "Terminal.app has no Kitty graphics protocol: use a terminal that has it"
    end
    if vim.env.TMUX then
      advice[#advice + 1] = "or install snacks.nvim (image) and `set -g allow-passthrough on` in tmux.conf"
    else
      advice[#advice + 1] = "or install snacks.nvim (image) or image.nvim"
    end
    advice[#advice + 1] = "see :h org-images-troubleshooting"
    h.warn(why, advice)
  end
  if backend and backend ~= "native" then
    h.info("with " .. backend .. ", :align / org-image-align are ignored; see :h org-images-troubleshooting")
  end
  local process, perr = images.latex_process()
  if process then
    h.ok("LaTeX previews render with: " .. process)
  else
    h.info("LaTeX previews: " .. perr)
  end
  if vim.fn.executable("magick") == 1 or vim.fn.executable("convert") == 1 then
    h.ok("ImageMagick found (non-PNG images are converted for vim.ui.img)")
  else
    h.info("ImageMagick not found: only PNG images can be previewed with vim.ui.img")
  end

  h.start("org.nvim completion")
  if pcall(require, "blink.cmp") then
    local ok_cfg, bcfg = pcall(require, "blink.cmp.config")
    local provider = ok_cfg and bcfg.sources and bcfg.sources.providers and bcfg.sources.providers.org
    if provider and provider.module == "org.completion.blink" then
      h.ok("blink.cmp org source configured")
    else
      h.info('blink.cmp detected: add provider `org = { name = "Org", module = "org.completion.blink" }`')
    end
  elseif pcall(require, "cmp") then
    h.info('nvim-cmp detected: register_source("org", require("org.completion.cmp").new())')
  else
    h.info("Use <C-x><C-o> (omnifunc) for completion")
  end

  require("org.health.terminal").check(h)
  require("org.extensions").check(h)
  M.check_emacs(h)
end

return M
