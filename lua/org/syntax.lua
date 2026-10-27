---@mod org.syntax The Vim syntax of org buffers: src block languages
---
--- Org buffers are drawn by the parser highlighter (org.ui.highlight, from
--- the decoration provider of org.ui.decorations). The `:syntax` of an org
--- buffer only includes the Vim syntax of the languages of its src and
--- export blocks that tree-sitter doesn't draw (org-src-fontify-natively,
--- `ui.src_highlight`), in regions over their bodies, and keeps the bodies
--- tree-sitter draws out of spell checking. syntax/org.lua applies it.

local M = {}

--- src block language -> vim syntax name
M.lang_aliases = {
  sh = "sh",
  shell = "sh",
  bash = "sh",
  zsh = "zsh",
  js = "javascript",
  javascript = "javascript",
  ts = "typescript",
  typescript = "typescript",
  py = "python",
  python = "python",
  python3 = "python",
  elisp = "lisp",
  ["emacs-lisp"] = "lisp",
  lisp = "lisp",
  lua = "lua",
  vim = "vim",
  viml = "vim",
  rb = "ruby",
  ruby = "ruby",
  rust = "rust",
  rs = "rust",
  go = "go",
  c = "c",
  cpp = "cpp",
  ["c++"] = "cpp",
  java = "java",
  sql = "sql",
  sqlite = "sql",
  json = "json",
  yaml = "yaml",
  toml = "toml",
  html = "html",
  css = "css",
  latex = "tex",
  tex = "tex",
  r = "r",
  R = "r",
  perl = "perl",
  php = "php",
  haskell = "haskell",
  dot = "dot",
  diff = "diff",
  make = "make",
  dockerfile = "dockerfile",
  markdown = "markdown",
  md = "markdown",
  xml = "xml",
  awk = "awk",
  fish = "fish",
  nix = "nix",
  elixir = "elixir",
  clojure = "clojure",
  scheme = "scheme",
  ocaml = "ocaml",
  kotlin = "kotlin",
  swift = "swift",
  scala = "scala",
  zig = "zig",
}

local function cmd(s)
  vim.cmd(s)
end

