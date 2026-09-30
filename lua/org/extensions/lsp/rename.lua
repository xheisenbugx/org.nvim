---@mod org.extensions.lsp.rename textDocument/rename and prepareRename
---
--- Renames a headline title, a CUSTOM_ID, an ID, a `<<target>>`, a
--- `<<<radio target>>>`, a `#+NAME:` or a footnote label, and rewrites every
--- link that points at it across the workspace files: `[[*Title]]`,
--- `[[Title]]`, `[[#custom-id]]`, `[[file:x.org::*Title]]`, `id:...`.
--- Descriptions equal to the old name follow (`rename.update_descriptions`).

local links = require("org.links")
local util = require("org.extensions.lsp.util")
local targets = require("org.extensions.lsp.targets")

local M = {}

local RENAMABLE = {
  heading = true,
  custom_id = true,
  id = true,
  target = true,
  radio = true,
  name = true,
  footnote = true,
}

-- the link forms that spell each subject's name
local FORMS = {
  heading = { heading = true, fuzzy = true },
  custom_id = { custom_id = true },
  id = { id = true },
  target = { fuzzy = true },
  radio = { fuzzy = true },
  name = { fuzzy = true },
}

--- Subject to rename at a position and the range under the cursor.
---@return org.lsp.Subject|nil, table|nil range
function M.subject(doc, lnum, col)
  local subject, link = targets.subject_at(doc, lnum, col)
  if not subject or not RENAMABLE[subject.kind] then
    return nil
  end
  if link then
    return subject, util.range(lnum, link.start_col, link.end_col)
  end
  local l = subject.decl_lnum or subject.lnum
  if subject.path == doc.path and l == lnum then
    return subject, util.range(l, subject.s, subject.e)
  end
  local line = doc.lines[lnum]
  return subject, util.range(lnum, 1, #line)
end

--- textDocument/prepareRename
function M.prepare(doc, lnum, col)
  local subject, range = M.subject(doc, lnum, col)
  if not subject then
    return nil
  end
  return { range = range, placeholder = subject.name }
end

local function validate(subject, new)
  if new == "" then
    return "The new name is empty"
  end
  if new:find("\n", 1, true) then
    return "The new name cannot span lines"
  end
  local k = subject.kind
  if (k == "custom_id" or k == "id" or k == "footnote") and new:find("%s") then
    return "The new name cannot contain blanks"
  end
  if k == "footnote" and new:find("[%]:]") then
    return "A footnote label cannot contain ']' or ':'"
  end
  if (k == "target" or k == "radio") and new:find("[<>]") then
    return "A target cannot contain '<' or '>'"
  end
  if k == "name" and new:match("^%s") then
    return "The name cannot start with a blank"
  end
end

--- The name as a search option spells it.
local function spelled(subject, new)
  if subject.kind == "heading" then
    return links.normalize_string(new)
  end
  return new
end

--- Something else in the file the new name would make links resolve to.
local function conflict(subject, new)
  local file = require("org.files").get(subject.path)
  if not file then
    return nil
  end
  local idx = targets.index(file)
  local k = subject.kind
  if k == "custom_id" then
    local hl = idx.custom_ids[new:lower()]
    if hl and hl.line ~= subject.lnum then
      return string.format("CUSTOM_ID %s is already used on line %d", new, hl.line)
    end
  elseif k == "footnote" then
    if #targets.footnote_uses(file.lines, new) > 0 then
      return string.format("Footnote %s already exists", new)
    end
  elseif k ~= "id" then
    local key = targets.key(spelled(subject, new))
    local t, n = idx.targets[key], idx.names[key]
    if t and t.lnum ~= subject.lnum then
      return string.format("Target <<%s>> on line %d already has that name", t.text, t.lnum)
    end
    if n and n.lnum ~= subject.lnum then
      return string.format("#+NAME: %s on line %d already has that name", n.text, n.lnum)
    end
    local hl = idx.headings[key]
    if hl and hl.line ~= subject.lnum and k ~= "heading" then
      return string.format("Headline %q on line %d already has that name", hl.title, hl.line)
    end
    if hl and hl.line ~= subject.lnum and k == "heading" then
      return "ambiguous-heading", hl
    end
  end
end

--- Where the link's text sits in its line: 1-based start column and the
--- raw text (escaped for bracket links).
local function link_text(link)
  if link.raw:sub(1, 2) == "[[" then
    return link.start_col + 2, link.raw_target or link.raw:sub(3, -3), true
  elseif link.angle then
    return link.start_col + 1, link.target, false
  end
  return link.start_col, link.raw, false
end

--- Edits that make one reference spell `new`.
local function reference_edits(ref, subject, new, old_display)
  local link = ref.link
  local out = {}
  local col, text, bracket = link_text(link)
  local ps, pe, repl
  if ref.form == "id" then
    ps = text:find(":", 1, true) + 1
    local sep = text:find("::", ps, true)
    pe = (sep or #text + 1) - 1
    repl = new
  else
    local off = 1
    if not ref.split.internal then
      local sep = text:find("::", 1, true)
      if not sep then
        return out
      end
      off = sep + 2
    end
    local lead = text:sub(off):match("^%s*[#*]?") or ""
    ps, pe = off + #lead, #text
    repl = spelled(subject, new)
  end
  if bracket then
    repl = links.escape(repl)
  end
  out[#out + 1] = { lnum = ref.lnum, s = col + ps - 1, e = col + pe - 1, text = repl }
  local o = util.opts().rename or {}
  if link.desc and o.update_descriptions ~= false and old_display then
    if targets.key(link.desc) == targets.key(old_display) then
      out[#out + 1] = {
        lnum = ref.lnum,
        s = link.desc_start,
        e = link.desc_start + #link.desc - 1,
        text = subject.kind == "heading" and links.normalize_string(new) or new,
      }
    end
  end
  return out
end

--- textDocument/rename: a WorkspaceEdit, or nil and an error message.
---@return table|nil edit, string|nil err
function M.rename(doc, lnum, col, new)
  local subject = M.subject(doc, lnum, col)
  if not subject then
    return nil, "Nothing to rename here"
  end
  new = vim.trim(new or "")
  local err = validate(subject, new)
  if err then
    return nil, err
  end
  if new == subject.name then
    return { changes = {} }
  end
  local by_path = {}
  local function add(path, e)
    by_path[path] = by_path[path] or {}
    table.insert(by_path[path], e)
  end
  local refs = targets.references(subject)
  local c, other = conflict(subject, new)
  local forms = FORMS[subject.kind]
  if c == "ambiguous-heading" then
    for _, r in ipairs(refs) do
      if r.form == "heading" or r.form == "fuzzy" then
        return nil,
          string.format(
            "Headline %q on line %d already has that title; links to it would be ambiguous",
            other.title,
            other.line
          )
      end
    end
  elseif c then
    return nil, c
  end

  -- the declaration
  if subject.kind == "footnote" then
    local home = util.doc_from_path(subject.path)
    for _, u in ipairs(targets.footnote_uses(home.lines, subject.name)) do
      add(subject.path, { lnum = u.lnum, s = u.ls, e = u.le, text = new })
    end
  else
    add(subject.path, { lnum = subject.decl_lnum or subject.lnum, s = subject.s, e = subject.e, text = new })
  end

  local old_display = subject.name
  if subject.kind == "heading" and subject.headline then
    old_display = subject.headline:plain_title()
  end
  for _, r in ipairs(refs) do
    if r.form == "radio" then
      add(r.doc.path, { lnum = r.lnum, s = r.s, e = r.e, text = new })
    elseif r.link and forms and forms[r.form] then
      for _, e in ipairs(reference_edits(r, subject, new, old_display)) do
        add(r.doc.path, e)
      end
    end
  end

  local changes = {}
  for path, edits in pairs(by_path) do
    table.sort(edits, function(a, b)
      return a.lnum < b.lnum or (a.lnum == b.lnum and a.s < b.s)
    end)
    local list, last = {}, nil
    for _, e in ipairs(edits) do
      -- drop an edit overlapping the previous one (a link inside a title)
      if not (last and last.lnum == e.lnum and e.s <= last.e) then
        list[#list + 1] = { range = util.range(e.lnum, e.s, e.e), newText = e.text }
        last = e
      end
    end
    changes[util.uri(path)] = list
  end
  return { changes = changes }
end

return M
