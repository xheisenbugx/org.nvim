---@mod org.babel.lang.lilypond LilyPond blocks (ob-lilypond)
---
--- Basic mode: a block is engraved to its :file. Arrange mode
--- (`arrange_mode`, `:Org babel_lilypond_toggle_arrange_mode`): evaluating
--- a block tangles every lilypond block of the file to FILE.ly, engraves
--- it and shows the PDF and plays the MIDI file.

local ob = require("org.babel.ob")
local lisp = require("org.babel.lisp")
local utils = require("org.utils")

local M = {}

local function opts()
  return ob.opts("lilypond") or {}
end

--- `org-babel-lilypond-commands`: lilypond, the PDF viewer and the MIDI
--- player.
function M.commands()
  local c = opts().commands
  if c then
    return c
  end
  if vim.fn.has("mac") == 1 then
    return { "/Applications/lilypond.app/Contents/Resources/bin/lilypond", "open", "open" }
  elseif vim.fn.has("win32") == 1 then
    return { "lilypond", "", "" }
  end
  return { "lilypond", "xdg-open", "xdg-open" }
end

M.BASIC_HEADER_ARGS = { results = "file", exports = "results" }
M.ARRANGE_HEADER_ARGS = { tangle = "yes", noweb = "yes", results = "silent", cache = "yes", comments = "yes" }

--- `org-babel-lilypond-set-header-args`
function M.set_header_args(arrange)
  local o = opts()
  o.default_header_args = vim.deepcopy(arrange and M.ARRANGE_HEADER_ARGS or M.BASIC_HEADER_ARGS)
end

--- `org-babel-expand-body:lilypond`: `$name` replaced by the value.
function M.expand(body, args, vars)
  local text = ob.body_text(body)
  for _, v in ipairs(vars) do
    local val = type(v.value) == "string" and v.value or lisp.prin1(v.value)
    text = text:gsub("%$" .. vim.pesc(v.name), (val:gsub("%%", "%%%%")))
  end
  local prologue, epilogue = ob.unq(args.prologue), ob.unq(args.epilogue)
  return (prologue and (prologue .. "\n") or "") .. text .. (epilogue and ("\n" .. epilogue .. "\n") or "")
end

M.PAPER_SETTINGS = [[#(if (ly:get-option 'use-paper-size-for-page)
            (begin (ly:set-option 'use-paper-size-for-page #f)
                   (ly:set-option 'tall-page-formats '%s)))
\paper {
  indent=0\mm
  tagline=""
  oddFooterMarkup=##f
  oddHeaderMarkup=##f
  bookTitleMarkup=##f
  scoreTitleMarkup=##f
}
]]

--- `org-babel-lilypond-process-basic`
local function process_basic(body, args)
  local out_file = ob.unq(args.file)
  if not out_file or out_file == "" then
    error("Wrong type argument: stringp, nil (lilypond blocks need a :file)", 0)
  end
  local file_type = out_file:match("%.([^./]+)$") or ""
  local cmdline = ob.unq(args.cmdline) or ""
  local in_file = ob.temp()
  ob.write(
    in_file,
    M.PAPER_SETTINGS:gsub("%%s", function()
      return file_type
    end) .. ob.expand_generic(type(body) == "table" and body or { body }, args, {})
  )
  local kind = ({ pdf = "--pdf ", eps = "--eps " })[file_type] or "--png "
  local cmd = M.commands()[1]
    .. " -dbackend=eps "
    .. "-dno-gs-load-fonts "
    .. "-dinclude-eps-fonts "
    .. kind
    .. "--output="
    .. out_file:gsub("%.[^./]*$", "")
    .. " "
    .. cmdline
    .. in_file
  return {
    steps = { { cmd = cmd } },
    convert = function()
      return nil
    end,
  }
end

--- Parse the line number of an error in the lilypond output
--- (`org-babel-lilypond-parse-line-num`: FILE:LINE:COL: error: ...).
function M.parse_line_num(output)
  local before = output:match("^(.*)error:")
  if not before then
    return nil
  end
  local line = before:match(":(%d+):%d+:%s*$")
  return tonumber(line)
end

--- Show the PDF / play the MIDI file of `file` (.ly) when the options
--- ask for it.
local function open_results(file)
  local o = opts()
  local cmds = M.commands()
  local base = file:gsub("%.[^./]*$", "")
  if o.display_pdf_post_tangle ~= false then
    local pdf = base .. ".pdf"
    if vim.fn.filereadable(pdf) == 1 then
      if cmds[2] ~= "" then
        vim.system({ cmds[2], pdf }, { detach = true })
      end
    else
      utils.notify("No pdf file generated so can't display!")
    end
  end
  if o.play_midi_post_tangle ~= false then
    local midi = base .. (vim.fn.has("win32") == 1 and ".mid" or ".midi")
    if vim.fn.filereadable(midi) == 1 then
      if cmds[3] ~= "" then
        vim.system({ cmds[3], midi }, { detach = true })
      end
    else
      utils.notify("No midi file generated so can't play!")
    end
  end