local function esc(s)
  -- magic-mode specials only (escaping + ? = etc. would turn them into multis)
  return vim.fn.escape(s, [[\/.*$^~[]])
end

--- The language of a `#+begin_src <lang>` or `#+begin_export <lang>` line.
local function block_language(line)
  local kind, lang = line:match("^%s*#%+[bB][eE][gG][iI][nN]_(%a+)%s+([^%s]+)")
  if kind and (kind:lower() == "src" or kind:lower() == "export") then
    return lang
  end
end

--- Languages used in `#+begin_src <lang>` and `#+begin_export <lang>`
--- lines of the buffer.
local function src_languages(bufnr)
  local langs = {}
  for _, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    local lang = line:byte(1) ~= 42 and block_language(line)
    if lang then
      langs[lang] = true
    end
  end
  return langs
end

local function has_syntax(name)
  return #vim.api.nvim_get_runtime_file("syntax/" .. name .. ".vim", false) > 0
    or #vim.api.nvim_get_runtime_file("syntax/" .. name .. ".lua", false) > 0
end

-- The variables that turn off the concealing of the syntax files of src
-- block languages (syntax/json.vim, syntax/markdown.vim)
local NO_CONCEAL = { "vim_json_conceal", "markdown_syntax_conceal" }

--- The vim syntax of a src block language: src_lang_modes
--- (org-src-lang-modes) first, then the built-in aliases.
local function syntax_of(lang)
  local modes = require("org.config").opts.src_lang_modes or {}
  if modes[lang] ~= nil then
    return modes[lang]
  end
  return M.lang_aliases[lang] or lang
end
M.syntax_of = syntax_of

--- Whether src blocks of `lang` can get a language syntax (not "org", in
--- any case: Neovim's bundled syntax/org.vim, which a case-insensitive file
--- system finds for "ORG" too, would define its regions over the whole
--- buffer; org.ui.highlight draws org bodies as Org).
local function includable(syn)
  return syn ~= "" and syn:lower() ~= "org" and syn:match("^[%w_]+$") ~= nil and has_syntax(syn)
end

--- How src blocks of the Vim syntax `syn` are highlighted: "treesitter"
--- (org.ui.src_highlight draws them), "syntax" (the syntax is included) or
--- nil (not at all), by `ui.src_highlight` and `ui.src_highlight_engine`.
---@return "treesitter"|"syntax"|nil
local function drawn_by(syn)
  local ts = require("org.ui.src_highlight")
  local engine = ts.engine()
  if not engine then
    return nil
  end
  if engine ~= "syntax" and ts.ts_lang_of_syntax(syn) then
    return "treesitter"
  end
  if engine ~= "treesitter" and includable(syn) then
    return "syntax"
  end
  return nil
end

--- Per buffer: the languages seen by the last `apply` (or found to have no
--- syntax since), and whether a new one is waiting.
local languages = {} ---@type table<integer, { seen: table<string, boolean>, pending: boolean, watching: boolean }>

--- The src and export block languages seen in `buf` (a superset of those
--- in it: one deleted since stays), or nil before its syntax was applied.
---@return table<string, boolean>?
function M.languages_seen(buf)
  local l = languages[buf]
  return l and l.seen
end

local function reapply(buf)
  local l = languages[buf]
  if not (l and l.pending) then
    return
  end
  l.pending = false
  if vim.api.nvim_buf_is_valid(buf) and vim.b[buf].current_syntax == "org" then
    vim.api.nvim_buf_call(buf, function()
      M.apply(buf)
    end)
  end
end

--- Highlight src blocks of a language as soon as a `#+begin_src <lang>`
--- line for it appears: the syntax is applied again (Emacs fontifies every
--- new block natively at once).
local function watch_languages(bufnr)
  if languages[bufnr].watching then
    return
  end
  languages[bufnr].watching = true
  vim.api.nvim_buf_attach(bufnr, false, {
    on_lines = function(_, buf, _, first, _, last)
      local l = languages[buf]
      if not l then
        return true
      end
      if l.pending or last - first > 1000 then
        return
      end
      for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, first, last, false)) do
        local lang = line:byte(1) ~= 42 and block_language(line)
        if lang and not l.seen[lang] then
          l.seen[lang] = true
          if drawn_by(syntax_of(lang)) then
            l.pending = true
            vim.schedule(function()
              reapply(buf)
            end)
            return
          end
        end
      end
    end,
    on_detach = function(_, buf)
      languages[buf] = nil
    end,
  })
  -- (before the next redraw when the change came from a command)
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP", "InsertLeave" }, {
    group = vim.api.nvim_create_augroup("org.syntax." .. bufnr, { clear = true }),
    buffer = bufnr,
    callback = function(ev)
      reapply(ev.buf)
    end,
  })
end

-- A block always ends at a headline (org-fontify-meta-lines-and-blocks),
-- so an unterminated #+begin_src doesn't swallow the rest of the file.
local BLOCK_STOP = [=[end=/^\ze\*\+\s/]=]

