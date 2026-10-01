---@mod org.export Export dispatcher
---
--- Native back-ends ported from Emacs Org 9.8 (ox-*.el): html, latex (and
--- pdf through latexmk/pdflatex), beamer, md (ox-md), gfm (GitHub
--- flavoured Markdown, plugin specific), ascii (plain text with the
--- ascii, latin1 or utf-8 charset), org, icalendar, odt (OpenDocument Text,
--- ox-odt), texinfo (and info through makeinfo), koma-letter (KOMA-Script
--- letters, ox-koma-letter, and their PDF) and man (ox-man, and man-pdf
--- through groff). Other formats are
--- produced by pandoc from the Org export of the buffer (odt too with
--- `export.odt.use_pandoc`).

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
  texinfo = { "texinfo", "texi" },
  texi = { "texinfo", "texi" },
  info = { "texinfo", "texi", info = true },
  odt = { "odt", "odt" },
  koma = { "koma-letter", "tex" },
  ["koma-letter"] = { "koma-letter", "tex" },
  ["koma-pdf"] = { "koma-letter", "tex", pdf = true },
  man = { "man", "man" },
  ["man-pdf"] = { "man", "man", man_pdf = true },
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
FILETYPES.texinfo = "texinfo"
FILETYPES["koma-letter"] = "tex"
FILETYPES.man = "nroff"

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

--- The temporary export buffer; shown in a split unless
--- `export.show_temporary_export_buffer` is false (or `hidden`).
local function open_scratch(text, ft, name, hidden)
  local buf = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split((text:gsub("\n$", "")), "\n", { plain = true }))
  vim.bo[buf].filetype = ft or ""
  pcall(vim.api.nvim_buf_set_name, buf, name .. " #" .. buf)
  vim.bo[buf].modified = false
  if not hidden and cfg().show_temporary_export_buffer ~= false then
    vim.cmd("vsplit")
    vim.api.nvim_win_set_buf(0, buf)
  end
  return buf
end

--- Write `text` to `path` in `export.coding_system` (org-export-coding-system;
--- nil = UTF-8).
local function write_text(path, text)
  local coding = cfg().coding_system
  if coding and not coding:lower():match("^utf%-?8") then
    local converted = vim.fn.iconv(text, "utf-8", coding)
    if converted ~= "" or text == "" then
      text = converted
    end
  end
  utils.writefile(path, vim.split((text:gsub("\n$", "")), "\n", { plain = true }))
end

--- Push the export output to the unnamed register (and the clipboard when
--- available), like org-kill-new, as `export.copy_to_kill_ring` says:
--- true, "if-interactive" (exports started from the dispatcher or a
--- command) or false.
function M.maybe_copy(text, interactive)
  local v = cfg().copy_to_kill_ring
  if not (v == true or (v == "if-interactive" and interactive)) then
    return
  end
  if not text or not text:match("%S") then
    return
  end
  vim.fn.setreg('"', text)
  pcall(vim.fn.setreg, "+", text)
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
  if spec and spec[1] == "texinfo" and not spec.info and (cfg().texinfo or {}).use_pandoc then
    spec = nil -- pandoc fallback (export.texinfo.use_pandoc)
  end
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
  if spec and spec[1] == "odt" then
    if (cfg().odt or {}).use_pandoc then
      spec = nil
    else
      return require("org.export.odt").export_file(lines, xopts, opts, src)
    end
  end
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
  if backend == "texinfo" and not opts.to_buffer and ext.output_file == nil then
    -- @setfilename / @direntry name the output file (relative to the source)
    ext.texinfo_output_file = function(info)
      local out = opts.output or M.output_file_name(src, extension, info)
      local dir = src and vim.fn.fnamemodify(src, ":p:h") or vim.fn.getcwd()
      local rel = ox().relative_path(out, dir)
      return rel:match("^%.%./") and out or rel
    end
  end
  local text, info, err = render(backend, lines, xopts)
  if not text then
    utils.error("Export failed: " .. err)
    return nil
  end
  if opts.to_buffer then
    local name = backend == "org" and "Org ORG Export" or ("Org " .. backend:upper() .. " Export")
    M.last_buffer = open_scratch(text, FILETYPES[backend], name, opts.hidden)
    M.maybe_copy(text, opts.interactive)
    return "buffer"
  end
  local out = opts.output or M.output_file_name(src, extension, info)
  write_text(out, text)
  M.maybe_copy(text, opts.interactive)
  if spec.pdf then
    return M.compile_pdf(out, opts)
  end
  if spec.info then
    return M.compile_info(out, opts)
  end
  if spec.man_pdf then
    return M.compile_man_pdf(out, opts)
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
    if opts.on_done then
      opts.on_done(result)
    end
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
  if spec[1] == "odt" then
    require("org.export.odt")
  end
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
    no_final_newline = opts.no_final_newline,
    ext = ext,
  }))