end

--- `org-babel-lilypond-compile-lilyfile`: returns lilypond's output.
function M.compile_lilyfile(file)
  local o = opts()
  utils.notify("Compiling " .. file .. "...")
  local args = { M.commands()[1] }
  if o.gen_png then
    args[#args + 1] = "--png"
  end
  if o.gen_html then
    args[#args + 1] = "--html"
  end
  if o.gen_pdf then
    args[#args + 1] = "--pdf"
  end
  if o.use_eps then
    args[#args + 1] = "-dbackend=eps"
  end
  if o.gen_svg then
    args[#args + 1] = "-dbackend=svg"
  end
  args[#args + 1] = "--output=" .. file:gsub("%.[^./]*$", "")
  args[#args + 1] = file
  local ok, res = pcall(function()
    return vim.system(args, { text = true, cwd = vim.fn.fnamemodify(file, ":h") }):wait()
  end)
  if not ok then
    return tostring(res)
  end
  return (res.stdout or "") .. (res.stderr or "")
end

--- `org-babel-lilypond-execute-tangled-ly`
function M.execute_tangled_ly(bufnr)
  local o = opts()
  if o.compile_post_tangle == false then
    return
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  local base = name:gsub("%.[^./]*$", "")
  local tangled, ly = base .. ".lilypond", base .. ".ly"
  if vim.fn.filereadable(tangled) == 0 then
    error("Error: Tangle Failed!", 0)
  end
  os.remove(ly)
  vim.uv.fs_rename(tangled, ly)
  local output = M.compile_lilyfile(ly)
  -- the *lilypond* buffer
  local lb = vim.fn.bufnr("*lilypond*")
  if lb == -1 then
    lb = vim.api.nvim_create_buf(false, true)
    pcall(vim.api.nvim_buf_set_name, lb, "*lilypond*")
  end
  vim.api.nvim_buf_set_lines(lb, 0, -1, false, vim.split(output, "\n", { plain = true }))
  if output:find("error:", 1, true) then
    -- org-babel-lilypond-process-compile-error: find the line in the Org buffer
    local n = M.parse_line_num(output)
    if n and n > 0 then
      local line = (vim.fn.readfile(ly)[n] or "")
      if line ~= "" then
        for i, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
          local s = l:find(line, 1, true)
          if s then
            for _, w in ipairs(vim.fn.win_findbuf(bufnr)) do
              vim.api.nvim_win_set_cursor(w, { i, s - 1 })
            end
            break
          end
        end
      end
    end
    error("Error: Compilation Failed!", 0)
  end
  open_results(ly)
end

--- `org-babel-lilypond-tangle`: tangle the lilypond blocks, then engrave.
function M.tangle(bufnr)
  bufnr = (bufnr and bufnr ~= 0) and bufnr or vim.api.nvim_get_current_buf()
  local written = require("org.babel.tangle").tangle({
    bufnr = bufnr,
    default_tangle = "yes",
    lang_re = "^lilypond$",
    silent = true,
  })
  if #written > 0 then
    local ok, err = pcall(M.execute_tangled_ly, bufnr)
    if not ok then
      utils.error(tostring(err))
      return nil
    end
    return true
  end
  return nil
end

function M.prepare(body, args, _, ctx)
  -- like Emacs, the header arguments of the mode apply from the next block
  M.set_header_args(opts().arrange_mode)
  if opts().arrange_mode then
    M.tangle(ctx.bufnr)
    return { value = nil }
  end
  return process_basic(body, args)
end

---------------------------------------------------------------------------
-- Toggles
---------------------------------------------------------------------------

local function toggle(key, label)
  local o = opts()
  o[key] = not o[key]
  utils.notify(label .. (o[key] and "ENABLED." or "DISABLED."))
  return o[key]
end

function M.toggle_midi_play()
  return toggle("play_midi_post_tangle", "Post-Tangle MIDI play has been ")
end

function M.toggle_pdf_display()
  return toggle("display_pdf_post_tangle", "Post-Tangle PDF display has been ")
end

function M.toggle_png_generation()
  return toggle("gen_png", "PNG image generation has been ")
end

function M.toggle_html_generation()
  return toggle("gen_html", "HTML generation has been ")
end

function M.toggle_pdf_generation()
  return toggle("gen_pdf", "PDF generation has been ")
end

function M.toggle_arrange_mode()
  local on = toggle("arrange_mode", "Arrange mode has been ")
  M.set_header_args(on)
  return on
end

return M
