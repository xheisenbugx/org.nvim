---@mod org.babel.tangle Tangling, detangling and jumping back (ob-tangle)
---
--- Writes the src blocks of an Org file to their `:tangle` files like
--- `org-babel-tangle`: link comments (`:comments link|org|both|noweb`)
--- use the same `[[file:x.org::*Heading][Heading:N]]` / `Heading:N ends
--- here` format as Emacs, so `detangle` and `jump_to_org` work on files
--- tangled by either editor.

local blocks_mod = require("org.babel.blocks")
local langs = require("org.babel.langs")
local utils = require("org.utils")

local M = {}

local function babel()
  return require("org.babel")
end

local function cfg()
  return require("org.config").opts.babel or {}
end

--- File extensions of languages for `:tangle yes` (org-babel-tangle-lang-exts;
--- other languages use their name).
M.LANG_EXTS = {
  ["emacs-lisp"] = "el",
  elisp = "el",
  bibtex = "bib",
  awk = "awk",
  ["C++"] = "cpp",
  clojure = "clj",
  clojurescript = "cljs",
  csharp = "cs",
  D = "d",
  fortran = "F90",
  groovy = "groovy",
  haskell = "hs",
  java = "java",
  julia = "jl",
  latex = "tex",
  LilyPond = "ly",
  lisp = "lisp",
  lua = "lua",
  maxima = "max",
  ocaml = "ml",
  perl = "pl",
  processing = "pde",
  python = "py",
  ruby = "rb",
  sed = "sed",
  js = "js",
}

--- Extension of `:tangle yes` files for `lang`.
function M.lang_ext(lang)
  local user = cfg().tangle_lang_exts or {}
  return user[lang] or M.LANG_EXTS[lang] or lang
end

--- Comment delimiters of a language (its major mode's comment-start and
--- comment-end in Emacs).
local COMMENT_BLOCK = {
  C = { "/* ", " */" },
  c = { "/* ", " */" },
  css = { "/* ", " */" },
  html = { "<!-- ", " -->" },
  xml = { "<!-- ", " -->" },
}

function M.comment_delims(lang)
  local cb = COMMENT_BLOCK[lang]
  if cb then
    return cb[1], cb[2]
  end
  if lang == "C++" or lang == "cpp" or lang == "D" then
    return "// ", ""
  end
  return langs.comment_prefix(lang), ""
end

--- Comment every non-blank line of `text` (comment-region).
local function comment_lines(lang, text)
  local s, e = M.comment_delims(lang)
  local out = {}
  for i, l in ipairs(vim.split(text, "\n", { plain = true })) do
    out[i] = l:match("%S") and (s .. l .. e) or l
  end
  return table.concat(out, "\n")
end

---------------------------------------------------------------------------
-- Links back to the Org file
---------------------------------------------------------------------------

--- `org-link--normalize-string`: statistics cookies removed, blanks packed;
--- with `context`, leading `*`/`#` and surrounding parentheses removed.
local function normalize(s, context)
  s = vim.trim((s or ""):gsub("%[%d*%%%]", " "):gsub("%[%d*/%d*%]", " "):gsub("[ \t]+", " "))
  if context then
    while true do
      if s:sub(1, 1) == "(" and s:sub(-1) == ")" then
        s = vim.trim(s:sub(2, -2))
      elseif s:match("^[#*]+[ \t]*") then
        s = s:gsub("^[#*]+[ \t]*", "", 1)
      else
        break
      end
    end
  end
  return s
end
M.normalize = normalize

--- Search string of a link to block `b` (org-link-precise-link-target):
--- its name, `#CUSTOM_ID` or `*Heading` of its entry, else its line.
local function link_search(lines, file, b)
  if b.name then
    return b.name
  end
  local hl = file and file:headline_at(b.start)
  if hl then
    local cid = hl.properties and hl.properties.CUSTOM_ID
    if cid and cid ~= "" then
      return "#" .. cid
    end
    return "*" .. normalize(hl.title)
  end
  return normalize(lines[b.start], true)
end

--- The heading components title of the entry of `b` (org-heading-components).
local function heading_title(file, b)
  local hl = file and file:headline_at(b.start)
  return hl and hl.title or nil, hl
end