end

--- Process a .texi file into an Info file with makeinfo
--- (org-texinfo-export-to-info). With `opts.open` the manual is shown with
--- `info` in a terminal window.
function M.compile_info(texi, opts)
  opts = opts or {}
  local texinfo = require("org.export.texinfo")
  local function done(result, err)
    if not result then
      utils.error(err or "Info file was not produced")
      return
    end
    utils.notify("Exported to " .. result)
    if opts.on_done then
      opts.on_done(result)
    end
    if opts.open or cfg().open_after_export then
      if vim.fn.executable("info") == 1 and #vim.api.nvim_list_uis() > 0 then
        vim.cmd("new")
        vim.fn.jobstart({ "info", "-f", result }, { term = true })
        vim.cmd("startinsert")
      else
        vim.ui.open(result)
      end
    end
  end
  if opts.async then
    utils.notify("Processing Texinfo file " .. vim.fn.fnamemodify(texi, ":t") .. " …")
    texinfo.compile(texi, done)
    return texi:gsub("%.texi$", "") .. ".info"
  end
  local result, err = texinfo.compile(texi)
  done(result, err)
  return result
end

--- Process a man file into a PDF with `export.man.pdf_process`
--- (org-man-compile).
function M.compile_man_pdf(file, opts)
  opts = opts or {}
  local man = require("org.export.man")
  local function done(result, err)
    if not result then
      utils.error(err or "PDF file was not produced")
      return
    end
    utils.notify("PDF file produced. " .. result)
    if opts.open or cfg().open_after_export then
      vim.ui.open(result)
    end
  end
  if opts.async then
    utils.notify("Processing Groff file " .. vim.fn.fnamemodify(file, ":t") .. " …")
    man.compile(file, done)
    return (file:gsub("%.[^/.]*$", "")) .. ".pdf"
  end
  local result, err = man.compile(file)
  done(result, err)
  return result
end

---------------------------------------------------------------------------
-- Asynchronous export and the export stack (org-export-stack)
---------------------------------------------------------------------------

--- Export results of background exports, newest first:
--- { source = path|bufnr|nil, backend = name, time = seconds, running = bool }.
M.stack_contents = {}

local STACK_NAME = "*Org Export Stack*"

local function stack_live(entry)
  if entry.running then
    return true
  end
  if type(entry.source) == "number" then
    return vim.api.nvim_buf_is_valid(entry.source)
  end
  return type(entry.source) == "string" and vim.uv.fs_stat(entry.source) ~= nil
end

