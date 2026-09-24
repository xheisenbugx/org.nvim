--- :checkhealth org
local M = {}

function M.check()
  local h = vim.health
  h.start("org.nvim")
  if vim.fn.has("nvim-0.10") == 1 then
    h.ok("Neovim " .. tostring(vim.version()))
  else
    h.error("Neovim >= 0.10 is required")
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
  if vim.fn.executable(pandoc) == 1 then
    h.ok("pandoc found (LaTeX/PDF/DOCX/ODT/... export)")
  else
    h.warn("pandoc not found: export to LaTeX/PDF/DOCX/ODT via pandoc unavailable (HTML/Markdown/text work)")
  end
  local seen = {}
  for lang, spec in pairs(cfg.babel.languages or {}) do
    local exe = spec.cmd and vim.split(spec.cmd, "%s+")[1]
    if exe and not seen[exe] then
      seen[exe] = true
      if exe == "nvim" or vim.fn.executable(exe) == 1 then
        h.ok(string.format("babel: %s (%s)", exe, lang))
      else
        h.info(string.format("babel: %s not found (src blocks in %s can't run)", exe, lang))
      end
    end
  end
  if vim.fn.has("mac") == 1 then
    h.info("notifications use osascript on macOS")
  elseif vim.fn.executable("notify-send") == 1 then
    h.ok("notify-send available for notifications")
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
end

return M