--- `%source-name`: the block's name, else "Heading:N" (N-th src block of
--- the entry; "No heading" before the first headline).
function M.source_name(lines, file, b, counter)
  if b.name then
    return b.name
  end
  local title = heading_title(file, b)
  if not counter then
    counter = 0
    local hl = file and file:headline_at(b.start)
    for _, x in ipairs(blocks_mod.parse_blocks(lines)) do
      if not x.call and x.start <= b.start then
        local xh = file and file:headline_at(x.start)
        if xh == hl then
          counter = counter + 1
        end
      end
    end
  end
  return string.format("%s:%d", title or "No heading", counter)
end

--- Absolute file name of an Org buffer (or "").
local function buf_file(bufnr)
  if type(bufnr) ~= "number" then
    return ""
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  return name ~= "" and vim.fn.fnamemodify(name, ":p") or ""
end

--- The link (without brackets) from a tangled file to block `b`
--- (org-babel-tangle--unbracketed-link): relative to the tangled file's
--- directory with `babel.tangle_use_relative_file_links`.
function M.unbracketed_link(bufnr, lines, file, b, tangle)
  local path = buf_file(bufnr)
  local search = link_search(lines, file, b)
  local target = path .. (search ~= "" and ("::" .. search) or "")
  if cfg().tangle_use_relative_file_links ~= false and path ~= "" then
    local org_dir = vim.fn.fnamemodify(path, ":h")
    local tdir = org_dir
    local t = blocks_mod.unquote(tangle or "")
    if t and t:find("/") then
      tdir = vim.fn.fnamemodify(utils.expand(t, org_dir), ":h")
    end
    return "file:" .. require("org.babel.results").relative(path, tdir) .. (search ~= "" and ("::" .. search) or "")
  end
  return "file:" .. vim.fn.fnamemodify(target, ":~")
end

--- `org-fill-template` for the comment formats.
local function fill(template, data)
  local keys = vim.tbl_keys(data)
  table.sort(keys, function(a, b)
    return #a > #b
  end)
  for _, k in ipairs(keys) do
    template = template:gsub("%%" .. vim.pesc(k), (tostring(data[k]):gsub("%%", "%%%%")))
  end
  return template
end

--- Begin and end link comments (uncommented) for block `b`
--- (org-babel-tangle-comment-links).
function M.comment_links(bufnr, b, file, counter, noweb, link_block)
  local lines = babel().buf_lines(bufnr)
  file = file or babel().get_file(bufnr)
  local args = b.args or blocks_mod.header_args(b, file)
  local data = {
    ["start-line"] = b.start + 1,
    file = (not noweb and cfg().tangle_use_relative_file_links ~= false)
        and vim.fn.fnamemodify(buf_file(bufnr), ":t")
      or buf_file(bufnr),
    link = M.unbracketed_link(bufnr, lines, file, link_block or b, args.tangle),
    -- around noweb expansions only the block's name is used
    ["source-name"] = noweb and (b.name or "") or M.source_name(lines, file, b, counter),
  }
  local beg = fill(cfg().tangle_comment_format_beg or "[[%link][%source-name]]", data)
  local fin = fill(cfg().tangle_comment_format_end or "%source-name ends here", data)
  return beg, fin, data
end

---------------------------------------------------------------------------
-- Tangling
---------------------------------------------------------------------------

--- Is `lnum` in a COMMENT or :ARCHIVE: subtree?
local function hidden(file, lnum)
  local hl = file and file:headline_at(lnum)
  return hl ~= nil and hl:is_hidden_by_ancestor()
end

--- Absolute file a block tangles to (org-babel-effective-tangled-filename).
function M.target(bufnr, lang, tangle)
  local src = buf_file(bufnr)
  local dir = src ~= "" and vim.fn.fnamemodify(src, ":h") or vim.fn.getcwd()
  tangle = blocks_mod.unquote(tangle or "no")
  if tangle == "no" or tangle == "nil" or tangle == "" then
    return nil
  end
  if tangle == "yes" then
    local base = src ~= "" and vim.fn.fnamemodify(src, ":r") or (dir .. "/tangled")
    return base .. "." .. M.lang_ext(lang)
  end
  return utils.expand(tangle, dir)
end

