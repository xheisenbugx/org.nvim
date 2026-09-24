local parser = require("org.parser")
local search = require("org.agenda.search")
local date = require("org.date")

local today = date.today()
local lines = {
  "#+FILETAGS: :file:",
  "* TODO [#A] Work task :work:urgent:",
  "  SCHEDULED: " .. today:to_string(),
  "  :PROPERTIES:",
  "  :Effort: 1:30",
  "  :CATEGORY: job",
  "  :END:",
  "** NEXT Sub task :boss:",
  "* WAIT Home thing :home:",
  "* DONE Finished :work:",
  "* Plain heading",
  "  some body text with needle inside",
}
local cfg = require("org.todo_keywords")
local f = parser.parse(vim.list_extend({ "#+TODO: TODO NEXT WAIT | DONE" }, lines), "/tmp/s.org")
local H = {}
for _, hl in ipairs(f.headlines) do
  H[hl:plain_title()] = hl
end

local function matches(m)
  local pred = search.compile(m)
  local out = {}
  for _, hl in ipairs(f.headlines) do
    if pred(hl) then
      out[#out + 1] = hl:plain_title()
    end
  end
  return out
end

describe("agenda.search", function()
  it("tags", function()
    eq({ "Work task", "Sub task", "Finished" }, matches("work"))
    eq({ "Work task", "Finished" }, matches("+work-boss"))
    eq({ "Sub task" }, matches("work&boss"))
    eq({ "Sub task", "Home thing" }, matches("boss|home"))
    eq({ "Home thing" }, matches("{^ho}"))
    eq(5, #matches("file"))
  end)
  it("properties", function()
    eq({ "Work task" }, matches('PRIORITY="A"'))
    eq({ "Sub task" }, matches("LEVEL>1"))
    eq({ "Home thing" }, matches('TODO="WAIT"'))
    eq({ "Work task" }, matches("Effort>60"))
    eq({ "Work task", "Sub task" }, matches("CATEGORY={^jo}")) -- CATEGORY inherits
    eq({ "Work task", "Sub task" }, matches('CATEGORY<>"s"&-home&-Finished'))
  end)
  it("dates", function()
    eq({ "Work task" }, matches('SCHEDULED<="<today>"'))
    eq({}, matches('SCHEDULED>"<today>"'))
    eq({ "Work task" }, matches('SCHEDULED<"<+1d>"'))
  end)
  it("todo part", function()
    eq({ "Work task", "Sub task" }, matches("work/TODO|NEXT"))
    eq({ "Work task", "Sub task" }, matches("work/!"))
    eq({ "Work task", "Sub task", "Home thing", "Plain heading" }, matches("/-DONE"))
    eq({ "Work task", "Home thing" }, matches("/!-NEXT"))
  end)
  it("reports errors", function()
    local pred, err = search.try_compile('FOO="unterminated')
    eq(nil, pred)
    ok(err)
  end)
  it("text search", function()
    local function t(q)
      local p = search.compile_text(q)
      local out = {}
      for _, hl in ipairs(f.headlines) do
        if p(hl) then
          out[#out + 1] = hl:plain_title()
        end
      end
      return out
    end
    eq({ "Plain heading" }, t("needle"))
    eq({ "Plain heading" }, t("+needle +body"))
    eq({}, t("+needle -body"))
    eq({ "Work task", "Sub task" }, t("*{task}"))
    eq({}, t("*needle"))
  end)
end)
