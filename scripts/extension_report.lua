-- The promotion report of the optional extensions: for each one, the value
-- of every criterion of "Promoting an extension" in CONTRIBUTING.md, whether
-- it passes, and the experimental extensions that pass them all.
--
--   nvim --headless --clean -l scripts/extension_report.lua [options] [name...]
--   make extensions-report [ARGS="..."]
--
-- Options:
--   --markdown          GitHub Markdown (for a job summary) instead of text
--   --json              the measurements as JSON
--   --coverage FILE     coverage.json of `make coverage` (default:
--                       coverage/coverage.json when it exists)
--   --no-gh             don't ask GitHub for open bug issues (also when
--                       `gh` is missing or fails: the column is skipped)
--   --issues FILE       open bug issues as the JSON of `gh issue list --json
--                       number,title,body,labels` instead of asking GitHub
--   --repo DIR          read the history (commits and tags) from the git
--                       repository DIR instead of this checkout
--   --demo FILE         the live demo config (default: $ORG_DEMO_CONFIG,
--                       else ~/demo/config.lua when it exists; skipped
--                       when there is none)
--
-- Names limit the report to those extensions (default: every built-in one).
-- Informational: it always exits 0 unless its own arguments are wrong.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)

--- The bar an experimental extension must clear to become stable. Keep it in
--- step with CONTRIBUTING.md ("Promoting an extension").
local BAR = {
  -- tests (`it(...)`) in its own spec files
  specs = 25,
  -- line coverage of its files, percent
  coverage = 80,
  -- minor or major releases (vX.Y.0 tags) that contain its first commit
  releases_since_added = 3,
  -- days since its first commit
  days_since_added = 30,
  -- minor or major releases after the one that shipped the last breaking
  -- change to its options
  releases_since_breaking = 3,
}

