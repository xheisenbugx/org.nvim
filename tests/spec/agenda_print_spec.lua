-- PostScript and PDF agenda export (org-agenda-write to .ps/.pdf, ps-print).
local config = require("org.config")
local date = require("org.date")
local utils = require("org.utils")
local printer = require("org.agenda.print")
vim.g.org_test = true

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")

local function read(path)
  local fd = assert(io.open(path, "rb"))
  local c = fd:read("*a")
  fd:close()
  return c
end

local function count(s, pat)
  local n = 0
  for _ in s:gmatch(pat) do
    n = n + 1
  end
  return n
end

local function numbered(n)
  local lines = {}
  for i = 1, n do
    lines[i] = "Line " .. i
  end
  return lines
end

--- Check the cross-reference table of a PDF: every offset points at its
--- "N 0 obj", startxref at "xref", and /Size matches.
local function check_pdf(c)
  ok(c:sub(1, 9) == "%PDF-1.4\n", c:sub(1, 20))
  ok(c:find("%%%%EOF\n$"))
  local startxref = tonumber(c:match("startxref\n(%d+)\n%%%%EOF\n$"))
  eq("xref", c:sub(startxref + 1, startxref + 4))
  local first, n = c:match("^xref\n(%d+) (%d+)\n", startxref + 1)
  eq("0", first)
  n = tonumber(n)
  eq(n, tonumber(c:match("trailer\n<< /Size (%d+)")))
  local pos = startxref + #("xref\n0 " .. n .. "\n") + 1
  for i = 0, n - 1 do
    local entry = c:sub(pos + i * 20, pos + i * 20 + 19)
    local off, kind = entry:match("^(%d+) %d+ ([fn]) \n$")
    ok(off, "bad xref entry " .. entry)
    if kind == "n" then
      local o = tonumber(off)
      eq(i .. " 0 obj", c:sub(o + 1, o + #(i .. " 0 obj")))
    end
  end
  return tonumber(c:match("/Type /Pages /Kids %b[] /Count (%d+)"))
end

describe("agenda print layout", function()
  it("uses ps-print's default page geometry", function()
    local L = printer.layout(printer.settings())
    -- letter, 8.5pt Courier: 72 lines of 97 columns (as ps-print)
    eq(72, L.lines)
    eq(97, L.width)
    eq("Letter", L.media)
    local A = printer.layout(printer.settings({ ["ps-paper-type"] = "'a4" }))
    eq("A4", A.media)
    ok(A.lines > L.lines)
    local land = printer.layout(printer.settings({ ps_landscape_mode = true, ps_number_of_columns = 2 }))
    eq(7, land.font_size)
    eq(2, land.cols)
    ok(land.w > land.h)
    local nohead = printer.layout(printer.settings({ ps_print_header = false }))
    ok(nohead.lines > L.lines)
    ok(not pcall(printer.layout, printer.settings({ ps_paper_type = "napkin" })))
  end)

  it("maps text to Latin-1 cells and wraps long lines", function()
    local rows = printer.format({ "a\tb", "é ┄┄ – “q” ✓ 日", string.rep("x", 22) }, nil, 20, false)
    eq("a       b", rows[1][1].text)
    eq('\233 -- - "q" x ??', rows[2][1].text)
    eq(string.rep("x", 20), rows[3][1].text)
    eq("xx", rows[4][1].text)
    eq(4, #rows)
  end)

  it("keeps bold and colours of the highlights", function()
    vim.api.nvim_set_hl(0, "OrgPrintTestBold", { bold = true, fg = 0xff0000 })
    local spans = { [0] = { { s = 2, e = 6, group = "OrgPrintTestBold" } } }
    local rows = printer.format({ "a bold c" }, spans, 97, true)
    eq(
      { "a ", "bold", " c" },
      vim.tbl_map(function(r)
        return r.text
      end, rows[1])
    )
    eq(1, rows[1][2].font)
    eq({ 1, 0, 0 }, rows[1][2].fg)
    local bw = printer.format({ "a bold c" }, spans, 97, false)
    eq(nil, bw[1][2].fg)
  end)
end)

describe("agenda PostScript", function()
  it("writes a DSC document with a page per 72 lines and ps-print's header", function()
    local ps = printer.postscript(numbered(150), nil)
    ok(ps:find("^%%!PS%-Adobe%-3%.0\n"))
    ok(ps:find("\n%%%%Pages: 3\n"))
    eq(3, count(ps, "\n%%%%Page: %d+ %d+\n"))
    ok(ps:find("%%%%EOF\n$"))
    ok(ps:find("%(Agenda View%)"))
    ok(ps:find("%(1/3%)") and ps:find("%(3/3%)"))
    ok(ps:find("%(" .. os.date("%x"):gsub("%p", "%%%0") .. "%)"))
    -- page 1 ends with line 72, page 2 starts with line 73
    local p2 = ps:find("%%%%Page: 2 2")
    ok(ps:find("%(Line 72%)") < p2)
    ok(ps:find("%(Line 73%)") > p2)
    ok(ps:find("%(Line 145%)") > ps:find("%%%%Page: 3 3"))
  end)

  it("escapes parentheses, backslashes and 8-bit characters", function()
    local ps = printer.postscript({ "a (b) c\\d é" }, nil)
    ok(ps:find("(a \\(b\\) c\\\\d \\351)", 1, true), ps)
    eq("(\\(\\)\\\\\\351)", printer.string_literal("()\\\233"))
  end)

  it("follows the settings", function()
    local ps = printer.postscript(numbered(10), nil, { ps_paper_type = "a4", ps_landscape_mode = true })
    ok(ps:find("%%%%DocumentMedia: A4 "))
    ok(ps:find("%%%%Orientation: Landscape"))
    ok(ps:find("90 rotate", 1, true))
    local plain = printer.postscript(numbered(10), nil, { ps_print_header = false })
    ok(not plain:find("Agenda View%)"))
  end)
end)

describe("agenda PDF", function()
  it("writes a valid PDF with one page per 72 lines", function()
    local c = printer.pdf(numbered(150), nil)
    eq(3, check_pdf(c))
    eq(3, count(c, "/Type /Page /Parent"))
    ok(c:find("/BaseFont /Courier /Encoding /WinAnsiEncoding", 1, true))
    ok(c:find("/MediaBox [0 0 612 792]", 1, true))
    ok(c:find("(Line 150) Tj", 1, true))
    -- stream lengths are exact
    for len, body in c:gmatch("<< /Length (%d+) >>\nstream\n(.-)endstream") do
      eq(tonumber(len), #body)
    end
  end)

  it("handles an empty agenda and escapes text", function()
    eq(1, check_pdf(printer.pdf({}, nil)))
    local c = printer.pdf({ "x (y) \\ ü" }, nil, { ps_paper_type = "a4" })
    check_pdf(c)
    ok(c:find("(x \\(y\\) \\\\ \\374) Tj", 1, true))
    ok(c:find("/MediaBox [0 0 595.276 841.89]", 1, true))
  end)
end)

describe("org-agenda-write to .ps and .pdf", function()
  local path = dir .. "/p.org"
  local FRI = date.days_from_civil(2026, 9, 25)
  local view = require("org.agenda.view")
  local export = require("org.agenda.export")
  local real_today
  before_each(function()
    real_today = date.today
    date.today = function()
      return date.from_days(FRI)
    end
    utils.writefile(path, { "* TODO Call (Bob) about \\ stuff", "  SCHEDULED: <2026-09-25 Fri>" })
  end)
  after_each(function()
    date.today = real_today
    pcall(view.quit, true)
  end)

  it("writes the current view", function()
    config.setup({ agenda_files = { path }, org_directory = dir })
    require("org.agenda").open_agenda({ span = "day", anchor = FRI })
    ok(export.write(dir .. "/a.ps"))
    local ps = read(dir .. "/a.ps")
    ok(ps:find("Call \\(Bob\\) about \\\\ stuff", 1, true), ps)
    ok(ps:find("%%%%Pages: 1\n"))
    ok(export.write(dir .. "/a.pdf"))
    eq(1, check_pdf(read(dir .. "/a.pdf")))
  end)

  it("applies agenda.exporter_settings and command settings in store_views", function()
    config.setup({
      agenda_files = { path },
      org_directory = dir,
      agenda = {
        exporter_settings = { ps_paper_type = "a4", ["ps-print-color-p"] = "black-white" },
        custom_commands = {
          x = {
            description = "todo",
            type = "todo",
            settings = { ps_landscape_mode = true },
            export_files = { dir .. "/x.ps", dir .. "/x.pdf" },
          },
        },
      },
    })
    eq(2, export.store_views())
    local ps = read(dir .. "/x.ps")
    ok(ps:find("%%%%DocumentMedia: A4 "))
    ok(ps:find("%%%%Orientation: Landscape"))
    ok(not ps:find("setrgbcolor S", 1, true))
    local c = read(dir .. "/x.pdf")
    eq(1, check_pdf(c))
    ok(c:find("/MediaBox [0 0 841.89 595.276]", 1, true))
  end)
end)
