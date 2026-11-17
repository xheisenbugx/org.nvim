---@mod org.export.latex.compile LaTeX to PDF compilation
---
--- org-latex-compile: the PDF process and its log.
---
--- Part of org.export.latex, which loads it.

local data = require("org.export.latex_data")
local shared = require("org.export.latex.shared")

local M = require("org.export.latex")

local lcfg = shared.lcfg

---------------------------------------------------------------------------
-- PDF compilation (org-latex-compile)
---------------------------------------------------------------------------

--- Commands used to compile (org-latex-pdf-process).
function M.pdf_process()
  local p = lcfg().pdf_process
  if p then
    return p
  end
  if vim.fn.executable("latexmk") == 1 and vim.fn.executable("perl") == 1 then
    return { "latexmk -f -pdf -%latex -interaction=nonstopmode -output-directory=%o %f" }
  end
  return {
    "%latex -interaction nonstopmode -output-directory %o %f",
    "%latex -interaction nonstopmode -output-directory %o %f",
    "%latex -interaction nonstopmode -output-directory %o %f",
  }
end

local function shell_quote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

--- Name of the buffer that gets the output of the compilation.
M.LOG_BUFFER = "*Org PDF LaTeX Output*"

--- Compile `texfile` to PDF (org-latex-compile): run
--- `export.latex.pdf_process`, its output going to the
--- "*Org PDF LaTeX Output*" buffer. Without `on_done` return pdf|nil,
--- err|nil, warnings, log. With `on_done`, run in the background, call
--- on_done(pdf|nil, err|nil, warnings, log) when done and return the
--- running process (|org.export.process|), which can be cancelled.
--- The options are read when the compilation starts.
---@param texfile string
---@param on_done? fun(pdf: string?, err: string?, warnings: string|string[]?, log: string?)
---@return any pdf the PDF (nil on failure), or the running process with on_done
---@return string? err
---@return string|string[]? warnings
---@return string? log
function M.compile(texfile, on_done)
  local lines = vim.fn.readfile(texfile, "", 2)
  local compiler
  for _, l in ipairs(lines) do
    local c = l:match("^%%.*(pdflatex)") or l:match("^%%.*(xelatex)") or l:match("^%%.*(lualatex)")
    if c then
      compiler = c
    end
  end
  compiler = compiler or lcfg().compiler or "pdflatex"
  local process = M.pdf_process()
  local dir = vim.fn.fnamemodify(texfile, ":p:h")
  local base = vim.fn.fnamemodify(texfile, ":t:r")
  local out = dir .. "/" .. base .. ".pdf"
  local bib = lcfg().bib_compiler or "bibtex"
  if type(process) == "function" then
    local ok, err = pcall(process, texfile)
    local pdf = vim.fn.filereadable(out) == 1 and out or nil
    if on_done then
      on_done(pdf, not ok and tostring(err) or nil)
      return
    end
    return pdf, not ok and tostring(err) or nil
  end
  -- one pass, with a function: a `%` in a file name is neither a capture
  -- of the replacement nor a spec of a later substitution
  local spec = {
    latex = shell_quote(compiler),
    bibtex = shell_quote(bib),
    bib = shell_quote(bib),
    F = shell_quote(vim.fn.fnamemodify(texfile, ":p")),
    f = shell_quote(vim.fn.fnamemodify(texfile, ":t")),
    b = shell_quote(base),
    o = shell_quote(dir),
    O = shell_quote(out),
  }
  local cmds = {}
  for _, c in ipairs(process) do
    cmds[#cmds + 1] = c:gsub("%%(%a+)", function(w)
      for _, k in ipairs({ "latex", "bibtex", "bib" }) do
        if w:sub(1, #k) == k then
          return spec[k] .. w:sub(#k + 1)
        end
      end
      local k = w:sub(1, 1)
      return spec[k] and spec[k] .. w:sub(2)
    end)
  end
  local mtime_before = vim.fn.getftime(out)
  local remove_logfiles = lcfg().remove_logfiles ~= false
  local logfiles_extensions = lcfg().logfiles_extensions or data.logfiles_extensions
  ---@param run org.export.Process
  local function finish(run)
    local produced = not run.cancelled and vim.fn.filereadable(out) == 1 and vim.fn.getftime(out) >= mtime_before
    local text = run:text()
    if not produced then
      -- org-compile-file signals the error before the log files are
      -- removed: they are kept, with the output buffer, for a look
      local err = string.format('File "%s" wasn\'t produced  See "%s" for details', out, run.log_name or M.LOG_BUFFER)
      if run.cancelled then
        err = "Compilation of " .. vim.fn.fnamemodify(texfile, ":t") .. " cancelled"
      end
      return nil, err, nil, text
    end
    if remove_logfiles then
      -- the files of `dir` named `base.*ext` (listed, not globbed:
      -- vim.fn.glob() would run `backticks` of #+EXPORT_FILE_NAME)
      local names = {}
      for name in require("org.utils").scandir(dir) do
        if name:sub(1, #base + 1) == base .. "." then
          names[#names + 1] = name
        end
      end
      for _, ext in ipairs(logfiles_extensions) do
        for _, name in ipairs(names) do
          local f = dir .. "/" .. name
          if name:sub(-#ext) == ext and f:match(vim.pesc(base) .. "%.?%d*%." .. vim.pesc(ext) .. "$") then
            os.remove(f)
          end
        end
        os.remove(dir .. "/" .. base .. "." .. ext)
      end
    end
    return out, nil, M.log_warnings(text), text
  end
  local process_mod = require("org.export.process")
  local popts = { cwd = dir, log_buffer = M.LOG_BUFFER }
  if not on_done then
    return finish(process_mod.run(cmds, popts))
  end
  return process_mod.run(cmds, popts, function(run)
    on_done(finish(run))
  end)
end
