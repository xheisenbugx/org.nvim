-- The playground page of the website: every tutor lesson has a recording
-- (docs/playground/<lesson>.cast, `make playground`) whose exercises match
-- the lesson, the recorder (scripts/playground/record.lua) runs headless
-- and fails when its steps don't do an exercise, and the page's helpers
-- (scripts/site/playground.lua).
local root = vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))
package.path = root .. "/scripts/?.lua;" .. package.path
local record = dofile(root .. "/scripts/playground/record.lua")
local playground = require("site.playground")

local function read(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return s
end

--- The header and events of an asciicast v2 file.
local function parse_cast(text)
  local lines = vim.split(text, "\n", { trimempty = true })
  local header = vim.json.decode(lines[1])
  local events = {}
  for i = 2, #lines do
    events[#events + 1] = vim.json.decode(lines[i])
  end
  return header, events
end

local function markers(events)
  local out = {}
  for _, e in ipairs(events) do
    if e[2] == "m" then
      out[#out + 1] = e[3]
    end
  end
  return out
end

--- Run the recorder; returns the vim.system result and the output dir.
local function run_recorder(lesson, env)
  local out = vim.fn.tempname()
  local data = vim.fn.tempname()
  local res = vim
    .system({ vim.v.progpath, "--headless", "--clean", "-l", root .. "/scripts/playground/record.lua", out, lesson }, {
      text = true,
      env = vim.tbl_extend("force", { XDG_DATA_HOME = data, XDG_STATE_HOME = data .. "/state" }, env or {}),
    })
    :wait(120000)
  vim.fn.delete(data, "rf")
  return res, out
end

describe("playground", function()
  it("has a recording and steps for every tutor lesson, matching its exercises", function()
    local lessons = record.lessons()
    ok(#lessons >= 2)
    for _, name in ipairs(lessons) do
      local cast = read(root .. "/docs/playground/" .. name .. ".cast")
      ok(cast, "no docs/playground/" .. name .. ".cast: run `make playground`")
      local header, events = parse_cast(cast)
      eq(2, header.version)
      eq(record.width, header.width)
      eq(record.height, header.height)
      ok(header.theme and header.theme.fg and header.theme.bg)
      -- times only go forward
      for i = 2, #events do
        ok(events[i][1] >= events[i - 1][1], name .. ": event " .. i .. " goes back in time")
      end
      local titles = record.titles(root .. "/tutor/org/" .. name .. ".org")
      local steps = record.steps(name)
      local played, expected = {}, {}
      for _, ex in ipairs(steps) do
        if ex.id ~= "intro" then
          ok(titles[ex.id], name .. ": steps for exercise " .. ex.id .. ", which the lesson doesn't have")
          played[ex.id] = true
        end
        expected[#expected + 1] = ex.title or titles[ex.id]
      end
      -- every exercise with a check is played
      for id in pairs(require("org.tutor").checks(name)) do
        ok(played[id], name .. ": exercise " .. id .. " has a check but no steps in scripts/playground/lessons")
      end
      eq(expected, markers(events), name .. ".cast is out of date with its lesson: run `make playground`")
      -- made from this lesson and these steps, by a known Neovim
      ok(header.generator and header.generator.nvim:match("^v%d"), name .. ".cast: no Neovim version")
      eq(
        record.source_hash(name),
        header.generator.source,
        name .. ".cast is older than its lesson or steps: run `make playground`"
      )
    end
  end)

  it("has recordings without a path of the machine they were made on", function()
    local temp = vim.fn.tempname():match("^(.*)[/\\]")
    for _, name in ipairs(record.lessons()) do
      local cast = read(root .. "/docs/playground/" .. name .. ".cast") or ""
      for _, path in ipairs({ "/private", "/var/folders", "/tmp/", "/Users/", "/home/", temp }) do
        ok(not cast:find(path, 1, true), name .. ".cast has the path " .. path)
      end
    end
  end)

  it("writes event times in whole milliseconds", function()
    for _, name in ipairs(record.lessons()) do
      local cast = read(root .. "/docs/playground/" .. name .. ".cast") or ""
      for line in cast:gmatch("\n(%[[^,]*),") do
        ok(line:match("^%[%d+$") or line:match("^%[%d+%.%d?%d?[1-9]$"), name .. ".cast: event time " .. line)
      end
    end
    eq("8.3", record.seconds(8300))
    eq("0", record.seconds(0))
    eq("12.05", record.seconds(12050))
    eq("1.001", record.seconds(1001))
  end)

  if vim.fn.has("win32") == 0 then
    it("records headless, with the exercise done", function()
      local res, out = run_recorder("basics", { ORG_PLAYGROUND_EXERCISES = "intro,1.2" })
      ok(res.code == 0, (res.stdout or "") .. (res.stderr or ""))
      local cast = read(out .. "/basics.cast")
      vim.fn.delete(out, "rf")
      ok(cast)
      local _, events = parse_cast(cast)
      eq({ "Welcome", "1.2 Insert a headline" }, markers(events))
      local typed, screen = {}, {}
      for _, e in ipairs(events) do
        if e[2] == "i" then
          typed[#typed + 1] = e[3]
        elseif e[2] == "o" then
          screen[#screen + 1] = e[3]
        end
      end
      eq({ "<M-CR>", "P", "e", "a", "r", "s", "<Esc>" }, typed)
      screen = table.concat(screen)
      ok(screen:find("Pears", 1, true))
      -- no path of the machine it ran on
      ok(not screen:find(vim.fn.tempname():match("^(.*)[/\\]"), 1, true))
    end)

    it("fails when the steps don't do an exercise", function()
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir, "p")
      vim.fn.writefile(
        { 'return { { id = "1.2", steps = { { at = "Apples" }, { key = "j" } } } }' },
        dir .. "/basics.lua"
      )
      local res = run_recorder("basics", { ORG_PLAYGROUND_STEPS = dir })
      vim.fn.delete(dir, "rf")
      eq(1, res.code)
      ok(res.stderr:find("basics 1.2: the steps don't pass the exercise's check", 1, true), res.stderr)
    end)
  end

  describe("page", function()
    it("renders the lesson text's markup", function()
      eq("press <code>&lt;Tab&gt;</code> a few times", playground.inline("press =<Tab>= a few times"))
      eq("x=1 and y=2, a <code>b</code>.", playground.inline("x=1 and y=2, a ~b~."))
      eq("see the treasure", playground.inline("see [[*Treasure chest][the treasure]]"))
    end)

    it("splits a lesson into its intro and exercises, without the practice material", function()
      local lesson = playground.parse({
        "#+TITLE: A lesson",
        "Hello.",
        "* Lesson 1",
        "** 1.1 Do it",
        "Press =x=.",
        "",
        "- Milk",
        "*** Practice",
        "** 1.2 Then this",
        "Text.",
        "| a | b |",
      })
      eq("A lesson", lesson.title)
      eq({ "Hello." }, lesson.intro)
      eq({ "1.1", "1.2" }, { lesson.exercises[1].id, lesson.exercises[2].id })
      eq({ "Press =x=.", "" }, lesson.exercises[1].lines)
      eq({ "Text." }, lesson.exercises[2].lines)
    end)

    it("lists the keys of an exercise as the tutor shows them", function()
      local keys = playground.keys({ { at = "x" }, { key = "{{org.cycle}}" }, { type = "Pears" } }, function(k)
        return k == "{{org.cycle}}" and "<Tab>" or k
      end)
      eq('<kbd>&lt;Tab&gt;</kbd> <span class="pg-typed">Pears</span>', keys)
    end)

    it("names a lesson by its number and title, without the tutor's prefix", function()
      eq({ "1", "The basics" }, { playground.short_title("org.nvim tutor 1: the basics") })
      eq(
        { "2", "Capture, agenda and clocking" },
        { playground.short_title("org.nvim tutor 2: capture, agenda and clocking") }
      )
      eq({ nil, "Something else" }, { playground.short_title("something else") })
    end)

    it("reads the exercises' times and the length of a recording", function()
      local cast = table.concat({
        '{"version":2,"width":80,"height":24}',
        '[0,"m","Welcome"]',
        '[0.5,"o","x"]',
        '[4.25,"m","1.1 Fold"]',
        '[61.9,"o","y"]',
      }, "\n")
      local tl = playground.timeline(cast)
      eq({ { label = "Welcome", t = 0 }, { label = "1.1 Fold", t = 4.25 } }, tl.markers)
      -- the player holds the last frame for 2 s
      eq(63.9, tl.duration)
      eq({ "Welcome", "1.1 Fold" }, playground.markers(cast))
      -- rounded down, as the player shows it
      eq("1:03", playground.clock(tl.duration))
      eq("0:04", playground.clock(4.25))
    end)

    it("builds lesson cards and an exercise list with times", function()
      local page = playground.build(root, {
        err = function(fmt, ...)
          error(string.format(fmt, ...))
        end,
        blob = function(path)
          return "https://example.invalid/" .. path
        end,
      })
      for _, name in ipairs(playground.lessons(root)) do
        local tab = page.body:match('<button type="button" role="tab" id="tab%-' .. name .. '".-</button>')
        ok(tab, "no tab for " .. name)
        ok(tab:find('<span class="pg%-tab%-num">Lesson %d+</span>'), tab)
        ok(tab:find('<span class="pg%-tab%-meta">%d+ exercises? · %d+:%d%d</span>'), tab)
      end
      ok(page.body:find('<span class="pg-step-time">0:00</span>', 1, true))
      ok(page.body:find('class="pg-install"', 1, true))
    end)
  end)
end)
