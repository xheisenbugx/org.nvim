---@mod org.export.ox.include #+INCLUDE expansion and COMMENT subtrees
---
--- Part of org.export.ox, which loads it: the functions are fields of
--- that module.

local element = require("org.export.element")
local utils = require("org.utils")
local M = require("org.export.ox")

local trim = M.trim

---------------------------------------------------------------------------
-- Preprocessing: #+INCLUDE
---------------------------------------------------------------------------

local function escape_code(lines)
  local out = {}
  for i, l in ipairs(lines) do
    if l:match("^[ \t]*,*%*") or l:match("^[ \t]*,*#%+") then
      out[i] = l:gsub("^([ \t]*)", "%1,", 1)
    else
      out[i] = l
    end
  end
  return out
end
M.escape_code = escape_code

--- Parse the value of an #+INCLUDE keyword (org-export-parse-include-value).
function M.parse_include_value(value, dir)
  local p = {}
  value = value:gsub(":coding +%S+", "")
  local file = value:match('^(".-")%s') or value:match('^(".-")$') or value:match("^(%S+)")
  if file then
    value = value:sub(#file + 1)
    local loc = file:match('::(.-)"?$')
    if loc then
      p.location = loc
      file = file:gsub('::.-("?)$', "%1")
    end
    file = file:match('^"(.*)"$') or file
    if file:match("^%a[%w+.-]*://") then
      p.file = file
    else
      p.file = utils.expand(file, dir)
    end
    p.raw_file = file
  end
  local oc = value:match(":only%-contents *([^: \r\t\n]%S*)")
  if value:match(":only%-contents") then
    p.only_contents = oc ~= nil and oc ~= "nil"
    value = value:gsub(":only%-contents *[^: \r\t\n]?%S*", "", 1)
  end
  local lines = value:match(':lines +"(%d*%-%d*)"')
  if lines then
    p.lines = lines
    value = value:gsub(':lines +"%d*%-%d*"', "", 1)
  end
  local env
  if value:match("%f[%w]example%f[%W]") then
    env = "literal"
  elseif value:match("%f[%w]export%f[%W]") then
    env = "literal"
  elseif value:match("%f[%w]src%f[%W]") then
    env = "literal"
  end
  p.env = env
  if not env then
    local ml = value:match(":minlevel +(%d+)")
    if ml then
      p.minlevel = tonumber(ml)
      value = value:gsub(":minlevel +%d+", "", 1)
    end
  end
  if env == "literal" then
    local args = value:match("%f[%w]export +(.-)%s*$") or value:match("%f[%w]src +(.-)%s*$")
    if args and args ~= "" then
      -- stop at the first :keyword
      args = trim(args:gsub("%s:.*$", ""))
      p.args = args ~= "" and args or nil
      if p.args then
        local s, e = value:find(vim.pesc(p.args), 1)
        if s then
          value = value:sub(1, s - 1) .. value:sub(e + 1)
        end
      end
    end
  end
  local block = value:match('"(%S+)"')
  if not block then
    for w, pos in value:gmatch("()(%S+)") do
      _ = w
    end
    local s = 1
    while true do
      local a, b = value:find("%S+", s)
      if not a then
        break
      end
      local word = value:sub(a, b)
      if not word:match("^:") and not (a > 1 and value:sub(a - 1, a - 1) == ":") then
        block = word
        break
      end
      -- skip keyword and its value
      if word:match("^:") then
        local a2, b2 = value:find("%S+", b + 1)
        s = (a2 and not value:sub(a2, b2):match("^:")) and (b2 + 1) or (b + 1)
      else
        s = b + 1
      end
    end
  end
  p.block = block
  return p
end

--- Lines of `file` restricted to `range` ("a-b", b exclusive).
local function restrict_lines(content, range)
  if not range then
    return content
  end
  local a, b = range:match("^(%d*)%-(%d*)$")
  a = tonumber(a) or 0
  b = tonumber(b) or 0
  local s = a == 0 and 1 or a
  local e = b == 0 and #content or (b - 1)
  return vim.list_slice(content, s, e)
end

--- Locate `search` in an org file's lines (org-link-search) and return the
--- lines of the element found (subtree, named element or target paragraph).
function M.include_location(content, search, only_contents)
  local file = require("org.parser").parse(content)
  local hl
  local s = search
  if s:match("^%*") then
    local title = trim(s:sub(2))
    hl = file:find_headline(function(h)
      return h:plain_title() == title or trim(h.title) == title
    end)
  elseif s:match("^#") then
    hl = file:find_by_custom_id(s:sub(2))
  end
  if hl then
    local first = hl.line
    local last = hl.end_line
    if only_contents then
      first = hl.line + 1
      if
        content[first]
        and content[first]:match("^[ \t]*[A-Z]+:[ \t]*[<%[]")
        and content[first]:match("^[ \t]*(%u+):")
        and ({ SCHEDULED = true, DEADLINE = true, CLOSED = true })[content[first]:match("^[ \t]*(%u+):")]
      then
        first = first + 1
      end
      if content[first] and content[first]:match("^[ \t]*:[Pp][Rr][Oo][Pp][Ee][Rr][Tt][Ii][Ee][Ss]:") then
        while content[first] and not content[first]:match("^[ \t]*:[Ee][Nn][Dd]:") do
          first = first + 1
        end
        first = first + 1
      end
    end
    return vim.list_slice(content, first, last)
  end
  -- named element or dedicated target
  local tree = element.parse(content, {})
  local found
  element.map(tree, "*", function(n)
    if found then
      return
    end
    if n.name == s and element.ELEMENTS[n.type] then
      found = n
    end
  end)
  if found then
    -- rebuild the element's lines: search for its NAME line
    for i, l in ipairs(content) do
      local nm = l:match("^[ \t]*#%+[Nn][Aa][Mm][Ee]:[ \t]*(.-)[ \t]*$")
      if nm == s then
        local j = i + 1
        while
          content[j]
          and content[j]:match("^[ \t]*#%+[%w_]+:")
          and not content[j]:lower():match("^[ \t]*#%+begin")
        do
          j = j + 1
        end
        local l2 = content[j] or ""
        local bt = l2:match("^[ \t]*#%+[Bb][Ee][Gg][Ii][Nn]_(%S+)")
        local last = j
        if bt then
          local endp = "^[ \t]*#%+end_" .. vim.pesc(bt:lower())
          while content[last] and not content[last]:lower():match(endp) do
            last = last + 1
          end
        elseif l2:match("^[ \t]*|") then
          while content[last + 1] and content[last + 1]:match("^[ \t]*[|#]") do
            last = last + 1
          end
        else
          while content[last + 1] and not content[last + 1]:match("^[ \t]*$") do
            last = last + 1
          end
        end
        -- element end includes following blank lines
        while content[last + 1] and content[last + 1]:match("^[ \t]*$") do
          last = last + 1
        end
        if only_contents then
          return vim.list_slice(content, j + 1, last - 1)
        end
        return vim.list_slice(content, i, math.min(last, #content))
      end
    end
  end
  local links = require("org.links")
  for i, l in ipairs(content) do
    -- a real target: not text in a link's description
    if links.find_target(l, s) then
      local a, b = i, i
      while a > 1 and not content[a - 1]:match("^[ \t]*$") do
        a = a - 1
      end
      while content[b + 1] and not content[b + 1]:match("^[ \t]*$") do
        b = b + 1
      end
      return vim.list_slice(content, a, b)
    end
  end
  error(string.format("No match for fuzzy expression: %s", s))
end

-- The link types whose path is rebased (org-element-link-parser gives
-- them the type "file").
local FILE_PREFIXES = { ["file:"] = true, ["file+sys:"] = true, ["file+emacs:"] = true }

--- `target` (the raw text of a link's target) with its relative file path
--- made relative to `top_dir` instead of `fdir`, or nil when it is not a
--- relative file link (org-export--update-included-link).
local function rebase_target(target, fdir, top_dir, bracket)
  local prefix = target:match("^[Ff][Ii][Ll][Ee][+%w]*:")
  if prefix and not FILE_PREFIXES[prefix:lower()] then
    return nil
  end
  if not prefix and not (bracket and target:match("^%.%.?/")) then
    return nil
  end
  local rest = target:sub(#(prefix or "") + 1)
  local path, search = rest:match("^(.-)(::.*)$")
  path = path or rest
  search = search or ""
  local links = require("org.links")
  if bracket then
    path = links.unescape(path)
  end
  if path == "" or utils.is_absolute(path) or path:match("^~") then
    return nil
  end
  local new = M.relative_path(vim.fs.normalize(fdir .. "/" .. path), top_dir)
  if bracket then
    new = links.escape(new)
  end
  return (prefix or "") .. new .. search
end

--- `text` with its file links rebased; `desc_only` keeps bracket links
--- (in a description only plain and angle links are looked for).
local function rebase_text(text, fdir, top_dir, desc_only)
  local found = require("org.links").parse_links(text)
  local skip = require("org.ui").verbatim_ranges(text)
  local function in_verbatim(col)
    for _, r in ipairs(skip) do
      if col >= r[1] and col <= r[2] then
        return true
      end
    end
  end
  for k = #found, 1, -1 do
    local l = found[k]
    local s, e = l.start_col, l.end_col
    if not in_verbatim(s) and not (desc_only and not (l.plain or l.angle)) then
      local repl
      if l.plain then
        repl = rebase_target(text:sub(s, e), fdir, top_dir, false)
      elseif l.angle then
        local t = rebase_target(text:sub(s + 1, e - 1), fdir, top_dir, false)
        repl = t and ("<" .. t .. ">")
      else
        local desc = l.desc and rebase_text(l.desc, fdir, top_dir, true)
        local t = rebase_target(l.raw_target, fdir, top_dir, true)
        if t or desc ~= l.desc then
          repl = "[[" .. (t or l.raw_target) .. "]" .. (desc and ("[" .. desc .. "]") or "") .. "]"
        end
      end
      if repl then
        text = text:sub(1, s - 1) .. repl .. text:sub(e + 1)
      end
    end
  end
  return text
end

--- Rebase the relative file links of the included `body` (lines of a file
--- in `fdir`) onto `top_dir`, in place. Links in verbatim blocks, comments,
--- fixed-width lines, keywords other than CAPTION and =verbatim= / ~code~
--- objects are left alone, as Emacs only updates link objects.
function M.rebase_included_links(body, fdir, top_dir)
  if vim.fs.normalize(fdir) == vim.fs.normalize(top_dir) then
    return
  end
  local parser = require("org.parser")
  local i = 1
  while i <= #body do
    local close = parser.verbatim_block_end(body, i, #body)
    if close then
      i = close + 1
    else
      local line = body[i]
      local key = line:match("^%s*#%+(%S-):")
      local objects = not (line:match("^%s*[#:]%s") or line:match("^%s*[#:]$"))
        and not (key and not key:upper():match("^CAPTION"))
      if objects and (line:find(":", 1, true)) then
        body[i] = rebase_text(line, fdir, top_dir, false)
      end
      i = i + 1
    end
  end
end

--- Expand #+INCLUDE keywords (org-export-expand-include-keyword).
---@param lines string[]
---@param dir string directory of the includer
---@param opts table { included, footnotes, file_prefix, includer, expand_env }
function M.expand_includes(lines, dir, opts)
  opts = opts or {}
  local included = opts.included or {}
  local footnotes = opts.footnotes or { order = {}, map = {} }
  local file_prefix = opts.file_prefix or { n = 0, map = {} }
  local top = opts.included == nil
  -- the directory every included link is made relative to: the top-level
  -- includer's, also in nested includes
  local top_dir = opts.top_dir or dir
  local out = {}
  local level = 0
  local in_block
  local commented_level
  local todo = opts.todo
  for _, line in ipairs(lines) do
    local stars = line:match("^(%*+) ")
    if stars then
      level = #stars
      if commented_level and level <= commented_level then
        commented_level = nil
      end
      local parts = require("org.parser").parse_headline_line(line, todo)
      if parts and parts.commented and not commented_level then
        commented_level = level
      end
    end
    local low = line:lower()
    local spec
    if in_block then
      if low:match("^[ \t]*#%+end_" .. vim.pesc(in_block) .. "[ \t]*$") then
        in_block = nil
      end
    else
      local b = low:match("^[ \t]*#%+begin_(%S+)")
      if b then
        in_block = b
      else
        spec = line:match("^[ \t]*#%+[Ii][Nn][Cc][Ll][Uu][Dd][Ee]:[ \t]*(.-)[ \t]*$")
      end
    end
    if spec and not commented_level then
      local ind = #(line:match("^([ \t]*)"))
      local p = M.parse_include_value(opts.expand_env and M.expand_env(spec) or spec, dir)
      local file = p.file
      if file then
        local is_url = file:match("^%a[%w+.-]*://") ~= nil
        local content
        if is_url then
          -- asked for or refused per resource_download_policy (org-file-contents)
          local err
          content, err = require("org.resources").contents(file, opts.includer)
          if not content then
            error(err or ("Cannot include file " .. file))
          end
        else
          content = utils.readfile(file)
          if not content then
            error("Cannot include file " .. file)
          end
        end
        local key = file .. "\0" .. (p.lines or "")
        if included[key] then
          error("Recursive file inclusion: " .. file)
        end
        local ind_str = string.rep(" ", ind)
        if p.env == "literal" then
          local body = restrict_lines(content, p.lines)
          out[#out + 1] = ind_str .. "#+BEGIN_" .. p.block .. (p.args and (" " .. p.args) or "")
          vim.list_extend(out, escape_code(body))
          out[#out + 1] = ind_str .. "#+END_" .. p.block
        elseif p.block then
          local body = restrict_lines(content, p.lines)
          out[#out + 1] = ind_str .. "#+BEGIN_" .. p.block
          vim.list_extend(out, body)
          out[#out + 1] = ind_str .. "#+END_" .. p.block
        else
          local body = content
          if p.location then
            body = M.include_location(content, p.location, p.only_contents)
          end
          body = restrict_lines(body, p.lines)
          -- links relative to the included file become relative to the
          -- top-level includer (org-export--prepare-file-contents)
          local fdir = vim.fn.fnamemodify(file, ":h")
          if opts.includer and not is_url then
            M.rebase_included_links(body, fdir, top_dir)
          end
          -- trim blank lines around contents
          while #body > 0 and body[1]:match("^[ \t]*$") do
            table.remove(body, 1)
          end
          while #body > 0 and body[#body]:match("^[ \t]*$") do
            table.remove(body)
          end
          -- keep the keyword indentation until the first headline
          if ind > 0 then
            for i, l in ipairs(body) do
              if l:match("^%*+ ") then
                break
              end
              if not l:match("^%[fn:[%w%-_]+%]") then
                body[i] = ind_str .. l
              end
            end
          end
          local minlevel = p.minlevel or (level + 1)
          local min
          for _, l in ipairs(body) do
            local st = l:match("^(%*+) ")
            if st and (not min or #st < min) then
              min = #st
            end
          end
          if min and minlevel then
            local off = minlevel - min
            if off ~= 0 then
              for i, l in ipairs(body) do
                local st, rest = l:match("^(%*+)( .*)$")
                if st then
                  body[i] = string.rep("*", math.max(1, #st + off)) .. rest
                end
              end
            end
          end
          -- make footnote labels file specific
          local id = file_prefix.map[file]
          if not id then
            id = file_prefix.n
            file_prefix.map[file] = id
            file_prefix.n = file_prefix.n + 1
          end
          local seen = {}
          for i, l in ipairs(body) do
            body[i] = l:gsub("%[fn:([%w%-_]+)([%]:])", function(label, tail)
              local new = "-" .. id .. "-" .. label
              seen[label] = new
              return "[fn:" .. new .. tail
            end)
          end
          -- definitions outside the included part
          if p.location or p.lines then
            local defined = {}
            for _, l in ipairs(body) do
              local lab = l:match("^%[fn:([%w%-_]+)%]")
              if lab then
                defined[lab] = true
              end
            end
            for label, new in pairs(seen) do
              if not defined[new] then
                for ci, l in ipairs(content) do
                  local d = l:match("^%[fn:" .. vim.pesc(label) .. "%][ \t]*(.*)$")
                  if d then
                    local def = { d }
                    local k = ci + 1
                    while
                      content[k]
                      and not content[k]:match("^%[fn:")
                      and not content[k]:match("^%*+ ")
                      and not (content[k]:match("^[ \t]*$") and (content[k + 1] or ""):match("^[ \t]*$"))
                    do
                      def[#def + 1] = content[k]
                      k = k + 1
                    end
                    if not footnotes.map[new] then
                      footnotes.map[new] = table.concat(def, "\n")
                      footnotes.order[#footnotes.order + 1] = new
                    end
                    break
                  end
                end
              end
            end
          end
          local sub_included = vim.deepcopy(included)
          sub_included[key] = true
          body = M.expand_includes(body, is_url and dir or fdir, {
            included = sub_included,
            footnotes = footnotes,
            file_prefix = file_prefix,
            includer = opts.includer,
            top_dir = top_dir,
            expand_env = opts.expand_env,
            todo = todo,
          })
          vim.list_extend(out, body)
        end
      end
    else
      out[#out + 1] = line
    end
  end
  if top and #footnotes.order > 0 then
    for _, label in ipairs(footnotes.order) do
      out[#out + 1] = ""
      out[#out + 1] = "[fn:" .. label .. "] " .. footnotes.map[label]
    end
  end
  return out
end

--- Relative path from `dir` to `path` (file-relative-name).
function M.relative_path(path, dir)
  path = vim.fs.normalize(path)
  dir = vim.fs.normalize(dir)
  local ps = vim.split(path, "/", { plain = true })
  local ds = vim.split(dir, "/", { plain = true })
  local i = 1
  while i <= #ps and i <= #ds and ps[i] == ds[i] do
    i = i + 1
  end
  local out = {}
  for _ = i, #ds do
    out[#out + 1] = ".."
  end
  for k = i, #ps do
    out[#out + 1] = ps[k]
  end
  local r = table.concat(out, "/")
  return r ~= "" and r or "."
end

--- Delete COMMENT subtrees (org-export--delete-comment-trees).
function M.delete_comment_trees(lines, todo)
  local out = {}
  local skip_level
  local parser = require("org.parser")
  for _, l in ipairs(lines) do
    local stars = l:match("^(%*+) ")
    if stars then
      if skip_level and #stars <= skip_level then
        skip_level = nil
      end
      if not skip_level then
        local parts = parser.parse_headline_line(l, todo)
        if parts and parts.commented then
          skip_level = #stars
        end
      end
    end
    if not skip_level then
      out[#out + 1] = l
    end
  end
  return out
end