--- Add a result to the stack, dropping entries with the same source
--- (org-export-add-to-stack). Returns the new entry.
function M.stack_add(source, backend, running)
  local new = { source = source, backend = backend, time = os.time(), running = running or nil }
  local keep = { new }
  for _, e in ipairs(M.stack_contents) do
    if source == nil or e.source ~= source then
      keep[#keep + 1] = e
    end
  end
  M.stack_contents = keep
  M.stack_refresh()
  return new
end

--- Mark a running entry as finished with its result (a file or a buffer);
--- a nil result removes it (the export failed).
function M.stack_finish(entry, source)
  if source == nil then
    M.stack_contents = vim.tbl_filter(function(e)
      return e ~= entry
    end, M.stack_contents)
  else
    M.stack_contents = vim.tbl_filter(function(e)
      return e == entry or e.source ~= source
    end, M.stack_contents)
    entry.source, entry.running, entry.time = source, nil, os.time()
  end
  M.stack_refresh()
end

local function stack_source_name(e)
  if e.running and e.source == nil then
    return ""
  end
  if type(e.source) == "number" then
    return vim.api.nvim_buf_get_name(e.source)
  end
  return e.source
end

--- Rows of the stack buffer (org-export--stack-generate): number, back-end,
--- age ("H:MM", or "run" while the export runs) and source. Unavailable
--- sources (deleted files, wiped buffers) are removed first.
function M.stack_lines()
  M.stack_contents = vim.tbl_filter(stack_live, M.stack_contents)
  local out = {}
  for i, e in ipairs(M.stack_contents) do
    local age
    if e.running then
      age = "run"
    else
      local secs = math.max(0, os.time() - e.time)
      age = string.format("%d:%02d", math.floor(secs / 3600), math.floor(secs % 3600 / 60))
    end
    out[#out + 1] = string.format("%-4s %-12s %-6s %s", tostring(i), e.backend or "", age, stack_source_name(e))
  end
  return out
end

local function stack_buffer()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and vim.fn.fnamemodify(vim.api.nvim_buf_get_name(b), ":t") == STACK_NAME then
      return b
    end
  end
end

--- Redraw the stack buffer, when it exists (org-export-stack-refresh).
function M.stack_refresh()
  local buf = stack_buffer()
  if not buf then
    return
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, M.stack_lines())
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
end

--- Remove every entry from the stack (org-export-stack-clear).
function M.stack_clear()
  M.stack_contents = {}
  M.stack_refresh()
end

local function stack_entry_at_point()
  local e = M.stack_contents[vim.api.nvim_win_get_cursor(0)[1]]
  if not e then
    utils.warn("Source unavailable, please refresh buffer")
  end
  return e
end

--- Remove the entry at the cursor from the stack (org-export-stack-remove);
--- the file or buffer itself is kept.
function M.stack_remove(entry)
  entry = entry or stack_entry_at_point()
  if not entry then
    return
  end
  M.stack_contents = vim.tbl_filter(function(e)
    return e ~= entry
  end, M.stack_contents)
  M.stack_refresh()
end

--- View the result at the cursor (org-export-stack-view): a buffer is
--- shown in another window, a file is opened like a file link
--- (org-open-file: `links.file_apps`, HTML and PDF with the system
--- opener), or in Neovim when `in_nvim`, like C-u in Emacs.
function M.stack_view(entry, in_nvim)
  entry = entry or stack_entry_at_point()
  if not entry or entry.running then
    return
  end
  if type(entry.source) == "number" then
    vim.cmd("wincmd p")
    vim.cmd("vsplit")
    vim.api.nvim_win_set_buf(0, entry.source)
  else
    require("org.links").open_file(entry.source, { app = in_nvim and "vim" or nil })
  end
end

--- Show the export stack (org-export-stack): results of the exports run in
--- the background. <CR>/v view, d remove, C clear, g refresh, q quit.
function M.stack_show()
  local buf = stack_buffer()
  if not buf then
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, STACK_NAME)
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].filetype = "orgexportstack"
    local function map(lhs, fn)
      vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true })
    end
    map("<CR>", function()
      M.stack_view(nil, vim.v.count > 0)
    end)
    map("v", function()
      M.stack_view(nil, vim.v.count > 0)
    end)
    map("d", function()
      M.stack_remove()
    end)
    map("C", M.stack_clear)
    map("g", M.stack_refresh)
    map("<Space>", "j")
    map("q", "<Cmd>close<CR>")
  end
  local win = vim.fn.bufwinid(buf)
  if win == -1 then
    vim.cmd("botright split")
    vim.api.nvim_win_set_buf(0, buf)
    win = vim.api.nvim_get_current_win()
  else
    vim.api.nvim_set_current_win(win)
  end
  vim.wo[win].winbar = string.format("%-4s %-12s %-6s %s", "#", "Backend", "Age", "Source")
  M.stack_refresh()
  utils.notify('Type "q" to quit, "g" to refresh')
  return buf
end

