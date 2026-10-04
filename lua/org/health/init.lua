--- :checkhealth org
local M = {}

--- Option classes of the LuaLS annotations in lua/org/_meta/:
--- class -> { fields = { name -> type }, parent?, open? (any key) }.
local function meta_classes()
  local classes = {}
  for _, f in ipairs(vim.api.nvim_get_runtime_file("lua/org/_meta/*.lua", true)) do
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
        if def == nil and not ty then
          out[#out + 1] = path .. k
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

function M.check()
  local h = vim.health
  h.start("org.nvim")
  if vim.fn.has("nvim-0.11") == 1 then
    h.ok("Neovim " .. tostring(vim.version()))
  else
    h.error("Neovim >= 0.11 is required")
  end

  local cfg = require("org.config").opts
  local utils = require("org.utils")
  local dir = utils.expand(cfg.org_directory, vim.fn.getcwd())
  if utils.is_dir(dir) then
    h.ok("org_directory: " .. dir)
  else
    h.warn("org_directory does not exist: " .. dir, { "mkdir -p " .. dir })
  end
  local files = require("org.files").agenda_file_paths()
  if #files > 0 then
    h.ok(string.format("%d agenda file(s) found", #files))
  else
    h.warn("No agenda files match `agenda_files`", { vim.inspect(cfg.agenda_files) })
  end
  local notes = utils.expand(cfg.default_notes_file)
  if utils.exists(notes) then
    h.ok("default_notes_file: " .. notes)
  else
    h.info("default_notes_file will be created on first capture: " .. notes)
  end

  local unknown = M.unknown_options(require("org.config").user_opts)
  if #unknown > 0 then
    h.warn("Unknown options passed to setup() (ignored): " .. table.concat(unknown, ", "), {
      "check the names in :h org-config and :h org-keymaps",
    })
  end

  local ignored = M.ignored_block_options(cfg.agenda.custom_commands)
  if #ignored > 0 then
    h.warn("Column view options in a block of a composite custom command (ignored): " .. table.concat(ignored, ", "), {
      "set them in the command's `settings`, as in Emacs (:h org-agenda-command-columns)",
    })
  end

  -- keyword config
  local ok, err = pcall(function()
    local t = require("org.todo_keywords").global()
    assert(#t.keywords > 0, "no keywords")
  end)
  if ok then
    h.ok("todo_keywords: " .. table.concat(require("org.todo_keywords").global():names(), " "))
  else
    h.error("todo_keywords invalid: " .. tostring(err))
  end

  -- conflicting plugins
  if package.loaded["orgmode"] then
    h.warn("nvim-orgmode is also loaded; both plugins handle *.org files")
  end

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
    h.info("with " .. backend .. ", :align / org-image-align are ignored (:h org-images-troubleshooting)")
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
end

return M
