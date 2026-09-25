-- Diary sexp emulation (org.agenda.sexp). Expected matches were produced by
-- Emacs 31 / Org 9.8.10 in batch: `(org-diary-sexp-entry SEXP ENTRY DATE)`
-- for every day of three windows (2026-08-20 +150 days, 2027-02-20 and
-- 2028-02-20 +14 days), ENTRY = "E %d%s" for anniversaries/cycles, else "E".
local sexp = require("org.agenda.sexp")
local date = require("org.date")

local SEXPS = {
  [==[(diary-float t 4 2)]==],
  [==[(diary-float t 1 -1)]==],
  [==[(diary-float 9 5 -1)]==],
  [==[(diary-float '(9 10) 0 1)]==],
  [==[(diary-float t 3 1 15)]==],
  [==[(diary-float t 5 -2 20)]==],
  [==[(diary-float 12 1 1 30)]==],
  [==[(diary-float t 0 3)]==],
  [==[(diary-anniversary 9 25 1990)]==],
  [==[(diary-anniversary 2 29 2000)]==],
  [==[(diary-anniversary 10 1)]==],
  [==[(org-anniversary 1990 9 25)]==],
  [==[(org-anniversary 2000 2 29)]==],
  [==[(diary-cyclic 10 9 1 2026)]==],
  [==[(org-cyclic 7 2026 9 3)]==],
  [==[(diary-block 9 20 2026 10 2 2026)]==],
  [==[(org-block 2026 9 20 2026 10 2)]==],
  [==[(diary-date 9 25 2026)]==],
  [==[(diary-date t 25 t)]==],
  [==[(diary-date '(9 10) 1 t)]==],
  [==[(org-date 2026 t 1)]==],
  [==[(org-date t 9 '(24 26))]==],
  [==[(org-class 2026 9 1 2026 12 20 5)]==],
  [==[(org-class 2026 9 1 2026 12 20 5 39 41)]==],
  [==[(and (diary-float t 5 -1) (not (diary-date 10 30 2026)))]==],
  [==[(or (diary-date 9 26 2026) (diary-date 10 3 2026))]==],
}

-- "SEXP|YYYY-MM-DD|RESULT" lines from Emacs
local EMACS = [==[
(diary-float t 4 2)|2026-09-10|E
(diary-float t 4 2)|2026-10-08|E
(diary-float t 4 2)|2026-11-12|E
(diary-float t 4 2)|2026-12-10|E
(diary-float t 4 2)|2027-01-14|E
(diary-float t 1 -1)|2026-08-31|E
(diary-float t 1 -1)|2026-09-28|E
(diary-float t 1 -1)|2026-10-26|E
(diary-float t 1 -1)|2026-11-30|E
(diary-float t 1 -1)|2026-12-28|E
(diary-float 9 5 -1)|2026-09-25|E
(diary-float '(9 10) 0 1)|2026-09-06|E
(diary-float '(9 10) 0 1)|2026-10-04|E
(diary-float t 3 1 15)|2026-09-16|E
(diary-float t 3 1 15)|2026-10-21|E
(diary-float t 3 1 15)|2026-11-18|E
(diary-float t 3 1 15)|2026-12-16|E
(diary-float t 5 -2 20)|2026-09-11|E
(diary-float t 5 -2 20)|2026-10-09|E
(diary-float t 5 -2 20)|2026-11-13|E
(diary-float t 5 -2 20)|2026-12-11|E
(diary-float t 5 -2 20)|2027-01-08|E
(diary-float 12 1 1 30)|2027-01-04|E
(diary-float t 0 3)|2026-09-20|E
(diary-float t 0 3)|2026-10-18|E
(diary-float t 0 3)|2026-11-15|E
(diary-float t 0 3)|2026-12-20|E
(diary-anniversary 9 25 1990)|2026-09-25|E 36th
(diary-anniversary 10 1)|2026-10-01|E 100th
(org-anniversary 1990 9 25)|2026-09-25|E 36th
(diary-cyclic 10 9 1 2026)|2026-09-01|E 0th
(diary-cyclic 10 9 1 2026)|2026-09-11|E 1st
(diary-cyclic 10 9 1 2026)|2026-09-21|E 2nd
(diary-cyclic 10 9 1 2026)|2026-10-01|E 3rd
(diary-cyclic 10 9 1 2026)|2026-10-11|E 4th
(diary-cyclic 10 9 1 2026)|2026-10-21|E 5th
(diary-cyclic 10 9 1 2026)|2026-10-31|E 6th
(diary-cyclic 10 9 1 2026)|2026-11-10|E 7th
(diary-cyclic 10 9 1 2026)|2026-11-20|E 8th
(diary-cyclic 10 9 1 2026)|2026-11-30|E 9th
(diary-cyclic 10 9 1 2026)|2026-12-10|E 10th
(diary-cyclic 10 9 1 2026)|2026-12-20|E 11th
(diary-cyclic 10 9 1 2026)|2026-12-30|E 12th
(diary-cyclic 10 9 1 2026)|2027-01-09|E 13th
(org-cyclic 7 2026 9 3)|2026-09-03|E 0th
(org-cyclic 7 2026 9 3)|2026-09-10|E 1st
(org-cyclic 7 2026 9 3)|2026-09-17|E 2nd
(org-cyclic 7 2026 9 3)|2026-09-24|E 3rd
(org-cyclic 7 2026 9 3)|2026-10-01|E 4th
(org-cyclic 7 2026 9 3)|2026-10-08|E 5th
(org-cyclic 7 2026 9 3)|2026-10-15|E 6th
(org-cyclic 7 2026 9 3)|2026-10-22|E 7th
(org-cyclic 7 2026 9 3)|2026-10-29|E 8th
(org-cyclic 7 2026 9 3)|2026-11-05|E 9th
(org-cyclic 7 2026 9 3)|2026-11-12|E 10th
(org-cyclic 7 2026 9 3)|2026-11-19|E 11th
(org-cyclic 7 2026 9 3)|2026-11-26|E 12th
(org-cyclic 7 2026 9 3)|2026-12-03|E 13th
(org-cyclic 7 2026 9 3)|2026-12-10|E 14th
(org-cyclic 7 2026 9 3)|2026-12-17|E 15th
(org-cyclic 7 2026 9 3)|2026-12-24|E 16th
(org-cyclic 7 2026 9 3)|2026-12-31|E 17th
(org-cyclic 7 2026 9 3)|2027-01-07|E 18th
(org-cyclic 7 2026 9 3)|2027-01-14|E 19th
(diary-block 9 20 2026 10 2 2026)|2026-09-20|E
(diary-block 9 20 2026 10 2 2026)|2026-09-21|E
(diary-block 9 20 2026 10 2 2026)|2026-09-22|E
(diary-block 9 20 2026 10 2 2026)|2026-09-23|E
(diary-block 9 20 2026 10 2 2026)|2026-09-24|E
(diary-block 9 20 2026 10 2 2026)|2026-09-25|E
(diary-block 9 20 2026 10 2 2026)|2026-09-26|E
(diary-block 9 20 2026 10 2 2026)|2026-09-27|E
(diary-block 9 20 2026 10 2 2026)|2026-09-28|E
(diary-block 9 20 2026 10 2 2026)|2026-09-29|E
(diary-block 9 20 2026 10 2 2026)|2026-09-30|E
(diary-block 9 20 2026 10 2 2026)|2026-10-01|E
(diary-block 9 20 2026 10 2 2026)|2026-10-02|E
(org-block 2026 9 20 2026 10 2)|2026-09-20|E
(org-block 2026 9 20 2026 10 2)|2026-09-21|E
(org-block 2026 9 20 2026 10 2)|2026-09-22|E
(org-block 2026 9 20 2026 10 2)|2026-09-23|E
(org-block 2026 9 20 2026 10 2)|2026-09-24|E
(org-block 2026 9 20 2026 10 2)|2026-09-25|E
(org-block 2026 9 20 2026 10 2)|2026-09-26|E
(org-block 2026 9 20 2026 10 2)|2026-09-27|E
(org-block 2026 9 20 2026 10 2)|2026-09-28|E
(org-block 2026 9 20 2026 10 2)|2026-09-29|E
(org-block 2026 9 20 2026 10 2)|2026-09-30|E
(org-block 2026 9 20 2026 10 2)|2026-10-01|E
(org-block 2026 9 20 2026 10 2)|2026-10-02|E
(diary-date 9 25 2026)|2026-09-25|E
(diary-date t 25 t)|2026-08-25|E
(diary-date t 25 t)|2026-09-25|E
(diary-date t 25 t)|2026-10-25|E
(diary-date t 25 t)|2026-11-25|E
(diary-date t 25 t)|2026-12-25|E
(diary-date '(9 10) 1 t)|2026-09-01|E
(diary-date '(9 10) 1 t)|2026-10-01|E
(org-date 2026 t 1)|2026-09-01|E
(org-date 2026 t 1)|2026-10-01|E
(org-date 2026 t 1)|2026-11-01|E
(org-date 2026 t 1)|2026-12-01|E
(org-date t 9 '(24 26))|2026-09-24|E
(org-date t 9 '(24 26))|2026-09-26|E
(org-class 2026 9 1 2026 12 20 5)|2026-09-04|E
(org-class 2026 9 1 2026 12 20 5)|2026-09-11|E
(org-class 2026 9 1 2026 12 20 5)|2026-09-18|E
(org-class 2026 9 1 2026 12 20 5)|2026-09-25|E
(org-class 2026 9 1 2026 12 20 5)|2026-10-02|E
(org-class 2026 9 1 2026 12 20 5)|2026-10-09|E
(org-class 2026 9 1 2026 12 20 5)|2026-10-16|E
(org-class 2026 9 1 2026 12 20 5)|2026-10-23|E
(org-class 2026 9 1 2026 12 20 5)|2026-10-30|E
(org-class 2026 9 1 2026 12 20 5)|2026-11-06|E
(org-class 2026 9 1 2026 12 20 5)|2026-11-13|E
(org-class 2026 9 1 2026 12 20 5)|2026-11-20|E
(org-class 2026 9 1 2026 12 20 5)|2026-11-27|E
(org-class 2026 9 1 2026 12 20 5)|2026-12-04|E
(org-class 2026 9 1 2026 12 20 5)|2026-12-11|E
(org-class 2026 9 1 2026 12 20 5)|2026-12-18|E
(org-class 2026 9 1 2026 12 20 5 39 41)|2026-09-04|E
(org-class 2026 9 1 2026 12 20 5 39 41)|2026-09-11|E
(org-class 2026 9 1 2026 12 20 5 39 41)|2026-09-18|E
(org-class 2026 9 1 2026 12 20 5 39 41)|2026-10-02|E
(org-class 2026 9 1 2026 12 20 5 39 41)|2026-10-16|E
(org-class 2026 9 1 2026 12 20 5 39 41)|2026-10-23|E
(org-class 2026 9 1 2026 12 20 5 39 41)|2026-10-30|E
(org-class 2026 9 1 2026 12 20 5 39 41)|2026-11-06|E
(org-class 2026 9 1 2026 12 20 5 39 41)|2026-11-13|E
(org-class 2026 9 1 2026 12 20 5 39 41)|2026-11-20|E
(org-class 2026 9 1 2026 12 20 5 39 41)|2026-11-27|E
(org-class 2026 9 1 2026 12 20 5 39 41)|2026-12-04|E
(org-class 2026 9 1 2026 12 20 5 39 41)|2026-12-11|E
(org-class 2026 9 1 2026 12 20 5 39 41)|2026-12-18|E
(and (diary-float t 5 -1) (not (diary-date 10 30 2026)))|2026-08-28|E
(and (diary-float t 5 -1) (not (diary-date 10 30 2026)))|2026-09-25|E
(and (diary-float t 5 -1) (not (diary-date 10 30 2026)))|2026-11-27|E
(and (diary-float t 5 -1) (not (diary-date 10 30 2026)))|2026-12-25|E
(or (diary-date 9 26 2026) (diary-date 10 3 2026))|2026-09-26|E
(or (diary-date 9 26 2026) (diary-date 10 3 2026))|2026-10-03|E
(diary-float t 1 -1)|2027-02-22|E
(diary-float t 0 3)|2027-02-21|E
(diary-anniversary 2 29 2000)|2027-03-01|E 27th
(org-anniversary 2000 2 29)|2027-03-01|E 27th
(diary-cyclic 10 9 1 2026)|2027-02-28|E 18th
(org-cyclic 7 2026 9 3)|2027-02-25|E 25th
(org-cyclic 7 2026 9 3)|2027-03-04|E 26th
(diary-date t 25 t)|2027-02-25|E
(and (diary-float t 5 -1) (not (diary-date 10 30 2026)))|2027-02-26|E
(diary-float t 1 -1)|2028-02-28|E
(diary-float t 0 3)|2028-02-20|E
(diary-anniversary 2 29 2000)|2028-02-29|E 28th
(org-anniversary 2000 2 29)|2028-02-29|E 28th
(diary-cyclic 10 9 1 2026)|2028-02-23|E 54th
(diary-cyclic 10 9 1 2026)|2028-03-04|E 55th
(org-cyclic 7 2026 9 3)|2028-02-24|E 77th
(org-cyclic 7 2026 9 3)|2028-03-02|E 78th
(diary-date t 25 t)|2028-02-25|E
(and (diary-float t 5 -1) (not (diary-date 10 30 2026)))|2028-02-25|E
]==]

local WINDOWS = { { 2026, 8, 20, 150 }, { 2027, 2, 20, 14 }, { 2028, 2, 20, 14 } }

describe("diary sexps", function()
  it("match the same days as Emacs, with the same entry text", function()
    local got = {}
    for _, w in ipairs(WINDOWS) do
      local start = date.days_from_civil(w[1], w[2], w[3])
      for _, s in ipairs(SEXPS) do
        local entry = (s:find("anniv") or s:find("cyclic")) and "E %d%s" or "E"
        for i = 0, w[4] - 1 do
          local r, err = sexp.eval(s, start + i, entry)
          ok(r ~= nil, "error in " .. s .. ": " .. tostring(err))
          if r then
            local y, m, d = date.civil_from_days(start + i)
            got[#got + 1] = string.format("%s|%04d-%02d-%02d|%s", s, y, m, d, r == true and "" or r)
          end
        end
      end
    end
    eq(vim.split(vim.trim(EMACS), "\n"), got)
  end)

  it("returns true for a match with empty entry text", function()
    local d = date.days_from_civil(2026, 9, 25)
    eq(true, sexp.eval("(diary-date 9 25 2026)", d))
    eq(false, sexp.eval("(diary-date 9 26 2026)", d))
    eq(true, sexp.eval("(org-class 2026 9 1 2026 12 20 5)", d))
  end)

  it("formats %d and %s like Emacs", function()
    local d = date.days_from_civil(2026, 9, 25)
    eq("Joe is 36 years old", sexp.eval("(org-anniversary 1990 9 25)", d, "Joe is %d years old"))
    eq("36th birthday, 100%", sexp.eval("(org-anniversary 1990 9 25)", d, "%d%s birthday, 100%%"))
    eq("plain", sexp.eval("(org-anniversary 1990 9 25)", d, "plain"))
    eq(
      { "st", "nd", "rd", "th", "th", "th", "th", "st", "th" },
      vim.tbl_map(sexp.ordinal_suffix, { 1, 2, 3, 4, 11, 12, 13, 21, 0 })
    )
  end)

  it("reports errors instead of evaluating unknown code", function()
    local d = date.days_from_civil(2026, 9, 25)
    local r, err = sexp.eval('(shell-command "rm -rf /")', d)
    eq(nil, r)
    ok(err:find("unsupported function"), err)
    r, err = sexp.eval("(diary-cyclic 0 9 1 2026)", d)
    eq(nil, r)
    ok(err:find("positive"), err)
    r, err = sexp.eval("(diary-date 9 25", d)
    eq(nil, r)
    ok(err:find("unbalanced"), err)
    r, err = sexp.eval("(diary-date 9 25 some-var)", d)
    eq(nil, r)
    ok(err:find("void%-variable"), err)
  end)

  it("parses lists, quotes, strings and (list ...)", function()
    local node = sexp.parse([[(diary-date (list 9 10) '(1 25) t "x")]])
    eq("diary-date", node.list[1].sym)
    eq("x", node.list[5])
    local d = date.days_from_civil(2026, 10, 25)
    eq(true, sexp.eval("(diary-date (list 9 10) '(1 25) t)", d))
    eq(true, sexp.eval("(org-date t '(9 10) 25)", d))
  end)

  it("finds <%%(...)> timestamps and %%(...) lines", function()
    local line = "* Meeting <%%(diary-float t 4 2)> and <%%(org-anniversary 1990 9 25) extra>"
    local found = sexp.find_all(line)
    eq(2, #found)
    eq("(diary-float t 4 2)", found[1].sexp)
    eq("<%%(diary-float t 4 2)>", line:sub(found[1].start_col, found[1].end_col))
    eq("(org-anniversary 1990 9 25)", found[2].sexp)
    eq(" extra", found[2].text_after)
    eq(
      { sexp = "(org-anniversary 1990 9 25)", text = "Birthday of Joe (%d)" },
      sexp.line_entry("%%(org-anniversary 1990 9 25) Birthday of Joe (%d)  ")
    )
    eq({ sexp = '(diary-date 9 25 t "a)b")', text = "" }, sexp.line_entry('&%%(diary-date 9 25 t "a)b")'))
    eq(nil, sexp.line_entry("  %%(diary-date 9 25 t) indented"))
    eq(nil, sexp.line_entry("text %%(diary-date 9 25 t)"))
  end)
end)
