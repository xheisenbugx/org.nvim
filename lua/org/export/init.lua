---@mod org.export Export dispatcher
---
--- Native back-ends ported from Emacs Org 9.8 (ox-*.el): html, latex (and
--- pdf through latexmk/pdflatex), beamer, md (ox-md), gfm (GitHub
--- flavoured Markdown, plugin specific), ascii (plain text with the
--- ascii, latin1 or utf-8 charset), org and icalendar. Other formats are
--- produced by pandoc from the Org export of the buffer.

local utils = require("org.utils")

local M = {}

--- format -> { backend, extension, charset? }
M.FORMATS = {
  html = { "html" },
  htm = { "html" },
  md = { "md", "md" },
  markdown = { "md", "md" },
  gfm = { "gfm", "md" },
  ["md-gfm"] = { "gfm", "md" },
  ascii = { "ascii", "txt", "ascii" },
  txt = { "ascii", "txt" },
  text = { "ascii", "txt" },
  latin1 = { "ascii", "txt", "latin1" },
  utf8 = { "ascii", "txt", "utf-8" },
  ["utf-8"] = { "ascii", "txt", "utf-8" },
  latex = { "latex", "tex" },
  tex = { "latex", "tex" },
  pdf = { "latex", "tex", pdf = true },
  beamer = { "beamer", "tex" },
  ["beamer-pdf"] = { "beamer", "tex", pdf = true },
  org = { "org", "org" },
  ics = { "icalendar", "ics" },
  icalendar = { "icalendar", "ics" },
}

--- Kept for backward compatibility: native formats -> module.
M.BACKENDS = {
  html = "org.export.html",
  md = "org.export.markdown",
  gfm = "org.export.gfm",
  txt = "org.export.ascii",
  latex = "org.export.latex",
  beamer = "org.export.beamer",
  org = "org.export.org",
}

local PANDOC_EXT = {
  docx = "docx",
  odt = "odt",
  rst = "rst",
  epub = "epub",
  epub3 = "epub",
  rtf = "rtf",
  asciidoc = "adoc",
  mediawiki = "wiki",
  textile = "textile",
  man = "man",
  jira = "jira",
  pptx = "pptx",
  typst = "typ",
  json = "json",
  revealjs = "html",
  dokuwiki = "txt",
  ipynb = "ipynb",
  texinfo = "texi",
}

local FILETYPES = { html = "html", md = "markdown", gfm = "markdown", ascii = "text", latex = "tex", beamer = "tex", org = "org", icalendar = "icalendar" }

local function cfg()
  return require("org.config").opts.export or {}
end

local function ox()
  return require("org.export.ox")
end

local function buffer_lines(bufnr)
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

