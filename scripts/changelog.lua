-- Generate CHANGELOG.md from the git history (Keep a Changelog style).
--
-- Each vX.Y.Z tag is a version. A version lists the pull requests merged
-- into dev since the previous tag: the first-parent commits of
-- prev..tag, which on dev are "Merge pull request #N from owner/branch"
-- commits whose body is the pull request's title (a Conventional Commits
-- subject). Commits made straight on the branch count too. Entries are
-- grouped by type; breaking changes (`type!:` or a `BREAKING CHANGE:`
-- footer in one of the pull request's commits) are listed first.
--
-- Usage (from the repository root):
--   nvim -l scripts/changelog.lua                     write CHANGELOG.md
--   nvim -l scripts/changelog.lua --version v1.3.0    name the commits after
--                                                     the latest tag v1.3.0
--   nvim -l scripts/changelog.lua --stdout            print instead of writing
--   nvim -l scripts/changelog.lua --section v1.3.0    print a version's entries
--   nvim -l scripts/changelog.lua --check v1.3.0      fail unless CHANGELOG.md
--                                                     has a v1.3.0 section
-- On a release/vX.Y.Z branch, --version defaults to vX.Y.Z.

local M = {}

M.repo_url = "https://github.com/xheisenbugx/org.nvim"

--- Sections of a version, in order. `collapse` puts the group in a
--- <details> block.
M.groups = {
  { key = "feat", title = "Features" },
  { key = "fix", title = "Fixes" },
  { key = "perf", title = "Performance" },
  { key = "docs", title = "Documentation" },
  { key = "refactor", title = "Refactors" },
  { key = "chore", title = "Tests, CI and chores", collapse = true },
}

-- Conventional Commits type -> group key. Types not listed go to chores;
-- `release` commits (the release branch's own) are left out.
local TYPE_GROUP = {
  feat = "feat",
  fix = "fix",
  perf = "perf",
  docs = "docs",
  doc = "docs",
  refactor = "refactor",
  revert = "fix",
  test = "chore",
  tests = "chore",
  ci = "chore",
  build = "chore",
  chore = "chore",
  style = "chore",
  release = false,
}

--- Split a Conventional Commits subject.
---@param subject string
---@return table|nil { type, scope, breaking, desc }
function M.parse(subject)
  local typ, rest = subject:match("^(%a+)(.*)$")
  if not typ then
    return nil
  end
  local scope
  local s = rest:match("^%(([^)]*)%)")
  if s then
    scope = s
    rest = rest:sub(#s + 3)
  end
  local bang = rest:sub(1, 1) == "!"
  if bang then
    rest = rest:sub(2)
  end
  local desc = rest:match("^:%s+(.+)$")
  if not desc then
    return nil
  end
  scope = scope and vim.trim(scope) or nil
  return { type = typ:lower(), scope = scope ~= "" and scope or nil, breaking = bang, desc = vim.trim(desc) }
end

-- Guess the type of a subject that isn't Conventional Commits, as the
-- first commits of the history are ("Add feature modules: ...").
local function guess_type(subject, branch)
  local prefix = branch and branch:match("^([%a]+)/")
  if prefix and TYPE_GROUP[prefix:lower()] ~= nil then
    return prefix:lower()
  end
  local l = subject:lower()
  if l:match("^merge ") then
    return "chore"
  end
  if l:match("readme") or l:match("documentation") or l:match("^docs?[%s:]") or l:match("typo") then
    return "docs"
  end
  if l:match("^fix") or l:match("^correct") or l:match("^repair") then
    return "fix"
  end
  if l:match("^test") or l:match("^ci[%s:]") or l:match("^bump") or l:match("^update dep") then
    return "chore"
  end
  if l:match("^refactor") or l:match("^rename") or l:match("^move") or l:match("^split") then
    return "refactor"
  end
  if l:match("^speed") or l:match("^faster") or l:match("^perf") or l:match("^optimi") then
    return "perf"
  end
  return "feat"
end

--- Turn a subject (and the branch it came from, if any) into an entry.
---@param subject string
---@param branch? string
---@return table { type, group, scope, breaking, desc }
function M.classify(subject, branch)
  subject = vim.trim(subject)
  local c = M.parse(subject)
  if not c or TYPE_GROUP[c.type] == nil then
    -- not Conventional Commits ("Core: config, ..." has no known type):
    -- guess the type and keep the whole subject
    c = { type = guess_type(subject, branch), breaking = c and c.breaking or false, desc = subject }
  end
  local g = TYPE_GROUP[c.type]
  if g == nil then
    g = "chore"
  end
  c.group = g or nil
  return c
end

--- Parse a "Merge pull request #N from owner/branch" subject.
---@return integer|nil pr, string|nil branch
function M.merge_info(subject)
  local n, branch = subject:match("^Merge pull request #(%d+) from [^/%s]+/(%S+)")
  if n then
    return tonumber(n), branch
  end
end

local function first_line(s)
  for l in (s or ""):gmatch("[^\n]+") do
    l = vim.trim(l)
    if l ~= "" then
      return l
    end
  end
end

--- An entry for one first-parent commit.
---@param c table { sha, subject, body, pr_messages? = string[] (the pull request's commit messages, oldest first) }
---@return table|nil entry (nil for commits left out)
function M.entry(c)
  local pr, branch = M.merge_info(c.subject)
  local title = c.subject
  if pr then
    title = first_line(c.body)
    -- GitHub's default title is the branch name ("Feat/emacs parity review")
    local default = title and branch and title:lower():gsub("[%s_-]+", "-") == branch:lower():gsub("[%s_-]+", "-")
    if default then
      title = nil
    end
    if not title then
      -- no title in the merge commit: the first Conventional Commits
      -- subject of the pull request, else its first commit, else the branch
      for _, m in ipairs(c.pr_messages or {}) do
        local s = first_line(m)
        if s and M.parse(s) then
          title = s
          break
        end
      end
      title = title or first_line((c.pr_messages or {})[1]) or (branch or ""):gsub("^%a+/", ""):gsub("[-_]", " ")
    end
  end
  local e = M.classify(title, branch)
  if not e.group then
    return nil
  end
  e.pr = pr
  e.sha = c.sha
  local msgs = c.pr_messages or { c.body }
  for _, m in ipairs(msgs) do
    if m and (m:match("\nBREAKING[ -]CHANGE:") or m:match("^BREAKING[ -]CHANGE:")) then
      e.breaking = true
    end
  end
  return e
end

-- Markdown-escape text outside `code spans`: < (Vim key notation such as
-- <C-c> would be read as an HTML tag) and * (emphasis).
local function escape(s)
  local out, i = {}, 1
  while i <= #s do
    local a, b = s:find("`[^`]+`", i)
    local plain = s:sub(i, (a or #s + 1) - 1)
    out[#out + 1] = plain:gsub("[<*]", "\\%0")
    if not a then
      break
    end
    out[#out + 1] = s:sub(a, b)
    i = b + 1
  end
  return table.concat(out)
end

local function link_prs(s, url)
  -- #36 in the text -> a link to pull request 36 (not inside `code`)
  return (s:gsub("(%f[%w#]#)(%d+)", function(_, n)
    return string.format("[#%s](%s/pull/%s)", n, url, n)
  end))
end

local function capitalize(s)
  local w = s:match("^%l+%f[^%w]") -- a plain lower-case first word
  -- another one-letter word is a key ("r turns ...", "e on ..."): R and E are other keys
  if w and (#w > 1 or w == "a") and not s:match("^%l+[%(%._]") then
    return s:sub(1, 1):upper() .. s:sub(2)
  end
  return s
end

--- One "- ..." line for an entry.
---@param e table
---@param opts? { url?: string, show_type?: boolean }
function M.render_entry(e, opts)
  opts = opts or {}
  local url = opts.url or M.repo_url
  local label
  if opts.show_type then
    label = e.type .. (e.scope and ("(" .. e.scope .. ")") or "")
  elseif e.scope then
    label = e.scope:gsub("%s*,%s*", ", ")
  end
  local parts = { "-" }
  if label then
    parts[#parts + 1] = "**" .. label .. ":**"
  end
  parts[#parts + 1] = link_prs(escape(capitalize(e.desc)), url)
  if e.pr then
    parts[#parts + 1] = string.format("([#%d](%s/pull/%d))", e.pr, url, e.pr)
  elseif e.sha then
    parts[#parts + 1] = string.format("([%s](%s/commit/%s))", e.sha:sub(1, 7), url, e.sha)
  end
  return table.concat(parts, " ")
end

--- The lines of one version's section.
---@param v table { name, date?, entries }
---@param opts? { url?: string }
function M.render_version(v, opts)
  local lines = {}
  local head = "## [" .. v.name .. "]"
  if v.date then
    head = head .. " - " .. v.date
  end
  lines[#lines + 1] = head
  lines[#lines + 1] = ""
  local by, breaking = {}, {}
  for _, e in ipairs(v.entries) do
    if e.breaking then
      breaking[#breaking + 1] = e
    else
      by[e.group] = by[e.group] or {}
      table.insert(by[e.group], e)
    end
  end
  local any = false
  if #breaking > 0 then
    any = true
    lines[#lines + 1] = "### ⚠ Breaking changes"
    lines[#lines + 1] = ""
    for _, e in ipairs(breaking) do
      lines[#lines + 1] = M.render_entry(e, { url = opts and opts.url, show_type = e.group == "chore" })
    end
    lines[#lines + 1] = ""
  end
  for _, g in ipairs(M.groups) do
    local list = by[g.key]
    if list then
      any = true
      if g.collapse then
        lines[#lines + 1] = string.format("<details><summary>%s (%d)</summary>", g.title, #list)
        lines[#lines + 1] = ""
      else
        lines[#lines + 1] = "### " .. g.title
        lines[#lines + 1] = ""
      end
      for _, e in ipairs(list) do
        lines[#lines + 1] = M.render_entry(e, { url = opts and opts.url, show_type = g.collapse })
      end
      lines[#lines + 1] = ""
      if g.collapse then
        lines[#lines + 1] = "</details>"
        lines[#lines + 1] = ""
      end
    end
  end
  if not any then
    lines[#lines + 1] = "No changes yet."
    lines[#lines + 1] = ""
  end
  return lines
end

--- The whole CHANGELOG.md.
---@param versions table[] newest first; { name, date?, entries, prev? }
---@param opts? { url?: string }
---@return string
function M.render(versions, opts)
  local url = opts and opts.url or M.repo_url
  local lines = {
    "# Changelog",
    "",
    "All notable changes to org.nvim, newest first. The format follows",
    "[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project",
    "uses [Semantic Versioning](https://semver.org/). Each entry is a merged",
    "pull request, by its [Conventional Commits](https://www.conventionalcommits.org/) title.",
    "",
    "This file is generated from the git history by `make changelog`",
    "(`scripts/changelog.lua`); edit the pull request titles, not this file.",
    "",
  }
  for _, v in ipairs(versions) do
    vim.list_extend(lines, M.render_version(v, opts))
  end
  for _, v in ipairs(versions) do
    local target
    if v.name == "Unreleased" then
      target = v.prev and string.format("%s/compare/%s...dev", url, v.prev) or url .. "/commits"
    elseif v.prev then
      target = string.format("%s/compare/%s...%s", url, v.prev, v.name)
    else
      target = string.format("%s/releases/tag/%s", url, v.name)
    end
    lines[#lines + 1] = string.format("[%s]: %s", v.name, target)
  end
  return table.concat(lines, "\n") .. "\n"
end

--- The entries of version `name` in a rendered changelog, without its
--- heading (for release notes). nil when there is no such section.
---@param text string
---@param name string
---@return string|nil
function M.section(text, name)
  local out, inside = {}, false
  for line in (text .. "\n"):gmatch("(.-)\n") do
    if line:match("^## %[") then
      if inside then
        break
      end
      inside = vim.startswith(line, "## [" .. name .. "]")
    elseif inside then
      if line:match("^%[[^%]]+%]: ") then
        break
      end
      out[#out + 1] = line
    end
  end
  if not inside and #out == 0 then
    return nil
  end
  return vim.trim(table.concat(out, "\n")) .. "\n"
end

------------------------------------------------------------------------
-- git

local function git(args)
  local r = vim.system(vim.list_extend({ "git" }, args), { text = true }):wait()
  if r.code ~= 0 then
    error("git " .. table.concat(args, " ") .. ": " .. (r.stderr or ""), 0)
  end
  return r.stdout
end

local SEP, END = "\31", "\30"

-- Commits of `range` as { sha, parents, subject, body }, newest first.
local function commits(range, first_parent)
  local args = { "log", "--format=%H" .. SEP .. "%P" .. SEP .. "%s" .. SEP .. "%b" .. END }
  if first_parent then
    table.insert(args, 2, "--first-parent")
  end
  args[#args + 1] = range
  local out = {}
  for rec in git(args):gmatch("(.-)" .. END) do
    rec = rec:gsub("^\n", "")
    local sha, parents, subject, body = rec:match("^(.-)" .. SEP .. "(.-)" .. SEP .. "(.-)" .. SEP .. "(.*)$")
    if sha then
      out[#out + 1] =
        { sha = sha, parents = vim.split(parents, " ", { trimempty = true }), subject = subject, body = body }
    end
  end
  return out
end

local function entries(range)
  local list = {}
  for _, c in ipairs(commits(range, true)) do
    if #c.parents > 1 then
      c.pr_messages = {}
      for _, pc in ipairs(commits(c.parents[1] .. ".." .. c.parents[2], false)) do
        table.insert(c.pr_messages, 1, pc.subject .. "\n\n" .. pc.body)
      end
    end
    local e = M.entry(c)
    if e then
      list[#list + 1] = e
    end
  end
  -- oldest first reads like a story within each group
  local rev = {}
  for i = #list, 1, -1 do
    rev[#rev + 1] = list[i]
  end
  return rev
end

--- vX.Y.Z tags, oldest first, with their dates.
function M.tags()
  local dates = {}
  for line in git({ "for-each-ref", "--format=%(refname:short) %(creatordate:short)", "refs/tags" }):gmatch("[^\n]+") do
    local t, d = line:match("^(%S+) (%S+)$")
    if t then
      dates[t] = d
    end
  end
  local out = {}
  for t in git({ "tag", "--sort=v:refname" }):gmatch("[^\n]+") do
    if t:match("^v%d+%.%d+%.%d+$") then
      out[#out + 1] = { name = t, date = dates[t] }
    end
  end
  return out
end

--- Collect every version from the repository, newest first.
---@param opts? { version?: string, head?: string, today?: string }
function M.collect(opts)
  opts = opts or {}
  local head = opts.head or "HEAD"
  local tags = M.tags()
  local versions = {}
  local prev
  for _, t in ipairs(tags) do
    versions[#versions + 1] = {
      name = t.name,
      date = t.date,
      prev = prev,
      entries = entries(prev and (prev .. ".." .. t.name) or t.name),
    }
    prev = t.name
  end
  local exists = false
  for _, t in ipairs(tags) do
    exists = exists or t.name == opts.version
  end
  local pending = entries(prev and (prev .. ".." .. head) or head)
  if opts.version and not exists then
    versions[#versions + 1] =
      { name = opts.version, date = opts.today or os.date("%Y-%m-%d"), prev = prev, entries = pending }
  else
    versions[#versions + 1] = { name = "Unreleased", prev = prev, entries = pending }
  end
  local newest = {}
  for i = #versions, 1, -1 do
    newest[#newest + 1] = versions[i]
  end
  return newest
end

local function read(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return s
end

local function main(args)
  local o = { file = "CHANGELOG.md" }
  local i = 1
  while i <= #args do
    local a = args[i]
    if a == "--version" or a == "--section" or a == "--check" or a == "--output" then
      o[a:sub(3)] = args[i + 1]
      i = i + 1
    elseif a == "--stdout" then
      o.stdout = true
    else
      io.stderr:write("changelog: unknown argument " .. a .. "\n")
      os.exit(2)
    end
    i = i + 1
  end
  local file = o.output or o.file
  if o.section or o.check then
    local name = o.section or o.check
    local s = M.section(read(file) or "", name)
    if not s then
      io.stderr:write(string.format("%s has no ## [%s] section; run make changelog VERSION=%s\n", file, name, name))
      os.exit(1)
    end
    if o.section then
      io.stdout:write(s)
    end
    os.exit(0)
  end
  if not o.version or o.version == "" then
    local branch = vim.trim(git({ "rev-parse", "--abbrev-ref", "HEAD" }))
    o.version = branch:match("^release/(v%d+%.%d+%.%d+)$")
  end
  if o.version and not o.version:match("^v%d+%.%d+%.%d+$") then
    io.stderr:write("changelog: --version must look like vX.Y.Z\n")
    os.exit(2)
  end
  local text = M.render(M.collect({ version = o.version }))
  if o.stdout then
    io.stdout:write(text)
  else
    local f = assert(io.open(file, "wb"))
    f:write(text)
    f:close()
    io.stdout:write("wrote " .. file .. (o.version and (" (" .. o.version .. ")") or "") .. "\n")
  end
  os.exit(0)
end

if arg and arg[0] and arg[0]:match("changelog%.lua$") then
  local args = {}
  for k = 1, #arg do
    args[#args + 1] = arg[k]
  end
  main(args)
end

return M
