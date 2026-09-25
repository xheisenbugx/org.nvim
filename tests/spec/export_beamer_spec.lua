local ox = require("org.export.ox")
local config = require("org.config")
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local dir = root .. "/fixtures/export/beamer/"

local function norm(s)
  return (s:gsub("org%x%x%x%x%x%x%x", "orgREF"):gsub("%s+$", ""))
end

local function read(name)
  return table.concat(vim.fn.readfile(dir .. name), "\n")
end

local function export(name, body_only)
  local file = dir .. name
  return ox.export_as("beamer", vim.fn.readfile(file), { filename = file, body_only = body_only })
end

describe("export beamer (Emacs ox-beamer parity)", function()
  before_each(function()
    config.opts.babel.evaluate_on_export = false
  end)

  it("frames, sections, blocks, columns, notes and againframe (body)", function()
    eq(norm(read("frames.body.tex")), norm(export("frames.org", true)))
  end)

  it("full document with themes, subtitle, header and outline frame", function()
    eq(norm(read("frames.tex")), norm(export("frames.org", false)))
  end)

  it("frame options, subtitles, environments, columns env, appendix, links and targets", function()
    eq(norm(read("envs.body.tex")), norm(export("envs.org", true)))
  end)

  it("frame level from BEAMER_env, fragile orgframe, overlays, TOC keyword and noteNH", function()
    eq(norm(read("misc.body.tex")), norm(export("misc.org", true)))
  end)

  it("defines the alternative frame environment when needed", function()
    local out = export("misc.org", false)
    ok(out:find("\\newenvironment<>{orgframe}[1][]{\\begin{frame}#2[environment=orgframe,#1]}{\\end{frame}}", 1, true), out)
  end)

  it("honours export.beamer options", function()
    config.opts.export.beamer = {
      frame_level = 1,
      outline_frame_title = "Plan",
      outline_frame_options = "allowframebreaks",
      frame_default_options = "t",
      environments_extra = { { "mybox", "m", "\\begin{mybox}%a{%h}", "\\end{mybox}" } },
    }
    local lines = { "#+OPTIONS: toc:t", "* F", "** Box", ":PROPERTIES:", ":BEAMER_env: mybox", ":END:", "x" }
    local ok_, out = pcall(ox.export_as, "beamer", lines, {})
    config.opts.export.beamer = nil
    ok(ok_, out)
    ok(out:find("\\begin{frame}[allowframebreaks]{Plan}", 1, true), out)
    ok(out:find("\\begin{frame}%[label={sec:org%x+},t%]{F}"), out)
    ok(out:find("\\begin{mybox}{Box}\nx\n\\end{mybox}", 1, true), out)
  end)

  it("errors on unknown block environments", function()
    local lines = { "* F", "** B", ":PROPERTIES:", ":BEAMER_env: nosuchenv", ":END:" }
    local ok_, err = pcall(ox.export_as, "beamer", lines, { body_only = true })
    ok(not ok_ and tostring(err):find("Wrong block type", 1, true), tostring(err))
  end)
end)
