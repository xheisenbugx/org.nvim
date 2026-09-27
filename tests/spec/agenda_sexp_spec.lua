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
    -- org-class returns `entry' itself, a string even when empty
    eq("", sexp.eval("(org-class 2026 9 1 2026 12 20 5)", d))
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

-- Pure Elisp in diary sexps (special forms, predicates, arithmetic, lists
-- and calendar.el helpers). Expected results from Emacs 31 / Org 9.8.10 in
-- batch: `(org-diary-sexp-entry SEXP "ENTRY" DATE)` for 2026-09-20 +60 days;
-- a list of strings is shown joined with "; ", one agenda entry each.
describe("diary sexps with Elisp forms", function()
  local ELISP = {
    [==[(when (memq(calendar-day-of-week date) '(1 2 4 5)) "18:00")]==],
    [==[(when (memq (calendar-day-of-week date) '(1 2 4 5)) "18:00 Gym")]==],
    [==[(if (= 0 (% (car (calendar-iso-from-absolute (calendar-absolute-from-gregorian date))) 2)) "Even week; Second")]==],
    [==[(let ((d (calendar-extract-day date))) (and (<= d 7) (= (calendar-day-of-week date) 1)))]==],
    [==[(cond ((= (calendar-extract-month date) 10) "October") ((> (calendar-extract-day date) 25) "late") (t nil))]==],
    [==[(unless (memq (calendar-day-of-week date) '(0 6)) "Weekday")]==],
    [==[(let* ((m (calendar-extract-month date)) (d (calendar-extract-day date))) (and (= m 10) (= d (calendar-last-day-of-month m (calendar-extract-year date)))))]==],
    [==[(= (calendar-day-number date) 280)]==],
    [==[(equal date (calendar-nth-named-day 2 3 10 2026))]==],
    [==[(equal date (calendar-nth-named-day -1 5 10 2026))]==],
    [==[(and (= 0 (mod (- (calendar-absolute-from-gregorian date) (calendar-absolute-from-gregorian '(9 1 2026))) 14)) (format "Payday %d" (calendar-extract-day date)))]==],
    [==[(equal date (calendar-gregorian-from-absolute (1+ (calendar-absolute-from-gregorian '(10 3 2026)))))]==],
    [==[(and (diary-float t 4 -1) (concat "Last " "Thu"))]==],
    [==[(or (diary-date 10 5 t) (diary-anniversary 10 7 2000))]==],
    [==[(member (calendar-extract-day date) (list 1 15))]==],
    [==[(progn (/ 7 2) (and (= (/ 7 2) 3) (= (/ -7 2) -3) (= (% -7 2) -1) (= (mod -7 2) 1) (= (calendar-day-of-week date) 3)))]==],
    [==[(nth 2 (list nil nil (calendar-leap-year-p 2028) nil))]==],
    [==[(when (eq (calendar-day-of-week date) 6) (number-to-string (calendar-extract-day date)))]==],
    [==[(let (x) (unless x (and (>= (calendar-extract-day date) 30) (list "a" "b"))))]==],
    [==[(if (zerop (% (calendar-extract-day date) 10)) "tens" "")]==],
  }
  local EXPECTED = [==[
(when (memq(calendar-day-of-week date) '(1 2 4 5)) "18:00")|2026-09-21|18:00
(when (memq(calendar-day-of-week date) '(1 2 4 5)) "18:00")|2026-09-22|18:00
(when (memq(calendar-day-of-week date) '(1 2 4 5)) "18:00")|2026-09-24|18:00
(when (memq(calendar-day-of-week date) '(1 2 4 5)) "18:00")|2026-09-25|18:00
(when (memq(calendar-day-of-week date) '(1 2 4 5)) "18:00")|2026-09-28|18:00
(when (memq(calendar-day-of-week date) '(1 2 4 5)) "18:00")|2026-09-29|18:00
(when (memq(calendar-day-of-week date) '(1 2 4 5)) "18:00")|2026-10-01|18:00
(when (memq(calendar-day-of-week date) '(1 2 4 5)) "18:00")|2026-10-02|18:00
(when (memq(calendar-day-of-week date) '(1 2 4 5)) "18:00")|2026-10-05|18:00
(when (memq(calendar-day-of-week date) '(1 2 4 5)) "18:00")|2026-10-06|18:00
(when (memq(calendar-day-of-week date) '(1 2 4 5)) "18:00")|2026-10-08|18:00
(when (memq(calendar-day-of-week date) '(1 2 4 5)) "18:00")|2026-10-09|18:00
(when (memq(calendar-day-of-week date) '(1 2 4 5)) "18:00")|2026-10-12|18:00
(when (memq(calendar-day-of-week date) '(1 2 4 5)) "18:00")|2026-10-13|18:00
(when (memq(calendar-day-of-week date) '(1 2 4 5)) "18:00")|2026-10-15|18:00
(when (memq(calendar-day-of-week date) '(1 2 4 5)) "18:00")|2026-10-16|18:00
(when (memq(calendar-day-of-week date) '(1 2 4 5)) "18:00")|2026-10-19|18:00
(when (memq(calendar-day-of-week date) '(1 2 4 5)) "18:00")|2026-10-20|18:00
(when (memq(calendar-day-of-week date) '(1 2 4 5)) "18:00")|2026-10-22|18:00
(when (memq(calendar-day-of-week date) '(1 2 4 5)) "18:00")|2026-10-23|18:00
(when (memq(calendar-day-of-week date) '(1 2 4 5)) "18:00")|2026-10-26|18:00
(when (memq(calendar-day-of-week date) '(1 2 4 5)) "18:00")|2026-10-27|18:00
(when (memq(calendar-day-of-week date) '(1 2 4 5)) "18:00")|2026-10-29|18:00
(when (memq(calendar-day-of-week date) '(1 2 4 5)) "18:00")|2026-10-30|18:00
(when (memq(calendar-day-of-week date) '(1 2 4 5)) "18:00")|2026-11-02|18:00
(when (memq(calendar-day-of-week date) '(1 2 4 5)) "18:00")|2026-11-03|18:00
(when (memq(calendar-day-of-week date) '(1 2 4 5)) "18:00")|2026-11-05|18:00
(when (memq(calendar-day-of-week date) '(1 2 4 5)) "18:00")|2026-11-06|18:00
(when (memq(calendar-day-of-week date) '(1 2 4 5)) "18:00")|2026-11-09|18:00
(when (memq(calendar-day-of-week date) '(1 2 4 5)) "18:00")|2026-11-10|18:00
(when (memq(calendar-day-of-week date) '(1 2 4 5)) "18:00")|2026-11-12|18:00
(when (memq(calendar-day-of-week date) '(1 2 4 5)) "18:00")|2026-11-13|18:00
(when (memq(calendar-day-of-week date) '(1 2 4 5)) "18:00")|2026-11-16|18:00
(when (memq(calendar-day-of-week date) '(1 2 4 5)) "18:00")|2026-11-17|18:00
(when (memq (calendar-day-of-week date) '(1 2 4 5)) "18:00 Gym")|2026-09-21|18:00 Gym
(when (memq (calendar-day-of-week date) '(1 2 4 5)) "18:00 Gym")|2026-09-22|18:00 Gym
(when (memq (calendar-day-of-week date) '(1 2 4 5)) "18:00 Gym")|2026-09-24|18:00 Gym
(when (memq (calendar-day-of-week date) '(1 2 4 5)) "18:00 Gym")|2026-09-25|18:00 Gym
(when (memq (calendar-day-of-week date) '(1 2 4 5)) "18:00 Gym")|2026-09-28|18:00 Gym
(when (memq (calendar-day-of-week date) '(1 2 4 5)) "18:00 Gym")|2026-09-29|18:00 Gym
(when (memq (calendar-day-of-week date) '(1 2 4 5)) "18:00 Gym")|2026-10-01|18:00 Gym
(when (memq (calendar-day-of-week date) '(1 2 4 5)) "18:00 Gym")|2026-10-02|18:00 Gym
(when (memq (calendar-day-of-week date) '(1 2 4 5)) "18:00 Gym")|2026-10-05|18:00 Gym
(when (memq (calendar-day-of-week date) '(1 2 4 5)) "18:00 Gym")|2026-10-06|18:00 Gym
(when (memq (calendar-day-of-week date) '(1 2 4 5)) "18:00 Gym")|2026-10-08|18:00 Gym
(when (memq (calendar-day-of-week date) '(1 2 4 5)) "18:00 Gym")|2026-10-09|18:00 Gym
(when (memq (calendar-day-of-week date) '(1 2 4 5)) "18:00 Gym")|2026-10-12|18:00 Gym
(when (memq (calendar-day-of-week date) '(1 2 4 5)) "18:00 Gym")|2026-10-13|18:00 Gym
(when (memq (calendar-day-of-week date) '(1 2 4 5)) "18:00 Gym")|2026-10-15|18:00 Gym
(when (memq (calendar-day-of-week date) '(1 2 4 5)) "18:00 Gym")|2026-10-16|18:00 Gym
(when (memq (calendar-day-of-week date) '(1 2 4 5)) "18:00 Gym")|2026-10-19|18:00 Gym
(when (memq (calendar-day-of-week date) '(1 2 4 5)) "18:00 Gym")|2026-10-20|18:00 Gym
(when (memq (calendar-day-of-week date) '(1 2 4 5)) "18:00 Gym")|2026-10-22|18:00 Gym
(when (memq (calendar-day-of-week date) '(1 2 4 5)) "18:00 Gym")|2026-10-23|18:00 Gym
(when (memq (calendar-day-of-week date) '(1 2 4 5)) "18:00 Gym")|2026-10-26|18:00 Gym
(when (memq (calendar-day-of-week date) '(1 2 4 5)) "18:00 Gym")|2026-10-27|18:00 Gym
(when (memq (calendar-day-of-week date) '(1 2 4 5)) "18:00 Gym")|2026-10-29|18:00 Gym
(when (memq (calendar-day-of-week date) '(1 2 4 5)) "18:00 Gym")|2026-10-30|18:00 Gym
(when (memq (calendar-day-of-week date) '(1 2 4 5)) "18:00 Gym")|2026-11-02|18:00 Gym
(when (memq (calendar-day-of-week date) '(1 2 4 5)) "18:00 Gym")|2026-11-03|18:00 Gym
(when (memq (calendar-day-of-week date) '(1 2 4 5)) "18:00 Gym")|2026-11-05|18:00 Gym
(when (memq (calendar-day-of-week date) '(1 2 4 5)) "18:00 Gym")|2026-11-06|18:00 Gym
(when (memq (calendar-day-of-week date) '(1 2 4 5)) "18:00 Gym")|2026-11-09|18:00 Gym
(when (memq (calendar-day-of-week date) '(1 2 4 5)) "18:00 Gym")|2026-11-10|18:00 Gym
(when (memq (calendar-day-of-week date) '(1 2 4 5)) "18:00 Gym")|2026-11-12|18:00 Gym
(when (memq (calendar-day-of-week date) '(1 2 4 5)) "18:00 Gym")|2026-11-13|18:00 Gym
(when (memq (calendar-day-of-week date) '(1 2 4 5)) "18:00 Gym")|2026-11-16|18:00 Gym
(when (memq (calendar-day-of-week date) '(1 2 4 5)) "18:00 Gym")|2026-11-17|18:00 Gym
(if (= 0 (% (car (calendar-iso-from-absolute (calendar-absolute-from-gregorian date))) 2)) "Even week; Second")|2026-09-20|Even week; Second
(if (= 0 (% (car (calendar-iso-from-absolute (calendar-absolute-from-gregorian date))) 2)) "Even week; Second")|2026-09-28|Even week; Second
(if (= 0 (% (car (calendar-iso-from-absolute (calendar-absolute-from-gregorian date))) 2)) "Even week; Second")|2026-09-29|Even week; Second
(if (= 0 (% (car (calendar-iso-from-absolute (calendar-absolute-from-gregorian date))) 2)) "Even week; Second")|2026-09-30|Even week; Second
(if (= 0 (% (car (calendar-iso-from-absolute (calendar-absolute-from-gregorian date))) 2)) "Even week; Second")|2026-10-01|Even week; Second
(if (= 0 (% (car (calendar-iso-from-absolute (calendar-absolute-from-gregorian date))) 2)) "Even week; Second")|2026-10-02|Even week; Second
(if (= 0 (% (car (calendar-iso-from-absolute (calendar-absolute-from-gregorian date))) 2)) "Even week; Second")|2026-10-03|Even week; Second
(if (= 0 (% (car (calendar-iso-from-absolute (calendar-absolute-from-gregorian date))) 2)) "Even week; Second")|2026-10-04|Even week; Second
(if (= 0 (% (car (calendar-iso-from-absolute (calendar-absolute-from-gregorian date))) 2)) "Even week; Second")|2026-10-12|Even week; Second
(if (= 0 (% (car (calendar-iso-from-absolute (calendar-absolute-from-gregorian date))) 2)) "Even week; Second")|2026-10-13|Even week; Second
(if (= 0 (% (car (calendar-iso-from-absolute (calendar-absolute-from-gregorian date))) 2)) "Even week; Second")|2026-10-14|Even week; Second
(if (= 0 (% (car (calendar-iso-from-absolute (calendar-absolute-from-gregorian date))) 2)) "Even week; Second")|2026-10-15|Even week; Second
(if (= 0 (% (car (calendar-iso-from-absolute (calendar-absolute-from-gregorian date))) 2)) "Even week; Second")|2026-10-16|Even week; Second
(if (= 0 (% (car (calendar-iso-from-absolute (calendar-absolute-from-gregorian date))) 2)) "Even week; Second")|2026-10-17|Even week; Second
(if (= 0 (% (car (calendar-iso-from-absolute (calendar-absolute-from-gregorian date))) 2)) "Even week; Second")|2026-10-18|Even week; Second
(if (= 0 (% (car (calendar-iso-from-absolute (calendar-absolute-from-gregorian date))) 2)) "Even week; Second")|2026-10-26|Even week; Second
(if (= 0 (% (car (calendar-iso-from-absolute (calendar-absolute-from-gregorian date))) 2)) "Even week; Second")|2026-10-27|Even week; Second
(if (= 0 (% (car (calendar-iso-from-absolute (calendar-absolute-from-gregorian date))) 2)) "Even week; Second")|2026-10-28|Even week; Second
(if (= 0 (% (car (calendar-iso-from-absolute (calendar-absolute-from-gregorian date))) 2)) "Even week; Second")|2026-10-29|Even week; Second
(if (= 0 (% (car (calendar-iso-from-absolute (calendar-absolute-from-gregorian date))) 2)) "Even week; Second")|2026-10-30|Even week; Second
(if (= 0 (% (car (calendar-iso-from-absolute (calendar-absolute-from-gregorian date))) 2)) "Even week; Second")|2026-10-31|Even week; Second
(if (= 0 (% (car (calendar-iso-from-absolute (calendar-absolute-from-gregorian date))) 2)) "Even week; Second")|2026-11-01|Even week; Second
(if (= 0 (% (car (calendar-iso-from-absolute (calendar-absolute-from-gregorian date))) 2)) "Even week; Second")|2026-11-09|Even week; Second
(if (= 0 (% (car (calendar-iso-from-absolute (calendar-absolute-from-gregorian date))) 2)) "Even week; Second")|2026-11-10|Even week; Second
(if (= 0 (% (car (calendar-iso-from-absolute (calendar-absolute-from-gregorian date))) 2)) "Even week; Second")|2026-11-11|Even week; Second
(if (= 0 (% (car (calendar-iso-from-absolute (calendar-absolute-from-gregorian date))) 2)) "Even week; Second")|2026-11-12|Even week; Second
(if (= 0 (% (car (calendar-iso-from-absolute (calendar-absolute-from-gregorian date))) 2)) "Even week; Second")|2026-11-13|Even week; Second
(if (= 0 (% (car (calendar-iso-from-absolute (calendar-absolute-from-gregorian date))) 2)) "Even week; Second")|2026-11-14|Even week; Second
(if (= 0 (% (car (calendar-iso-from-absolute (calendar-absolute-from-gregorian date))) 2)) "Even week; Second")|2026-11-15|Even week; Second
(let ((d (calendar-extract-day date))) (and (<= d 7) (= (calendar-day-of-week date) 1)))|2026-10-05|ENTRY
(let ((d (calendar-extract-day date))) (and (<= d 7) (= (calendar-day-of-week date) 1)))|2026-11-02|ENTRY
(cond ((= (calendar-extract-month date) 10) "October") ((> (calendar-extract-day date) 25) "late") (t nil))|2026-09-26|late
(cond ((= (calendar-extract-month date) 10) "October") ((> (calendar-extract-day date) 25) "late") (t nil))|2026-09-27|late
(cond ((= (calendar-extract-month date) 10) "October") ((> (calendar-extract-day date) 25) "late") (t nil))|2026-09-28|late
(cond ((= (calendar-extract-month date) 10) "October") ((> (calendar-extract-day date) 25) "late") (t nil))|2026-09-29|late
(cond ((= (calendar-extract-month date) 10) "October") ((> (calendar-extract-day date) 25) "late") (t nil))|2026-09-30|late
(cond ((= (calendar-extract-month date) 10) "October") ((> (calendar-extract-day date) 25) "late") (t nil))|2026-10-01|October
(cond ((= (calendar-extract-month date) 10) "October") ((> (calendar-extract-day date) 25) "late") (t nil))|2026-10-02|October
(cond ((= (calendar-extract-month date) 10) "October") ((> (calendar-extract-day date) 25) "late") (t nil))|2026-10-03|October
(cond ((= (calendar-extract-month date) 10) "October") ((> (calendar-extract-day date) 25) "late") (t nil))|2026-10-04|October
(cond ((= (calendar-extract-month date) 10) "October") ((> (calendar-extract-day date) 25) "late") (t nil))|2026-10-05|October
(cond ((= (calendar-extract-month date) 10) "October") ((> (calendar-extract-day date) 25) "late") (t nil))|2026-10-06|October
(cond ((= (calendar-extract-month date) 10) "October") ((> (calendar-extract-day date) 25) "late") (t nil))|2026-10-07|October
(cond ((= (calendar-extract-month date) 10) "October") ((> (calendar-extract-day date) 25) "late") (t nil))|2026-10-08|October
(cond ((= (calendar-extract-month date) 10) "October") ((> (calendar-extract-day date) 25) "late") (t nil))|2026-10-09|October
(cond ((= (calendar-extract-month date) 10) "October") ((> (calendar-extract-day date) 25) "late") (t nil))|2026-10-10|October
(cond ((= (calendar-extract-month date) 10) "October") ((> (calendar-extract-day date) 25) "late") (t nil))|2026-10-11|October
(cond ((= (calendar-extract-month date) 10) "October") ((> (calendar-extract-day date) 25) "late") (t nil))|2026-10-12|October
(cond ((= (calendar-extract-month date) 10) "October") ((> (calendar-extract-day date) 25) "late") (t nil))|2026-10-13|October
(cond ((= (calendar-extract-month date) 10) "October") ((> (calendar-extract-day date) 25) "late") (t nil))|2026-10-14|October
(cond ((= (calendar-extract-month date) 10) "October") ((> (calendar-extract-day date) 25) "late") (t nil))|2026-10-15|October
(cond ((= (calendar-extract-month date) 10) "October") ((> (calendar-extract-day date) 25) "late") (t nil))|2026-10-16|October
(cond ((= (calendar-extract-month date) 10) "October") ((> (calendar-extract-day date) 25) "late") (t nil))|2026-10-17|October
(cond ((= (calendar-extract-month date) 10) "October") ((> (calendar-extract-day date) 25) "late") (t nil))|2026-10-18|October
(cond ((= (calendar-extract-month date) 10) "October") ((> (calendar-extract-day date) 25) "late") (t nil))|2026-10-19|October
(cond ((= (calendar-extract-month date) 10) "October") ((> (calendar-extract-day date) 25) "late") (t nil))|2026-10-20|October
(cond ((= (calendar-extract-month date) 10) "October") ((> (calendar-extract-day date) 25) "late") (t nil))|2026-10-21|October
(cond ((= (calendar-extract-month date) 10) "October") ((> (calendar-extract-day date) 25) "late") (t nil))|2026-10-22|October
(cond ((= (calendar-extract-month date) 10) "October") ((> (calendar-extract-day date) 25) "late") (t nil))|2026-10-23|October
(cond ((= (calendar-extract-month date) 10) "October") ((> (calendar-extract-day date) 25) "late") (t nil))|2026-10-24|October
(cond ((= (calendar-extract-month date) 10) "October") ((> (calendar-extract-day date) 25) "late") (t nil))|2026-10-25|October
(cond ((= (calendar-extract-month date) 10) "October") ((> (calendar-extract-day date) 25) "late") (t nil))|2026-10-26|October
(cond ((= (calendar-extract-month date) 10) "October") ((> (calendar-extract-day date) 25) "late") (t nil))|2026-10-27|October
(cond ((= (calendar-extract-month date) 10) "October") ((> (calendar-extract-day date) 25) "late") (t nil))|2026-10-28|October
(cond ((= (calendar-extract-month date) 10) "October") ((> (calendar-extract-day date) 25) "late") (t nil))|2026-10-29|October
(cond ((= (calendar-extract-month date) 10) "October") ((> (calendar-extract-day date) 25) "late") (t nil))|2026-10-30|October
(cond ((= (calendar-extract-month date) 10) "October") ((> (calendar-extract-day date) 25) "late") (t nil))|2026-10-31|October
(unless (memq (calendar-day-of-week date) '(0 6)) "Weekday")|2026-09-21|Weekday
(unless (memq (calendar-day-of-week date) '(0 6)) "Weekday")|2026-09-22|Weekday
(unless (memq (calendar-day-of-week date) '(0 6)) "Weekday")|2026-09-23|Weekday
(unless (memq (calendar-day-of-week date) '(0 6)) "Weekday")|2026-09-24|Weekday
(unless (memq (calendar-day-of-week date) '(0 6)) "Weekday")|2026-09-25|Weekday
(unless (memq (calendar-day-of-week date) '(0 6)) "Weekday")|2026-09-28|Weekday
(unless (memq (calendar-day-of-week date) '(0 6)) "Weekday")|2026-09-29|Weekday
(unless (memq (calendar-day-of-week date) '(0 6)) "Weekday")|2026-09-30|Weekday
(unless (memq (calendar-day-of-week date) '(0 6)) "Weekday")|2026-10-01|Weekday
(unless (memq (calendar-day-of-week date) '(0 6)) "Weekday")|2026-10-02|Weekday
(unless (memq (calendar-day-of-week date) '(0 6)) "Weekday")|2026-10-05|Weekday
(unless (memq (calendar-day-of-week date) '(0 6)) "Weekday")|2026-10-06|Weekday
(unless (memq (calendar-day-of-week date) '(0 6)) "Weekday")|2026-10-07|Weekday
(unless (memq (calendar-day-of-week date) '(0 6)) "Weekday")|2026-10-08|Weekday
(unless (memq (calendar-day-of-week date) '(0 6)) "Weekday")|2026-10-09|Weekday
(unless (memq (calendar-day-of-week date) '(0 6)) "Weekday")|2026-10-12|Weekday
(unless (memq (calendar-day-of-week date) '(0 6)) "Weekday")|2026-10-13|Weekday
(unless (memq (calendar-day-of-week date) '(0 6)) "Weekday")|2026-10-14|Weekday
(unless (memq (calendar-day-of-week date) '(0 6)) "Weekday")|2026-10-15|Weekday
(unless (memq (calendar-day-of-week date) '(0 6)) "Weekday")|2026-10-16|Weekday
(unless (memq (calendar-day-of-week date) '(0 6)) "Weekday")|2026-10-19|Weekday
(unless (memq (calendar-day-of-week date) '(0 6)) "Weekday")|2026-10-20|Weekday
(unless (memq (calendar-day-of-week date) '(0 6)) "Weekday")|2026-10-21|Weekday
(unless (memq (calendar-day-of-week date) '(0 6)) "Weekday")|2026-10-22|Weekday
(unless (memq (calendar-day-of-week date) '(0 6)) "Weekday")|2026-10-23|Weekday
(unless (memq (calendar-day-of-week date) '(0 6)) "Weekday")|2026-10-26|Weekday
(unless (memq (calendar-day-of-week date) '(0 6)) "Weekday")|2026-10-27|Weekday
(unless (memq (calendar-day-of-week date) '(0 6)) "Weekday")|2026-10-28|Weekday
(unless (memq (calendar-day-of-week date) '(0 6)) "Weekday")|2026-10-29|Weekday
(unless (memq (calendar-day-of-week date) '(0 6)) "Weekday")|2026-10-30|Weekday
(unless (memq (calendar-day-of-week date) '(0 6)) "Weekday")|2026-11-02|Weekday
(unless (memq (calendar-day-of-week date) '(0 6)) "Weekday")|2026-11-03|Weekday
(unless (memq (calendar-day-of-week date) '(0 6)) "Weekday")|2026-11-04|Weekday
(unless (memq (calendar-day-of-week date) '(0 6)) "Weekday")|2026-11-05|Weekday
(unless (memq (calendar-day-of-week date) '(0 6)) "Weekday")|2026-11-06|Weekday
(unless (memq (calendar-day-of-week date) '(0 6)) "Weekday")|2026-11-09|Weekday
(unless (memq (calendar-day-of-week date) '(0 6)) "Weekday")|2026-11-10|Weekday
(unless (memq (calendar-day-of-week date) '(0 6)) "Weekday")|2026-11-11|Weekday
(unless (memq (calendar-day-of-week date) '(0 6)) "Weekday")|2026-11-12|Weekday
(unless (memq (calendar-day-of-week date) '(0 6)) "Weekday")|2026-11-13|Weekday
(unless (memq (calendar-day-of-week date) '(0 6)) "Weekday")|2026-11-16|Weekday
(unless (memq (calendar-day-of-week date) '(0 6)) "Weekday")|2026-11-17|Weekday
(unless (memq (calendar-day-of-week date) '(0 6)) "Weekday")|2026-11-18|Weekday
(let* ((m (calendar-extract-month date)) (d (calendar-extract-day date))) (and (= m 10) (= d (calendar-last-day-of-month m (calendar-extract-year date)))))|2026-10-31|ENTRY
(= (calendar-day-number date) 280)|2026-10-07|ENTRY
(equal date (calendar-nth-named-day 2 3 10 2026))|2026-10-14|ENTRY
(equal date (calendar-nth-named-day -1 5 10 2026))|2026-10-30|ENTRY
(and (= 0 (mod (- (calendar-absolute-from-gregorian date) (calendar-absolute-from-gregorian '(9 1 2026))) 14)) (format "Payday %d" (calendar-extract-day date)))|2026-09-29|Payday 29
(and (= 0 (mod (- (calendar-absolute-from-gregorian date) (calendar-absolute-from-gregorian '(9 1 2026))) 14)) (format "Payday %d" (calendar-extract-day date)))|2026-10-13|Payday 13
(and (= 0 (mod (- (calendar-absolute-from-gregorian date) (calendar-absolute-from-gregorian '(9 1 2026))) 14)) (format "Payday %d" (calendar-extract-day date)))|2026-10-27|Payday 27
(and (= 0 (mod (- (calendar-absolute-from-gregorian date) (calendar-absolute-from-gregorian '(9 1 2026))) 14)) (format "Payday %d" (calendar-extract-day date)))|2026-11-10|Payday 10
(equal date (calendar-gregorian-from-absolute (1+ (calendar-absolute-from-gregorian '(10 3 2026)))))|2026-10-04|ENTRY
(and (diary-float t 4 -1) (concat "Last " "Thu"))|2026-09-24|Last Thu
(and (diary-float t 4 -1) (concat "Last " "Thu"))|2026-10-29|Last Thu
(or (diary-date 10 5 t) (diary-anniversary 10 7 2000))|2026-10-05|ENTRY
(or (diary-date 10 5 t) (diary-anniversary 10 7 2000))|2026-10-07|ENTRY
(member (calendar-extract-day date) (list 1 15))|2026-10-01|ENTRY
(member (calendar-extract-day date) (list 1 15))|2026-10-15|ENTRY
(member (calendar-extract-day date) (list 1 15))|2026-11-01|ENTRY
(member (calendar-extract-day date) (list 1 15))|2026-11-15|ENTRY
(progn (/ 7 2) (and (= (/ 7 2) 3) (= (/ -7 2) -3) (= (% -7 2) -1) (= (mod -7 2) 1) (= (calendar-day-of-week date) 3)))|2026-09-23|ENTRY
(progn (/ 7 2) (and (= (/ 7 2) 3) (= (/ -7 2) -3) (= (% -7 2) -1) (= (mod -7 2) 1) (= (calendar-day-of-week date) 3)))|2026-09-30|ENTRY
(progn (/ 7 2) (and (= (/ 7 2) 3) (= (/ -7 2) -3) (= (% -7 2) -1) (= (mod -7 2) 1) (= (calendar-day-of-week date) 3)))|2026-10-07|ENTRY
(progn (/ 7 2) (and (= (/ 7 2) 3) (= (/ -7 2) -3) (= (% -7 2) -1) (= (mod -7 2) 1) (= (calendar-day-of-week date) 3)))|2026-10-14|ENTRY
(progn (/ 7 2) (and (= (/ 7 2) 3) (= (/ -7 2) -3) (= (% -7 2) -1) (= (mod -7 2) 1) (= (calendar-day-of-week date) 3)))|2026-10-21|ENTRY
(progn (/ 7 2) (and (= (/ 7 2) 3) (= (/ -7 2) -3) (= (% -7 2) -1) (= (mod -7 2) 1) (= (calendar-day-of-week date) 3)))|2026-10-28|ENTRY
(progn (/ 7 2) (and (= (/ 7 2) 3) (= (/ -7 2) -3) (= (% -7 2) -1) (= (mod -7 2) 1) (= (calendar-day-of-week date) 3)))|2026-11-04|ENTRY
(progn (/ 7 2) (and (= (/ 7 2) 3) (= (/ -7 2) -3) (= (% -7 2) -1) (= (mod -7 2) 1) (= (calendar-day-of-week date) 3)))|2026-11-11|ENTRY
(progn (/ 7 2) (and (= (/ 7 2) 3) (= (/ -7 2) -3) (= (% -7 2) -1) (= (mod -7 2) 1) (= (calendar-day-of-week date) 3)))|2026-11-18|ENTRY
(nth 2 (list nil nil (calendar-leap-year-p 2028) nil))|2026-09-20|ENTRY
(nth 2 (list nil nil (calendar-leap-year-p 2028) nil))|2026-09-21|ENTRY
(nth 2 (list nil nil (calendar-leap-year-p 2028) nil))|2026-09-22|ENTRY
(nth 2 (list nil nil (calendar-leap-year-p 2028) nil))|2026-09-23|ENTRY
(nth 2 (list nil nil (calendar-leap-year-p 2028) nil))|2026-09-24|ENTRY
(nth 2 (list nil nil (calendar-leap-year-p 2028) nil))|2026-09-25|ENTRY
(nth 2 (list nil nil (calendar-leap-year-p 2028) nil))|2026-09-26|ENTRY
(nth 2 (list nil nil (calendar-leap-year-p 2028) nil))|2026-09-27|ENTRY
(nth 2 (list nil nil (calendar-leap-year-p 2028) nil))|2026-09-28|ENTRY
(nth 2 (list nil nil (calendar-leap-year-p 2028) nil))|2026-09-29|ENTRY
(nth 2 (list nil nil (calendar-leap-year-p 2028) nil))|2026-09-30|ENTRY
(nth 2 (list nil nil (calendar-leap-year-p 2028) nil))|2026-10-01|ENTRY
(nth 2 (list nil nil (calendar-leap-year-p 2028) nil))|2026-10-02|ENTRY
(nth 2 (list nil nil (calendar-leap-year-p 2028) nil))|2026-10-03|ENTRY
(nth 2 (list nil nil (calendar-leap-year-p 2028) nil))|2026-10-04|ENTRY
(nth 2 (list nil nil (calendar-leap-year-p 2028) nil))|2026-10-05|ENTRY
(nth 2 (list nil nil (calendar-leap-year-p 2028) nil))|2026-10-06|ENTRY
(nth 2 (list nil nil (calendar-leap-year-p 2028) nil))|2026-10-07|ENTRY
(nth 2 (list nil nil (calendar-leap-year-p 2028) nil))|2026-10-08|ENTRY
(nth 2 (list nil nil (calendar-leap-year-p 2028) nil))|2026-10-09|ENTRY
(nth 2 (list nil nil (calendar-leap-year-p 2028) nil))|2026-10-10|ENTRY
(nth 2 (list nil nil (calendar-leap-year-p 2028) nil))|2026-10-11|ENTRY
(nth 2 (list nil nil (calendar-leap-year-p 2028) nil))|2026-10-12|ENTRY
(nth 2 (list nil nil (calendar-leap-year-p 2028) nil))|2026-10-13|ENTRY
(nth 2 (list nil nil (calendar-leap-year-p 2028) nil))|2026-10-14|ENTRY
(nth 2 (list nil nil (calendar-leap-year-p 2028) nil))|2026-10-15|ENTRY
(nth 2 (list nil nil (calendar-leap-year-p 2028) nil))|2026-10-16|ENTRY
(nth 2 (list nil nil (calendar-leap-year-p 2028) nil))|2026-10-17|ENTRY
(nth 2 (list nil nil (calendar-leap-year-p 2028) nil))|2026-10-18|ENTRY
(nth 2 (list nil nil (calendar-leap-year-p 2028) nil))|2026-10-19|ENTRY
(nth 2 (list nil nil (calendar-leap-year-p 2028) nil))|2026-10-20|ENTRY
(nth 2 (list nil nil (calendar-leap-year-p 2028) nil))|2026-10-21|ENTRY
(nth 2 (list nil nil (calendar-leap-year-p 2028) nil))|2026-10-22|ENTRY
(nth 2 (list nil nil (calendar-leap-year-p 2028) nil))|2026-10-23|ENTRY
(nth 2 (list nil nil (calendar-leap-year-p 2028) nil))|2026-10-24|ENTRY
(nth 2 (list nil nil (calendar-leap-year-p 2028) nil))|2026-10-25|ENTRY
(nth 2 (list nil nil (calendar-leap-year-p 2028) nil))|2026-10-26|ENTRY
(nth 2 (list nil nil (calendar-leap-year-p 2028) nil))|2026-10-27|ENTRY
(nth 2 (list nil nil (calendar-leap-year-p 2028) nil))|2026-10-28|ENTRY
(nth 2 (list nil nil (calendar-leap-year-p 2028) nil))|2026-10-29|ENTRY
(nth 2 (list nil nil (calendar-leap-year-p 2028) nil))|2026-10-30|ENTRY
(nth 2 (list nil nil (calendar-leap-year-p 2028) nil))|2026-10-31|ENTRY
(nth 2 (list nil nil (calendar-leap-year-p 2028) nil))|2026-11-01|ENTRY
(nth 2 (list nil nil (calendar-leap-year-p 2028) nil))|2026-11-02|ENTRY
(nth 2 (list nil nil (calendar-leap-year-p 2028) nil))|2026-11-03|ENTRY
(nth 2 (list nil nil (calendar-leap-year-p 2028) nil))|2026-11-04|ENTRY
(nth 2 (list nil nil (calendar-leap-year-p 2028) nil))|2026-11-05|ENTRY
(nth 2 (list nil nil (calendar-leap-year-p 2028) nil))|2026-11-06|ENTRY
(nth 2 (list nil nil (calendar-leap-year-p 2028) nil))|2026-11-07|ENTRY
(nth 2 (list nil nil (calendar-leap-year-p 2028) nil))|2026-11-08|ENTRY
(nth 2 (list nil nil (calendar-leap-year-p 2028) nil))|2026-11-09|ENTRY
(nth 2 (list nil nil (calendar-leap-year-p 2028) nil))|2026-11-10|ENTRY
(nth 2 (list nil nil (calendar-leap-year-p 2028) nil))|2026-11-11|ENTRY
(nth 2 (list nil nil (calendar-leap-year-p 2028) nil))|2026-11-12|ENTRY
(nth 2 (list nil nil (calendar-leap-year-p 2028) nil))|2026-11-13|ENTRY
(nth 2 (list nil nil (calendar-leap-year-p 2028) nil))|2026-11-14|ENTRY
(nth 2 (list nil nil (calendar-leap-year-p 2028) nil))|2026-11-15|ENTRY
(nth 2 (list nil nil (calendar-leap-year-p 2028) nil))|2026-11-16|ENTRY
(nth 2 (list nil nil (calendar-leap-year-p 2028) nil))|2026-11-17|ENTRY
(nth 2 (list nil nil (calendar-leap-year-p 2028) nil))|2026-11-18|ENTRY
(when (eq (calendar-day-of-week date) 6) (number-to-string (calendar-extract-day date)))|2026-09-26|26
(when (eq (calendar-day-of-week date) 6) (number-to-string (calendar-extract-day date)))|2026-10-03|3
(when (eq (calendar-day-of-week date) 6) (number-to-string (calendar-extract-day date)))|2026-10-10|10
(when (eq (calendar-day-of-week date) 6) (number-to-string (calendar-extract-day date)))|2026-10-17|17
(when (eq (calendar-day-of-week date) 6) (number-to-string (calendar-extract-day date)))|2026-10-24|24
(when (eq (calendar-day-of-week date) 6) (number-to-string (calendar-extract-day date)))|2026-10-31|31
(when (eq (calendar-day-of-week date) 6) (number-to-string (calendar-extract-day date)))|2026-11-07|7
(when (eq (calendar-day-of-week date) 6) (number-to-string (calendar-extract-day date)))|2026-11-14|14
(let (x) (unless x (and (>= (calendar-extract-day date) 30) (list "a" "b"))))|2026-09-30|a; b
(let (x) (unless x (and (>= (calendar-extract-day date) 30) (list "a" "b"))))|2026-10-30|a; b
(let (x) (unless x (and (>= (calendar-extract-day date) 30) (list "a" "b"))))|2026-10-31|a; b
(if (zerop (% (calendar-extract-day date) 10)) "tens" "")|2026-09-20|tens
(if (zerop (% (calendar-extract-day date) 10)) "tens" "")|2026-09-21|
(if (zerop (% (calendar-extract-day date) 10)) "tens" "")|2026-09-22|
(if (zerop (% (calendar-extract-day date) 10)) "tens" "")|2026-09-23|
(if (zerop (% (calendar-extract-day date) 10)) "tens" "")|2026-09-24|
(if (zerop (% (calendar-extract-day date) 10)) "tens" "")|2026-09-25|
(if (zerop (% (calendar-extract-day date) 10)) "tens" "")|2026-09-26|
(if (zerop (% (calendar-extract-day date) 10)) "tens" "")|2026-09-27|
(if (zerop (% (calendar-extract-day date) 10)) "tens" "")|2026-09-28|
(if (zerop (% (calendar-extract-day date) 10)) "tens" "")|2026-09-29|
(if (zerop (% (calendar-extract-day date) 10)) "tens" "")|2026-09-30|tens
(if (zerop (% (calendar-extract-day date) 10)) "tens" "")|2026-10-01|
(if (zerop (% (calendar-extract-day date) 10)) "tens" "")|2026-10-02|
(if (zerop (% (calendar-extract-day date) 10)) "tens" "")|2026-10-03|
(if (zerop (% (calendar-extract-day date) 10)) "tens" "")|2026-10-04|
(if (zerop (% (calendar-extract-day date) 10)) "tens" "")|2026-10-05|
(if (zerop (% (calendar-extract-day date) 10)) "tens" "")|2026-10-06|
(if (zerop (% (calendar-extract-day date) 10)) "tens" "")|2026-10-07|
(if (zerop (% (calendar-extract-day date) 10)) "tens" "")|2026-10-08|
(if (zerop (% (calendar-extract-day date) 10)) "tens" "")|2026-10-09|
(if (zerop (% (calendar-extract-day date) 10)) "tens" "")|2026-10-10|tens
(if (zerop (% (calendar-extract-day date) 10)) "tens" "")|2026-10-11|
(if (zerop (% (calendar-extract-day date) 10)) "tens" "")|2026-10-12|
(if (zerop (% (calendar-extract-day date) 10)) "tens" "")|2026-10-13|
(if (zerop (% (calendar-extract-day date) 10)) "tens" "")|2026-10-14|
(if (zerop (% (calendar-extract-day date) 10)) "tens" "")|2026-10-15|
(if (zerop (% (calendar-extract-day date) 10)) "tens" "")|2026-10-16|
(if (zerop (% (calendar-extract-day date) 10)) "tens" "")|2026-10-17|
(if (zerop (% (calendar-extract-day date) 10)) "tens" "")|2026-10-18|
(if (zerop (% (calendar-extract-day date) 10)) "tens" "")|2026-10-19|
(if (zerop (% (calendar-extract-day date) 10)) "tens" "")|2026-10-20|tens
(if (zerop (% (calendar-extract-day date) 10)) "tens" "")|2026-10-21|
(if (zerop (% (calendar-extract-day date) 10)) "tens" "")|2026-10-22|
(if (zerop (% (calendar-extract-day date) 10)) "tens" "")|2026-10-23|
(if (zerop (% (calendar-extract-day date) 10)) "tens" "")|2026-10-24|
(if (zerop (% (calendar-extract-day date) 10)) "tens" "")|2026-10-25|
(if (zerop (% (calendar-extract-day date) 10)) "tens" "")|2026-10-26|
(if (zerop (% (calendar-extract-day date) 10)) "tens" "")|2026-10-27|
(if (zerop (% (calendar-extract-day date) 10)) "tens" "")|2026-10-28|
(if (zerop (% (calendar-extract-day date) 10)) "tens" "")|2026-10-29|
(if (zerop (% (calendar-extract-day date) 10)) "tens" "")|2026-10-30|tens
(if (zerop (% (calendar-extract-day date) 10)) "tens" "")|2026-10-31|
(if (zerop (% (calendar-extract-day date) 10)) "tens" "")|2026-11-01|
(if (zerop (% (calendar-extract-day date) 10)) "tens" "")|2026-11-02|
(if (zerop (% (calendar-extract-day date) 10)) "tens" "")|2026-11-03|
(if (zerop (% (calendar-extract-day date) 10)) "tens" "")|2026-11-04|
(if (zerop (% (calendar-extract-day date) 10)) "tens" "")|2026-11-05|
(if (zerop (% (calendar-extract-day date) 10)) "tens" "")|2026-11-06|
(if (zerop (% (calendar-extract-day date) 10)) "tens" "")|2026-11-07|
(if (zerop (% (calendar-extract-day date) 10)) "tens" "")|2026-11-08|
(if (zerop (% (calendar-extract-day date) 10)) "tens" "")|2026-11-09|
(if (zerop (% (calendar-extract-day date) 10)) "tens" "")|2026-11-10|tens
(if (zerop (% (calendar-extract-day date) 10)) "tens" "")|2026-11-11|
(if (zerop (% (calendar-extract-day date) 10)) "tens" "")|2026-11-12|
(if (zerop (% (calendar-extract-day date) 10)) "tens" "")|2026-11-13|
(if (zerop (% (calendar-extract-day date) 10)) "tens" "")|2026-11-14|
(if (zerop (% (calendar-extract-day date) 10)) "tens" "")|2026-11-15|
(if (zerop (% (calendar-extract-day date) 10)) "tens" "")|2026-11-16|
(if (zerop (% (calendar-extract-day date) 10)) "tens" "")|2026-11-17|
(if (zerop (% (calendar-extract-day date) 10)) "tens" "")|2026-11-18|
]==]

  it("match Emacs for when/if/cond/let, memq, arithmetic and calendar helpers", function()
    local got = {}
    local start = date.days_from_civil(2026, 9, 20)
    for _, s in ipairs(ELISP) do
      for i = 0, 59 do
        local r, err = sexp.eval(s, start + i, "ENTRY")
        ok(r ~= nil, "error in " .. s .. ": " .. tostring(err))
        if r then
          local y, m, d = date.civil_from_days(start + i)
          got[#got + 1] = string.format("%s|%04d-%02d-%02d|%s", s, y, m, d, r == true and "ENTRY" or r)
        end
      end
    end
    eq(vim.split(vim.trim(EXPECTED), "\n"), got)
  end)

  it("binds date and entry, and keeps unknown functions an error", function()
    local d = date.days_from_civil(2026, 9, 21)
    eq("9/21/2026", sexp.eval('(format "%d/%d/%d" (car date) (nth 1 date) (nth 2 date))', d))
    eq("Gym", sexp.eval("(and (= (calendar-day-of-week date) 1) entry)", d, "Gym"))
    local r, err = sexp.eval('(when t (shell-command "ls"))', d)
    eq(nil, r)
    ok(err:find("unsupported function shell%-command"), err)
    r, err = sexp.eval("(let ((x 1)) y)", d)
    eq(nil, r)
    ok(err:find("void%-variable y"), err)
  end)
end)