--- Resolve export options: { bufnr, subtree_line, visible_only, ... }.
local function resolve(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or 0
  if bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  local subtree_line = opts.subtree_line
  if opts.subtree and not subtree_line then
    subtree_line = vim.api.nvim_win_get_cursor(0)[1]
  end
  return bufnr, subtree_line
end

--- Output file name (org-export-output-file-name).
---@param src string|nil visited file
---@param ext string extension without dot
---@param info table|nil export info (EXPORT_FILE_NAME)
---@param pub_dir string|nil
function M.output_file_name(src, ext, info, pub_dir)
  local base
  if info then
    base = info.subtree_props and info.subtree_props.EXPORT_FILE_NAME
    if not base and info.keywords and info.keywords.EXPORT_FILE_NAME then
      base = info.keywords.EXPORT_FILE_NAME[1]
    end
  end
  local dir
  if base then
    base = utils.expand(base, src and vim.fn.fnamemodify(src, ":p:h") or vim.fn.getcwd())
  else
    if not src or src == "" then
      base = vim.fn.getcwd() .. "/export"
    else
      base = vim.fn.fnamemodify(src, ":p"):gsub("%.gpg$", "")
    end
    if cfg().output_dir then
      dir = utils.expand(cfg().output_dir, src and vim.fn.fnamemodify(src, ":p:h") or vim.fn.getcwd())
    end
  end
  base = base:gsub("%.[^/%.]*$", "")
  local out = base .. "." .. ext
  if pub_dir then
    out = vim.fs.normalize(pub_dir .. "/" .. vim.fn.fnamemodify(out, ":t"))
  elseif dir then
    out = vim.fs.normalize(dir .. "/" .. vim.fn.fnamemodify(out, ":t"))
  end
  if src and vim.fs.normalize(vim.fn.fnamemodify(src, ":p")) == vim.fs.normalize(out) then
    out = out .. "." .. ext
  end
  return out
end

local function open_scratch(text, ft, name)
  vim.cmd("vsplit")
  local buf = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_win_set_buf(0, buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split((text:gsub("\n$", "")), "\n", { plain = true }))
  vim.bo[buf].filetype = ft or ""
  pcall(vim.api.nvim_buf_set_name, buf, name .. " #" .. buf)
  vim.bo[buf].modified = false
  return buf
end

local function write_text(path, text)
  utils.writefile(path, vim.split((text:gsub("\n$", "")), "\n", { plain = true }))
end

local function run(cmd, opts)
  local ok, obj = pcall(function()
    return vim.system(cmd, opts or {}):wait(opts and opts.timeout or 120000)
  end)
  if not ok then
    return { code = -1, stderr = tostring(obj), stdout = "" }
  end
  return obj
end

local function pandoc_cmd()
  local p = cfg().pandoc or {}
  local cmd = p.cmd or "pandoc"
  local list = type(cmd) == "table" and vim.deepcopy(cmd) or vim.split(cmd, "%s+", { trimempty = true })
  return list, p.args or {}
end

--- Render with a native back-end.
---@return string|nil text, table|nil info, string|nil err
local function render(backend, lines, opts)
  local ok, text, info = pcall(ox().export_as, backend, lines, opts)
  if not ok then
    return nil, nil, tostring(text)
  end
  return text, info
end

--- Export a buffer.
---@param format string html|md|gfm|txt|ascii|latin1|utf8|latex|pdf|beamer|org|ics|<pandoc format>
---@param opts? { bufnr?: integer, subtree?: boolean, subtree_line?: integer, body_only?: boolean, visible_only?: boolean, to_buffer?: boolean, open?: boolean, output?: string, async?: boolean, ext?: table, options?: table }
---@return string|nil output path (or "buffer") / nil on failure
function M.export(format, opts)
  opts = opts or {}
  local bufnr, subtree_line = resolve(opts)
  local lines = buffer_lines(bufnr)
  local src = vim.api.nvim_buf_get_name(bufnr)
  src = src ~= "" and src or nil
  local spec = M.FORMATS[format]
  if spec and spec[1] == "icalendar" then
    return require("org.export.icalendar").export_file(bufnr, opts)
  end
  local ext = vim.tbl_extend("force", opts.ext or {}, opts.options or {})
  local xopts = {
    filename = src,
    bufnr = bufnr,
    subtree_line = subtree_line,
    body_only = opts.body_only,
    visible_only = opts.visible_only,
    ext = ext,
  }
  if not spec then
    -- pandoc: convert the Org export of the buffer
    local text, _, err = render("org", lines, xopts)
    if not text then
      utils.error("Export failed: " .. err)
      return nil
    end
    local cmd, extra = pandoc_cmd()
    if vim.fn.executable(cmd[1]) == 0 then
      utils.error("pandoc not found (needed for " .. format .. " export). Install pandoc or set export.pandoc.cmd")
      return nil
    end
    local out = opts.output or M.output_file_name(src, PANDOC_EXT[format] or format)
    vim.list_extend(cmd, { "-f", "org", "-t", format, "-o", out })
    if not opts.body_only then
      cmd[#cmd + 1] = "--standalone"
    end
    vim.list_extend(cmd, extra)
    local cwd = src and vim.fn.fnamemodify(src, ":p:h") or vim.fn.getcwd()
    local res = run(cmd, { stdin = text, cwd = cwd, text = true })
    if res.code ~= 0 then
      utils.error("pandoc failed:\n" .. (res.stderr or ""))
      return nil
    end
    utils.notify("Exported to " .. out)
    if opts.open or cfg().open_after_export then
      vim.ui.open(out)
    end
    return out
  end
  local backend, extension, charset = spec[1], spec[2], spec[3]
  if backend == "html" then
    extension = (cfg().html or {}).extension or "html"
  end
  if charset then
    ext.ascii_charset = charset
  end
  local text, info, err = render(backend, lines, xopts)
  if not text then
    utils.error("Export failed: " .. err)
    return nil
  end
  if opts.to_buffer then
    local name = backend == "org" and "Org ORG Export" or ("Org " .. backend:upper() .. " Export")
    open_scratch(text, FILETYPES[backend], name)
    return "buffer"
  end
  local out = opts.output or M.output_file_name(src, extension, info)
  write_text(out, text)
  if spec.pdf then
    return M.compile_pdf(out, opts)
  end
  utils.notify("Exported to " .. out)
  if opts.open or cfg().open_after_export then
    vim.ui.open(out)
  end
  return out
end

--- Compile a .tex file to PDF (org-latex-compile). Asynchronous with
--- `opts.async` (or `export.latex.async_compile`): the UI does not block
--- and a notification is shown when the PDF is ready.
function M.compile_pdf(tex, opts)
  opts = opts or {}
  local latex = require("org.export.latex")
  local pdf = tex:gsub("%.tex$", ".pdf")
  local async = opts.async
  if async == nil then
    async = ((cfg().latex or {}).async_compile ~= false) and #vim.api.nvim_list_uis() > 0
  end
  local function done(result, err, warnings)
    if not result then
      utils.error(err or "PDF compilation failed")
      return
    end
    local msg = "PDF file produced"
    if warnings == "error" then
      msg = msg .. " with errors."
    elseif type(warnings) == "table" and #warnings > 0 then
      msg = msg .. " with warnings: " .. table.concat(warnings, " ")
    else
      msg = msg .. "."
    end
    utils.notify(msg .. " " .. result)
    if opts.open or cfg().open_after_export then
      vim.ui.open(result)
    end
  end
  if async then
    utils.notify("Compiling " .. vim.fn.fnamemodify(tex, ":t") .. " …")
    latex.compile(tex, done)
    return pdf
  end
  local result, err, warnings = latex.compile(tex)
  done(result, err, warnings)
  return result
end

--- Render a buffer (or `opts.lines`) to a string without writing
--- anything (for tests / API). Native formats only.
---
--- ```lua
--- local html = require("org.export").to_string("html", { body_only = true })
--- ```
---@param format string
---@param opts? { bufnr?: integer, lines?: string[], filename?: string, subtree_line?: integer, body_only?: boolean, visible_only?: boolean, ext?: table, options?: table }
---@return string
function M.to_string(format, opts)
  opts = opts or {}
  local spec = M.FORMATS[format]
  if not spec then
    error("to_string: unsupported format " .. tostring(format))
  end
  local bufnr = opts.bufnr
  if not opts.lines then
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    if bufnr == 0 then
      bufnr = vim.api.nvim_get_current_buf()
    end
  end
  local lines = opts.lines or buffer_lines(bufnr)
  local ext = vim.tbl_extend("force", opts.ext or {}, opts.options or {})
  if spec[3] then
    ext.ascii_charset = spec[3]
  end
  local filename = opts.filename
  if not filename and bufnr and not opts.lines then
    local n = vim.api.nvim_buf_get_name(bufnr)
    filename = n ~= "" and n or nil
  end
  return (ox().export_as(spec[1], lines, {
    filename = filename,
    bufnr = bufnr,
    subtree_line = opts.subtree_line,
    body_only = opts.body_only,
    visible_only = opts.visible_only,
    ext = ext,
  }))
end

---------------------------------------------------------------------------
-- Default template (org-export-insert-default-template)
---------------------------------------------------------------------------

local function elisp_print(v)
  if v == true then
    return "t"
  elseif v == false or v == nil then
    return "nil"
  elseif type(v) == "number" then
    return tostring(v)
  elseif type(v) == "table" then
    local parts = {}
    for _, x in ipairs(v) do
      parts[#parts + 1] = type(x) == "string" and ('"' .. x .. '"') or elisp_print(x)
    end
    return "(" .. (v.negate and ("not" .. (#parts > 0 and " " or "")) or "") .. table.concat(parts, " ") .. ")"
  end
  return tostring(v)
end
M.elisp_print = elisp_print

--- Insert the export keywords with their default values at the cursor line
--- (org-export-insert-default-template). With `subtree`, set EXPORT_*
--- properties on the current headline instead. `backend` selects the
--- option set ("default" = generic options).
---@param opts? { subtree?: boolean, backend?: string }
function M.insert_template(opts)
  opts = opts or {}
  local backend = opts.backend or "default"
  local o = ox()
  local options = {}
  if backend ~= "default" then
    local b = o.get_backend(backend)
    if not b then
      utils.error("Unknown export back-end: " .. backend)
      return
    end
    options = o.all_options(b)
    if #options == 0 then
      options = {}
    end
    -- only the back-end's own options (org-export-backend-options)
    local own = b.options
    if type(own) == "function" then
      own = own()
    end
    options = own or {}
  else
    options = o.global_options()
  end
  local items, keywords = {}, {}
  local seen_opt, seen_kw = {}, {}
  for _, entry in ipairs(options) do
    local keyword, option = entry[2], entry[3]
    local value = entry[4]
    if type(value) == "function" then
      value = value()
    end
    if keyword then
      if not seen_kw[keyword] then
        seen_kw[keyword] = true
        if entry[5] == "split" and type(value) == "table" then
          value = table.concat(value, " ")
        end
        keywords[#keywords + 1] = { keyword, value }
      end
    elseif option then
      if not seen_opt[option] then
        seen_opt[option] = true
        items[#items + 1] = { option, value }
      end
    end
  end
  table.sort(items, function(a, b)
    return a[1] < b[1]
  end)
  local option_strings = {}
  for _, it in ipairs(items) do
    option_strings[#option_strings + 1] = it[1] .. ":" .. elisp_print(it[2])
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(bufnr)
  local function kw_value(key, value)
    if key == "DATE" then
      return value or require("org.date").today():to_string()
    elseif key == "TITLE" then
      return value or (name ~= "" and vim.fn.fnamemodify(name, ":t:r") or vim.fn.bufname(bufnr))
    end
    if type(value) == "table" then
      return ""
    end
    return value
  end
  if opts.subtree then
    local edit = require("org.edit")
    local b, _, hl = edit.resolve_headline()
    if not hl then
      utils.warn("No subtree to set export options for")
      return
    end
    if #option_strings > 0 then
      edit.set_property(b, hl.line, "EXPORT_OPTIONS", table.concat(option_strings, " "))
    end
    for _, kv in ipairs(keywords) do
      local v = kw_value(kv[1], kv[2])
      edit.set_property(b, hl.line, "EXPORT_" .. kv[1], v ~= nil and tostring(v) or "")
    end
    return
  end
  local out = {}
  local fill = (vim.bo[bufnr].textwidth > 0 and vim.bo[bufnr].textwidth) or 70
  local i = 1
  while i <= #option_strings do
    local line = "#+options:"
    local width = 10
    while i <= #option_strings and (width + #option_strings[i] + 1) < fill do
      line = line .. " " .. option_strings[i]
      width = width + #option_strings[i] + 1
      i = i + 1
    end
    if line == "#+options:" then
      line = line .. " " .. option_strings[i]
      i = i + 1
    end
    out[#out + 1] = line
  end
  for _, kv in ipairs(keywords) do
    local v = kw_value(kv[1], kv[2])
    v = v ~= nil and tostring(v) or ""
    out[#out + 1] = "#+" .. kv[1]:lower() .. ":" .. (v:match("%S") and (" " .. v) or "")
  end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  vim.api.nvim_buf_set_lines(bufnr, row - 1, row - 1, false, out)
  return out
end

---------------------------------------------------------------------------
-- Dispatcher (org-export-dispatch)
---------------------------------------------------------------------------

--- Emacs-like export dispatcher (C-c C-e).
function M.prompt()
  if not utils.ensure_org() then
    return
  end
  local state = { subtree = false, body_only = false, visible_only = false, async = false }
  local subtree_line = vim.api.nvim_win_get_cursor(0)[1]
  local function onoff(v)
    return v and "on" or "off"
  end
  while true do
    local items = {
      { key = "b", label = "Toggle: body only = " .. onoff(state.body_only), value = { toggle = "body_only" } },
      { key = "s", label = "Toggle: export scope = " .. (state.subtree and "subtree" or "buffer"), value = { toggle = "subtree" } },
      { key = "v", label = "Toggle: visible only = " .. onoff(state.visible_only), value = { toggle = "visible_only" } },
      { key = "a", label = "Toggle: async (PDF) = " .. onoff(state.async), value = { toggle = "async" } },
      {
        key = "c",
        label = "Export to iCalendar",
        items = {
          { key = "f", label = "Current file", value = { ical = "file" } },
          { key = "a", label = "All agenda files", value = { ical = "agenda" } },
          { key = "c", label = "Combine all agenda files", value = { ical = "combine" } },
        },
      },
      {
        key = "h",
        label = "Export to HTML",
        items = {
          { key = "H", label = "As HTML buffer", value = { fmt = "html", to_buffer = true } },
          { key = "h", label = "As HTML file", value = { fmt = "html" } },
          { key = "o", label = "As HTML file and open", value = { fmt = "html", open = true } },
        },
      },
      {
        key = "l",
        label = "Export to LaTeX",
        items = {
          { key = "L", label = "As LaTeX buffer", value = { fmt = "latex", to_buffer = true } },
          { key = "l", label = "As LaTeX file", value = { fmt = "latex" } },
          { key = "p", label = "As PDF file", value = { fmt = "pdf" } },
          { key = "o", label = "As PDF file and open", value = { fmt = "pdf", open = true } },
          { key = "B", label = "As LaTeX buffer (Beamer)", value = { fmt = "beamer", to_buffer = true } },
          { key = "b", label = "As LaTeX file (Beamer)", value = { fmt = "beamer" } },
          { key = "P", label = "As PDF file (Beamer)", value = { fmt = "beamer-pdf" } },
          { key = "O", label = "As PDF file and open (Beamer)", value = { fmt = "beamer-pdf", open = true } },
        },
      },
      {
        key = "m",
        label = "Export to Markdown",
        items = {
          { key = "M", label = "To temporary buffer", value = { fmt = "md", to_buffer = true } },
          { key = "m", label = "To file", value = { fmt = "md" } },
          { key = "o", label = "To file and open", value = { fmt = "md", open = true } },
          { key = "G", label = "GitHub flavoured, to temporary buffer", value = { fmt = "gfm", to_buffer = true } },
          { key = "g", label = "GitHub flavoured, to file", value = { fmt = "gfm" } },
        },
      },
      {
        key = "O",
        label = "Export to Org",
        items = {
          { key = "O", label = "As Org buffer", value = { fmt = "org", to_buffer = true } },
          { key = "o", label = "As Org file", value = { fmt = "org" } },
          { key = "v", label = "As Org file and open", value = { fmt = "org", open = true } },
        },
      },
      {
        key = "o",
        label = "Export to ODT (pandoc)",
        items = {
          { key = "o", label = "As ODT file", value = { fmt = "odt" } },
          { key = "O", label = "As ODT file and open", value = { fmt = "odt", open = true } },
        },
      },
      {
        key = "d",
        label = "Export to DOCX (pandoc)",
        items = {
          { key = "d", label = "As DOCX file", value = { fmt = "docx" } },
          { key = "o", label = "As DOCX file and open", value = { fmt = "docx", open = true } },
        },
      },
      {
        key = "t",
        label = "Export to Plain Text",
        items = {
          { key = "A", label = "As ASCII buffer", value = { fmt = "ascii", to_buffer = true } },
          { key = "a", label = "As ASCII file", value = { fmt = "ascii" } },
          { key = "L", label = "As Latin1 buffer", value = { fmt = "latin1", to_buffer = true } },
          { key = "l", label = "As Latin1 file", value = { fmt = "latin1" } },
          { key = "U", label = "As UTF-8 buffer", value = { fmt = "utf8", to_buffer = true } },
          { key = "u", label = "As UTF-8 file", value = { fmt = "utf8" } },
        },
      },
      {
        key = "P",
        label = "Publish",
        items = {
          { key = "f", label = "Current file", value = { publish = "file" } },
          { key = "p", label = "Current project", value = { publish = "current" } },
          { key = "x", label = "Choose project", value = { publish = "choose" } },
          { key = "a", label = "All projects", value = { publish = "all" } },
        },
      },
      { key = "p", label = "Other format via pandoc…", value = { fmt = "__pandoc" } },
      { key = "#", label = "Insert default export template", value = { template = true } },
    }
    local choice = require("org.ui").menu({ title = "Org Export", items = items })
    if not choice then
      return
    end
    if choice.toggle then
      state[choice.toggle] = not state[choice.toggle]
    elseif choice.template then
      local cats = { "default" }
      for _, n in ipairs({ "ascii", "beamer", "html", "icalendar", "latex", "md", "org" }) do
        cats[#cats + 1] = n
      end
      local cat = utils.input_complete("Options category: ", cats, "default")
      if not cat or cat == "" then
        return
      end
      return M.insert_template({ subtree = state.subtree, backend = cat })
    elseif choice.ical then
      local ical = require("org.export.icalendar")
      if choice.ical == "file" then
        return ical.export_file(0, { async = state.async })
      elseif choice.ical == "agenda" then
        return ical.export_agenda_files({ async = state.async })
      end
      return ical.combine_agenda_files({ async = state.async })
    elseif choice.publish then
      local pub = require("org.export.publish")
      if choice.publish == "file" then
        return pub.publish_current_file(false)
      elseif choice.publish == "current" then
        return pub.publish_current_project(false)
      elseif choice.publish == "all" then
        return pub.publish_all(false)
      end
      local names = {}
      for _, p in ipairs(pub.projects()) do
        names[#names + 1] = p[1]
      end
      local name = utils.input_complete("Publish project: ", names)
      if name and name ~= "" then
        return pub.publish_project(name, false)
      end
      return
    else
      local fmt = choice.fmt
      if fmt == "__pandoc" then
        fmt = utils.input({ prompt = "Pandoc output format: ", default = "rst" })
        if not fmt or fmt == "" then
          return
        end
      end
      return M.export(fmt, {
        subtree = state.subtree,
        subtree_line = state.subtree and subtree_line or nil,
        body_only = state.body_only,
        visible_only = state.visible_only,
        async = state.async or nil,
        to_buffer = choice.to_buffer,
        open = choice.open,
      })
    end
  end
end

--- :Org export [format] [subtree] [body] [visible] [buffer] [open] [async]
function M.command(args)
  local words = vim.split(vim.trim(args or ""), "%s+", { trimempty = true })
  if #words == 0 then
    return M.prompt()
  end
  local opts = {}
  for i = 2, #words do
    local w = words[i]
    if w == "subtree" then
      opts.subtree = true
    elseif w == "body" or w == "body-only" then
      opts.body_only = true
    elseif w == "visible" or w == "visible-only" then
      opts.visible_only = true
    elseif w == "buffer" then
      opts.to_buffer = true
    elseif w == "open" then
      opts.open = true
    elseif w == "async" then
      opts.async = true
    end
  end
  return M.export(words[1], opts)
end

--- :Org publish [project|all|file] [force]
function M.publish_command(args)
  local words = vim.split(vim.trim(args or ""), "%s+", { trimempty = true })
  local force = vim.tbl_contains(words, "force")
  local pub = require("org.export.publish")
  local target = words[1]
  if not target or target == "force" or target == "current" then
    return pub.publish_current_project(force)
  elseif target == "all" then
    return pub.publish_all(force)
  elseif target == "file" then
    return pub.publish_current_file(force)
  end
  return pub.publish_project(target, force)
end

return M
