---@mod org.extensions.cli.info The listing commands: templates, files, tags, keywords, schema, version
---
--- What the configuration defines: capture templates, agenda files, tags,
--- TODO keywords and priorities, and the JSON schema and version. Part of
--- org.extensions.cli.run, which loads it.

local data = require("org.extensions.cli.data")
local schema = require("org.extensions.cli.schema")

local M = require("org.extensions.cli.run")

local fail = M.fail

function M.cmd_templates()
  local capture = require("org.capture")
  local templates = capture.templates()
  local keys = vim.tbl_keys(templates)
  table.sort(keys)
  local list, text = {}, {}
  for _, k in ipairs(keys) do
    local t = templates[k]
    local group = type(t) ~= "table"
    local desc = type(t) == "table" and t.description or (type(t) == "string" and t) or ""
    ---@type string|vim.NIL
    local target = vim.NIL
    if not group then
      local ok, p = pcall(capture.target_path, t)
      target = ok and data.path(p) or vim.NIL
    end
    list[#list + 1] = {
      key = k,
      description = desc,
      type = group and vim.NIL or (t.type or "entry"),
      target = target,
      group = group,
    }
    text[#text + 1] = k .. "\t" .. desc .. (group and " (group)" or "")
  end
  return { data = list, text = text }
end

function M.cmd_files()
  local list, text = {}, {}
  for _, f in ipairs(require("org.files").agenda_files()) do
    list[#list + 1] = {
      file = data.path(f.filename),
      title = data.nn(f:title()),
      category = data.nn(f:category()),
      headlines = #f.headlines,
    }
    text[#text + 1] = f.filename
  end
  return { data = list, text = text }
end

function M.cmd_tags()
  local counts, defined = {}, {}
  local tags = require("org.tags")
  local function define(defs)
    for _, d in ipairs(defs or {}) do
      if type(d) == "table" and d.name and not d.name:match("^[{}]") then
        defined[d.name] = true
      end
    end
  end
  local utils = require("org.utils")
  utils.try("cli info: tags of the options", function()
    define(tags.option_definitions())
  end)
  for _, f in ipairs(require("org.files").agenda_files()) do
    utils.try("cli info: tags of an agenda file", function()
      define(f:tag_definitions())
    end)
    for _, t in ipairs(f.settings.filetags or {}) do
      counts[t] = (counts[t] or 0) + 1
    end
    for _, hl in ipairs(f.headlines) do
      for _, t in ipairs(hl.tags) do
        counts[t] = (counts[t] or 0) + 1
      end
    end
  end
  local names = {}
  for k in pairs(counts) do
    names[#names + 1] = k
  end
  for k in pairs(defined) do
    if not counts[k] then
      names[#names + 1] = k
    end
  end
  table.sort(names)
  local list, text = {}, {}
  for _, n in ipairs(names) do
    list[#list + 1] = { name = n, count = counts[n] or 0, defined = defined[n] or false }
    text[#text + 1] = string.format("%s\t%d", n, counts[n] or 0)
  end
  return { data = list, text = text }
end

function M.cmd_keywords()
  local cfg = require("org.todo_keywords").global()
  local sequences, todo, done = {}, {}, {}
  for _, seq in ipairs(cfg.sequences) do
    local s = {}
    for _, kw in ipairs(seq) do
      s[#s + 1] = { name = kw.name, done = kw.done or false, key = data.nn(kw.key) }
      table.insert(kw.done and done or todo, kw.name)
    end
    sequences[#sequences + 1] = s
  end
  local o = require("org.config").opts
  local priority = {
    highest = tostring(o.priority_highest),
    lowest = tostring(o.priority_lowest),
    default = tostring(o.priority_default),
  }
  local text = {}
  for _, s in ipairs(sequences) do
    local parts = {}
    local bar = false
    for _, kw in ipairs(s) do
      if kw.done and not bar then
        parts[#parts + 1] = "|"
        bar = true
      end
      parts[#parts + 1] = kw.name
    end
    text[#text + 1] = table.concat(parts, " ")
  end
  text[#text + 1] = string.format("priorities: %s-%s (default %s)", priority.highest, priority.lowest, priority.default)
  return { data = { sequences = sequences, todo = todo, done = done, priority = priority }, text = text }
end

function M.cmd_schema(words)
  local name = #words > 0 and table.concat(words, " ") or nil
  local doc = schema.describe(name)
  if not doc then
    fail("unknown command " .. name, "unknown_command", { command = name })
  end
  return { data = doc, raw = vim.json.encode(doc) .. "\n" }
end

function M.cmd_version()
  local v = require("org.version").release
  return { data = { version = v }, text = { "org.nvim " .. v } }
end