--- The regions of src and export blocks whose language is drawn by an
--- included Vim syntax (or by tree-sitter: the region then only keeps the
--- body out of spell checking), and the syncing.
---@param bufnr integer
---@param config table
local function src_regions(bufnr, config)
  local langs = src_languages(bufnr)
  languages[bufnr] = languages[bufnr] or {}
  languages[bufnr].seen = vim.deepcopy(langs)
  languages[bufnr].pending = false
  watch_languages(bufnr)
  do
    local included = {}
    local modes = config.src_lang_modes or {}
    local sorted = vim.tbl_keys(langs)
    table.sort(sorted)
    local raw = false
    for _, lang in ipairs(sorted) do
      local syn = syntax_of(lang)
      local how = not included[syn] and drawn_by(syn)
      if how then
        if not raw then
          raw = true
          -- The bodies of src, example, export and comment blocks are
          -- raw text: a `#+begin_src <lang>` line in one opens no
          -- language region that would run on past the block. (Defined
          -- first: on a block's own begin line the language region,
          -- defined after it, wins.)
          cmd(
            string.format(
              [=[syntax region orgBlockRaw start=/\c^\s*#+begin_\z(src\|example\|export\|comment\)\%%(\s.*\)\=$/ end=/\c^\s*#+end_\z1\%%(\s.*\)\=$/ %s keepend contains=@NoSpell]=],
              BLOCK_STOP
            )
          )
        end
        included[syn] = true
        local cluster = "orgSrc_" .. syn
        if how == "syntax" then
          local saved = vim.b.current_syntax
          vim.b.current_syntax = nil
          -- Emacs shows a block as typed: no concealing from the language's
          -- syntax (json hides the quotes of strings, markdown the markers
          -- of emphasis). Off only while it is included here, so files of
          -- that language keep the user's setting.
          local conceal = {}
          for _, var in ipairs(NO_CONCEAL) do
            conceal[var] = vim.g[var]
            vim.g[var] = 0
          end
          local ok = pcall(cmd, string.format("syntax include @%s syntax/%s.vim", cluster, syn))
          if not ok then
            pcall(cmd, string.format("syntax include @%s syntax/%s.lua", cluster, syn))
          end
          for _, var in ipairs(NO_CONCEAL) do
            vim.g[var] = conceal[var]
          end
          vim.b.current_syntax = saved
          -- (back to the default after an included file's `syntax case
          -- ignore`)
          cmd("syntax case match")
        else
          -- tree-sitter draws the body (org.ui.src_highlight): the region
          -- only keeps it plain text, like an included syntax's leftovers
          cmd(string.format("syntax cluster %s contains=@NoSpell", cluster))
        end
        -- all aliases of this syntax
        local names = { esc(lang) }
        local seen = { [lang] = true }
        for _, map in ipairs({ modes, M.lang_aliases }) do
          for alias in pairs(map) do
            if not seen[alias] and syntax_of(alias) == syn then
              seen[alias] = true
              names[#names + 1] = esc(alias)
            end
          end
        end
        -- (the language ends at a blank: "c++" is not "c")
        for _, kind in ipairs({ "src", "export" }) do
          cmd(
            string.format(
              [=[syntax region orgSrcBlock_%s matchgroup=orgSrcDelimiter start=/\c^\s*#+begin_%s\s\+\%%(%s\)\%%(\s.*\)\=$/ end=/\c^\s*#+end_%s\%%(\s.*\)\=$/ %s keepend contains=@%s]=],
              syn,
              kind,
              table.concat(names, [[\|]]),
              kind,
              BLOCK_STOP,
              cluster
            )
          )
        end
      end
    end
  end
  -- Included syntax files set the buffer's syncing and spell options:
  -- org's own come last.
  cmd("syntax spell toplevel")
  cmd("syntax sync clear")
  -- Sync on headlines and block delimiters, which no region crosses, so a
  -- line in the middle of a long block is still drawn in its language when
  -- it is the first line on screen.
  cmd("syntax sync minlines=10 maxlines=5000")
  -- (block begin lines are no sync points: parsing from the headline or
  -- block end above them finds the block)
  cmd([=[syntax sync match orgSyncHeadline grouphere NONE /^\*\+\s/]=])
  cmd([=[syntax sync match orgSyncBlockEnd grouphere NONE /\c^\s*#+end_\S*/]=])
end

--- Define the syntax of `bufnr`: the src block regions (see the top of
--- this module).
---@param bufnr? integer
function M.apply(bufnr)
  require("org.highlights").ensure()
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  cmd("syntax clear")
  cmd("syntax spell toplevel")
  src_regions(bufnr, require("org.config").opts)
  require("org.highlights").apply_todo_faces()
  -- (`:syntax clear` above deleted it: without it the syntax would no
  -- longer be defined again for a new src language)
  vim.b[bufnr].current_syntax = "org"
end

--- Draw `bufnr`, which sets 'syntax' to org without being an org buffer
--- (the drill window), with the parser highlighter, until its 'syntax'
--- changes.
---@param bufnr integer
function M.attach_decorations(bufnr)
  if vim.bo[bufnr].filetype == "org" then
    return
  end
  require("org.ui.decorations").attach(bufnr)
  -- (one group for all such buffers, each with its own autocmd)
  local group = vim.api.nvim_create_augroup("org.syntax.decorations", { clear = false })
  vim.api.nvim_clear_autocmds({ group = group, buffer = bufnr })
  vim.api.nvim_create_autocmd("Syntax", {
    group = group,
    buffer = bufnr,
    callback = function(ev)
      if ev.match ~= "org" and vim.bo[ev.buf].filetype ~= "org" then
        vim.api.nvim_clear_autocmds({ group = group, buffer = ev.buf })
        require("org.ui.decorations").detach(ev.buf)
      end
    end,
  })
end

return M
