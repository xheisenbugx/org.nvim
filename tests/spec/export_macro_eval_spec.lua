-- (eval ...) macros and the built-in macros (org-macro.el). Expected outputs
-- were produced by Emacs 31 / Org 9.8.10 in batch (org-export-as 'ascii /
-- 'texinfo, body only). Forms the Lisp interpreter doesn't implement run in
-- an external Emacs: those tests are skipped without an `emacs` executable.
local ox = require("org.export.ox")
local config = require("org.config")

local function has_emacs()
  return require("org.babel.elisp").command() ~= nil
end

local function export(backend, lines, filename)
  return (ox.export_as(backend, lines, { body_only = true, filename = filename }))
end

--- The exported text as one line (the ASCII back-end fills paragraphs).
local function flat(s)
  return vim.trim((s:gsub("%s+", " ")))
end

local macros = {
  "#+MACRO: up (eval (upcase $1))",
  '#+MACRO: cat (eval (concat "<" $1 "|" $2 ">"))',
  '#+MACRO: lit (eval (concat "$1" "-" $1))',
  "#+MACRO: num (eval (+ 1 2))",
  "#+MACRO: nilm (eval nil)",
  '#+MACRO: lst (eval (list 1 "a"))',
  '#+MACRO: miss (eval (concat "x" $2))',
  '#+MACRO: str (eval "plain $1")',
  '#+MACRO: fmt (eval (format "%d-%s" (string-to-number $1) $2))',
  "#+MACRO: ext (eval (string-reverse $1))",
  "",
}

describe("(eval ...) macros", function()
  local saved
  before_each(function()
    saved = { vim.deepcopy(config.opts.babel.emacs_lisp), config.opts.export.with_author }
    config.opts.babel.evaluate_on_export = false
    config.opts.export.with_author = false
  end)
  after_each(function()
    config.opts.babel.emacs_lisp = saved[1]
    config.opts.export.with_author = saved[2]
  end)

  it("evaluate the form with $1..$N bound to the arguments", function()
    config.opts.babel.emacs_lisp.command = false
    local lines = vim.list_extend(vim.deepcopy(macros), {
      "up: {{{up(hello)}}}",
      "cat: {{{cat(a,b)}}}",
      "lit: {{{lit(z)}}}",
      "num: {{{num}}}",
      "nil: [{{{nilm}}}]",
      "lst: {{{lst}}}",
      "miss: {{{miss(a)}}}",
      "str: {{{str(q)}}}",
      "fmt: {{{fmt(12,x)}}}",
    })
    -- Emacs: $1 inside a string stays as it is, missing arguments are nil,
    -- the value is inserted with (format "%s" ...)
    eq("up: HELLO cat: <a|b> lit: $1-z num: 3 nil: [] lst: (1 a) miss: x str: plain $1 fmt: 12-x",
      flat(export("ascii", lines)))
  end)

  it("export nothing when they can't be evaluated", function()
    config.opts.babel.emacs_lisp.command = false
    local warn = require("org.utils").warn
    require("org.utils").warn = function() end
    local out = export("ascii", vim.list_extend(vim.deepcopy(macros), { "ext: {{{ext(abc)}}}" }))
    require("org.utils").warn = warn
    eq("ext:", flat(out))
  end)

  it("run in Emacs what the interpreter does not implement", function()
    if not has_emacs() then
      return
    end
    eq("ext: cba", flat(export("ascii", vim.list_extend(vim.deepcopy(macros), { "ext: {{{ext(abc)}}}" }))))
  end)

  it("org-texinfo-kbd-macro exports key bindings like the Org manual", function()
    config.opts.babel.emacs_lisp.command = false
    local out = export("texinfo", {
      "#+MACRO: kbd (eval (org-texinfo-kbd-macro $1))",
      "#+MACRO: kbdn (eval (org-texinfo-kbd-macro $1 t))",
      "",
      "* Keys",
      "Type {{{kbd(C-c SPC)}}} or {{{kbd(M-RET x)}}} then {{{kbd(C-x TAB)}}}.",
    })
    eq(table.concat({
      "@node Keys",
      "@chapter Keys",
      "",
      "Type @kbd{C-c @key{SPC}} or @kbd{M-@key{RET} x} then @kbd{C-x @key{TAB}}.",
    }, "\n"), vim.trim(out))
    eq("@kbd{C-c @key{SPC}}", require("org.table.elisp").eval('(org-texinfo-kbd-macro "C-c SPC" t)'))
  end)
end)

describe("built-in macros", function()
  before_each(function()
    config.opts.babel.evaluate_on_export = false
  end)

  it("expand like org-macro-initialize-templates", function()
    local path = vim.fn.tempname() .. "/bm_builtin.org"
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    local lines = {
      "#+TITLE: The *title*",
      "#+AUTHOR: Ann Author",
      "#+EMAIL: ann@example.org",
      "#+DATE: <2024-03-05 Tue>",
      "#+KEYWORDS: alpha beta",
      '#+MACRO: time (eval (format "custom-%s" $1))',
      "",
      "* Head",
      ":PROPERTIES:",
      ":CUSTOM_ID: h1",
      ":COLOR: blue",
      ":END:",
      "title={{{title}}} author={{{author}}} email={{{email}}}",
      "date={{{date}}} date2={{{date(%Y/%m/%d)}}}",
      "kw={{{keyword(KEYWORDS)}}} file={{{input-file}}}",
      "n={{{n}}} {{{n}}} {{{n(x)}}} {{{n}}} {{{n(x,-)}}} {{{n(,5)}}} {{{n}}}",
      "prop={{{property(COLOR)}}} prop2={{{property(COLOR,#h1)}}}",
      "time={{{time(%Y)}}}",
      "mtime={{{modification-time(%Y)}}}",
    }
    vim.fn.writefile(lines, path)
    -- a #+MACRO named like a built-in one replaces it (time), as in Emacs
    eq(
      "1 Head ====== title=The *title* author=Ann Author email=ann@example.org date=<2024-03-05 Tue> "
        .. "date2=2024/03/05 kw=alpha beta file=bm_builtin.org n=1 2 1 3 1 5 6 prop=blue prop2=blue "
        .. "time=custom-%Y mtime="
        .. os.date("%Y", vim.fn.getftime(path)),
      flat(export("ascii", lines, path))
    )
    eq("y=" .. os.date("%Y"), flat(export("ascii", { "y={{{time(%Y)}}}" })))
  end)
end)