--- Lua source for a value (strings, numbers, booleans and tables; functions
--- and other values are left out), for the configuration of the
--- asynchronous export process.
local function serialize(v, seen)
  local t = type(v)
  if t == "string" then
    return string.format("%q", v)
  elseif t == "number" or t == "boolean" then
    return tostring(v)
  elseif t ~= "table" or v == vim.NIL then
    return "nil"
  end
  seen = seen or {}
  if seen[v] then
    return "nil"
  end
  seen[v] = true
  local parts = {}
  for k, x in pairs(v) do
    local kt = type(k)
    if (kt == "string" or kt == "number") and type(x) ~= "function" then
      local val = serialize(x, seen)
      if val ~= "nil" then
        local keystr = kt == "number" and ("[" .. k .. "]") or string.format("[%q]", k)
        parts[#parts + 1] = keystr .. "=" .. val
      end
    end
  end
  seen[v] = nil
  return "{" .. table.concat(parts, ",") .. "}"
end
M._serialize = serialize

local PLUGIN_ROOT = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h:h")

--- The script run by the export process: set up org.nvim with the
--- session's options (without Lua functions, like the -Q Emacs of
--- org-export-async-start), answer no to every prompt (Babel blocks that
--- need a confirmation keep their results), export and write the result.
local CHILD_SCRIPT = [[
local job = dofile(_G.arg[1])
vim.opt.rtp:prepend(job.root)
vim.opt.swapfile = false
package.path = job.root .. "/lua/?.lua;" .. job.root .. "/lua/?/init.lua;" .. package.path
local utils = require("org.utils")
utils.input = function() return nil end
utils.input_complete = function() return nil end
utils.confirm = function() return false end
utils.notify = function() end
vim.fn.input = function() return "" end
vim.fn.confirm = function() return 0 end
vim.ui.select = function(_, _, cb) cb(nil) end
require("org").setup(job.config)
if job.init_file and job.init_file ~= "" then
  dofile(vim.fn.expand(job.init_file))
end
local buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, job.lines)
if job.filename then
  pcall(vim.api.nvim_buf_set_name, buf, job.filename)
end
vim.api.nvim_set_current_buf(buf)
vim.bo[buf].filetype = "org"
local export = require("org.export")
local result = {}
local ok, err = pcall(function()
  if job.to_buffer then
    result.text = export.to_string(job.format, {
      bufnr = buf,
      filename = job.filename,
      subtree_line = job.subtree_line,
      body_only = job.body_only,
    })
    result.filetype = job.filetype
  else
    result.output = export.export(job.format, {
      bufnr = buf,
      subtree_line = job.subtree_line,
      body_only = job.body_only,
      output = job.output,
      async = false,
    })
  end
end)
if not ok then
  result.error = tostring(err)
end
local f = assert(io.open(job.result, "w"))
f:write("return " .. export._serialize(result))
f:close()
]]

--- Export in the background (dispatcher `a`, `export.in_background`,
--- `:Org export FORMAT async`): like org-export-async-start, a separate
--- Neovim process exports a copy of the buffer with the session's options
--- (`export.async_init_file`, a Lua file, runs there first) and the result
--- (a file, or a buffer for "as buffer" exports) goes to the export stack
--- instead of being shown. Visible-only exports run in this Neovim, right
--- after the dispatcher closes.
function M.export_async(format, opts)
  opts = vim.tbl_extend("force", {}, opts or {})
  opts.bufnr = (opts.bufnr == nil or opts.bufnr == 0) and vim.api.nvim_get_current_buf() or opts.bufnr
  if opts.subtree and not opts.subtree_line then
    opts.subtree_line = vim.api.nvim_win_get_cursor(0)[1]
  end
  local spec = M.FORMATS[format]
  local backend = spec and spec[1] or format
  local entry = M.stack_add(nil, backend, true)
  utils.notify("Initializing asynchronous export process")
  local function finish(result)
    M.stack_finish(entry, result)
    if result and opts.open and type(result) == "string" then
      vim.ui.open(result)
    end
  end
  if not opts.visible_only then
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local src = vim.api.nvim_buf_get_name(opts.bufnr)
    local job = {
      root = PLUGIN_ROOT,
      config = require("org.config").opts,
      init_file = cfg().async_init_file,
      lines = vim.api.nvim_buf_get_lines(opts.bufnr, 0, -1, false),
      filename = src ~= "" and src or nil,
      format = format,
      subtree_line = opts.subtree_line,
      body_only = opts.body_only,
      output = opts.output,
      to_buffer = opts.to_buffer,
      filetype = spec and FILETYPES[spec[1]] or nil,
      result = dir .. "/result.lua",
    }
    local jobfile, script = dir .. "/job.lua", dir .. "/run.lua"
    local ok = pcall(function()
      local f = assert(io.open(jobfile, "w"))
      f:write("return " .. serialize(job))
      f:close()
      f = assert(io.open(script, "w"))
      f:write(CHILD_SCRIPT)
      f:close()
    end)
    local cmd = { vim.v.progpath, "--clean", "--headless", "-n", "-i", "NONE", "-l", script, jobfile }
    local sysopts = { text = true, cwd = src ~= "" and vim.fn.fnamemodify(src, ":p:h") or nil }
    local started = ok
      and pcall(vim.system, cmd, sysopts, function(res)
        vim.schedule(function()
          local okr, r = pcall(dofile, job.result)
          vim.fn.delete(dir, "rf")
          if not okr or type(r) ~= "table" or r.error then
            local msg = okr and type(r) == "table" and r.error or (res.stderr ~= "" and res.stderr) or tostring(r)
            utils.error("Asynchronous export failed: " .. tostring(msg))
            return finish(nil)
          end
          if r.text then
            local name = backend == "org" and "Org ORG Export" or ("Org " .. backend:upper() .. " Export")
            local buf = open_scratch(r.text, r.filetype, name, true)
            M.last_buffer = buf
            return finish(buf)
          end
          finish(r.output and vim.fn.fnamemodify(r.output, ":p") or nil)
        end)
      end)
    if started then
      return entry
    end
  end
  -- in this Neovim, right after the dispatcher (visible-only needs the folds)
  opts.hidden = true
  opts.async = true
  opts.interactive = nil -- output is not copied from asynchronous exports
  local compiled = spec and (spec.pdf or spec.info)
  opts.on_done = function(result)
    M.stack_finish(entry, result)
  end
  vim.schedule(function()
    local ok, res = pcall(M.export, format, opts)
    if not ok or not res then
      M.stack_finish(entry, nil)
      if not ok then
        utils.error("Export failed: " .. tostring(res))
      end
    elseif res == "buffer" then
      M.stack_finish(entry, M.last_buffer)
    elseif not compiled then
      M.stack_finish(entry, vim.fn.fnamemodify(res, ":p"))
    end
  end)
  return entry
