---@mod org.syntax Regex syntax highlighting for org buffers

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
M.block_language = block_language

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

-- Link target inside [[...]]: no unescaped brackets (org-link-bracket-re).
local LINK_TARGET = [=[\%([^][\\]\|\\\+[][]\|\\\+[^][]\)\+]=]
-- Link description: anything up to "]]", over at most one line break
-- (`fill-paragraph` wraps long descriptions).
local LINK_DESC = [=[\%(.\{-1,}\|.\{-}\n.\{-}\)]=]
-- Plain link path: balanced parentheses allowed, no trailing punctuation
-- other than "/" (org-link-plain-re).
local PLAIN_PATH = (function()
  local char = [=[[^][[:space:]()<>]]=]
  local group = [=[(\%([^][[:space:]()<>]\|([^][[:space:]()<>]*)\)*)]=]
  return [=[\%(]=] .. char .. [=[\|]=] .. group .. [=[\)*\%([^][[:space:]()<>[:punct:]]\|\/\|]=] .. group .. [=[\)]=]
end)()
-- Start of a plain link: not after a letter or digit. (`\<` would depend on
-- 'iskeyword', which includes "_" and which included src languages change.)
local WORD_START = [=[\%([[:alnum:]]\)\@1<!]=]
-- A line that ends a paragraph (org-element-paragraph-separate): headline,
-- footnote definition, diary sexp, empty line, table, comment, keyword,
-- block, drawer, fixed width, rule, LaTeX environment, clock, list item.
local PARA_SEP = table.concat({
  [=[\*\+\s]=],
  [=[\[fn:[-_[:alnum:]]\+\]]=],
  [=[%%(]=],
  [=[\s*\%($\||\|+\%(-\++\)\+\s*$\|#\%(\s\|$\|+\%([bB][eE][gG][iI][nN]_\S\+\|\S\+\%(\[.*\]\)\=:\)\)\|:\%(\s\|$\|[-_[:alnum:]]\+:\s*$\)\|-\{5,}\s*$\|\\begin{[[:alnum:]*]\+}\|CLOCK:\|\%([-+*]\|\d\+[.)]\)\%(\s\|$\)\)]=],
}, [[\|]])
-- A headline: blocks, LaTeX and links never continue across one.
local HEADLINE = [=[\*\+\s]=]

--- Link syntax: bracket, angle, plain and radio links, and custom link type
--- faces (`links.types.<name>.face`). All are in the `@orgLinks` cluster.
function M.links(bufnr, conceal_links)
  local links = require("org.links")
  local lconceal = conceal_links and " conceal" or ""
  local cluster = { "orgLink", "orgLinkPlain" }
  local schemes = {}
  for name in pairs(links.URL_SCHEMES) do
    schemes[#schemes + 1] = esc(name)
  end
  local types = require("org.config").opts.links.types or {}
  for name in pairs(types) do
    if name:match("^[%w_+%-]+$") then
      schemes[#schemes + 1] = esc(name)
    end
  end
  table.sort(schemes)
  local scheme_alt = table.concat(schemes, [[\|]])
  cmd(string.format([=[syntax match orgLinkPlain /%s\%%(%s\):%s/]=], WORD_START, scheme_alt, PLAIN_PATH))
  -- <type:path> (org-link-angle-re): the path may contain spaces
  cmd(string.format([=[syntax match orgLinkPlain /<\%%(%s\):[^>]\+>/ contains=@NoSpell]=], scheme_alt))
  local bracket = [=[\[\[]=] .. LINK_TARGET .. [=[\]\%(\[]=] .. LINK_DESC .. [=[\]\)\?\]]=]
  cmd(
    string.format(
      [=[syntax match orgLink /%s/ contains=orgLinkTargetHidden,orgLinkBracket,orgTimestamp,orgTimestampInactive,@NoSpell]=],
      bracket
    )
  )
  -- lookbehind (not \zs): orgLinkBracket already consumes the "[[", so a
  -- pattern that has to match from "[[" would never get a chance to apply
  cmd(
    string.format(
      [=[syntax match orgLinkTargetHidden /\(\[\[\)\@<=%s\]\[\ze%s\]\]/ contained]=],
      LINK_TARGET,
      LINK_DESC
    ) .. lconceal
  )
  cmd([[syntax match orgLinkBracket /\[\[\|\]\]/ contained]] .. lconceal)
  -- custom link faces
  for name, def in pairs(types) do
    local face = type(def) == "table" and def.face or nil
    if type(face) == "string" and name:match("^[%w_+%-]+$") then
      local group = "orgLinkType_" .. name:gsub("[^%w_]", "_")
      cmd(
        string.format(
          [=[syntax match %s /\[\[%s:%s\]\%%(\[%s\]\)\?\]/ contains=orgLinkTargetHidden,orgLinkBracket,@NoSpell]=],
          group,
          esc(name),
          LINK_TARGET,
          LINK_DESC
        )
      )
      cmd(string.format([=[syntax match %s /%s%s:%s/]=], group, WORD_START, esc(name), PLAIN_PATH))
      vim.api.nvim_set_hl(0, group, { link = face, default = true })
      cluster[#cluster + 1] = group
    end
  end
  -- radio links: words matching a <<<radio target>>>
  local targets = {}
  for _, t in ipairs(links.radio_targets(bufnr)) do
    targets[#targets + 1] = esc(t):gsub(" +", [[\_s\+]])
  end
  if #targets > 0 then
    cmd(
      string.format(
        [=[syntax match orgRadioLink /\c\%%(^\|[^[:alnum:]]\)\@<=\%%(%s\)\%%($\|[^[:alnum:]]\)\@=/ contains=@NoSpell]=],
        table.concat(targets, [[\|]])
      )
    )
    cluster[#cluster + 1] = "orgRadioLink"
  end
  cmd("syntax cluster orgLinks contains=" .. table.concat(cluster, ","))
end

--- LaTeX fragments and environments, entities and sub/superscripts, as
--- `ui.highlight_latex_and_related` lists them (org-highlight-latex-and-related):
--- "latex" (OrgLatex), "native" (the tex syntax), "entities", "script".
---@param scripts? boolean|string which `^`/`_` are scripts (default
--- `ui.use_sub_superscripts`; a buffer's `#+OPTIONS: ^:` overrides it)
function M.latex_and_related(ui, scripts)
  if scripts == nil then
    scripts = ui.use_sub_superscripts
  end
  local set = {}
  for _, v in ipairs(type(ui.highlight_latex_and_related) == "table" and ui.highlight_latex_and_related or {}) do
    set[v] = true
  end
  if set.entities then
    -- (with the character after the name, like Emacs, unless a blank).
    -- Defined before the environments, which win at "\begin{".
    cmd(
      [=[syntax match orgLatexEntity /\\\%(there4\|sup[123]\|frac[13][24]\|\a\+\)\%({}\|[^[:alpha:][:space:]]\|\ze\s\|$\)/]=]
    )
  end
  local latex = set.latex or set.native
  if latex then
    -- org-latex-regexps with the default org-format-latex-options :matchers
    local contains = ""
    if set.native and has_syntax("tex") then
      local saved = vim.b.current_syntax
      vim.b.current_syntax = nil
      if pcall(cmd, "syntax include @orgTexNative syntax/tex.vim") then
        contains = " contains=@orgTexNative"
      end
      vim.b.current_syntax = saved
      cmd("syntax case match")
    end
    -- $x$ and $...$: not after a $, not starting or ending with blanks
    cmd([=[syntax match orgLatex /\%(^\|[^$]\)\@<=\$[^ \t,;.$]\$\ze\%([[:punct:][:space:]]\|$\)/]=])
    cmd(
      [=[syntax match orgLatex /\%(^\|[^$]\)\@<=\$[^ \t,;.$][^$]\{-}[^ \t,.$]\$\ze\%([[:punct:][:space:]]\|$\)/]=]
        .. contains
    )
    -- $$...$$, \(...\) and \[...\]: only when closed, and not over an empty
    -- line (org-do-latex-and-related) or a headline
    local body = [=[\%(\%(\n\s*\n\|\n]=] .. HEADLINE .. [=[\)\@!\_.\)\{-}]=]
    local stop = [=[ end=/^\ze]=] .. HEADLINE .. [=[/]=]
    for _, d in ipairs({ { [=[\$\$]=], [=[\$\$]=] }, { [=[\\(]=], [=[\\)]=] }, { [=[\\\[]=], [=[\\\]]=] } }) do
      cmd(
        string.format([=[syntax region orgLatex start=/%s\ze%s%s/ end=/%s/%s keepend]=], d[1], body, d[2], d[2], stop)
          .. contains
      )
    end
    -- \begin{env} ... \end{env}, when closed before the next headline
    cmd(
      string.format(
        [=[syntax region orgLatex start=/^\s*\\begin{\z(\([[:alnum:]*]\+\)\)}\ze\%%(\%%(\n%s\)\@!\_.\)\{-}\\end{\1}/ end=/\\end{\z1}/%s keepend]=],
        HEADLINE,
        stop
      ) .. contains
    )
  end
  if set.script and scripts ~= false then
    local body = [=[\%({[^}]*}\|([^)]*)\|\*\|[+-]\?[[:alnum:].,\\]*[[:alnum:]]\)]=]
    if scripts == "{}" then
      body = [=[{[^}]*}]=]
    end
    cmd(string.format([=[syntax match orgLatexScript /\S\@<=[_^]%s/]=], body))
  end
end

-- Inline objects: what paragraphs, emphasis, list terms, property values,
-- footnotes and table cells contain.
local OBJECTS = {
  "@orgLinks",
  "orgTimestamp",
  "orgTimestampInactive",
  "orgSexpDate",
  "orgFootnote",
  "orgMacro",
  "orgTarget",
  "orgStatistic",
  "orgStatisticDone",
  "orgLatex",
  "orgLatexEntity",
  "orgLatexScript",
  "orgLineBreak",
  "orgExportSnippet",
  "orgInlineSrc",
}
local MARKUP = { "orgBold", "orgItalic", "orgUnderline", "orgStrikethrough", "orgVerbatim", "orgCode" }

local function list(...)
  local out = {}
  for _, t in ipairs({ ... }) do
    for _, v in ipairs(type(t) == "table" and t or { t }) do
      out[#out + 1] = v
    end
  end
  return table.concat(out, ",")
end

--- Emphasis (org-do-emphasis-faces): orgBold, orgItalic, orgUnderline,
--- orgStrikethrough, orgVerbatim and orgCode regions.
---@param in_table boolean the variant for table cells (contained in
--- orgTable): never across a "|" (Emacs: "Do not span over cells in table
--- rows"), one line
---@param synmaxcol integer the buffer's 'synmaxcol' (0: no limit)
local function emphasis(in_table, conceal_emph, synmaxcol)
  -- org-emphasis-regexp-components: allowed characters before and after
  -- the markers, the characters the text cannot start or end with (only
  -- blanks), and at most one newline inside (Emacs `org-emph-re`).
  local pre = [=[\%(^\|[[:space:]('"{-]\)\@1<=]=]
  local post = [=[\%($\|[[:space:].,:!?;'")}\[-]\)]=]
  local border = in_table and [=[[^[:space:]|]]=] or [=[\S]=]
  local any = in_table and "[^|]" or "."
  -- Markup is drawn only when it ends before 'synmaxcol': past it Vim
  -- doesn't look for the end of a region, which then went on over the
  -- following lines. The text is matched only up to that column too: each
  -- opening marker looks ahead for its closing one, and a long line with
  -- many unclosed markers took time quadratic in its length (400 ms to
  -- draw a 10,000-character one; at 100,000 "'redrawtime' exceeded" turned
  -- syntax off).
  local before_max, upto_max, count = "", "", [=[\{-}]=]
  if synmaxcol > 0 then
    before_max = string.format([=[\%%<%dc]=], synmaxcol)
    upto_max = string.format([=[\%%<%dc]=], synmaxcol + 1)
    -- (cheaper than testing the column at each character)
    count = string.format([=[\{-,%d}]=], synmaxcol)
  end
  local function chars(c)
    return c .. count
  end
  -- the newline cannot be followed by a line that ends the paragraph
  local nl = in_table and "" or string.format([=[\%%(\n\%%(%s\)\@!%s\)\=]=], PARA_SEP, chars("."))
  local body = string.format([=[\%%(%s\|%s%s%s%s\)%s]=], border, border, chars(any), nl, border, upto_max)
  -- (the general regions don't start on table rows, where the cell
  -- variant applies; ".\{-}": a greedy ".*" went to the end of the line
  -- and back for each marker)
  local not_table = in_table and "" or [=[\%(^\s*|.\{-}\)\@<!]=]
  local function emph(i, char)
    local group = MARKUP[i]
    local c = esc(char)
    -- headline stars never open bold markup (Emacs `org-do-emphasis-faces`),
    -- or "*** Title" would be bold "*" with both outer stars concealed
    local not_stars = char == "*" and [=[\%(^\*\+ \)\@!]=] or ""
    local contains
    if char == "=" or char == "~" then
      contains = ""
    else
      local others = {}
      for j, g in ipairs(MARKUP) do
        -- (not the group itself: "*a *b *c ..." would nest without end)
        if j ~= i then
          others[#others + 1] = g
        end
      end
      contains = "contains=" .. list("@Spell", OBJECTS, others)
    end
    -- The end is the first marker after a non-blank that is not the
    -- opening marker itself: the text is never empty ("==" is no markup).
    -- \%#=1: the backtracking engine tries the cheap look-behind first; the
    -- NFA engine ran out of 'maxmempattern' on long lines with many markers
    cmd(
      string.format(
        [=[syntax region %s matchgroup=%sDelimiter start=/\%%#=1%s%s%s%s%s\ze%s%s%s/ end=/\%%#=1%s\@4<=\%%(\%%(^\|[[:space:]('"{-]\)%s\)\@2<!%s\ze%s/ keepend%s%s %s]=],
        group,
        group,
        before_max,
        not_stars,
        pre,
        c,
        not_table,
        body,
        c,
        post,
        border,
        c,
        c,
        post,
        in_table and " contained oneline" or "",
        conceal_emph,
        contains
      )
    )
  end
  for i, char in ipairs({ "*", "/", "_", "+", "=", "~" }) do
    emph(i, char)
  end
end

--- The vim syntax of a src block language: src_lang_modes
--- (org-src-lang-modes) first, then the built-in aliases.
local function syntax_of(lang)
  local modes = require("org.config").opts.src_lang_modes or {}
  if modes[lang] ~= nil then
    return modes[lang]
  end
  return M.lang_aliases[lang] or lang
end

--- Whether src blocks of `lang` can get a language syntax (not "org":
--- Neovim's bundled syntax/org.vim would redefine orgBold and friends for
--- the whole buffer).
local function includable(syn)
  return syn ~= "" and syn ~= "org" and syn:match("^[%w_]+$") ~= nil and has_syntax(syn)
end

--- Per buffer: the languages seen by the last `apply` (or found to have no
--- syntax since), and whether a new one is waiting.
local languages = {} ---@type table<integer, { seen: table<string, boolean>, pending: boolean, watching: boolean }>

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
          if includable(syntax_of(lang)) then
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

function M.apply(bufnr)
  require("org.highlights").ensure()
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local config = require("org.config").opts
  local file = require("org.files").get_buffer(bufnr)
  local todo = file.settings.todo
  local ui = config.ui or {}
  local hide_emph = ui.hide_emphasis_markers
  -- a buffer can override it (presentation slides do)
  if vim.b[bufnr].org_hide_emphasis_markers ~= nil then
    hide_emph = vim.b[bufnr].org_hide_emphasis_markers
  end
  local conceal_emph = hide_emph and " concealends" or ""
  -- org-link-descriptive; toggle_link_display sets the buffer variable
  local conceal_links = ui.conceal_links ~= false
  if vim.b[bufnr].org_link_descriptive ~= nil then
    conceal_links = vim.b[bufnr].org_link_descriptive and true or false
  end
  local lists = require("org.lists")

  cmd("syntax clear")
  cmd("syntax spell toplevel")

  -- Comments & keywords -----------------------------------------------------
  cmd([=[syntax match orgComment /^\s*#\(\s.*\)\?$/ contains=@Spell,@orgLinks]=])
  cmd([=[syntax match orgKeyword /^\s*#+\S\+:/ nextgroup=orgKeywordValue skipwhite]=])
  cmd([=[syntax match orgKeywordValue /.*$/ contained]=])
  -- org-hidden-keywords: "#+TITLE:" and the like hidden (up to the colon)
  local hidden = {}
  for _, k in ipairs(ui.hidden_keywords or {}) do
    hidden[tostring(k):lower()] = true
  end
  -- #+TITLE and the document info keywords: their links are active
  cmd([=[syntax match orgTitle /^\s*#+\ctitle:.*$/ contains=orgTitleKeyword,@orgLinks]=])
  cmd([=[syntax match orgTitleKeyword /^\s*#+\ctitle:/ contained]=] .. (hidden.title and " conceal" or ""))
  for _, k in ipairs({ "author", "date", "email", "subtitle" }) do
    cmd(
      string.format(
        [=[syntax match orgInfoKeyword /^\s*#+\c%s:/ nextgroup=orgInfoValue skipwhite%s]=],
        k,
        hidden[k] and " conceal" or ""
      )
    )
  end
  cmd([=[syntax match orgInfoValue /.*$/ contained contains=@orgLinks]=])

  -- Lists --------------------------------------------------------------------
  -- bullets as org.lists reads them (lists.allow_alphabetical,
  -- lists.ordered_item_terminator)
  local term = ({ ["."] = [=[\.]=], [")"] = ")" })[lists.opt("ordered_item_terminator")] or "[.)]"
  local counter = [=[\d\+]=] .. (lists.opt("allow_alphabetical") and [=[\|\a]=] or "")
  cmd(string.format([=[syntax match orgListBullet /^\s*\zs\%%([-+]\|\%%(%s\)%s\)\ze\%%(\s\|$\)/]=], counter, term))
  cmd([=[syntax match orgListBullet /^\s\+\zs\*\ze\%(\s\|$\)/]=])
  -- checkboxes (org-list-full-item-re): after a bullet and an optional
  -- [@N] counter, followed by a blank; case-sensitive [X]
  local box_before = [=[\%(^\s*\%([-+*]\|\%(\d\+\|\a\)[.)]\)\s\+\%(\[@\%(start:\)\=\%(\d\+\|\a\)\]\s*\)\=\)\@<=]=]
  cmd(string.format([=[syntax match orgCheckbox /%s\[ \]\ze\%%(\s\|$\)/]=], box_before))
  cmd(string.format([=[syntax match orgCheckboxChecked /%s\[X\]\ze\%%(\s\|$\)/]=], box_before))
  cmd(string.format([=[syntax match orgCheckboxPartial /%s\[-\]\ze\%%(\s\|$\)/]=], box_before))
  -- statistics cookies: complete ones in the done face
  -- (org-get-checkbox-statistics-face)
  cmd([=[syntax match orgStatistic /\[\d*\/\d*\]\|\[\d*%\]/]=])
  cmd([=[syntax match orgStatisticDone /\[\(\d\+\)\/\1\]\|\[100%\]/]=])

  -- Timestamps ---------------------------------------------------------------
  -- org-tsr-regexp-both: a date, then nothing or a space and anything up
  -- to the first closing bracket of either kind; not after "["
  local ts = [=[\d\{4}-\d\d-\d\d\%( [^]>]*\)\=[]>]]=]
  local range = [=[\%(--\=-\=[[<]]=] .. ts .. [=[\)\=]=]
  cmd(string.format([=[syntax match orgTimestamp /\[\@1<!<%s%s/]=], ts, range))
  cmd(string.format([=[syntax match orgTimestampInactive /\[\@1<!\[%s%s/]=], ts, range))
  -- diary sexps
  cmd([=[syntax match orgSexpDate /^&\=%%(.*\|<%%([^>]\{-}>/]=])
  cmd([=[syntax match orgPlanning /\%([[:alnum:]]\)\@1<!\(SCHEDULED\|DEADLINE\|CLOSED\):/]=])
  cmd([=[syntax match orgClock /^\s*\zsCLOCK:/ nextgroup=orgTimestampInactive skipwhite]=])
  -- the duration at the end of a CLOCK: line
  cmd([=[syntax match orgClockDuration /\%(^\s*CLOCK:.*\)\@<==>\s*-\?\d\+:\d\d/]=])

  -- Drawers & properties -----------------------------------------------------
  cmd([=[syntax match orgDrawer /^\s*:\(\w\|[-_]\)\+:\s*$/]=])
  -- (org-property-re: the name may contain colons, ":header-args:lua:")
  cmd([=[syntax match orgPropertyKey /^\s*:\S\{-1,}:\ze\s\+\S/ nextgroup=orgPropertyValue skipwhite]=])
  cmd(string.format([=[syntax match orgPropertyValue /.*$/ contained contains=%s]=], list(OBJECTS)))

  -- Fixed width, rules, targets, footnotes, macros, latex -------------------
  cmd([=[syntax match orgFixedWidth /^\s*:\(\s.*\)\?$/]=])
  cmd([=[syntax match orgHorizontalRule /^\s*-\{5,}\s*$/]=])
  cmd([=[syntax match orgTarget /<<<\?[^<>]\+>>>\?/]=])
  -- references [fn:name]; inline and named definitions [fn::text],
  -- [fn:name:text] with nested brackets and markup inside
  cmd([=[syntax match orgFootnote /\[fn:[-_[:alnum:]]\+\]/]=])
  cmd(
    string.format(
      [=[syntax region orgFootnote matchgroup=orgFootnote start=/\[fn:[-_[:alnum:]]*:/ end=/\]/ oneline contains=orgFootnoteNest,%s,@Spell]=],
      list(MARKUP, OBJECTS)
    )
  )
  cmd([=[syntax region orgFootnoteNest start=/\[/ end=/\]/ oneline contained transparent contains=orgFootnoteNest]=])
  -- (org-hide-macro-markers: the braces hidden)
  cmd([=[syntax match orgMacro /{{{\a[-[:alnum:]_]*.\{-}}}}/ contains=orgMacroMarker]=])
  cmd([=[syntax match orgMacroMarker /{{{\|}}}/ contained]=] .. (ui.hide_macro_markers and " conceal" or ""))
  -- the buffer's #+OPTIONS: ^: decides which scripts are scripts
  local scripts = ui.use_sub_superscripts
  local ok_d, deco = pcall(require, "org.ui.decorations")
  if ok_d and deco.sub_superscripts then
    scripts = deco.sub_superscripts(file, scripts)
  end
  M.latex_and_related(ui, scripts)
  cmd([=[syntax match orgLineBreak /\\\\\s*$/]=])
  -- inline export snippets @@backend:value@@
  cmd([=[syntax match orgExportSnippet /@@[a-z-]\+:.\{-}@@/ contains=orgExportSnippetMarker,orgExportSnippetBackend]=])
  cmd([=[syntax match orgExportSnippetMarker /@@/ contained]=])
  cmd([=[syntax match orgExportSnippetBackend /\%(@@\)\@<=[a-z-]\+:/ contained]=])
  -- inline src blocks src_LANG[header]{body} (org-fontify-inline-src-blocks)
  cmd(
    [=[syntax match orgInlineSrc /\%([[:alnum:]_]\)\@1<!src_[^[:space:][{]\+\%(\[[^]]*\]\)\={[^}]*}/ contains=orgInlineSrcMarker,orgInlineSrcLang,orgInlineSrcHeader,orgInlineSrcBody,@NoSpell]=]
  )
  cmd([=[syntax match orgInlineSrcMarker /src_\|[{}]/ contained]=])
  cmd([=[syntax match orgInlineSrcLang /\%(src_\)\@4<=[^[:space:][{]\+/ contained]=])
  cmd([=[syntax match orgInlineSrcHeader /\[[^]]*\]/ contained]=])
  cmd([=[syntax match orgInlineSrcBody /{\@1<=[^}]\+/ contained]=])

  -- Emphasis -----------------------------------------------------------------
  emphasis(false, conceal_emph, vim.bo[bufnr].synmaxcol)

  -- Links --------------------------------------------------------------------
  M.links(bufnr, conceal_links)

  -- Description list terms (defined after the markup, links and timestamps,
  -- so a term that starts with one of them is still a term) ------------------
  -- The term is looked for only inside orgListTermLine, a transparent match
  -- of the whole item up to " ::" from the start of the line. On its own,
  -- the term's look-behind for the bullet ran at every column of every
  -- line: with the NFA engine, a paragraph line of a few hundred
  -- characters ran out of 'maxmempattern' (E363), which turned off
  -- highlighting below it (#121); with the backtracking engine each column
  -- went back to the start of the line, quadratic in its length (110 ms to
  -- draw a 3,000-character line; at 30,000 "'redrawtime' exceeded" turned
  -- syntax off). \%#=1: the lazy \{-} is cheaper with backtracking.
  local item = [=[^\s*\%([-+]\|\s\*\)\s\+\%(\[[ X-]\]\s\+\)\=]=]
  local term = [=[\%(\[[ X-]\]\%(\s\|$\)\)\@!\S.\{-}\ze\s::\%(\s\|$\)]=]
  cmd(
    string.format(
      [=[syntax match orgListTermLine /\%%#=1%s%s/ transparent contains=orgListBullet,orgCheckbox,orgCheckboxChecked,orgCheckboxPartial,orgListTerm]=],
      item,
      term
    )
  )
  cmd(
    string.format(
      [=[syntax match orgListTerm /\%%#=1\%%(%s\)\@<=%s/ contained contains=%s]=],
      item,
      term,
      list(MARKUP, OBJECTS)
    )
  )

  -- Tables -------------------------------------------------------------------
  cmd(
    string.format(
      [=[syntax match orgTable /^\s*|.*$/ contains=orgTableSeparator,orgTableHline,orgTableFormula,%s,@orgLinks,orgTimestamp,orgTimestampInactive,orgFootnote,orgMacro,orgTarget,orgStatistic,orgStatisticDone,orgExportSnippet]=],
      table.concat(MARKUP, ",")
    )
  )
  cmd([=[syntax match orgTableSeparator /|/ contained]=])
  -- table internals (org-formula): alignment cookies, field formulas and
  -- the marking column. \%#=1: on a long cell the NFA engine ran out of
  -- 'maxmempattern' (E363) and highlighting was turned off. The
  -- backtracking engine matches what follows a look-behind before the
  -- look-behind itself, so each pattern starts with characters that fail
  -- fast: the marking column takes the bar before it as leading context
  -- (lc=1) instead of a look-behind, which tried " *" at every column of a
  -- padded cell (quadratic in its width).
  cmd([=[syntax match orgTableFormula /\%#=1\%(| *\)\@<=<[lrc]\=\d*>/ contained]=])
  cmd([=[syntax match orgTableFormula /\%#=1\%(|\s*\)\@<=:\==[^|]*/ contained]=])
  cmd([=[syntax match orgTableFormula /\%#=1\%(^\s*| *\)\@<=[#*]\ze *|/ contained]=])
  cmd(
    [=[syntax match orgTableFormula /\%#=1\%(^\s*\)\@<=| *[$!_^\/] *|.*\ze|/lc=1 contained contains=orgTableSeparator]=]
  )
  -- table.el borders (`+--+---+`), fontified like table lines in Emacs
  cmd([=[syntax match orgTable /^\s*+-[-+].*$/]=])
  cmd([=[syntax match orgTableHline /^\s*|[-+]\+|\?\s*$/ contained]=])
  cmd([=[syntax match orgTableFormula /^\s*#+\ctblfm:.*$/]=])
  -- markup in cells (after the formulas, so "| =v= |" is verbatim)
  emphasis(true, conceal_emph, vim.bo[bufnr].synmaxcol)

  -- Blocks -------------------------------------------------------------------
  -- A block always ends at a headline (org-fontify-meta-lines-and-blocks),
  -- so an unterminated #+begin_src doesn't swallow the rest of the file.
  local block_stop = [=[end=/^\ze]=] .. HEADLINE .. "/"
  cmd([=[syntax case ignore]=])
  -- other blocks (center, special blocks like #+begin_note) and dynamic
  -- blocks: only the delimiter lines; their contents are ordinary Org
  cmd([=[syntax match orgBlockDelimiter /^\s*#+\%(begin\|end\)\%(_\S\+\|:\)\%(\s.*\)\=$/]=])
  -- src, example, export and comment blocks: raw text
  cmd(
    string.format(
      [=[syntax region orgBlock matchgroup=orgBlockDelimiter start=/^\s*#+begin_\z(src\|example\|export\|comment\)\%%(\s.*\)\=$/ end=/^\s*#+end_\z1\%%(\s.*\)\=$/ %s keepend contains=@NoSpell]=],
      block_stop
    )
  )
  -- quote and verse blocks: Org text with the quote face underneath (the
  -- elements and objects of @orgQuoteContents; not `contains=TOP`, which
  -- would leave the text out of spell checking)
  cmd(
    "syntax cluster orgQuoteContents contains="
      .. list(
        "@Spell,orgComment,orgKeyword,orgTitle,orgInfoKeyword,orgListBullet,orgListTermLine",
        "orgCheckbox,orgCheckboxChecked,orgCheckboxPartial,orgPlanning,orgClock,orgClockDuration",
        "orgDrawer,orgPropertyKey,orgFixedWidth,orgHorizontalRule,orgTable,orgTableFormula",
        "orgBlockDelimiter,orgBlock,orgQuoteBlock",
        MARKUP,
        OBJECTS
      )
  )
  cmd(
    string.format(
      [=[syntax region orgQuoteBlock matchgroup=orgBlockDelimiter start=/^\s*#+begin_\z(quote\|verse\)\%%(\s.*\)\=$/ end=/^\s*#+end_\z1\%%(\s.*\)\=$/ %s keepend contains=@orgQuoteContents]=],
      block_stop
    )
  )
  cmd([=[syntax case match]=])

  local langs = src_languages(bufnr)
  languages[bufnr] = languages[bufnr] or {}
  languages[bufnr].seen = vim.deepcopy(langs)
  languages[bufnr].pending = false
  watch_languages(bufnr)
  if ui.src_highlight ~= false then
    local included = {}
    local modes = config.src_lang_modes or {}
    local sorted = vim.tbl_keys(langs)
    table.sort(sorted)
    for _, lang in ipairs(sorted) do
      local syn = syntax_of(lang)
      if not included[syn] and includable(syn) then
        included[syn] = true
        local cluster = "orgSrc_" .. syn
        local saved = vim.b.current_syntax
        vim.b.current_syntax = nil
        local ok = pcall(cmd, string.format("syntax include @%s syntax/%s.vim", cluster, syn))
        if not ok then
          pcall(cmd, string.format("syntax include @%s syntax/%s.lua", cluster, syn))
        end
        vim.b.current_syntax = saved
        -- an included file's `syntax case ignore` would make the org rules
        -- below (TODO keywords, priorities) case-insensitive
        cmd("syntax case match")
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
              [=[syntax region orgSrcBlock_%s matchgroup=orgBlockDelimiter start=/\c^\s*#+begin_%s\s\+\%%(%s\)\%%(\s.*\)\=$/ end=/\c^\s*#+end_%s\%%(\s.*\)\=$/ %s keepend contains=@%s]=],
              syn,
              kind,
              table.concat(names, [[\|]]),
              kind,
              block_stop,
              cluster
            )
          )
        end
        cmd("syntax cluster orgQuoteContents add=orgSrcBlock_" .. syn)
      end
    end
  end
  -- Included syntax files set the buffer's syncing, spell and keyword
  -- options: org's own come last.
  cmd("syntax spell toplevel")
  cmd("syntax sync clear")
  -- Sync on headlines and block delimiters, which no region crosses, so a
  -- line in the middle of a long block is still drawn as block text when
  -- it is the first line on screen; and redraw the line above a change:
  -- emphasis and links can continue on the next line.
  cmd("syntax sync minlines=10 maxlines=5000 linebreaks=1")
  -- (block begin lines are no sync points: parsing from the headline or
  -- block end above them finds the block)
  cmd([=[syntax sync match orgSyncHeadline grouphere NONE /^\*\+\s/]=])
  cmd([=[syntax sync match orgSyncBlockEnd grouphere NONE /\c^\s*#+end_\S*/]=])

  -- Headlines (defined last so they win) ------------------------------------
  local contains = list(
    "orgTodo,orgDone,orgTodoCustom,orgPriority,orgTags",
    MARKUP,
    OBJECTS,
    "orgHeadlineComment,orgHeadlineTodo,orgHeadlineArchived,@Spell"
  )
  -- org-level-color-stars-only: the level face on the stars only; the
  -- rest of the headline is orgHeadlineText
  local stars_only = ui.level_color_stars_only
  -- levels past 8 cycle through the 8 faces (org-get-level-face)
  local function level_pattern(n)
    return stars_only and string.format([=[/^\%%(\*\{8}\)*\*\{%d} / contained]=], n)
      or string.format([=[/^\%%(\*\{8}\)*\*\{%d} .*$/ contains=%s]=], n, contains)
  end
  if stars_only then
    cmd(
      string.format(
        [=[syntax match orgHeadlineText /^\*\+ .*$/ contains=orgHeadlineLevel1,orgHeadlineLevel2,orgHeadlineLevel3,orgHeadlineLevel4,orgHeadlineLevel5,orgHeadlineLevel6,orgHeadlineLevel7,orgHeadlineLevel8,%s]=],
        contains
      )
    )
  end
  for level = 1, 8 do
    cmd(string.format([=[syntax match orgHeadlineLevel%d %s]=], level, level_pattern(level)))
  end

  local todo_alt = todo:vim_alternation("todo")
  local done_alt = todo:vim_alternation("done")
  local all_alt = todo:vim_alternation()
  if todo_alt ~= "" then
    cmd(string.format([[syntax match orgTodo /\(^\*\+\s\+\)\@<=\(%s\)\ze\(\s\|$\)/ contained]], todo_alt))
  end
  if done_alt ~= "" then
    cmd(string.format([[syntax match orgDone /\(^\*\+\s\+\)\@<=\(%s\)\ze\(\s\|$\)/ contained]], done_alt))
    if ui.fontify_done_headline ~= false then
      cmd(
        string.format(
          [=[syntax match orgHeadlineDone /^\*\+\s\+\(%s\)\%%(\s.*\)\=$/ contains=orgDone,orgPriority,orgTags,%s,orgHeadlineComment,orgHeadlineArchived,@Spell]=],
          done_alt,
          list(MARKUP, OBJECTS)
        )
      )
    end
  end
  -- per-keyword faces
  for name in pairs(ui.todo_keyword_faces or {}) do
    if todo:is_keyword(name) then
      cmd(
        string.format(
          [=[syntax match orgTodoKw_%s /\(^\*\+\s\+\)\@<=%s\ze\(\s\|$\)/ contained containedin=orgHeadlineLevel1,orgHeadlineLevel2,orgHeadlineLevel3,orgHeadlineLevel4,orgHeadlineLevel5,orgHeadlineLevel6,orgHeadlineLevel7,orgHeadlineLevel8,orgHeadlineText,orgHeadlineDone,orgHeadlineArchived]=],
          name:gsub("[^%w_]", "_"),
          esc(name)
        )
      )
    end
  end
  cmd([=[syntax match orgPriority /\[#\(\u\|\d\d\=\)\]/ contained contains=orgPriorityA,orgPriorityB,orgPriorityC]=])
  cmd([=[syntax match orgPriorityA /\[#A\]/ contained]=])
  cmd([=[syntax match orgPriorityB /\[#B\]/ contained]=])
  cmd([=[syntax match orgPriorityC /\[#C\]/ contained]=])
  -- tags: letters, digits and _@#% (org-tag-re), non-ASCII letters too
  cmd([=[syntax match orgTags /\s\zs:\%(\%([[:alnum:]_@#%]\|[^\x01-\x7f]\)\+:\)\+\ze\s*$/ contained]=])
  -- ui.priority_faces / ui.tag_faces (org-priority-faces, org-tag-faces)
  local hls = require("org.highlights")
  for prio in pairs(ui.priority_faces or {}) do
    cmd(
      string.format(
        [=[syntax match %s /\[#%s\]/ contained containedin=orgPriority]=],
        hls.face_group("orgPriorityFace_", prio),
        esc(tostring(prio))
      )
    )
  end
  for tag in pairs(ui.tag_faces or {}) do
    cmd(
      string.format(
        [=[syntax match %s /:\zs%s\ze:/ contained containedin=orgTags]=],
        hls.face_group("orgTagFace_", tag),
        esc(tostring(tag))
      )
    )
  end
  -- COMMENT after the stars, an optional TODO keyword and an optional
  -- priority cookie, followed by a blank (org-set-font-lock-defaults)
  cmd(
    string.format(
      [=[syntax match orgHeadlineComment /\(^\*\+\%%( \+\%%(%s\)\)\=\%%( \+\[#\%%(\u\|\d\d\=\)\]\)\= \+\)\@<=COMMENT\ze\%%(\s\|$\)/ contained]=],
      all_alt ~= "" and all_alt or [[\%$]]
    )
  )
  if todo_alt ~= "" and ui.fontify_todo_headline then
    -- org-fontify-todo-headline: the text after a TODO keyword, priority
    -- cookie and tags included. Defined last, it wins over the items that
    -- start where it does ("[#A]", a link, ...) and contains them.
    cmd(
      string.format(
        [=[syntax match orgHeadlineTodo /\(^\*\+\s\+\(%s\)\s\+\)\@<=\S.*$/ contained contains=orgPriority,orgTags,%s,orgHeadlineComment,orgHeadlineArchived,@Spell]=],
        todo_alt,
        list(MARKUP, OBJECTS)
      )
    )
  end
  -- headlines tagged ARCHIVE: dimmed after the stars (org-archived).
  -- \%#=1: the NFA engine ran out of 'maxmempattern' (E363) on a headline
  -- of a thousand characters and turned highlighting off; the backtracking
  -- one gives up at once on a line without ":ARCHIVE:", and on one with it
  -- matches right after the stars.
  cmd(
    string.format(
      [=[syntax match orgHeadlineArchived /\%%#=1\(^\*\+ \)\@<=.*:ARCHIVE:.*$/ contained contains=orgTodo,orgDone,orgPriority,orgTags,%s,orgHeadlineComment,@Spell]=],
      list(MARKUP, OBJECTS)
    )
  )

  require("org.highlights").apply_todo_faces()
end

return M
