-- The playground page of the website: a recording of each `:Org tutor`
-- lesson (docs/playground/<lesson>.cast, made by `make playground`, see
-- scripts/playground/record.lua) to play in the page, next to the
-- lesson's exercises with their keys, and a box to try the syntax.
--
-- The page's script (assets/playground.js) plays the asciicast v2 files
-- itself. A recording is loaded with a <script> tag, as
-- playground/<lesson>.js, so the page also works from file://; the .cast
-- file is published too, for any asciicast player.
local html = require("site.html")

local M = {}

--- Lesson names: basics first (the tutor's default), then the others.
---@param root string
---@return string[]
function M.lessons(root)
  local out = {}
  for _, f in ipairs(vim.fn.glob(root .. "/tutor/org/*.org", false, true)) do
    out[#out + 1] = vim.fn.fnamemodify(f, ":t:r")
  end
  table.sort(out, function(a, b)
    if (a == "basics") ~= (b == "basics") then
      return a == "basics"
    end
    return a < b
  end)
  return out
end

--- Org inline markup of the lesson text as HTML: =verbatim= and ~code~
--- as code, *bold*, links as their description.
---@param text string
---@return string
function M.inline(text)
  local parts = {}
  local i = 1
  while i <= #text do
    local s, e, mark, body = text:find("([=~])([^%s=~][^=~]-)%1", i)
    -- markup starts after a blank or ( and ends before a blank or punctuation
    while
      s
      and not (
        (s == 1 or text:sub(s - 1, s - 1):match("[%s(\"']")) and text:sub(e + 1, e + 1):match("^[%s%.,;:!?)\"']?$")
      )
    do
      s, e, mark, body = text:find("([=~])([^%s=~][^=~]-)%1", s + 1)
    end
    if not s then
      parts[#parts + 1] = html.escape(text:sub(i))
      break
    end
    parts[#parts + 1] = html.escape(text:sub(i, s - 1))
    parts[#parts + 1] = "<code>" .. html.escape(body) .. "</code>"
    i = e + 1
    local _ = mark
  end
  local out = table.concat(parts)
  out = out:gsub("%[%[[^%]]-%]%[([^%]]-)%]%]", "%1")
  return out
end

--- The paragraphs of `lines` (blank-line separated) as <p>, list items
--- as <ul>.
local function prose(lines)
  local out, para, list = {}, {}, nil
  local function flush()
    if #para > 0 then
      local text = M.inline(table.concat(para, " "))
      if list then
        list[#list + 1] = "<li>" .. text .. "</li>"
      else
        out[#out + 1] = "<p>" .. text .. "</p>"
      end
      para = {}
    end
  end
  local function end_list()
    flush()
    if list then
      out[#out + 1] = "<ul>" .. table.concat(list) .. "</ul>"
      list = nil
    end
  end
  for _, line in ipairs(lines) do
    local item = line:match("^%- (.*)$")
    if line:match("^%s*$") then
      end_list()
    elseif item then
      flush()
      list = list or {}
      para = { item }
    else
      para[#para + 1] = vim.trim(line)
    end
  end
  end_list()
  return table.concat(out, "\n")
end

--- The parts of a lesson: its title, the text before the first headline,
--- and each exercise ({ id, title, lines } with the instructions: the
--- text up to the practice material under it).
---@param lines string[] the rendered lesson
function M.parse(lines)
  local lesson = { title = "", intro = {}, exercises = {} }
  local cur = nil
  local in_intro = true
  for _, line in ipairs(lines) do
    local t = line:match("^#%+[Tt][Ii][Tt][Ll][Ee]:%s*(.-)%s*$")
    local stars, rest = line:match("^(%*+)%s+(.*)$")
    if t then
      lesson.title = t
    elseif stars then
      in_intro = false
      local id, title = rest:match("^(%d+%.%d+)%s+(.-)%s*$")
      if id and #stars == 2 then
        cur = { id = id, title = title, lines = {}, open = true }
        lesson.exercises[#lesson.exercises + 1] = cur
      elseif cur then
        cur.open = false
      end
    elseif in_intro then
      if not line:match("^#%+") then
        lesson.intro[#lesson.intro + 1] = line
      end
    elseif cur and cur.open then
      -- the practice material: a table, or a list after a blank line
      local prev = cur.lines[#cur.lines]
      if line:match("^%s*|") or (line:match("^%s*[-+] ") and (prev == nil or prev:match("^%s*$"))) then
        cur.open = false
      else
        cur.lines[#cur.lines + 1] = line
      end
    end
  end
  return lesson
end

--- The first paragraph of `lines`.
local function first_paragraph(lines)
  local out = {}
  for _, line in ipairs(lines) do
    if line:match("^%s*$") then
      if #out > 0 then
        break
      end
    else
      out[#out + 1] = line
    end
  end
  return out
end

--- A key as the tutor shows it, as <kbd>.
local function kbd(key)
  return "<kbd>" .. html.escape(key) .. "</kbd>"
end

--- What the recording does in an exercise: its keys (as the lesson
--- shows them) and typed text, in order.
---@param steps table[] the exercise's steps (scripts/playground/lessons)
---@param render fun(key: string): string
function M.keys(steps, render)
  local out = {}
  for _, step in ipairs(steps or {}) do
    if step.key then
      out[#out + 1] = kbd(render(step.key))
    elseif step.type then
      out[#out + 1] = '<span class="pg-typed">' .. html.escape(step.type) .. "</span>"
    end
  end
  return table.concat(out, " ")
end

--- The cast's markers, in order.
---@param cast string
---@return string[]
function M.markers(cast)
  local out = {}
  for line in cast:gmatch("[^\n]+") do
    if line:sub(1, 1) == "[" then
      local ev = vim.json.decode(line)
      if ev[2] == "m" then
        out[#out + 1] = ev[3]
      end
    end
  end
  return out
end

--- The playground page and its files.
---@param root string the checkout
---@param opts { err: fun(fmt: string, ...), blob: fun(path: string): string }
---@return { body: string, files: table<string, string> }
function M.build(root, opts)
  local tutor = require("org.tutor")
  -- the recordings' leader key (tests/screen.lua)
  local leader = vim.g.mapleader
  vim.g.mapleader = " "
  local function render(key)
    return tutor.render({ key })[1]
  end
  local files = {}
  local b = {
    "<h1>Playground</h1>",
    '<p class="lead">Try org.nvim before you install it: watch each lesson of the built-in tutor, '
      .. "<code>:Org tutor</code>, played in a real Neovim. Pause, scrub, step through the exercises and "
      .. "copy any text off the screen. The keys are org.nvim's defaults, with the leader key on "
      .. "<kbd>Space</kbd>.</p>",
  }
  local lessons = M.lessons(root)
  b[#b + 1] = '<div class="pg-tabs" role="tablist" aria-label="Lessons">'
  for k, name in ipairs(lessons) do
    b[#b + 1] = '<button type="button" role="tab" id="tab-'
      .. name
      .. '" aria-controls="lesson-'
      .. name
      .. '" aria-selected="'
      .. tostring(k == 1)
      .. '">'
      .. html.escape(name)
      .. "</button>"
  end
  b[#b + 1] = "</div>"
  for k, name in ipairs(lessons) do
    local cast_path = root .. "/docs/playground/" .. name .. ".cast"
    local f = io.open(cast_path, "rb")
    local cast = f and f:read("*a") or nil
    if f then
      f:close()
    end
    local lesson = M.parse(tutor.render(vim.fn.readfile(root .. "/tutor/org/" .. name .. ".org")))
    local ok_steps, steps = pcall(dofile, root .. "/scripts/playground/lessons/" .. name .. ".lua")
    if not cast then
      opts.err("tutor/org/%s.org has no recording docs/playground/%s.cast: run `make playground`", name, name)
    end
    if not ok_steps then
      opts.err("scripts/playground/lessons/%s.lua: %s", name, tostring(steps))
      steps = {}
    end
    local by_id = {}
    for _, ex in ipairs(steps) do
      by_id[ex.id] = ex
    end
    local markers = cast and M.markers(cast) or {}
    local marker_set = {}
    for _, m in ipairs(markers) do
      marker_set[m] = true
    end
    files["playground/" .. name .. ".cast"] = cast or ""
    files["playground/" .. name .. ".js"] = "window.ORG_CAST&&window.ORG_CAST("
      .. vim.json.encode(name)
      .. ","
      .. vim.json.encode(cast or "")
      .. ");\n"
    b[#b + 1] = '<section class="pg-lesson" id="lesson-'
      .. name
      .. '" role="tabpanel" aria-labelledby="tab-'
      .. name
      .. '" data-lesson="'
      .. name
      .. '" data-src="playground/'
      .. name
      .. '.js"'
      .. (k == 1 and "" or " hidden")
      .. ">"
    b[#b + 1] = "<h2>" .. html.escape(lesson.title) .. "</h2>"
    b[#b + 1] = '<div class="pg-player" tabindex="0" aria-label="Recording of the '
      .. name
      .. ' lesson">'
      .. '<noscript><p>The player needs JavaScript; <a href="playground/'
      .. name
      .. '.cast">download the recording</a> for any asciicast player.</p></noscript></div>'
    b[#b + 1] = '<ol class="pg-steps">'
    local welcome = "Welcome"
    b[#b + 1] = '<li data-marker="'
      .. welcome
      .. '"><div class="pg-step-head"><button type="button" class="pg-jump" aria-label="Play: Welcome">'
      .. "▶</button><strong>Welcome</strong></div>"
      .. prose(first_paragraph(lesson.intro))
      .. "</li>"
    for _, ex in ipairs(lesson.exercises) do
      local label = ex.id .. " " .. ex.title
      local played = marker_set[label]
      if cast and by_id[ex.id] and not played then
        opts.err("docs/playground/%s.cast has no exercise %q: the lesson changed, run `make playground`", name, label)
      end
      b[#b + 1] = '<li id="'
        .. name
        .. "-"
        .. ex.id:gsub("%.", "-")
        .. '"'
        .. (played and (' data-marker="' .. html.escape(label) .. '"') or "")
        .. '><div class="pg-step-head">'
        .. (played and ('<button type="button" class="pg-jump" aria-label="Play: ' .. html.escape(label) .. '">▶</button>') or "")
        .. "<strong>"
        .. html.escape(label)
        .. "</strong></div>"
        .. prose(ex.lines)
        .. (by_id[ex.id] and ('<p class="pg-keys-used">Keys: ' .. M.keys(by_id[ex.id].steps, render) .. "</p>") or "")
        .. "</li>"
    end
    b[#b + 1] = "</ol>"
    b[#b + 1] = '<p class="pg-source">The lesson: <a href="'
      .. opts.blob("tutor/org/" .. name .. ".org")
      .. '"><code>tutor/org/'
      .. name
      .. '.org</code></a> · the recording: <a href="playground/'
      .. name
      .. '.cast">'
      .. name
      .. ".cast</a> (asciicast v2)</p>"
    b[#b + 1] = "</section>"
  end
  vim.g.mapleader = leader

  b[#b + 1] = '<h2 id="try-the-syntax">Try the syntax</h2>'
  b[#b + 1] = "<p>Type some Org below: headlines, TODO keywords, tags, lists, checkboxes, tables, "
    .. "dates and markup are highlighted as you type. (This box only colors text; the editing "
    .. "happens in Neovim.)</p>"
  b[#b + 1] = '<div class="pg-try"><pre class="pg-try-hl" aria-hidden="true"></pre>'
    .. '<textarea class="pg-try-input" wrap="off" spellcheck="false" autocapitalize="off" autocomplete="off" '
    .. 'aria-label="Org text to highlight">'
    .. html.escape(table.concat({
      "#+TITLE: My first org file",
      "",
      "* TODO Write the report                                   :work:",
      "  SCHEDULED: <2026-10-12 Mon> DEADLINE: <2026-10-16 Fri>",
      "** [#A] Gather the numbers",
      "   - [X] Sales",
      "   - [ ] Costs",
      "* DONE Call Bob",
      "  Notes with *bold*, /italic/, =verbatim= and a [[https://org-nvim.com][link]].",
      "",
      "| Fruit | Count |",
      "|-------+-------|",
      "| Apple |     3 |",
    }, "\n"))
    .. "</textarea></div>"
  b[#b + 1] = '<h2 id="install">Next: install it</h2>'
  b[#b + 1] = '<p>Ready for the real thing? <a href="index.html#-install-in-30-seconds">Install org.nvim</a> '
    .. "and run <code>:Org tutor</code>: every exercise is checked as you do it.</p>"
  return { body = table.concat(b, "\n"), files = files }
end

return M