end

---------------------------------------------------------------------------
-- Convert region in place (org-export-replace-region-by)
---------------------------------------------------------------------------

--- Replace the selected Org text by its body-only export
--- (org-html-convert-region-to-html, org-latex-convert-region-to-latex,
--- org-md-convert-region-to-md, org-ascii-convert-region-to-ascii / -utf8,
--- org-texinfo-convert-region-to-texinfo and their org-export-region-to-*
--- aliases). The region is exported on its own, like a temporary Org
--- buffer. `range` = { line1, line2 } (linewise, from `:[range]`),
--- otherwise the Visual selection.
---@param format string html|latex|md|ascii|utf8|texinfo|...
---@param range? integer[]
function M.convert_region(format, range)
  local bufnr = vim.api.nvim_get_current_buf()
  local srow, scol, erow, ecol, mode
  if range then
    srow, erow, mode = range[1], range[2], "V"
  else
    local m = vim.fn.mode()
    if m ~= "v" and m ~= "V" and m ~= "\22" then
      utils.warn("No active region to replace")
      return false
    end
    srow, scol, erow, ecol, mode = utils.visual_range()
    vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
  end
  if mode == "v" then
    local last = vim.api.nvim_buf_get_lines(bufnr, erow - 1, erow, false)[1] or ""
    local erow0, ecol0, eol = erow - 1, nil, false
    if ecol > #last then
      -- `v$`: the selection takes the end of the line too
      eol = true
      if erow < vim.api.nvim_buf_line_count(bufnr) then
        erow0, ecol0 = erow, 0
      else
        ecol0 = #last
      end
    else
      -- the end column is inclusive and points at the start of a (multibyte) character
      ecol0 = ecol + vim.str_utf_end(last, ecol)
    end
    local parts = vim.api.nvim_buf_get_text(bufnr, srow - 1, scol - 1, erow0, ecol0, {})
    if eol and parts[#parts] == "" then
      parts[#parts] = nil
    end
    local out = M.to_string(format, {
      lines = parts,
      body_only = true,
      -- like the buffer text Emacs exports, the last line has no newline
      no_final_newline = not eol,
    })
    vim.api.nvim_buf_set_text(bufnr, srow - 1, scol - 1, erow0, ecol0, vim.split(out, "\n", { plain = true }))
  else
    local lines = vim.api.nvim_buf_get_lines(bufnr, srow - 1, erow, false)
    local out = M.to_string(format, { lines = lines, body_only = true })
    local new = out == "" and {} or vim.split((out:gsub("\n$", "")), "\n", { plain = true })
    vim.api.nvim_buf_set_lines(bufnr, srow - 1, erow, false, new)
  end
  return true
end

for _, f in ipairs({ "html", "latex", "md", "ascii", "utf8", "texinfo" }) do
  M["convert_region_to_" .. f] = function()
    return M.convert_region(f)
  end
  M["export_region_to_" .. f] = function(_, opts)
    return M.convert_region_command(f, opts)
  end
end

--- :[range]Org convert_region {format} (the `org-export-region-to-*`
--- commands); without a range, the last Visual selection.
function M.convert_region_command(args, opts)
  local format = vim.trim(args or "")
  if format == "" then
    utils.warn("Usage: :[range]Org convert_region html|latex|md|ascii|utf8|texinfo|...")
    return
  end
  if not M.FORMATS[format] then
    utils.error("Unknown export format: " .. format)
    return
  end
  local range
  if opts and opts.range and opts.range > 0 then
    range = { opts.line1, opts.line2 }
  else
    local s, e = vim.fn.line("'<"), vim.fn.line("'>")
    if s == 0 or e == 0 then
      utils.warn("No active region to replace")
      return
    end
    range = { s, e }
  end
  return M.convert_region(format, range)
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
  if backend == "odt" then
    require("org.export.odt")
  end
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

local function dispatcher_items(state)
  local function onoff(v)
    return v and "on" or "off"
  end
  return {
    { heading = true, label = "Options" },
    { key = "b", label = "Body only", state = onoff(state.body_only), value = { toggle = "body_only" } },
    {
      key = "s",
      label = "Export scope",
      state = state.subtree and "subtree" or "buffer",
      value = { toggle = "subtree" },
    },
    { key = "v", label = "Visible only", state = onoff(state.visible_only), value = { toggle = "visible_only" } },
    { key = "f", label = "Force publishing", state = onoff(state.force), value = { toggle = "force" } },
    { key = "a", label = "Async export", state = onoff(state.async), value = { toggle = "async" } },
    { heading = true, label = "Export" },
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
      key = "i",
      label = "Export to Texinfo",
      items = {
        { key = "t", label = "As TEXI file", value = { fmt = "texinfo" } },
        { key = "i", label = "As INFO file", value = { fmt = "info" } },
        { key = "o", label = "As INFO file and open", value = { fmt = "info", open = true } },
      },
    },
    {
      key = "k",
      label = "Export with KOMA Scrlttr2",
      items = {
        { key = "L", label = "As LaTeX buffer", value = { fmt = "koma-letter", to_buffer = true } },
        { key = "l", label = "As LaTeX file", value = { fmt = "koma-letter" } },
        { key = "p", label = "As PDF file", value = { fmt = "koma-pdf" } },
        { key = "o", label = "As PDF file and open", value = { fmt = "koma-pdf", open = true } },
      },
    },
    {
      key = "M",
      label = "Export to MAN",
      items = {
        { key = "m", label = "As MAN file", value = { fmt = "man" } },
        { key = "p", label = "As PDF file", value = { fmt = "man-pdf" } },
        { key = "o", label = "As PDF file and open", value = { fmt = "man-pdf", open = true } },
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
      label = "Export to ODT",
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
    { key = "p", label = "Other format via pandoc", value = { fmt = "__pandoc" } },
    { key = "&", label = "Export stack", value = { stack = true } },
    { key = "#", label = "Insert default export template", value = { template = true } },
  }
end

--- Ctrl-keys of the dispatcher options (C-b C-s C-v C-f C-a in Emacs).
local CTRL_TOGGLES = { ["\2"] = "b", ["\19"] = "s", ["\22"] = "v", ["\6"] = "f", ["\1"] = "a" }

--- The compact dispatcher of `export.dispatch_use_expert_ui`
--- (org-export-dispatch-use-expert-ui): no menu window, only a prompt
--- "Export command (C-bvsfa) [keys]: " with the active options
--- highlighted. `?` switches to the standard menu.
local function expert_menu(items, state)
  local level = items
  local first
  while true do
    local chunks = { { "Export command (C-", "Question" } }
    for _, k in ipairs({ "b", "v", "s", "f", "a" }) do
      local field = ({ b = "body_only", v = "visible_only", s = "subtree", f = "force", a = "async" })[k]
      chunks[#chunks + 1] = { k, state[field] and "Special" or "Question" }
    end
    local keys = {}
    for _, it in ipairs(level) do
      if not it.heading and not (first == nil and #it.key == 1 and ("bsvfa"):find(it.key, 1, true)) then
        keys[#keys + 1] = it.key
      end
    end
    if not first then
      keys[#keys + 1] = "?"
    end
    keys[#keys + 1] = "q"
    chunks[#chunks + 1] = { ") [" .. table.concat(keys) .. "]: ", "Question" }
    vim.api.nvim_echo(chunks, false, {})
    local ok, ch = pcall(vim.fn.getcharstr)
    vim.api.nvim_echo({ { "" } }, false, {})
    if not ok or ch == "\27" or ch == "\3" or ch == "q" then
      if ch == "q" and first then
        level, first = items, nil
      else
        return nil
      end
    elseif ch == "?" and not first then
      return "standard"
    elseif CTRL_TOGGLES[ch] then
      for _, it in ipairs(items) do
        if not it.heading and it.key == CTRL_TOGGLES[ch] then
          return it.value
        end
      end
    else
      local chosen
      for _, it in ipairs(level) do
        if not it.heading and it.key == ch then
          chosen = it
          break
        end
      end
      if not chosen then
        utils.warn("No menu entry for key: " .. ch)
        return nil
      end
      if chosen.items then
        level, first = chosen.items, ch
      else
        return chosen.value
      end
    end
  end
end

--- Emacs-like export dispatcher (C-c C-e). The options start from
--- `export.initial_scope`, `export.body_only`, `export.visible_only`,
--- `export.force_publishing` and `export.in_background`.
function M.prompt()
  if not utils.ensure_org() then
    return
  end
  local c = cfg()
  local state = {
    subtree = c.initial_scope == "subtree",
    body_only = c.body_only == true,
    visible_only = c.visible_only == true,
    force = c.force_publishing == true,
    async = c.in_background == true,
  }
  local subtree_line = vim.api.nvim_win_get_cursor(0)[1]
  local expert = c.dispatch_use_expert_ui == true
  while true do
    local items = dispatcher_items(state)
    local choice
    if expert then
      choice = expert_menu(items, state)
      if choice == "standard" then
        expert = false
        choice = require("org.ui").menu({ title = "Org Export", items = items })
      end
    else
      choice = require("org.ui").menu({ title = "Org Export", items = items })
    end
    if not choice then
      return
    end
    if choice.toggle then
      state[choice.toggle] = not state[choice.toggle]
    elseif choice.stack then
      return M.stack_show()
    elseif choice.template then
      local cats = { "default" }
      for _, n in ipairs({
        "ascii",
        "beamer",
        "html",
        "icalendar",
        "koma-letter",
        "latex",
        "man",
        "md",
        "odt",
        "org",
        "texinfo",
      }) do
        cats[#cats + 1] = n
      end
      local cat = require("org.ui").choose({
        prompt = "Options category: ",
        title = "Insert export template",
        items = cats,
        default = "default",
      })
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
      local async = state.async or nil
      if choice.publish == "file" then
        return pub.publish_current_file(state.force, async)
      elseif choice.publish == "current" then
        return pub.publish_current_project(state.force, async)
      elseif choice.publish == "all" then
        return pub.publish_all(state.force, async)
      end
      local names = {}
      for _, p in ipairs(pub.projects()) do
        names[#names + 1] = p[1]
      end
      local name = require("org.ui").choose({ prompt = "Publish project: ", items = names })
      if name and name ~= "" then
        return pub.publish_project(name, state.force, async)
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
      local opts = {
        subtree = state.subtree,
        subtree_line = state.subtree and subtree_line or nil,
        body_only = state.body_only,
        visible_only = state.visible_only,
        to_buffer = choice.to_buffer,
        open = choice.open,
        interactive = true,
      }
      if state.async then
        return M.export_async(fmt, opts)
      end
      return M.export(fmt, opts)
    end
  end
end

--- :Org export [format] [subtree] [body] [visible] [buffer] [open] [async]
function M.command(args)
  local words = vim.split(vim.trim(args or ""), "%s+", { trimempty = true })
  if #words == 0 then
    return M.prompt()
  end
  local opts = { interactive = true }
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
  if opts.async then
    return M.export_async(words[1], opts)
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
