-- The faces of dates and planning (org-date, org-special-keyword,
-- org-sexp-date) org.nvim's parser highlighter draws, against those Emacs
-- Org 9.8.12 draws on every fixture (tests/helpers/faces.lua).
local F = require("tests.helpers.faces")
local P = require("tests.emacs_parity")

--- The input file of a fixture (its name with "-" for "/").
local function input_of(name)
  for _, dir in ipairs({ "examples", "tests/fixtures/emacs/fontify", "tests/fixtures/emacs/faces" }) do
    local prefix = dir:gsub("/", "-") .. "-"
    if name:sub(1, #prefix) == prefix then
      return P.root .. "/" .. dir .. "/" .. name:sub(#prefix + 1)
    end
  end
end

--- The end of the key of a property line (org-property-re: ":KEY:" then a
--- blank or the end of the line), or nil. Emacs draws the key in
--- org-special-keyword, a face this family shares with the keywords and
--- drawers part, which draws property keys: these lines are compared
--- below with the key left out (once the parts are merged the whole line
--- compares).
local function property_key_end(line)
  return line:match("^[ \t]*:%S+:()[ \t]") or line:match("^[ \t]*:%S+:()$")
end

local KNOWN = {
  ["examples-19-export.org"] = {
    -- The body of a "#+begin_src org" block: Emacs draws it natively, in
    -- an Org buffer where the escaped ",#+DATE:" isn't a keyword and its
    -- date is drawn; org.nvim draws src block bodies with the syntax of
    -- their language (no part of the parser highlighter).
    [382] = "native fontification of an org src block",
  },
  ["tests-fixtures-emacs-faces-date.org"] = {
    -- A date right after "[" (a link's description "[<2026-...>]"): the
    -- matcher of org-activate-dates then returns nil, which ends the
    -- search for dates up to the end of the region font-lock is drawing
    -- (here the rest of the file, the fixture fontifies it at once; a
    -- jit-lock chunk in a window). An Emacs bug not worth copying:
    -- org.nvim leaves out only that date.
    [95] = "dates after a date that follows [",
  },
}

local fixtures = F.fixtures()
for _, fx in ipairs(fixtures) do
  local lines = vim.fn.readfile(input_of(fx.name))
  local known = KNOWN[fx.name] or {}
  for l, line in ipairs(lines) do
    if property_key_end(line) then
      known[l] = known[l] or "a property line (compared below without its key)"
    end
  end
  KNOWN[fx.name] = known
end

--- Runs ("<count>:<code>") with special-keyword left out of bytes 1 to
--- `upto`.
local function strip_key(runs, upto)
  if not runs then
    return nil
  end
  local codes = {}
  for count, code in runs:gmatch("(%d+):([^,]+)") do
    for _ = 1, tonumber(count) do
      local c = code
      if #codes < upto then
        local names = {}
        for name in c:gmatch("[^+]+") do
          if name ~= "special-keyword" then
            names[#names + 1] = name
          end
        end
        c = #names > 0 and table.concat(names, "+") or "."
      end
      codes[#codes + 1] = c
    end
  end
  local out, cur, n, any = {}, nil, 0, false
  for _, c in ipairs(codes) do
    any = any or c ~= "."
    if c == cur then
      n = n + 1
    else
      if cur then
        out[#out + 1] = n .. ":" .. cur
      end
      cur, n = c, 1
    end
  end
  if cur then
    out[#out + 1] = n .. ":" .. cur
  end
  return any and table.concat(out, ",") or nil
end

describe("emacs faces: date", function()
  with_config({ ui = { highlighter = "parser", hide_emphasis_markers = true } })
  F.spec("date", KNOWN)

  it("property lines, the key left out", function()
    local diffs = {}
    for _, fx in ipairs(fixtures) do
      local lines = vim.fn.readfile(input_of(fx.name))
      local props = {}
      for l, line in ipairs(lines) do
        local e = property_key_end(line)
        if e then
          props[l] = e - 1
        end
      end
      if next(props) then
        local buf = org_buffer(lines, { 1, 0 })
        vim.wo.conceallevel = 2
        local got = F.nvim_lines(F.nvim_faces(buf), "date")
        local expected = {}
        for _, l in ipairs(P.lines(P.read(fx.expected))) do
          local n, r = l:match("^(%d+)\t(.*)$")
          if n then
            expected[tonumber(n)] = F.emacs_line(r, "date", false)
          end
        end
        for l, upto in pairs(props) do
          local want, have = strip_key(expected[l], upto), strip_key(got[l], upto)
          if (want or "") ~= (have or "") then
            diffs[#diffs + 1] =
              string.format("%s:%d: %s\n  emacs:    %s\n  org.nvim: %s", fx.name, l, lines[l], want or "-", have or "-")
          end
        end
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end
    table.sort(diffs)
    eq("", table.concat(diffs, "\n"))
  end)
end)