local opts = { format = "text", gh = true, only = {} }
do
  local i = 1
  while i <= #arg do
    local a = arg[i]
    if a == "--markdown" then
      opts.format = "markdown"
    elseif a == "--json" then
      opts.format = "json"
    elseif a == "--no-gh" then
      opts.gh = false
    elseif a == "--coverage" or a == "--demo" or a == "--issues" or a == "--repo" then
      i = i + 1
      opts[a:sub(3)] = arg[i]
    elseif a:match("^[%w_]+$") then
      opts.only[#opts.only + 1] = a
    else
      io.stderr:write("extension_report.lua: unknown argument " .. a .. "\n")
      os.exit(2)
    end
    i = i + 1
  end
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

local function exists(path)
  return path and vim.uv.fs_stat(path) ~= nil
end

---@return string|nil stdout, nil when the command failed
local function run(cmd)
  local ok, res = pcall(function()
    return vim.system(cmd, { cwd = root, text = true }):wait()
  end)
  if not ok or res.code ~= 0 then
    return nil
  end
  return res.stdout
end

local function git(...)
  return run(vim.list_extend({ "git", "-C", opts.repo or root }, { ... }))
end

local function lines(s)
  return vim.split(s or "", "\n", { trimempty = true })
end

--- `word` as a whole word in `s` (letters, digits and _ around it don't count).
local function has_word(s, word)
  return s:find("%f[%w_]" .. vim.pesc(word) .. "%f[^%w_]") ~= nil
end

local exts = require("org.extensions")
local names = exts.builtin()
if #opts.only > 0 then
  for _, n in ipairs(opts.only) do
    if not vim.tbl_contains(names, n) then
      io.stderr:write("extension_report.lua: no built-in extension " .. n .. "\n")
      os.exit(2)
    end
  end
  names = opts.only
end

-- ---------------------------------------------------------------------------
-- Specs

local spec_dir = root .. "/tests/spec"
local spec_files = {}
for name, kind in vim.fs.dir(spec_dir) do
  if kind == "file" and name:match("_spec%.lua$") then
    spec_files[#spec_files + 1] = name
  end
end
table.sort(spec_files)

local EDGE_FILE = { "edge", "safety", "stress", "fuzz", "robust" }
local EDGE_DESCRIBE = { "edge", "stress", "malformed", "fuzz", "robust", "corner", "pathological", "safety" }

--- Its own spec files: ext_<name>_spec.lua, ext_<name>_<part>_spec.lua and
--- fuzz_<name>[_<part>]_spec.lua.
local function own_specs(name)
  local out = {}
  for _, f in ipairs(spec_files) do
    local base = f:gsub("_spec%.lua$", "")
    for _, prefix in ipairs({ "ext_", "fuzz_" }) do
      local p = prefix .. name
      if base == p or base:sub(1, #p + 1) == p .. "_" then
        out[#out + 1] = f
        break
      end
    end
  end
  return out
end

local function measure_specs(name)
  local files = own_specs(name)
  local tests, edge = 0, nil
  for _, f in ipairs(files) do
    local text = read(spec_dir .. "/" .. f) or ""
    for l in text:gmatch("[^\n]+") do
      if l:match("^%s*it%(") then
        tests = tests + 1
      end
      local d = not edge and l:match('^%s*describe%("([^"]*)"')
      if d then
        for _, w in ipairs(EDGE_DESCRIBE) do
          if d:lower():find(w, 1, true) then
            edge = f .. ': describe "' .. d .. '"'
            break
          end
        end
      end
    end
    local base = f:gsub("_spec%.lua$", "")
    if base:match("^fuzz_") then
      edge = f
    end
    for _, w in ipairs(EDGE_FILE) do
      if base:sub(#("ext_" .. name) + 2):find(w, 1, true) then
        edge = f
      end
    end
  end
  return { files = files, tests = tests, edge = edge }
end

-- ---------------------------------------------------------------------------
-- Coverage

local coverage_path = opts.coverage or (exists(root .. "/coverage/coverage.json") and root .. "/coverage/coverage.json")
local coverage
if coverage_path then
  local text = read(coverage_path)
  local ok, data = pcall(vim.json.decode, text or "")
  if ok and type(data) == "table" and type(data.modules) == "table" then
    coverage = data.modules
  else
    io.stderr:write("extension_report.lua: can't read coverage from " .. coverage_path .. "\n")
  end
end

---@return number|nil percent
local function measure_coverage(name)
  if not coverage then
    return nil
  end
  local dir, single = "lua/org/extensions/" .. name .. "/", "lua/org/extensions/" .. name .. ".lua"
  local n, hit = 0, 0
  for _, m in pairs(coverage) do
    local file = type(m) == "table" and m.file or ""
    if file:sub(1, #dir) == dir or file == single then
      n, hit = n + (m.lines or 0), hit + (m.hit or 0)
    end
  end
  if n == 0 then
    return 0
  end
  return hit * 100 / n
end

-- ---------------------------------------------------------------------------
-- Docs: every option in its doc/org.txt section and in lua/org/_meta

local doc = read(root .. "/doc/org.txt") or ""
local doc_lines = vim.split(doc, "\n")

--- Its section of doc/org.txt, from the *org-extensions-<name>* tag to the
--- next separator line.
local function doc_section(name)
  local tag = "*org-extensions-" .. name:gsub("_", "-") .. "*"
  for i, l in ipairs(doc_lines) do
    if l:find(tag, 1, true) then
      local out = {}
      for j = i, #doc_lines do
        if j > i and (doc_lines[j]:match("^%-%-%-%-%-%-%-%-%-%-") or doc_lines[j]:match("^==========")) then
          break
        end
        out[#out + 1] = doc_lines[j]
      end
      return table.concat(out, "\n")
    end
  end
end

-- name -> { class = "org.Config.Extensions.X", file = path, text = file text }
local meta = {}
do
  local files = vim.fn.glob(root .. "/lua/org/_meta/*.lua", false, true)
  local texts = {}
  for _, f in ipairs(files) do
    texts[f] = read(f) or ""
  end
  for _, text in pairs(texts) do
    for ext, class in text:gmatch("\n%-%-%-@field ([%w_]+)%? (org%.Config%.Extensions%.[%w_]+)") do
      meta[ext] = { class = class }
    end
  end
  for _, m in pairs(meta) do
    for f, text in pairs(texts) do
      if text:find("---@class " .. m.class .. "\n", 1, true) then
        m.file, m.text = f, text
      end
    end
  end
end

--- The `---@field` names of `class` in a _meta file's text.
local function class_fields(text, class)
  local fields, on = {}, false
  for _, l in ipairs(vim.split(text or "", "\n")) do
    local c = l:match("^%-%-%-@class ([%w_.]+)")
    if c then
      on = c == class
    elseif on then
      if not l:match("^%-%-%-") then
        on = false
      else
        local f = l:match("^%-%-%-@field ([%w_]+)")
        if f then
          fields[f] = true
        end
      end
    end
  end
  return fields
end

--- A table of records the user adds to (capture templates by key, block
--- types): every value is a table.
local function is_record_map(t)
  for _, v in pairs(t) do
    if type(v) ~= "table" then
      return false
    end
  end
  return true
end

--- Option names of an extension: the keys of its `defaults` and, one level
--- down, the keys of a table of options (not of a list, of a map of records
--- or of a table of keys, `keys` or `<...>_keys`, whose entries are actions
--- documented with the keys bound to them).
local function option_names(defaults)
  local top, nested = {}, {}
  for k, v in pairs(defaults or {}) do
    if type(k) == "string" and k ~= "enabled" then
      top[#top + 1] = k
      local keys = k == "keys" or k:match("_keys$")
      if type(v) == "table" and not keys and not vim.islist(v) and next(v) ~= nil and not is_record_map(v) then
        for k2 in pairs(v) do
          if type(k2) == "string" then
            nested[#nested + 1] = k2
          end
        end
      end
    end
  end
  table.sort(top)
  table.sort(nested)
  return top, vim.fn.uniq(nested)
end

local function measure_docs(name, ext)
  local section = doc_section(name)
  local m = meta[name]
  local missing = { doc = {}, meta = {} }
  if not section then
    missing.doc[1] = "(no *org-extensions-" .. name:gsub("_", "-") .. "* section)"
  end
  if not m or not m.text then
    missing.meta[1] = "(no _meta class)"
  end
  local top, nested = option_names(ext.defaults)
  local fields = m and m.text and class_fields(m.text, m.class) or {}
  for _, k in ipairs(top) do
    if section and not has_word(section, k) then
      missing.doc[#missing.doc + 1] = k
    end
    if m and m.text and not fields[k] then
      missing.meta[#missing.meta + 1] = k
    end
  end
  for _, k in ipairs(nested) do
    -- nested shapes are typed inline or by shared classes in _meta: only
    -- the manual is checked for them, where `<name>_<key>` (an action
    -- named after it) counts too
    if section and not has_word(section, k) and not has_word(section, name .. "_" .. k) then
      missing.doc[#missing.doc + 1] = k
    end
  end
  return { options = #top + #nested, missing = missing, ok = #missing.doc == 0 and #missing.meta == 0 }
end

-- ---------------------------------------------------------------------------
-- History: releases since it was added and since its last breaking change

-- the history is only measured with every commit and the release tags
local history_ok = vim.trim(git("rev-parse", "--is-shallow-repository") or "") == "false"

--- vX.Y.Z -> { X, Y, Z }
local function version(tag)
  local x, y, z = tag:match("^v(%d+)%.(%d+)%.(%d+)$")
  return x and { tonumber(x), tonumber(y), tonumber(z) } or nil
end

local function older(a, b)
  local va, vb = version(a), version(b)
  for i = 1, 3 do
    if va[i] ~= vb[i] then
      return va[i] < vb[i]
    end
  end
  return false
end

local release_tags = {}
for _, t in ipairs(lines(git("tag", "--list", "v*"))) do
  if version(t) then
    release_tags[t] = true
  end
end
if next(release_tags) == nil then
  history_ok = false
end

--- The release tags that contain `commit`, oldest first.
local function releases_with(commit)
  local out = {}
  for _, t in ipairs(lines(git("tag", "--contains", commit))) do
    if release_tags[t] then
      out[#out + 1] = t
    end
  end
  table.sort(out, older)
  return out
end

--- Minor and major releases (vX.Y.0) that contain `commit`; with `after`,
--- not counting the release that shipped it.
local function releases_since(commit, after)
  local n = 0
  for i, t in ipairs(releases_with(commit)) do
    if version(t)[3] == 0 and not (after and i == 1) then
      n = n + 1
    end
  end
  return n
end

local SCOPE_ALL = { extensions = true, ext = true }

-- commits marked breaking (`type(scope)!:` or a BREAKING CHANGE: footer):
-- { hash, time, subject, scopes = { name = true }, footer = text }
local breaking_commits = {}
do
  local out =
    git("log", "-E", "--format=%H%x1f%ct%x1f%s%x1f%b%x1e", "--grep=^[a-z]+(\\([^)]*\\))?!:", "--grep=BREAKING CHANGE:")
  for rec in (out or ""):gmatch("([^\30]+)") do
    local hash, time, subject, body = rec:match("^%s*(%x+)\31(%d+)\31([^\31]*)\31(.*)$")
    if hash then
      local scope, bang = subject:match("^%a+%(([^)]*)%)(!?):")
      if not scope then
        bang = subject:match("^%a+(!?):")
      end
      local footer = body:match("BREAKING CHANGE:(.*)")
      if bang == "!" or footer then
        local scopes = {}
        for s in (scope or ""):gmatch("[^,%s]+") do
          scopes[(s:gsub("-", "_"))] = true
        end
        breaking_commits[#breaking_commits + 1] =
          { hash = hash, time = tonumber(time), subject = subject, scopes = scopes, footer = footer }
      end
    end
  end
end

--- Whether `text` names extension `name` unambiguously: `` `name` ``,
--- "name extension" or `extensions.name` (many names are English words, so
--- the bare word doesn't count).
local function names_extension(text, name)
  text = text:lower()
  for _, n in ipairs({ name, (name:gsub("_", "-")) }) do
    local p = vim.pesc(n)
    if
      text:find("`" .. p .. "`")
      or text:find("%f[%w_]" .. p .. " extension")
      or text:find("extensions%." .. p .. "%f[^%w_]")
    then
      return true
    end
  end
  return false
end

--- Whether breaking commit `c` is a breaking change of extension `name`:
--- its scope is the extension; or its scope is `extensions`/`ext` and its
--- subject or footer names it as a word; or its footer names it
--- unambiguously (names_extension).
local function breaks(c, name)
  if c.scopes[name] then
    return true
  end
  for s in pairs(c.scopes) do
    if SCOPE_ALL[s] then
      local subject = c.subject:gsub("^[^:]*:", "")
      if has_word(subject, name) or (c.footer and has_word(c.footer, name)) then
        return true
      end
    end
  end
  return c.footer ~= nil and names_extension(c.footer, name)
end

-- file contents at a revision, shared by the extensions whose options are
-- typed in the same _meta file
local shown = {}
local function show(spec)
  if shown[spec] == nil then
    shown[spec] = git("show", spec) or false
  end
  return shown[spec] or nil
end

--- The newest commit that removed an option (a `---@field`) of `class` from
--- its _meta file, as { hash, time }.
local function last_option_removal(file, class)
  local rel = file:sub(#root + 2)
  local out = git("log", "--format=%H %ct", "--", rel)
  for _, l in ipairs(lines(out)) do
    local hash, time = l:match("^(%x+) (%d+)$")
    local after = show(hash .. ":" .. rel)
    local before = show(hash .. "^:" .. rel)
    if after and before then
      local fa, fb = class_fields(after, class), class_fields(before, class)
      -- a class that is new, or moved to another file, removes nothing
      if next(fa) and next(fb) then
        for f in pairs(fb) do
          if not fa[f] then
            return { hash = hash, time = tonumber(time), field = f }
          end
        end
      end
    end
  end
end

--- nil when the history can't be measured (a shallow clone, no tags).
local function measure_history(name)
  if not history_ok then
    return nil
  end
  local dir = "lua/org/extensions/" .. name
  local log = lines(git("log", "--reverse", "--format=%H %ct", "--", dir, dir .. ".lua"))[1]
  local first, first_time = (log or ""):match("^(%x+) (%d+)$")
  local res = {
    added = first and releases_since(first) or 0,
    age = first and math.floor((os.time() - tonumber(first_time)) / 86400) or 0,
  }
  local last
  for _, c in ipairs(breaking_commits) do
    if breaks(c, name) then
      last = c
      break -- git log lists the newest first
    end
  end
  local m = meta[name]
  local removal = m and m.file and last_option_removal(m.file, m.class)
  if removal and (not last or removal.time > last.time) then
    last = removal
  end
  if last then
    res.breaking = releases_since(last.hash, true)
    res.breaking_commit = last.hash:sub(1, 7) .. (last.field and (" (removed " .. last.field .. ")") or "")
  end
  return res
end

-- ---------------------------------------------------------------------------
-- Open bug issues (GitHub, optional)

local issues
if opts.issues then
  local ok, data = pcall(vim.json.decode, read(opts.issues) or "")
  if not ok or type(data) ~= "table" then
    io.stderr:write("extension_report.lua: can't read issues from " .. opts.issues .. "\n")
    os.exit(2)
  end
  issues = data
elseif opts.gh and vim.fn.executable("gh") == 1 then
  local out = run({
    "gh",
    "issue",
    "list",
    "--state",
    "open",
    "--label",
    "bug",
    "--limit",
    "1000",
    "--json",
    "number,title,body,labels",
  })
  local ok, data = pcall(vim.json.decode, out or "")
  if out and ok and type(data) == "table" then
    issues = data
  end
end

-- names that are also everyday words (or core terms): a bug title only
-- counts for them when it names the extension unambiguously
local WORDS = {
  cli = true,
  code = true,
  diagrams = true,
  drill = true,
  journal = true,
  literate = true,
  lsp = true,
  merge = true,
  present = true,
  review = true,
  sidebar = true,
  timeline = true,
  transclusion = true,
}

--- The "Extension" field of the bug report form (.github/ISSUE_TEMPLATE/
--- bug_report.yml), as GitHub renders it in the body.
local function form_extension(body)
  local v = ((body or "") .. "\n"):match("\n?###%s*Extension%s*\n%s*([^\n]-)%s*\n")
  return v and v:lower()
end

--- Whether a bug issue is about extension `name`: a label named after it
--- (or `ext:<name>`), the form's Extension field, or its title naming it:
--- `name: ...`, `[name] ...`, `fix(name): ...`, `` `name` ``, "name
--- extension", `extensions.name`, or (for a name that isn't an everyday
--- word) the name as a word; or its body saying "name extension" or
--- `extensions.name`.
local function about(issue, name)
  local alt = name:gsub("_", "-")
  local labels = {}
  for _, l in ipairs(issue.labels or {}) do
    labels[(type(l) == "table" and l.name or tostring(l)):lower()] = true
  end
  if labels[name] or labels[alt] or labels["ext:" .. name] then
    return true
  end
  local field = form_extension(issue.body)
  if field == name or field == alt then
    return true
  end
  local title = (issue.title or ""):lower()
  for _, n in ipairs({ name, alt }) do
    local p = vim.pesc(n)
    if
      title:find("^%s*" .. p .. "%s*:")
      or title:find("^%s*%[" .. p .. "%]")
      or title:find("^%s*%a+%(" .. p .. "%)!?:")
      or (not WORDS[name] and has_word(title, n))
    then
      return true
    end
    local body = (issue.body or ""):lower()
    if body:find("%f[%w_]" .. p .. " extension") or body:find("extensions%." .. p .. "%f[^%w_]") then
      return true
    end
  end
  return names_extension(title, name)
end

--- Open issues labelled `bug` about the extension (about()).
local function measure_bugs(name)
  if not issues then
    return nil
  end
  local out = {}
  for _, i in ipairs(issues) do
    if about(i, name) then
      out[#out + 1] = "#" .. tostring(i.number)
    end
  end
  return out
end

-- ---------------------------------------------------------------------------
-- The live demo (optional)

local demo_path = opts.demo or vim.env.ORG_DEMO_CONFIG or vim.fn.expand("~/demo/config.lua")
local demo = exists(demo_path) and read(demo_path) or nil
local demo_extensions = demo and demo:match("\n%s*extensions%s*=%s*(%b{})")

local function measure_demo(name)
  if not demo then
    return nil
  end
  return demo_extensions ~= nil and demo_extensions:find("\n%s*" .. name .. "%s*=") ~= nil
end

-- ---------------------------------------------------------------------------
-- Measure

-- criteria in column order: key, header, required (a skipped optional one
-- doesn't block a promotion, but must be checked by hand)
local CRITERIA = {
  { "specs", "specs", true },
  { "edge", "edge spec", true },
  { "coverage", "coverage", true },
  { "docs", "docs", true },
  { "health", "health", true },
  { "added", "releases, age", true },
  { "breaking", "no break", true },
  { "bugs", "open bugs", false },
  { "demo", "demo", false },
}

local rows = {}
for _, name in ipairs(names) do
  local ok, ext = pcall(require, "org.extensions." .. name)
  ext = ok and type(ext) == "table" and ext or {}
  local specs = measure_specs(name)
  local cov = measure_coverage(name)
  local docs = measure_docs(name, ext)
  local hist = measure_history(name)
  local bugs = measure_bugs(name)
  local in_demo = measure_demo(name)
  local c = {}
  c.specs = { value = tostring(specs.tests), pass = specs.tests >= BAR.specs }
  c.edge = { value = specs.edge and "yes" or "no", pass = specs.edge ~= nil, detail = specs.edge }
  if cov then
    c.coverage = { value = ("%.1f%%"):format(cov), pass = cov >= BAR.coverage }
  else
    c.coverage = { value = "?", pass = nil, detail = "run make coverage" }
  end
  local missing = {}
  if #docs.missing.doc > 0 then
    missing[#missing + 1] = "doc/org.txt: " .. table.concat(docs.missing.doc, ", ")
  end
  if #docs.missing.meta > 0 then
    missing[#missing + 1] = "_meta: " .. table.concat(docs.missing.meta, ", ")
  end
  c.docs = {
    value = docs.ok and ("%d opts"):format(docs.options)
      or ("%d missing"):format(#docs.missing.doc + #docs.missing.meta),
    pass = docs.ok,
    detail = #missing > 0 and table.concat(missing, "; ") or nil,
  }
  c.health = { value = type(ext.health) == "function" and "yes" or "no", pass = type(ext.health) == "function" }
  if not hist then
    c.added = { value = "?", pass = nil, detail = "needs full history and tags" }
    c.breaking = { value = "?", pass = nil, detail = "needs full history and tags" }
  else
    c.added = {
      value = ("%d, %dd"):format(hist.added, hist.age),
      pass = hist.added >= BAR.releases_since_added and hist.age >= BAR.days_since_added,
      releases = hist.added,
      days = hist.age,
    }
  end
  if not hist then
    -- not measured
  elseif hist.breaking then
    c.breaking = {
      value = tostring(hist.breaking),
      pass = hist.breaking >= BAR.releases_since_breaking,
      detail = "last breaking change " .. hist.breaking_commit,
    }
  else
    c.breaking = { value = "never", pass = true }
  end
  if bugs then
    c.bugs = { value = tostring(#bugs), pass = #bugs == 0, detail = #bugs > 0 and table.concat(bugs, " ") or nil }
  else
    c.bugs = { value = "-", pass = nil, detail = "not checked (gh)" }
  end
  if in_demo == nil then
    c.demo = { value = "-", pass = nil, detail = "not checked (no demo config)" }
  else
    c.demo = { value = in_demo and "yes" or "no", pass = in_demo }
  end
  local failed, unknown = {}, {}
  for _, crit in ipairs(CRITERIA) do
    local r = c[crit[1]]
    if r.pass == false then
      failed[#failed + 1] = crit[1]
    elseif r.pass == nil then
      unknown[#unknown + 1] = crit[1]
    end
  end
  rows[#rows + 1] = {
    name = name,
    stability = exts.stability(name),
    criteria = c,
    failed = failed,
    unknown = unknown,
  }
end

local REQUIRED = {}
for _, crit in ipairs(CRITERIA) do
  REQUIRED[crit[1]] = crit[3]
end

--- The criteria that keep it from promotion: the failed ones and the
--- required ones that weren't measured.
local function blockers(r)
  local out = vim.deepcopy(r.failed)
  for _, k in ipairs(r.unknown) do
    if REQUIRED[k] then
      out[#out + 1] = k
    end
  end
  return out
end

-- what a failed criterion lacks, in words
local SHORT = {
  specs = function(c)
    return ("specs %s of %d"):format(c.value, BAR.specs)
  end,
  edge = function()
    return "an edge-case spec"
  end,
  coverage = function(c)
    return ("coverage %s of %d%%"):format(c.value, BAR.coverage)
  end,
  docs = function(c)
    return "options missing from " .. (c.detail or c.value)
  end,
  health = function()
    return "a health check"
  end,
  added = function(c)
    return ("releases %d of %d, days since its first commit %d of %d"):format(
      c.releases,
      BAR.releases_since_added,
      c.days,
      BAR.days_since_added
    )
  end,
  breaking = function(c)
    return ("releases since a breaking change %s of %d (%s)"):format(c.value, BAR.releases_since_breaking, c.detail)
  end,
  bugs = function(c)
    return "open bugs: " .. (c.detail or c.value)
  end,
  demo = function()
    return "a place in the live demo"
  end,
}

local function why(r, keys)
  local out = {}
  for _, k in ipairs(keys) do
    local cr = r.criteria[k]
    out[#out + 1] = cr.pass == nil and (k .. " not measured (" .. (cr.detail or "?") .. ")") or SHORT[k](cr)
  end
  return table.concat(out, "; ")
end

local candidates, near, far, below = {}, {}, {}, {}
for _, r in ipairs(rows) do
  local b = blockers(r)
  if r.stability == "experimental" and #b == 0 then
    candidates[#candidates + 1] = r
  elseif r.stability == "experimental" and #b <= 2 then
    near[#near + 1] = r
  elseif r.stability == "experimental" then
    far[#far + 1] = r
  elseif r.stability == "stable" and #r.failed > 0 then
    below[#below + 1] = r
  end
end
for _, r in ipairs(rows) do
  r.candidate = r.stability == "experimental" and #blockers(r) == 0
end

if opts.format == "json" then
  io.stdout:write(vim.json.encode({ bar = BAR, extensions = rows }) .. "\n")
  return
end

-- ---------------------------------------------------------------------------
-- Print

local md = opts.format == "markdown"
local out = {}
local function say(s)
  out[#out + 1] = s or ""
end

local function mark(r)
  if r.pass == nil then
    return r.value
  end
  return r.value .. (r.pass and " ✓" or " ✗")
end

local header = { "extension", "stability" }
for _, crit in ipairs(CRITERIA) do
  header[#header + 1] = crit[2]
end
local tbl = {}
for _, r in ipairs(rows) do
  local cells = { r.name, r.stability }
  for _, crit in ipairs(CRITERIA) do
    cells[#cells + 1] = mark(r.criteria[crit[1]])
  end
  tbl[#tbl + 1] = cells
end

local bar = ("Bar: ≥ %d specs, an edge-case spec, ≥ %d%% line coverage, every option documented, a health check, "):format(
  BAR.specs,
  BAR.coverage
) .. ("in ≥ %d minor releases and ≥ %d days old, ≥ %d minor releases after the one with its last breaking option change, "):format(
  BAR.releases_since_added,
  BAR.days_since_added,
  BAR.releases_since_breaking
) .. "no open bug issues, in the live demo."

if md then
  say("## Extension promotion report")
  say()
  say(bar .. ' See CONTRIBUTING.md, "Promoting an extension".')
  say()
  say("| " .. table.concat(header, " | ") .. " |")
  local sep = {}
  for i = 1, #header do
    sep[i] = i <= 2 and "---" or "---:"
  end
  say("| " .. table.concat(sep, " | ") .. " |")
  for _, cells in ipairs(tbl) do
    cells[1] = "`" .. cells[1] .. "`"
    say("| " .. table.concat(cells, " | ") .. " |")
  end
else
  say('Extension promotion report (CONTRIBUTING.md, "Promoting an extension")')
  say(bar)
  say()
  local widths = {}
  for i, h in ipairs(header) do
    widths[i] = vim.fn.strdisplaywidth(h)
    for _, cells in ipairs(tbl) do
      widths[i] = math.max(widths[i], vim.fn.strdisplaywidth(cells[i]))
    end
  end
  local function fmt(cells)
    local parts = {}
    for i, s in ipairs(cells) do
      local pad = string.rep(" ", widths[i] - vim.fn.strdisplaywidth(s))
      parts[i] = i <= 2 and (s .. pad) or (pad .. s)
    end
    return (table.concat(parts, "  "):gsub("%s+$", ""))
  end
  say(fmt(header))
  for _, cells in ipairs(tbl) do
    say(fmt(cells))
  end
end

local function list(title, items, describe)
  say()
  say(md and ("### " .. title) or (title .. ":"))
  if md then
    say()
  end
  if #items == 0 then
    say(md and "None." or "  none")
  end
  for _, r in ipairs(items) do
    say((md and "- `%s`: %s" or "  %s: %s"):format(r.name, describe(r)))
  end
end

list("Candidates for promotion", candidates, function(r)
  return "passes every criterion"
    .. (#r.unknown > 0 and ("; not measured here, check by hand: " .. table.concat(r.unknown, ", ")) or "")
end)
list("Near misses (one or two criteria short)", near, function(r)
  return "needs " .. why(r, blockers(r))
end)
list("Further off", far, function(r)
  return "needs " .. why(r, blockers(r))
end)
list("Stable but below the bar (not demoted; look into it)", below, function(r)
  return "lacks " .. why(r, r.failed)
end)

io.stdout:write(table.concat(out, "\n") .. "\n")
