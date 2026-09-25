---@mod org.export Export dispatcher
---
--- Native backends: html, markdown, text (UTF-8), latex (+ pdf through
--- latexmk/pdflatex). Anything else goes through pandoc.

local utils = require("org.utils")

local M = {}

M.BACKENDS = {
  html = "org.export.html",
  md = "org.export.markdown",
  txt = "org.export.text",
  latex = "org.export.latex",
}

local ALIASES = {
  html = "html",
  htm = "html",
  md = "md",
  markdown = "md",
  gfm = "md",
  txt = "txt",
  text = "txt",
  ascii = "txt",
  utf8 = "txt",
  latex = "latex",
  tex = "latex",
  pdf = "pdf",
  org = "org",
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
  ["jira"] = "jira",
  pptx = "pptx",
  typst = "typ",
  json = "json",
  beamer = "tex",
  revealjs = "html",
  dokuwiki = "txt",
  ipynb = "ipynb",
}

local FILETYPES = { html = "html", md = "markdown", txt = "text", latex = "tex", org = "org" }

local function cfg()
  return require("org.config").opts.export or {}
end

--- Lines of the buffer with noexport/COMMENT subtrees removed (org -> org).
local function filtered_org(lines, subtree_line)
  local parser = require("org.parser")
  local file = parser.parse(lines)
  local exclude = {}
  for _, t in ipairs(cfg().exclude_tags or { "noexport" }) do
    exclude[t] = true
  end
  local drop = {}
  for _, hl in ipairs(file.headlines) do
    local bad = hl.commented
    for _, t in ipairs(hl.tags) do
      if exclude[t] then
        bad = true
      end
    end
    if bad then
      for l = hl.line, hl.end_line do
        drop[l] = true
      end
    end
  end
  local s, e = 1, #lines
  if subtree_line then
    local hl = file:headline_at(subtree_line)
    if hl then
      s, e = hl.line, hl.end_line
    end
  end
  local out = {}
  for i = s, e do
    if not drop[i] then
      out[#out + 1] = lines[i]
    end
  end
  return out
end

--- Output path for `ext`.
local function output_path(src, doc_name, ext)
  local dir = cfg().output_dir and utils.expand(cfg().output_dir, vim.fn.fnamemodify(src or ".", ":p:h"))
    or (src and src ~= "" and vim.fn.fnamemodify(src, ":p:h"))
    or vim.fn.getcwd()
  local base = doc_name and doc_name ~= "" and doc_name
    or (src and src ~= "" and vim.fn.fnamemodify(src, ":t:r"))
    or "export"
  base = base:gsub("%." .. vim.pesc(ext) .. "$", "")
  if base:match("^/") or base:match("^~") then
    return utils.expand(base .. "." .. ext)
  end
  return vim.fs.normalize(dir .. "/" .. base .. "." .. ext)
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

--- Export through pandoc from the (filtered) org text.
local function pandoc_export(fmt, lines, src, doc_name, opts)
  local cmd, extra = pandoc_cmd()
  if vim.fn.executable(cmd[1]) == 0 then
    utils.error("pandoc not found (needed for " .. fmt .. " export). Install pandoc or set export.pandoc.cmd")
    return nil
  end
  local ext = fmt == "pdf" and "pdf" or (PANDOC_EXT[fmt] or fmt)
  local out = opts.output or output_path(src, doc_name, ext)
  vim.list_extend(cmd, { "-f", "org", "-o", out })
  if fmt ~= "pdf" then
    vim.list_extend(cmd, { "-t", fmt })
  end
  if not opts.body_only then
    cmd[#cmd + 1] = "--standalone"
  end
  vim.list_extend(cmd, extra)
  local cwd = src and src ~= "" and vim.fn.fnamemodify(src, ":p:h") or vim.fn.getcwd()
  local res = run(cmd, { stdin = table.concat(lines, "\n") .. "\n", cwd = cwd, text = true })
  if res.code ~= 0 then
    utils.error("pandoc failed:\n" .. (res.stderr or ""))
    return nil
  end
  return out
end

--- Compile a .tex file to PDF with latexmk / pdflatex, falling back to pandoc.
local function tex_to_pdf(tex, lines, src, doc_name, opts)
  local dir = vim.fn.fnamemodify(tex, ":h")
  local pdf = tex:gsub("%.tex$", ".pdf")
  if vim.fn.executable("latexmk") == 1 then
    local res = run({ "latexmk", "-pdf", "-interaction=nonstopmode", "-halt-on-error", "-output-directory=" .. dir, tex }, { cwd = dir, text = true })
    if res.code == 0 then
      run({ "latexmk", "-c", "-output-directory=" .. dir, tex }, { cwd = dir })
      return pdf
    end
    utils.error("latexmk failed:\n" .. (res.stdout or ""):sub(-2000))
    return nil
  elseif vim.fn.executable("pdflatex") == 1 then
    for _ = 1, 2 do
      local res = run({ "pdflatex", "-interaction=nonstopmode", "-halt-on-error", "-output-directory=" .. dir, tex }, { cwd = dir, text = true })
      if res.code ~= 0 then
        utils.error("pdflatex failed:\n" .. (res.stdout or ""):sub(-2000))
        return nil
      end
    end
    for _, e in ipairs({ "aux", "log", "out", "toc" }) do
      os.remove((tex:gsub("%.tex$", "." .. e)))
    end
    return pdf
  end
  return pandoc_export("pdf", lines, src, doc_name, opts)
end

--- Export a buffer.
---@param format string html|md|markdown|txt|latex|pdf|org|<pandoc format>
---@param opts? { bufnr?: integer, subtree?: boolean, subtree_line?: integer, body_only?: boolean, to_buffer?: boolean, open?: boolean, output?: string, options?: table }
---@return string|nil output path (or buffer name) / nil on failure
function M.export(format, opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  if bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  local fmt = ALIASES[format] or format
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local src = vim.api.nvim_buf_get_name(bufnr)
  local subtree_line = opts.subtree_line
  if opts.subtree and not subtree_line then
    subtree_line = vim.api.nvim_win_get_cursor(0)[1]
  end

  if fmt == "org" then
    local out_lines = filtered_org(lines, subtree_line)
    local text = table.concat(out_lines, "\n") .. "\n"
    if opts.to_buffer or not opts.output then
      open_scratch(text, "org", "Org Export")
      return "buffer"
    end
    utils.writefile(opts.output, out_lines)
    return opts.output
  end

  local backend_mod = M.BACKENDS[fmt]
  local native = backend_mod or fmt == "pdf"
  if not native then
    local out = pandoc_export(fmt, filtered_org(lines, subtree_line), src, nil, opts)
    if out then
      utils.notify("Exported to " .. out)
      if opts.open or cfg().open_after_export then
        vim.ui.open(out)
      end
    end
    return out
  end

  local ast = require("org.export.ast")
  local ok, doc = pcall(ast.parse, lines, { filename = src ~= "" and src or nil, subtree_line = subtree_line, options = opts.options })
  if not ok then
    utils.error("Export failed while parsing: " .. tostring(doc))
    return nil
  end
  local backend = require(backend_mod or M.BACKENDS.latex)
  local ok2, text = pcall(backend.render, doc, { body_only = opts.body_only })
  if not ok2 then
    utils.error("Export failed: " .. tostring(text))
    return nil
  end
  if opts.to_buffer then
    open_scratch(text, FILETYPES[fmt] or "tex", "Org " .. fmt:upper() .. " Export")
    return "buffer"
  end
  local out
  if fmt == "pdf" then
    local tex = output_path(src, doc.export_file_name, "tex")
    utils.writefile(tex, vim.split((text:gsub("\n$", "")), "\n", { plain = true }))
    out = tex_to_pdf(tex, filtered_org(lines, subtree_line), src, doc.export_file_name, opts)
  else
    out = opts.output or output_path(src, doc.export_file_name, backend.extension)
    utils.writefile(out, vim.split((text:gsub("\n$", "")), "\n", { plain = true }))
  end
  if out then
    utils.notify("Exported to " .. out)
    if opts.open or cfg().open_after_export then
      vim.ui.open(out)
    end
  end
  return out
end

--- Render a buffer to a string without writing anything (for tests / API).
function M.to_string(format, opts)
  opts = opts or {}
  local bufnr = opts.bufnr or 0
  local fmt = ALIASES[format] or format
  local lines = opts.lines or vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local ast = require("org.export.ast")
  local doc = ast.parse(lines, { filename = opts.filename, subtree_line = opts.subtree_line, options = opts.options })
  return require(M.BACKENDS[fmt]).render(doc, { body_only = opts.body_only })
end

--- Insert the export keywords with their current values (C-c C-e #,
--- org-export-insert-default-template). With `subtree`, set EXPORT_*
--- properties on the current headline instead.
---@param opts? { subtree?: boolean }
function M.insert_template(opts)
  opts = opts or {}
  local ast = require("org.export.ast")
  local file = require("org.files").get_buffer(0)
  local o = ast.options(file.settings)
  local function fmt(v)
    if v == true then
      return "t"
    elseif v == false then
      return "nil"
    elseif type(v) == "table" then
      local parts = {}
      for _, x in ipairs(v) do
        parts[#parts + 1] = '"' .. x .. '"'
      end
      return "(" .. (v.negate and "not " or "") .. table.concat(parts, " ") .. ")"
    end
    return tostring(v)
  end
  local keys = {
    { "<", "timestamps" },
    { "H", "H" },
    { "\\n", "linebreaks" },
    { "^", "sub" },
    { "arch", "arch" },
    { "author", "author" },
    { "c", "clocks" },
    { "d", "drawers" },
    { "date", "date" },
    { "e", "entities" },
    { "email", "email" },
    { "f", "footnotes" },
    { "num", "num" },
    { "p", "planning" },
    { "pri", "pri" },
    { "prop", "prop" },
    { "stat", "stat" },
    { "tags", "tags" },
    { "tasks", "tasks" },
    { "tex", "latex" },
    { "title", "title" },
    { "toc", "toc" },
    { "todo", "todo" },
    { "|", "tables" },
  }
  local items = {}
  for _, k in ipairs(keys) do
    items[#items + 1] = k[1] .. ":" .. fmt(o[k[2]])
  end
  local kw = file.settings.keywords
  local function first(name, default)
    return kw[name] and kw[name][1] or default
  end
  local name = vim.api.nvim_buf_get_name(0)
  local today = require("org.date").today():clone({ active = false }):to_string()
  local values = {
    { "TITLE", first("TITLE", name ~= "" and vim.fn.fnamemodify(name, ":t:r") or "") },
    { "DATE", first("DATE", today) },
    { "AUTHOR", first("AUTHOR", vim.env.USER or "") },
    { "EMAIL", first("EMAIL", "") },
    { "LANGUAGE", first("LANGUAGE", "en") },
    { "SELECT_TAGS", table.concat(o.select_tags or {}, " ") },
    { "EXCLUDE_TAGS", table.concat(o.exclude_tags or {}, " ") },
  }
  if opts.subtree then
    local edit = require("org.edit")
    local bufnr, _, hl = edit.resolve_headline()
    if not hl then
      utils.warn("No subtree to set export options for")
      return
    end
    local line = hl.line
    edit.set_property(bufnr, line, "EXPORT_OPTIONS", table.concat(items, " "))
    for _, kv in ipairs(values) do
      if kv[1] ~= "SELECT_TAGS" and kv[1] ~= "EXCLUDE_TAGS" then
        local v = kv[1] == "TITLE" and hl:plain_title() or kv[2]
        edit.set_property(bufnr, line, "EXPORT_" .. kv[1], v)
      end
    end
    return
  end
  local out = {}
  local cur = "#+options:"
  for _, item in ipairs(items) do
    if #cur + #item + 1 > 70 then
      out[#out + 1] = cur
      cur = "#+options:"
    end
    cur = cur .. " " .. item
  end
  out[#out + 1] = cur
  for _, kv in ipairs(values) do
    out[#out + 1] = "#+" .. kv[1]:lower() .. ": " .. kv[2]
  end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  vim.api.nvim_buf_set_lines(0, row - 1, row - 1, false, out)
  return out
end

--- Emacs-like export dispatcher (C-c C-e).
function M.prompt()
  if not utils.ensure_org() then
    return
  end
  local state = { subtree = false, body_only = false }
  local subtree_line = vim.api.nvim_win_get_cursor(0)[1]
  while true do
    local function onoff(v)
      return v and "on" or "off"
    end
    local items = {
      { key = "s", label = "Toggle: export scope = " .. (state.subtree and "subtree" or "buffer"), value = { toggle = "subtree" } },
      { key = "b", label = "Toggle: body only = " .. onoff(state.body_only), value = { toggle = "body_only" } },
      {
        key = "h",
        label = "Export to HTML",
        items = {
          { key = "h", label = "As HTML file", value = { fmt = "html" } },
          { key = "H", label = "As HTML buffer", value = { fmt = "html", to_buffer = true } },
          { key = "o", label = "As HTML file and open", value = { fmt = "html", open = true } },
        },
      },
      {
        key = "m",
        label = "Export to Markdown",
        items = {
          { key = "m", label = "As Markdown file", value = { fmt = "md" } },
          { key = "M", label = "As Markdown buffer", value = { fmt = "md", to_buffer = true } },
          { key = "o", label = "As Markdown file and open", value = { fmt = "md", open = true } },
        },
      },
      {
        key = "t",
        label = "Export to plain text",
        items = {
          { key = "u", label = "As UTF-8 text file", value = { fmt = "txt" } },
          { key = "a", label = "As UTF-8 text file", value = { fmt = "txt" } },
          { key = "U", label = "As UTF-8 text buffer", value = { fmt = "txt", to_buffer = true } },
          { key = "o", label = "As text file and open", value = { fmt = "txt", open = true } },
        },
      },
      {
        key = "l",
        label = "Export to LaTeX",
        items = {
          { key = "l", label = "As LaTeX file", value = { fmt = "latex" } },
          { key = "L", label = "As LaTeX buffer", value = { fmt = "latex", to_buffer = true } },
          { key = "p", label = "As PDF file", value = { fmt = "pdf" } },
          { key = "o", label = "As PDF file and open", value = { fmt = "pdf", open = true } },
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
      { key = "O", label = "As Org buffer (noexport removed)", value = { fmt = "org", to_buffer = true } },
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
      return M.insert_template({ subtree = state.subtree })
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
        to_buffer = choice.to_buffer,
        open = choice.open,
      })
    end
  end
end

--- :Org export [format] [subtree] [body] [buffer] [open]
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
    elseif w == "buffer" then
      opts.to_buffer = true
    elseif w == "open" then
      opts.open = true
    end
  end
  return M.export(words[1], opts)
end

return M