--- Org text before block `b` for `:comments org|both`: from its heading
--- (or the end of the previous src block) to the block.
local function org_comment(lines, file, b, prev_end)
  local from_line, from_col = 1, 1
  local hl = file and file:headline_at(b.start)
  if hl then
    from_line = hl.line
    from_col = #(lines[hl.line]:match("^%*+%s+") or "") + 1
  end
  if
    prev_end
    and (prev_end.line > from_line or (prev_end.line == from_line and prev_end.col > from_col))
  then
    from_line, from_col = prev_end.line, prev_end.col
  end
  local parts = { lines[from_line]:sub(from_col) }
  for i = from_line + 1, b.start - 1 do
    parts[#parts + 1] = lines[i]
  end
  local text = table.concat(parts, "\n") .. "\n"
  if from_line >= b.start then
    return ""
  end
  -- org-remove-indentation
  local tl = vim.split(text, "\n", { plain = true })
  tl = babel().dedent(tl)
  return table.concat(tl, "\n")
end

--- The body a block tangles to: noweb (in :tangle context), variables,
--- :prologue / :epilogue, coderefs removed with -r, the body hook, common
--- indentation removed and blank lines trimmed.
local function tangled_body(bufnr, b, args)
  local lines = babel().expand_body(bufnr, b, args, "tangle")
  local text = table.concat(lines, "\n")
  M.body = text
  babel().fire("OrgBabelTangleBody", { lang = b.lang, name = b.name })
  text = M.body or text
  M.body = nil
  local tl = vim.split(text, "\n", { plain = true })
  local preserve = blocks_mod.preserve_indentation(b.switches)
  if not preserve then
    tl = babel().dedent(tl)
  end
  text = table.concat(tl, "\n")
  if preserve then
    text = text:gsub("^[\n]+", ""):gsub("%s+$", "")
  else
    text = vim.trim(text)
  end
  return text
end

--- Specs of the blocks of `bufnr` to tangle, grouped by target file in
--- order (org-babel-tangle-collect-blocks).
---@param opts { only_line?: integer, tangle_file?: string, lang_re?: string, target?: string }
function M.collect(bufnr, opts)
  local lines = babel().buf_lines(bufnr)
  local file = babel().get_file(bufnr)
  local groups, order = {}, {}
  local counters = {}
  local prev_end
  for _, b in ipairs(blocks_mod.parse_blocks(lines)) do
    if not b.call then
      local hl = file and file:headline_at(b.start)
      local key = hl or "none"
      counters[key] = (counters[key] or 0) + 1
      local counter = counters[key]
      local skip = hidden(file, b.start) or (opts.only_line and opts.only_line ~= b.start)
      if not skip then
        local args = blocks_mod.header_args(b, file)
        if opts.default_tangle and (args.tangle == nil or args.tangle == "no") then
          args.tangle = opts.default_tangle
        end
        local tfile = blocks_mod.unquote(args.tangle or "no")
        local ok_lang = not opts.lang_re or (b.lang ~= "" and vim.regex(opts.lang_re):match_str(b.lang))
        if
          tfile ~= "no"
          and not (b.lang == "" and tfile == "yes")
          and not (opts.tangle_file and opts.tangle_file ~= tfile)
          and ok_lang
        then
          local target = M.target(bufnr, b.lang, args.tangle)
          if target and (not opts.target or opts.target == target) then
            b.args = args
            local comments = args.comments or "no"
            local spec = {
              block = b,
              args = args,
              lang = b.lang,
              counter = opts.only_line and 1 or counter,
              comments = comments,
            }
            if comments == "org" or comments == "both" then
              spec.comment = org_comment(lines, file, b, prev_end)
            end
            babel()._noweb_parent = b
            local ok, body = pcall(tangled_body, bufnr, b, args)
            babel()._noweb_parent = nil
            if not ok then
              error(body, 0)
            end
            spec.body = body
            if not groups[target] then
              groups[target] = {}
              order[#order + 1] = target
            end
            table.insert(groups[target], spec)
          end
        end
      end
      prev_end = { line = b.finish, col = (lines[b.finish]:find("[Ee][Nn][Dd]_[Ss][Rr][Cc]") or 1) + 7 }
    end
  end
  return groups, order
end

--- Text of one spec (org-babel-spec-to-string).
local function spec_to_string(bufnr, spec, file)
  local comments = spec.comments
  local link = comments == "both" or comments == "link" or comments == "yes" or comments == "noweb"
  local out = {}
  local function insert_comment(text)
    if comments and comments ~= "no" and text and text:match("%S") then
      if cfg().tangle_uncomment_comments then
        out[#out + 1] = text
      else
        out[#out + 1] = comment_lines(spec.lang, text) .. "\n"
      end
    end
  end
  if spec.comment then
    insert_comment(spec.comment)
  end
  local beg, fin
  if link then
    beg, fin = M.comment_links(bufnr, spec.block, file, spec.counter)
    insert_comment(beg)
  end
  out[#out + 1] = spec.body .. "\n"
  if link then
    insert_comment(fin)
  end
  return table.concat(out)
end

local function read_bytes(path)
  local fh = io.open(path, "rb")
  if not fh then
    return nil
  end
  local s = fh:read("*a")
  fh:close()
  return s
end

--- Tangle `bufnr` (org-babel-tangle). Returns the list of written files.
---@param opts? { bufnr?: integer, target?: string, only_line?: integer, tangle_file?: string, lang_re?: string, default_tangle?: string, silent?: boolean }
function M.tangle(opts)
  opts = opts or {}
  local bufnr = opts.bufnr
  if not bufnr or bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  -- org-babel-pre-tangle-hook (save-buffer in Emacs)
  if cfg().tangle_save_buffer ~= false and vim.bo[bufnr].modified and vim.api.nvim_buf_get_name(bufnr) ~= "" then
    pcall(vim.api.nvim_buf_call, bufnr, function()
      vim.cmd("silent noautocmd write")
    end)
  end
  babel().fire("OrgBabelTanglePre", { bufnr = bufnr })
  local file = babel().get_file(bufnr)
  babel()._noweb_seen = {}
  local cok, groups, order = pcall(M.collect, bufnr, opts)
  babel()._noweb_seen = nil
  if not cok then
    utils.error("Tangle: " .. tostring(groups))
    return {}
  end
  local source = buf_file(bufnr)
  local written, count = {}, 0
  for _, target in ipairs(order) do
    local specs = groups[target]
    local chunks = {}
    local modes = {}
    local make_dir = false
    local she_banged = false
    local size = 0
    for _, spec in ipairs(specs) do
      local shebang = spec.args.shebang and blocks_mod.unquote(spec.args.shebang)
      if shebang == "" then
        shebang = nil
      end
      local tmode = spec.args["tangle-mode"]
      if shebang and not tmode then
        tmode = "o755"
      end
      if tmode then
        local mode, err = babel().file_mode(tmode)
        if mode then
          table.insert(modes, 1, mode)
        else
          utils.error(err)
        end
      end
      local m = spec.args.mkdirp
      if m and m ~= "no" then
        make_dir = true
      end
      if spec.args.padline ~= "no" and size > 0 then
        chunks[#chunks + 1] = "\n"
        size = size + 1
      end
      if shebang and not she_banged then
        chunks[#chunks + 1] = shebang .. "\n"
        she_banged = true
        size = size + 1
      end
      local text = spec_to_string(bufnr, spec, file)
      chunks[#chunks + 1] = text
      size = size + #text
      count = count + 1
    end
    local content = table.concat(chunks)
    local dir = vim.fn.fnamemodify(target, ":h")
    if make_dir then
      vim.fn.mkdir(dir, "p")
    end
    if target == source then
      utils.error("Not allowed to tangle into the same file as self")
    elseif not utils.is_dir(dir) then
      utils.error("Tangle: directory does not exist (use :mkdirp yes): " .. dir)
    else
      if read_bytes(target) ~= content then
        -- org-babel-tangle-remove-file-before-write `auto': recreate
        -- read-only targets
        if utils.exists(target) and vim.fn.filewritable(target) ~= 1 then
          os.remove(target)
        end
        local fh = io.open(target, "wb")
        if fh then
          fh:write(content)
          fh:close()
          -- like Emacs, the modes are applied in turn: the first block's wins
          for i = #modes, 1, -1 do
            vim.uv.fs_chmod(target, modes[i])
          end
        else
          utils.error("Cannot write " .. target)
        end
      end
      table.insert(written, 1, target)
    end
  end
  if not opts.silent then
    utils.notify(
      string.format(
        "Tangled %d code block%s from %s",
        count,
        count == 1 and "" or "s",
        vim.fn.fnamemodify(source ~= "" and source or "buffer", ":t")
      )
    )
  end
  for _, f in ipairs(written) do
    babel().fire("OrgBabelTanglePost", { bufnr = bufnr, file = f })
  end
  babel().fire("OrgBabelTangleFinished", { bufnr = bufnr, files = written })
  return written
end

---------------------------------------------------------------------------
-- Back from tangled files
---------------------------------------------------------------------------

--- Link comment pairs of tangled lines: { start, finish, link, name }
--- (lines between start and finish are the block body).
local function comment_pairs(lines)
  local pairs_ = {}
  local i = 1
  while i <= #lines do
    local link, name = lines[i]:match("%[%[([^%]]+)%]%[([^%]]+)%]%]")
    if link then
      local stop
      for j = i + 1, #lines do
        if lines[j]:find(" " .. name .. " ends here", 1, true) then
          stop = j
          break
        end
      end
      if stop then
        pairs_[#pairs_ + 1] = { start = i, finish = stop, link = link, name = name }
        i = stop
      end
    end
    i = i + 1
  end
  return pairs_
end
M.comment_pairs = comment_pairs

--- Find the Org block a link comment points to. Returns the Org buffer
--- and the block (from `parse_blocks`), or nil and a message.
function M.find_block(link, name, from_dir)
  local path, search = link:match("^file:(.-)::(.*)$")
  if not path then
    path = link:match("^file:(.*)$")
  end
  if not path then
    return nil, "Not a file link: " .. link
  end
  local full = utils.expand(path, from_dir)
  if not utils.exists(full) then
    return nil, "No such file: " .. full
  end
  local obuf = utils.load_buffer(full)
  local lines = babel().buf_lines(obuf)
  local file = babel().get_file(obuf)
  local list = {}
  for _, b in ipairs(blocks_mod.parse_blocks(lines)) do
    if not b.call then
      list[#list + 1] = b
    end
  end
  local n = name:match("[^ \t\n\r]:(%d+)$")
  if n then
    n = tonumber(n)
    -- the n-th block after the heading the search string names
    local start = 1
    if search and search ~= "" then
      if search:sub(1, 1) == "*" then
        local want = normalize(search:sub(2))
        for _, h in ipairs(file and file.headlines or {}) do
          if normalize(h.title) == want then
            start = h.line
            break
          end
        end
      elseif search:sub(1, 1) == "#" then
        for _, h in ipairs(file and file.headlines or {}) do
          if h.properties and h.properties.CUSTOM_ID == search:sub(2) then
            start = h.line
            break
          end
        end
      else
        for i, l in ipairs(lines) do
          if normalize(l, true) == search then
            start = i
            break
          end
        end
      end
    end
    local k = 0
    for _, b in ipairs(list) do
      if b.start >= start then
        k = k + 1
        if k == n then
          return obuf, b
        end
      end
    end
    return nil, "Cannot find block " .. name
  end
  for _, b in ipairs(list) do
    if b.name == name then
      return obuf, b
    end
  end
  return nil, "No src block named " .. name
end

--- Replace the body of `b` in `obuf` with `body` (a string), re-indented
--- like org-babel-update-block-body.
local function update_block_body(obuf, b, body)
  local lines = vim.split(body:gsub("\n$", ""), "\n", { plain = true })
  if not blocks_mod.preserve_indentation(b.switches) then
    lines = babel().dedent(lines)
    local ind = #(b.indent or "") + (require("org.config").opts.edit_src_content_indentation or 0)
    -- indent-rigidly: tabs unless 'expandtab' (Emacs indent-tabs-mode)
    local ts = vim.bo[obuf].tabstop > 0 and vim.bo[obuf].tabstop or 8
    for i, l in ipairs(lines) do
      if l ~= "" then
        local ws = l:match("^( *)")
        local width = ind + #ws
        local lead = string.rep(" ", width)
        if not vim.bo[obuf].expandtab then
          lead = string.rep("\t", math.floor(width / ts)) .. string.rep(" ", width % ts)
        end
        lines[i] = lead .. l:sub(#ws + 1)
      end
    end
  end
  lines = blocks_mod.escape(lines)
  vim.api.nvim_buf_set_lines(obuf, b.start, b.finish - 1, false, lines)
end

--- Propagate the edits of a tangled file back to its Org file
--- (org-babel-detangle). Needs link comments (`:comments link`).
---@param path? string the tangled file (default: the current buffer)
function M.detangle(path)
  local bufnr = path and utils.load_buffer(utils.expand(path, vim.fn.getcwd())) or vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local dir = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":p:h")
  local count = 0
  for _, p in ipairs(comment_pairs(lines)) do
    local obuf, b = M.find_block(p.link, p.name, dir)
    if obuf then
      local body = table.concat(vim.list_slice(lines, p.start + 1, p.finish - 1), "\n") .. "\n"
      update_block_body(obuf, b, body)
      count = count + 1
    else
      utils.warn(b)
    end
  end
  utils.notify(string.format("Detangled %d code blocks", count))
  return count
end

--- Jump from a tangled file to the Org block the cursor is in
--- (org-babel-tangle-jump-to-org), keeping the position in the body.
function M.jump_to_org()
  local bufnr = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local cur = vim.api.nvim_win_get_cursor(0)
  local lnum = cur[1]
  local found
  for _, p in ipairs(comment_pairs(lines)) do
    if p.start < lnum and lnum < p.finish then
      found = p
    end
  end
  if not found then
    utils.error("Not in tangled code")
    return nil
  end
  local dir = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":p:h")
  local obuf, b = M.find_block(found.link, found.name, dir)
  if not obuf then
    utils.error(b)
    return nil
  end
  local body = table.concat(vim.list_slice(lines, found.start + 1, found.finish - 1), "\n")
  local wins = vim.fn.win_findbuf(obuf)
  if #wins > 0 then
    vim.api.nvim_set_current_win(wins[1])
  else
    vim.api.nvim_win_set_buf(0, obuf)
  end
  local row = b.start + 1 + (lnum - found.start - 1)
  local col = cur[2]
  if row > b.finish - 1 then
    row, col = b.start + 1, 0
  end
  pcall(vim.api.nvim_win_set_cursor, 0, { math.min(row, vim.api.nvim_buf_line_count(obuf)), col })
  pcall(vim.cmd, "normal! zv")
  return body
end

--- Remove the lines tangling added to the current (tangled) buffer: link
--- comments, their "ends here" lines and noweb references
--- (org-babel-tangle-clean). Emacs 9.8's command has a bug and removes
--- nothing; this does what its documentation says.
function M.clean(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local drop = {}
  for _, p in ipairs(comment_pairs(lines)) do
    drop[p.start], drop[p.finish] = true, true
  end
  for i, l in ipairs(lines) do
    if l:match("%[%[file:.-%]%[.-%]%]") or babel().find_noweb(l, 1) then
      drop[i] = true
    end
  end
  local out = {}
  for i, l in ipairs(lines) do
    if not drop[i] then
      out[#out + 1] = l
    end
  end
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, out)
  return #lines - #out
end

--- Tangle an Org file and run the Lua it produced (a Lua counterpart of
--- org-babel-load-file, which loads Emacs Lisp). The Lua blocks are
--- tangled to FILE.lua next to it (unless it is newer than the Org file
--- and `compile` is false) and run with `dofile`.
---@param path string
---@return any result of the file
function M.load_file(path)
  path = utils.expand(path, vim.fn.getcwd())
  if not utils.exists(path) then
    error("No such file: " .. path, 0)
  end
  local out = vim.fn.fnamemodify(path, ":r") .. ".lua"
  if not utils.exists(out) or vim.fn.getftime(out) < vim.fn.getftime(path) then
    local obuf = utils.load_buffer(path)
    M.tangle({ bufnr = obuf, target = out, default_tangle = out, lang_re = "^lua$", silent = true })
  end
  if not utils.exists(out) then
    error("No Lua code tangled from " .. path, 0)
  end
  return dofile(out)
end

return M
