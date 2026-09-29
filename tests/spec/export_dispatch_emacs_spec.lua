-- Export dispatcher options, the export stack, region conversion and
-- other ox.el options. Expected export output comes from Emacs Org 9.8.10
-- (emacs -Q --batch, org-export-string-as / org-*-convert-region-to-*).
local export = require("org.export")
local config = require("org.config")
local utils = require("org.utils")
local ui = require("org.ui")

--- Set export options (dotted keys) for one test and return a restore function.
local function set_export(opts)
  local saved = {}
  for key, v in pairs(opts) do
    local t, k = config.opts.export, key
    local sub, rest = key:match("^(%w+)%.(.+)$")
    if sub then
      t, k = config.opts.export[sub], rest
    end
    saved[#saved + 1] = { t, k, t[k] }
    t[k] = v
  end
  return function()
    for i = #saved, 1, -1 do
      local s = saved[i]
      s[1][s[2]] = s[3]
    end
  end
end

local function body(fmt, lines)
  return export.to_string(fmt, { lines = lines, body_only = true })
end

describe("export dispatch (Emacs parity)", function()
  local restore
  before_each(function()
    config.opts.babel.evaluate_on_export = false
  end)
  after_each(function()
    if restore then
      restore()
      restore = nil
    end
    config.opts.babel.evaluate_on_export = true
  end)

  describe("convert region in place", function()
    local region = { "before", "Some *bold* text -- here.", '- item "q"', "after" }
    -- org-*-convert-region-to-* on lines 2-3 of `region`, from Emacs 9.8.10
    local expected = {
      html = {
        "before",
        "<p>",
        "Some <b>bold</b> text &ndash; here.",
        "</p>",
        '<ul class="org-ul">',
        '<li>item "q"</li>',
        "</ul>",
        "after",
      },
      latex = {
        "before",
        "Some \\textbf{bold} text -- here.",
        "\\begin{itemize}",
        '\\item item "q"',
        "\\end{itemize}",
        "after",
      },
      md = {
        "before",
        "",
        "# Table of Contents",
        "",
        "",
        "",
        "Some **bold** text &ndash; here.",
        "",
        '-   item "q"',
        "",
        "after",
      },
      ascii = { "before", "Some *bold* text -- here.", '- item "q"', "after" },
      utf8 = { "before", "Some *bold* text – here.", '• item "q"', "after" },
      texinfo = { "before", "after" },
    }
    for fmt, want in pairs(expected) do
      it("replaces lines by their " .. fmt .. " export (:[range]Org convert_region)", function()
        local buf = org_buffer(region, { 1, 0 })
        export.convert_region_command(fmt, { range = 2, line1 = 2, line2 = 3 })
        eq(want, buf_lines(buf))
      end)
    end

    it("has the org-export-region-to-* aliases", function()
      local buf = org_buffer(region, { 1, 0 })
      export.export_region_to_utf8(nil, { range = 2, line1 = 2, line2 = 3 })
      eq(expected.utf8, buf_lines(buf))
    end)

    local function charwise(fmt, srow, scol, erow, ecol)
      local vr, mode = utils.visual_range, vim.fn.mode
      utils.visual_range = function()
        return srow, scol, erow, ecol, "v"
      end
      vim.fn.mode = function()
        return "v"
      end
      local ok, err = pcall(export["convert_region_to_" .. fmt])
      utils.visual_range, vim.fn.mode = vr, mode
      assert(ok, err)
    end

    it("converts a characterwise selection like an Emacs region (html)", function()
      local buf = org_buffer({ "Intro *bold* end." }, { 1, 0 })
      charwise("html", 1, 7, 1, 12)
      -- Emacs: "Intro <p>\n<b>bold</b></p>\n end.\n"
      eq({ "Intro <p>", "<b>bold</b></p>", " end." }, buf_lines(buf))
    end)

    it("converts a characterwise selection like an Emacs region (latex)", function()
      local buf = org_buffer({ "Intro *bold* end." }, { 1, 0 })
      charwise("latex", 1, 7, 1, 12)
      eq({ "Intro \\textbf{bold}", " end." }, buf_lines(buf))
    end)

    it("is not applicable without a selection", function()
      local buf = org_buffer({ "text" }, { 1, 0 })
      local warn = utils.warn
      utils.warn = function() end
      eq(false, export.convert_region_to_html())
      utils.warn = warn
      eq({ "text" }, buf_lines(buf))
    end)
  end)

  describe("ox options", function()
    it("leaves citations alone without org-export-process-citations", function()
      restore = set_export({ process_citations = false })
      eq("<p>\nText here.\n</p>\n", body("html", { "Text [cite:@key] here." }))
      eq("Text here.\n", body("latex", { "Text [cite:@key] here." }))
    end)

    it("keeps macros unexpanded without org-export-replace-macros", function()
      restore = set_export({ replace_macros = false })
      local src = { "#+macro: foo bar", "Text {{{foo}}} {{{title}}} here." }
      eq("<p>\nText here.\n</p>\n", body("html", src))
      eq("Text here.\n", body("ascii", src))
    end)

    it("aborts on a macro when Babel replaces only {{{results}}}", function()
      restore = set_export({ replace_macros = false })
      config.opts.babel.evaluate_on_export = true
      local ok, err = pcall(body, "ascii", { "#+macro: foo bar", "Text {{{foo}}} here." })
      eq(false, ok)
      eq("Undefined Org macro: foo; aborting", err)
    end)

    it("uses org-export-smart-quotes-alist for a language", function()
      restore = set_export({
        with_smart_quotes = true,
        smart_quotes_alist = {
          en = {
            primary_opening = { ["utf-8"] = "<<", html = "&laquo;" },
            primary_closing = { ["utf-8"] = ">>", html = "&raquo;" },
          },
        },
      })
      eq("<p>\nHe said &laquo;hi&raquo; and 'x' it's\n</p>\n", body("html", { "He said \"hi\" and 'x' it's" }))
    end)

    it("formats html5 <time> with org-html-datetime-formats", function()
      restore = set_export({
        ["html.datetime_formats"] = { "%d/%m/%Y", "%d/%m/%Y %H.%M" },
        ["html.html5_fancy"] = true,
        ["html.doctype"] = "html5",
      })
      local out = body("html", { "<2026-03-04 Wed> and [2026-03-05 Thu 10:30]" })
      ok(out:find('<time class="timestamp" datetime="04/03/2026">&lt;2026-03-04 Wed&gt;</time>', 1, true), out)
      ok(out:find('<time class="timestamp" datetime="05/03/2026 10.30">[2026-03-05 Thu 10:30]</time>', 1, true), out)
    end)

    it("uses org-html-infojs-template", function()
      restore = set_export({ ["html.infojs_template"] = "INFOJS %SCRIPT_PATH|%MANAGER_OPTIONS" })
      local out = export.to_string("html", { lines = { "#+infojs_opt: view:info toc:nil path:js/x.js", "text" } })
      local want = table.concat({
        'INFOJS js/x.js|org_html_manager.set("TOC_DEPTH", "3");',
        'org_html_manager.set("LINK_HOME", "");',
        'org_html_manager.set("LINK_UP", "");',
        'org_html_manager.set("LOCAL_TOC", "1");',
        'org_html_manager.set("VIEW_BUTTONS", "0");',
        'org_html_manager.set("MOUSE_HINT", "underline");',
        'org_html_manager.set("FIXED_TOC", "0");',
        'org_html_manager.set("TOC", "0");',
        'org_html_manager.set("VIEW", "info");',
        "</head>",
      }, "\n")
      ok(out:find(want, 1, true), out)
    end)

    it("writes org-latex-compiler-file-string", function()
      restore = set_export({
        ["latex.compiler_file_string"] = "%% -*- latex-run-command: %s -*-\n",
        timestamp_file = false,
      })
      local out = export.to_string("latex", { lines = { "#+latex_compiler: xelatex", "text" } })
      eq("% -*- latex-run-command: xelatex -*-\n\\documentclass", out:sub(1, 51))
      restore()
      restore = set_export({ ["latex.compiler_file_string"] = false, timestamp_file = false })
      out = export.to_string("latex", { lines = { "#+latex_compiler: xelatex", "text" } })
      eq("\\documentclass[11pt]{article}", out:sub(1, 29))
    end)

    it("reports org-latex-known-warnings from the log", function()
      local latex = require("org.export.latex")
      restore = set_export({ ["latex.known_warnings"] = { { "Custom thing", "[custom]" } } })
      local warnings = latex.log_warnings("line\nCustom thing happened\nOverfull \\hbox (1pt)\n")
      eq({ "[custom]" }, warnings)
    end)
  end)

  describe("dispatcher", function()
    local menu, getcharstr
    before_each(function()
      menu, getcharstr = ui.menu, vim.fn.getcharstr
    end)
    after_each(function()
      ui.menu, vim.fn.getcharstr = menu, getcharstr
    end)

    local function labels(items)
      local out = {}
      for _, it in ipairs(items) do
        out[it.key] = it.label
      end
      return out
    end

    it("starts from the org-export-* dispatcher options", function()
      restore = set_export({
        initial_scope = "subtree",
        body_only = true,
        visible_only = true,
        force_publishing = true,
        in_background = true,
      })
      org_buffer({ "* H", "text" }, { 1, 0 })
      local seen
      ui.menu = function(o)
        seen = labels(o.items)
        return nil
      end
      export.prompt()
      eq("Toggle: body only = on", seen.b)
      eq("Toggle: export scope = subtree", seen.s)
      eq("Toggle: visible only = on", seen.v)
      eq("Toggle: force publishing = on", seen.f)
      eq("Toggle: async export = on", seen.a)
    end)

    it("passes the force toggle to publishing", function()
      org_buffer({ "* H" }, { 1, 0 })
      local pub = require("org.export.publish")
      local orig = pub.publish_current_file
      local got
      pub.publish_current_file = function(force, async)
        got = { force, async }
      end
      local answers = { { toggle = "force" }, { publish = "file" } }
      ui.menu = function()
        return table.remove(answers, 1)
      end
      export.prompt()
      pub.publish_current_file = orig
      eq({ true, nil }, got)
    end)

    it("reads keys from a prompt with org-export-dispatch-use-expert-ui", function()
      restore = set_export({ dispatch_use_expert_ui = true })
      org_buffer({ "* H", "text" }, { 1, 0 })
      ui.menu = function()
        error("the menu must not be shown")
      end
      local keys = { "\2", "t", "A" } -- C-b, then t A (ASCII buffer)
      vim.fn.getcharstr = function()
        return table.remove(keys, 1)
      end
      local got
      local orig = export.export
      export.export = function(fmt, opts)
        got = { fmt, opts.body_only, opts.to_buffer }
      end
      export.prompt()
      export.export = orig
      eq({ "ascii", true, true }, got)
    end)

    it("switches from the expert prompt to the menu with ?", function()
      restore = set_export({ dispatch_use_expert_ui = true })
      org_buffer({ "* H" }, { 1, 0 })
      local shown = false
      ui.menu = function()
        shown = true
        return nil
      end
      local keys = { "?" }
      vim.fn.getcharstr = function()
        return table.remove(keys, 1) or "\27"
      end
      export.prompt()
      ok(shown)
    end)
  end)

  describe("export buffers and output", function()
    it("keeps the buffer hidden without org-export-show-temporary-export-buffer", function()
      restore = set_export({ show_temporary_export_buffer = false })
      org_buffer({ "text" }, { 1, 0 })
      local wins = #vim.api.nvim_list_wins()
      eq("buffer", export.export("ascii", { to_buffer = true, body_only = true }))
      eq(wins, #vim.api.nvim_list_wins())
      eq({ "text" }, vim.api.nvim_buf_get_lines(export.last_buffer, 0, -1, false))
      vim.api.nvim_buf_delete(export.last_buffer, { force = true })
    end)

    it("copies the output with org-export-copy-to-kill-ring", function()
      org_buffer({ "copied text" }, { 1, 0 })
      vim.fn.setreg('"', "none")
      restore = set_export({ show_temporary_export_buffer = false, copy_to_kill_ring = "if-interactive" })
      export.export("ascii", { to_buffer = true, body_only = true })
      eq("none", vim.fn.getreg('"'))
      export.export("ascii", { to_buffer = true, body_only = true, interactive = true })
      eq("copied text\n", vim.fn.getreg('"'))
      restore()
      restore = set_export({ show_temporary_export_buffer = false, copy_to_kill_ring = true })
      vim.fn.setreg('"', "none")
      export.export("ascii", { to_buffer = true, body_only = true })
      eq("copied text\n", vim.fn.getreg('"'))
    end)

    it("writes files in org-export-coding-system", function()
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir, "p")
      local buf = org_buffer({ "café" }, { 1, 0 })
      vim.api.nvim_buf_set_name(buf, dir .. "/x.org")
      restore = set_export({ coding_system = "latin1", open_after_export = false })
      local notify = utils.notify
      utils.notify = function() end
      local out = export.export("utf8", { body_only = true })
      utils.notify = notify
      local fd = assert(io.open(out, "rb"))
      local bytes = fd:read("*a")
      fd:close()
      eq("caf\233\n", bytes)
    end)
  end)

  describe("export stack", function()
    before_each(function()
      export.stack_clear()
    end)

    it("lists background exports and removes stale entries", function()
      local f = vim.fn.tempname()
      vim.fn.writefile({ "x" }, f)
      export.stack_add(f, "html")
      local buf = vim.api.nvim_create_buf(true, true)
      export.stack_add(buf, "ascii")
      local lines = export.stack_lines()
      eq(2, #lines)
      ok(lines[1]:match("^1    ascii        0:00   "), lines[1])
      ok(lines[2]:match("^2    html         0:00   " .. vim.pesc(f) .. "$"), lines[2])
      vim.api.nvim_buf_delete(buf, { force = true })
      eq(1, #export.stack_lines())
      -- adding the same source again moves it to the top, once
      export.stack_add(f, "html")
      eq(1, #export.stack_contents)
      export.stack_clear()
      eq({}, export.stack_lines())
    end)

    it("shows the stack in a buffer with view / remove keys", function()
      local f = vim.fn.tempname()
      vim.fn.writefile({ "x" }, f)
      export.stack_add(f, "latex")
      local notify = utils.notify
      utils.notify = function() end
      local buf = export.stack_show()
      utils.notify = notify
      eq(1, #vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      export.stack_remove()
      eq({ "" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      vim.cmd("close")
    end)

    it("puts the result of an asynchronous export on the stack", function()
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir, "p")
      local buf = org_buffer({ "text" }, { 1, 0 })
      vim.api.nvim_buf_set_name(buf, dir .. "/a.org")
      restore = set_export({ open_after_export = false })
      local notify = utils.notify
      utils.notify = function() end
      local entry = export.export_async("ascii", {})
      eq(true, entry.running)
      eq("run", export.stack_lines()[1]:match("^1%s+ascii%s+(%S+)"))
      vim.wait(2000, function()
        return not entry.running
      end)
      utils.notify = notify
      ok(entry.source:match("/a%.txt$"), entry.source)
      eq(1, #export.stack_lines())
    end)

    it("exports in a separate Neovim with export.async_init_file", function()
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir, "p")
      local marker = dir .. "/marker"
      vim.fn.writefile(
        { string.format("vim.fn.writefile({ tostring(vim.fn.getpid()) }, %q)", marker) },
        dir .. "/init.lua"
      )
      local buf = org_buffer({ "* H", "body text" }, { 1, 0 })
      vim.api.nvim_buf_set_name(buf, dir .. "/b.org")
      restore = set_export({ open_after_export = false, async_init_file = dir .. "/init.lua" })
      local notify = utils.notify
      utils.notify = function() end
      local entry = export.export_async("ascii", { to_buffer = true, body_only = true })
      vim.wait(5000, function()
        return not entry.running
      end)
      utils.notify = notify
      -- the init file ran in another process
      local pid = tonumber(vim.fn.readfile(marker)[1])
      ok(pid and pid ~= vim.fn.getpid())
      eq("number", type(entry.source))
      local lines = vim.api.nvim_buf_get_lines(entry.source, 0, -1, false)
      eq({ "1 H", "===", "", "  body text" }, lines)
      -- not shown
      eq(-1, vim.fn.bufwinid(entry.source))
      vim.api.nvim_buf_delete(entry.source, { force = true })
    end)
  end)
end)
