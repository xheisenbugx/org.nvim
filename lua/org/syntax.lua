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
  ["org"] = nil,
}

local function cmd(s)
  vim.cmd(s)
end

local function esc(s)
  -- magic-mode specials only (escaping + ? = etc. would turn them into multis)
  return vim.fn.escape(s, [[\/.*$^~[]])
end

--- Languages used in `#+begin_src <lang>` lines of the buffer.
local function src_languages(bufnr)
  local langs = {}
  for _, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    local lang = line:match("^%s*#%+[bB][eE][gG][iI][nN]_[sS][rR][cC]%s+([%w_%+%-]+)")
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
-- Plain link path: balanced parentheses allowed, no trailing punctuation
-- other than "/" (org-link-plain-re).
local PLAIN_PATH = (function()
  local char = [=[[^][[:space:]()<>]]=]
  local group = [=[(\%([^][[:space:]()<>]\|([^][[:space:]()<>]*)\)*)]=]
  return [=[\%(]=] .. char .. [=[\|]=] .. group .. [=[\)*\%([^][[:space:]()<>[:punct:]]\|\/\|]=] .. group .. [=[\)]=]
end)()

--- Link syntax: bracket, plain and radio links, and custom link type faces
--- (`links.types.<name>.face`). All are in the `@orgLinks` cluster.
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
  cmd(string.format([=[syntax match orgLinkPlain /\<\%%(%s\):%s/]=], table.concat(schemes, [[\|]]), PLAIN_PATH))
  local bracket = [=[\[\[]=] .. LINK_TARGET .. [=[\]\%(\[.\{-1,}\]\)\?\]]=]
  cmd(string.format([=[syntax match orgLink /%s/ contains=orgLinkTargetHidden,orgLinkBracket,@NoSpell]=], bracket))
  -- lookbehind (not \zs): orgLinkBracket already consumes the "[[", so a
  -- pattern that has to match from "[[" would never get a chance to apply
  cmd(
    string.format([=[syntax match orgLinkTargetHidden /\(\[\[\)\@<=%s\]\[\ze.\{-1,}\]\]/ contained]=], LINK_TARGET)
      .. lconceal
  )
  cmd([[syntax match orgLinkBracket /\[\[\|\]\]/ contained]] .. lconceal)
  -- custom link faces
  for name, def in pairs(types) do
    local face = type(def) == "table" and def.face or nil
    if type(face) == "string" and name:match("^[%w_+%-]+$") then
      local group = "orgLinkType_" .. name:gsub("[^%w_]", "_")
      cmd(string.format(
        [=[syntax match %s /\[\[%s:%s\]\%%(\[.\{-1,}\]\)\?\]/ contains=orgLinkTargetHidden,orgLinkBracket,@NoSpell]=],
        group,
        esc(name),
        LINK_TARGET
      ))
      cmd(string.format([=[syntax match %s /\<%s:%s/]=], group, esc(name), PLAIN_PATH))
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
    cmd(string.format(
      [=[syntax match orgRadioLink /\c\%%(^\|[^[:alnum:]]\)\@<=\%%(%s\)\%%($\|[^[:alnum:]]\)\@=/ contains=@NoSpell]=],
      table.concat(targets, [[\|]])
    ))
    cluster[#cluster + 1] = "orgRadioLink"
  end
  cmd("syntax cluster orgLinks contains=" .. table.concat(cluster, ","))
end

function M.apply(bufnr)
  local config = require("org.config").opts
  local file = require("org.files").get_buffer(bufnr)
  local todo = file.settings.todo
  local ui = config.ui or {}
  local conceal_emph = ui.hide_emphasis_markers and " concealends" or ""
  -- org-link-descriptive; toggle_link_display sets the buffer variable
  local conceal_links = ui.conceal_links ~= false
  if vim.b[bufnr].org_link_descriptive ~= nil then
    conceal_links = vim.b[bufnr].org_link_descriptive and true or false
  end

  cmd("syntax clear")
  cmd("syntax spell toplevel")
  cmd("syntax sync minlines=200")

  -- Comments & keywords -----------------------------------------------------
  cmd([=[syntax match orgComment /^\s*#\(\s.*\)\?$/ contains=@Spell]=])
  cmd([=[syntax match orgKeyword /^\s*#+\S\+:/ nextgroup=orgKeywordValue skipwhite]=])
  cmd([=[syntax match orgKeywordValue /.*$/ contained]=])
  cmd([=[syntax match orgTitle /^\s*#+\ctitle:.*$/ contains=orgTitleKeyword]=])
  cmd([=[syntax match orgTitleKeyword /^\s*#+\ctitle:/ contained]=])

  -- Lists --------------------------------------------------------------------
  cmd([=[syntax match orgListBullet /^\s*\zs\([-+]\|\d\+[.)]\|\a[.)]\)\ze\(\s\|$\)/]=])
  cmd([=[syntax match orgListBullet /^\s\+\zs\*\ze\s/]=])
  cmd([=[syntax match orgListTerm /\(^\s*\([-+]\|\s\*\)\s\+\(\[[ xX-]\]\s\+\)\?\)\@<=\S.\{-}\ze\s::\(\s\|$\)/ contains=orgBold,orgItalic,orgCode,orgVerbatim]=])
  cmd([=[syntax match orgCheckbox /\(^\s*\([-+*]\|\d\+[.)]\)\s\+\)\@<=\[ \]/]=])
  cmd([=[syntax match orgCheckboxChecked /\(^\s*\([-+*]\|\d\+[.)]\)\s\+\)\@<=\[[xX]\]/]=])
  cmd([=[syntax match orgCheckboxPartial /\(^\s*\([-+*]\|\d\+[.)]\)\s\+\)\@<=\[-\]/]=])
  cmd([=[syntax match orgStatistic /\[\d*\/\d*\]\|\[\d*%\]/]=])

  -- Timestamps ---------------------------------------------------------------
  cmd([=[syntax match orgTimestamp /<\d\{4}-\d\{2}-\d\{2}[^>]*>\(--<\d\{4}-\d\{2}-\d\{2}[^>]*>\)\?/]=])
  cmd([=[syntax match orgTimestampInactive /\[\d\{4}-\d\{2}-\d\{2}[^]]*\]\(--\[\d\{4}-\d\{2}-\d\{2}[^]]*\]\)\?/]=])
  cmd([=[syntax match orgPlanning /\<\(SCHEDULED\|DEADLINE\|CLOSED\):/]=])
  cmd([=[syntax match orgClock /^\s*\zsCLOCK:/ nextgroup=orgTimestampInactive skipwhite]=])
  cmd([=[syntax match orgClockDuration /=>\s*-\?\d\+:\d\d/]=])

  -- Drawers & properties -----------------------------------------------------
  cmd([=[syntax match orgDrawer /^\s*:\(\w\|[-_]\)\+:\s*$/]=])
  cmd([=[syntax match orgPropertyKey /^\s*:[^[:space:]:]\+:\ze\s\+\S/ nextgroup=orgPropertyValue skipwhite]=])
  cmd([=[syntax match orgPropertyValue /.*$/ contained]=])

  -- Fixed width, rules, targets, footnotes, macros, latex -------------------
  cmd([=[syntax match orgFixedWidth /^\s*:\(\s.*\)\?$/]=])
  cmd([=[syntax match orgHorizontalRule /^\s*-\{5,}\s*$/]=])
  cmd([=[syntax match orgTarget /<<<\?[^<>]\+>>>\?/]=])
  cmd([=[syntax match orgFootnote /\[fn:[^]]*\]/]=])
  cmd([=[syntax match orgMacro /{{{[^}]\+}}}/]=])
  cmd([=[syntax match orgLatex /\\\a\+\({[^}]*}\)*\|\$[^$ ]\([^$]*[^$ ]\)\?\$\|\\(.\{-}\\)\|\\\[.\{-}\\\]/]=])
  cmd([=[syntax match orgLineBreak /\\\\\s*$/]=])

  -- Emphasis -----------------------------------------------------------------
  -- org-emphasis-regexp-components: allowed characters before and after
  -- the markers, the characters the text cannot start or end with, and at
  -- most one newline inside (Emacs `org-emph-re`).
  local pre = [=[\%(^\|[[:space:]('"{-]\)\@<=]=]
  local post = [=[\%($\|[[:space:]-.,:!?;'")}\[]\)]=]
  local border = [=[[^[:space:],"']]=]
  -- (the newline cannot be followed by a headline)
  local body = string.format([=[\%%(%s\|%s.\{-}\%%(\n\%%(\*\+ \)\@!.\{-}\)\=%s\)]=], border, border, border)
  local markup = "orgBold,orgItalic,orgUnderline,orgStrikethrough,orgVerbatim,orgCode"
  local function emph(group, char, extra)
    local c = esc(char)
    cmd(string.format(
      [=[syntax region %s matchgroup=%sDelimiter start=/%s%s\ze%s%s%s/ end=/\%%(%s\)\@<=%s\ze%s/ keepend%s %s]=],
      group,
      group,
      pre,
      c,
      body,
      c,
      post,
      border,
      c,
      post,
      conceal_emph,
      extra or ("contains=@Spell,@orgLinks," .. markup)
    ))
  end
  emph("orgBold", "*")
  emph("orgItalic", "/")
  emph("orgUnderline", "_")
  emph("orgStrikethrough", "+")
  emph("orgVerbatim", "=", "")
  emph("orgCode", "~", "")

  -- Links --------------------------------------------------------------------
  M.links(bufnr, conceal_links)

  -- Tables -------------------------------------------------------------------
  cmd([=[syntax match orgTable /^\s*|.*$/ contains=orgTableSeparator,orgTableHline,orgBold,orgItalic,orgCode,orgVerbatim,@orgLinks,orgTimestamp,orgTimestampInactive]=])
  cmd([=[syntax match orgTableSeparator /|/ contained]=])
  cmd([=[syntax match orgTableHline /^\s*|[-+]\+|\?\s*$/ contained]=])
  cmd([=[syntax match orgTableFormula /^\s*#+\ctblfm:.*$/]=])

  -- Blocks -------------------------------------------------------------------
  cmd([=[syntax case ignore]=])
  cmd([=[syntax region orgBlock matchgroup=orgBlockDelimiter start=/^\s*#+begin_\z(\w\+\)\>.*$/ end=/^\s*#+end_\z1\>.*$/ keepend contains=@NoSpell]=])
  cmd([=[syntax region orgDynamicBlock matchgroup=orgBlockDelimiter start=/^\s*#+begin:.*$/ end=/^\s*#+end:.*$/ keepend contains=orgTable,orgTimestamp,orgTimestampInactive,@orgLinks]=])
  cmd([=[syntax region orgQuoteBlock matchgroup=orgBlockDelimiter start=/^\s*#+begin_\(quote\|verse\|center\)\>.*$/ end=/^\s*#+end_\(quote\|verse\|center\)\>.*$/ keepend contains=orgBold,orgItalic,orgUnderline,orgCode,orgVerbatim,@orgLinks,@Spell]=])
  cmd([=[syntax case match]=])

  if ui.src_highlight ~= false then
    local included = {}
    for lang in pairs(src_languages(bufnr)) do
      local syn = M.lang_aliases[lang] or lang
      if syn ~= "" and not included[syn] and syn:match("^[%w_]+$") and has_syntax(syn) then
        included[syn] = true
        local cluster = "orgSrc_" .. syn
        local saved = vim.b.current_syntax
        vim.b.current_syntax = nil
        local ok = pcall(cmd, string.format("syntax include @%s syntax/%s.vim", cluster, syn))
        if not ok then
          pcall(cmd, string.format("syntax include @%s syntax/%s.lua", cluster, syn))
        end
        vim.b.current_syntax = saved
        -- all aliases of this syntax
        local names = { esc(lang) }
        for alias, target in pairs(M.lang_aliases) do
          if target == syn and alias ~= lang then
            names[#names + 1] = esc(alias)
          end
        end
        cmd(string.format(
          [=[syntax region orgSrcBlock_%s matchgroup=orgBlockDelimiter start=/\c^\s*#+begin_src\s\+\(%s\)\>.*$/ end=/\c^\s*#+end_src\>.*$/ keepend contains=@%s]=],
          syn,
          table.concat(names, [[\|]]),
          cluster
        ))
      end
    end
  end

  -- Headlines (defined last so they win) ------------------------------------
  local contains =
    "orgTodo,orgDone,orgTodoCustom,orgPriority,orgTags,orgTimestamp,orgTimestampInactive,@orgLinks,orgStatistic,orgBold,orgItalic,orgUnderline,orgCode,orgVerbatim,orgStrikethrough,orgHeadlineComment,orgFootnote,@Spell"
  for level = 1, 8 do
    cmd(string.format(
      [=[syntax match orgHeadlineLevel%d /^\*\{%d} .*$/ contains=%s]=],
      level,
      level,
      contains
    ))
  end
  for level = 9, 20 do
    local l = ((level - 1) % 8) + 1
    cmd(string.format(
      [=[syntax match orgHeadlineLevel%d /^\*\{%d} .*$/ contains=%s]=],
      l,
      level,
      contains
    ))
  end

  local todo_alt = todo:vim_alternation("todo")
  local done_alt = todo:vim_alternation("done")
  if todo_alt ~= "" then
    cmd(string.format([[syntax match orgTodo /\(^\*\+\s\+\)\@<=\(%s\)\ze\(\s\|$\)/ contained]], todo_alt))
  end
  if done_alt ~= "" then
    cmd(string.format([[syntax match orgDone /\(^\*\+\s\+\)\@<=\(%s\)\ze\(\s\|$\)/ contained]], done_alt))
    if ui.fontify_done_headline ~= false then
      cmd(string.format(
        [=[syntax match orgHeadlineDone /^\*\+\s\+\(%s\)\s.*$/ contains=orgDone,orgTags,orgTimestamp,orgTimestampInactive,@orgLinks,orgPriority]=],
        done_alt
      ))
    end
  end
  -- per-keyword faces
  for name in pairs(ui.todo_keyword_faces or {}) do
    if todo:is_keyword(name) then
      cmd(string.format(
        [=[syntax match orgTodoKw_%s /\(^\*\+\s\+\)\@<=%s\ze\(\s\|$\)/ contained containedin=orgHeadlineLevel1,orgHeadlineLevel2,orgHeadlineLevel3,orgHeadlineLevel4,orgHeadlineLevel5,orgHeadlineLevel6,orgHeadlineLevel7,orgHeadlineLevel8,orgHeadlineDone]=],
        name:gsub("[^%w_]", "_"),
        esc(name)
      ))
    end
  end
  cmd([=[syntax match orgPriority /\[#\(\u\|\d\d\=\)\]/ contained contains=orgPriorityA,orgPriorityB,orgPriorityC]=])
  cmd([=[syntax match orgPriorityA /\[#A\]/ contained]=])
  cmd([=[syntax match orgPriorityB /\[#B\]/ contained]=])
  cmd([=[syntax match orgPriorityC /\[#C\]/ contained]=])
  cmd([=[syntax match orgTags /\s\zs:\([^[:space:]:]\+:\)\+\ze\s*$/ contained]=])
  -- ui.priority_faces / ui.tag_faces (org-priority-faces, org-tag-faces)
  local hls = require("org.highlights")
  for prio in pairs(ui.priority_faces or {}) do
    cmd(string.format(
      [=[syntax match %s /\[#%s\]/ contained containedin=orgPriority]=],
      hls.face_group("orgPriorityFace_", prio),
      esc(tostring(prio))
    ))
  end
  for tag in pairs(ui.tag_faces or {}) do
    cmd(string.format(
      [=[syntax match %s /:\zs%s\ze:/ contained containedin=orgTags]=],
      hls.face_group("orgTagFace_", tag),
      esc(tostring(tag))
    ))
  end
  cmd([=[syntax match orgHeadlineComment /\(^\*\+\s\+\(\S\+\s\+\)\?\)\@<=COMMENT\>/ contained]=])

  require("org.highlights").apply_todo_faces()
end

return M
