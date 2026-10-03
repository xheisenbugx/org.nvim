---@mod org.export.ox.code Source code: line numbers, coderefs, formatting
---
--- Part of org.export.ox, which loads it: the functions are fields of
--- that module.

local element = require("org.export.element")
local M = require("org.export.ox")

---------------------------------------------------------------------------
-- Source code
---------------------------------------------------------------------------

function M.get_loc(el, info)
  local nl = el.number_lines
  if not nl then
    return nil
  end
  if nl[1] == "new" then
    return nl[2]
  end
  local loc = 0
  return element.map(info.parse_tree, { ["src-block"] = true, ["example-block"] = true }, function(x)
    if x == el then
      return loc + nl[2]
    end
    local ln = x.number_lines
    if ln then
      local _, count = (x.value or ""):gsub("\n", "")
      if not (x.value or ""):match("\n$") and (x.value or "") ~= "" then
        count = count + 1
      end
      if ln[1] == "new" then
        loc = ln[2] + count
      else
        loc = loc + ln[2] + count
      end
    end
  end, { ignore = info.ignore, first_match = true })
end

--- Code without coderefs and indentation, plus { [line] = label }
--- (org-export-unravel-code).
function M.unravel_code(el)
  local value = el.value or ""
  local lines = vim.split((value:gsub("\n$", "")), "\n", { plain = true })
  if not el.preserve_indent then
    lines = element.remove_indentation(lines)
  end
  local fmt = el.label_fmt or require("org.config").opts.coderef_label_format or "(ref:%s)"
  local s, e = fmt:find("%s", 1, true)
  local pre, post = fmt:sub(1, s - 1), fmt:sub(e + 1)
  local pat = "()[ \t]*" .. vim.pesc(pre) .. "([%-%w_][%-%w_ ]*)" .. vim.pesc(post) .. "()[ \t]*$"
  local refs = {}
  for i, l in ipairs(lines) do
    local a, label, b = l:match(pat)
    if a then
      refs[i] = label
      lines[i] = l:sub(1, a - 1) .. l:sub(b)
    end
  end
  return table.concat(lines, "\n"), refs
end

--- Apply fun(line, number|nil, ref|nil) to each line (org-export-format-code).
function M.format_code(code, fun, num_lines, refs)
  local locs = vim.split(code, "\n", { plain = true })
  local out = {}
  for i, loc in ipairs(locs) do
    out[i] = fun(loc, num_lines and (num_lines + i) or nil, refs and refs[i] or nil)
  end
  return table.concat(out, "\n") .. "\n"
end

function M.format_code_default(el, info)
  local code, refs = M.unravel_code(el)
  local code_lines = vim.split(code, "\n", { plain = true })
  if #code_lines == 0 then
    return ""
  end
  local use_refs = el.retain_labels and refs or nil
  local num_start = M.get_loc(el, info)
  local num_fmt = num_start and ("%" .. #tostring(#code_lines + num_start) .. "d  ") or nil
  local max_width = 0
  for _, l in ipairs(code_lines) do
    max_width = math.max(max_width, #l)
  end
  if num_start then
    max_width = max_width + #string.format(num_fmt, num_start)
  end
  return M.format_code(code, function(loc, num, ref)
    local number_str = num_fmt and string.format(num_fmt, num) or ""
    local r = number_str .. loc
    if ref then
      r = r .. string.rep(" ", 6 + max_width - (#loc + #number_str)) .. "(" .. ref .. ")"
    end
    return r
  end, num_start, use_refs)
end
