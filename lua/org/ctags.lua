---@mod org.ctags Plain links through tags files (org-ctags)
---
--- Like Emacs org-ctags: `<<targets>>` in Org files become tags (the
--- `ctags` program writes them into a `tags` file next to the file), and a
--- plain link `[[foo]]` is looked up with Neovim's tag machinery (`:tag`,
--- |taglist()|, the 'tags' option; CTRL-T goes back). When nothing is
--- found, `ctags.open_link_functions` decide what happens (rebuild the
--- tags and try again, create a new topic, ...). Turn it on with
--- `ctags.enabled = true` (Emacs: org-ctags-enable). See |org-ctags|.

local config = require("org.config")
local utils = require("org.utils")

local M = {}

local function cfg()
  return config.opts.ctags or {}
end

--- The ctags program (org-ctags-path-to-ctags): `ctags.path_to_ctags`,
--- else ctags-exuberant when installed, else ctags.
---@return string
function M.program()
  local p = cfg().path_to_ctags
  if p and p ~= "" then
    return p
  end
  return vim.fn.executable("ctags-exuberant") == 1 and "ctags-exuberant" or "ctags"
end

--- `name` made absolute like expand-file-name: relative to the directory
--- of the current buffer's file (Emacs's default-directory), else the
--- current directory.
local function absolute(name)
  name = vim.fs.normalize(name)
  if not utils.is_absolute(name) then
    local file = vim.api.nvim_buf_get_name(0)
    local base = file ~= "" and vim.fn.fnamemodify(file, ":p:h") or vim.fn.getcwd()
    name = base .. "/" .. name
  end
  return vim.fs.normalize(vim.fn.fnamemodify(name, ":p"))
end

--- Emacs's `capitalize`: each word starts upper case, the rest lower case.
local function capitalize(s)
  return (s:gsub("(%w)(%w*)", function(a, b)
    return a:upper() .. b:lower()
  end))
end

--- The text of a new topic (org-ctags-new-topic-template, `%t` = the
--- capitalized title).
local function topic_text(title)
  local tpl = cfg().new_topic_template or "* <<%t>>\n\n\n\n\n\n"
  return (tpl:gsub("%%t", function()
    return capitalize(title)
  end))
end

--- (Re)create the tags file of `dir` (default: the directory of the
--- current file) with the tags of every file below it, `<<targets>>` of
--- Org files included (org-ctags-create-tags). Neovim reads the `tags`
--- file (Vim format) where Emacs uses `TAGS`.
---@param dir? string
---@return boolean ok
function M.create_tags(dir)
  if not dir then
    local name = vim.api.nvim_buf_get_name(0)
    if name == "" then
      utils.error("org-ctags: the buffer has no file")
      return false
    end
    dir = vim.fn.fnamemodify(name, ":p:h")
  end
  dir = absolute(dir):gsub("/$", "")
  local cmd = {
    M.program(),
    "--langdef=orgmode",
    "--langmap=orgmode:.org",
    "--regex-orgmode=" .. (cfg().tag_regexp or [[/<<([^<>]+)>>/\1/d,definition/]]),
    "-f",
    dir .. "/tags",
    "-R",
    dir,
  }
  local ok, res = pcall(function()
    return vim.system(cmd, { text = true, cwd = dir }):wait(60000)
  end)
  -- like Emacs, a failing exit code is not an error
  return ok and res ~= nil and res.code == 0
end

--- Every tag of the tags files of the current buffer ('tags' option)
--- (org-ctags-all-tags-in-current-tags-table), sorted, without duplicates.
---@return string[]
function M.all_tags()
  local seen, out = {}, {}
  local ok, list = pcall(vim.fn.taglist, ".")
  for _, t in ipairs(ok and list or {}) do
    if not seen[t.name] then
      seen[t.name] = true
      out[#out + 1] = t.name
    end
  end
  table.sort(out)
  return out
end

--- Where `tag` is defined (org-ctags-get-filename-for-tag): `{ filename,
--- cmd }` of the first match in the tags files, or nil.
---@param tag string
---@return { filename: string, cmd: string }|nil
function M.get_filename_for_tag(tag)
  local ok, list = pcall(vim.fn.taglist, "^" .. vim.fn.escape(tag, [[\.*$^~[]]) .. "$")
  local t = ok and list[1] or nil
  return t and { filename = t.filename, cmd = t.cmd } or nil
end

--- Jump to the tag `name` with `:tag` (org-ctags-find-tag). Returns true
--- when found; the cursor stays put otherwise.
---@param name string
---@return boolean
function M.find_tag(name)
  if not name or name == "" or not M.get_filename_for_tag(name) then
    return false
  end
  return (pcall(vim.cmd.tag, { args = { name }, mods = { silent = true } }))
end

--- Insert `text` at Emacs's point-max: after the last line (whose newline
--- ends it), or in place of an empty buffer's only line.
local function insert_at_end(buf, text)
  local lines = vim.split(text, "\n", { plain = true })
  if lines[#lines] == "" then
    lines[#lines] = nil -- the final newline ends the last line
  end
  local n = vim.api.nvim_buf_line_count(buf)
  if n == 1 and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "" then
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, lines)
  else
    vim.api.nvim_buf_set_lines(buf, n, n, false, lines)
  end
end

--- Open `name` (an Org file) and add a new topic at its end
--- (org-ctags-open-file): the new-topic template, titled `title` or
--- `name`.
---@param name string
---@param title? string
function M.open_file(name, title)
  vim.cmd("edit " .. vim.fn.fnameescape(absolute(name)))
  local buf = vim.api.nvim_get_current_buf()
  insert_at_end(buf, topic_text(title or name))
  vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(buf), 0 })
  return buf
end

--- Visit the buffer `name.org`, else the file `name.org` (in the current
--- directory) (org-ctags-visit-buffer-or-file). A missing file is created
--- with a new topic when `create` is true, or "ask" and confirmed.
---@param name string
---@param create? boolean|"ask"
---@return boolean visited
function M.visit_buffer_or_file(name, create)
  local filename = absolute(name) .. ".org"
  -- a buffer called NAME.org (Emacs buffer names are file names)
  local buf
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.fn.buflisted(b) == 1 and vim.fn.fnamemodify(vim.api.nvim_buf_get_name(b), ":t") == name .. ".org" then
      buf = b
      break
    end
  end
  if buf then
    vim.api.nvim_set_current_buf(buf)
    return true
  elseif utils.exists(filename) then
    utils.notify(string.format("Opening existing org file %q...", filename))
    vim.cmd("edit " .. vim.fn.fnameescape(filename))
    return true
  elseif
    create == true or (create == "ask" and utils.confirm(string.format("File `%s.org' not found; create?", name)))
  then
    M.open_file(filename, name)
    return true
  end
  return false
end

--- Append a new top-level topic for `name` at the end of the current
--- buffer (org-ctags-append-topic): two newlines and the new-topic
--- template; the cursor lands where Emacs puts it.
---@param name string
---@return boolean
function M.append_topic(name)
  local buf = vim.api.nvim_get_current_buf()
  local before = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local topic = topic_text(name)
  insert_at_end(buf, "\n\n" .. topic)
  utils.notify("Adding topic in buffer " .. vim.fn.bufname(buf))
  -- Emacs: from point-max, backward-char 4, end-of-line, forward-line 2,
  -- done on the text Emacs has (the old text ends with a newline)
  local pre = (#before == 1 and before[1] == "") and "" or table.concat(before, "\n") .. "\n"
  local full = pre .. "\n\n" .. topic
  local prefix = vim.fn.strcharpart(full, 0, math.max(0, vim.fn.strchars(full) - 4))
  local _, nl_before = prefix:gsub("\n", "")
  local _, nl = full:gsub("\n", "")
  local total = vim.api.nvim_buf_line_count(buf)
  local target = nl_before + 1 + 2
  if target <= nl then
    vim.api.nvim_win_set_cursor(0, { target, 0 })
  elseif full:sub(-1) == "\n" then
    -- point-max after the final newline: the start of the last line here
    vim.api.nvim_win_set_cursor(0, { total, 0 })
  else
    -- point-max: the end of the last line
    local last = vim.api.nvim_buf_get_lines(buf, total - 1, total, false)[1]
    vim.api.nvim_win_set_cursor(0, { total, math.max(0, #last - 1) })
  end
  return true
end

--- The functions of `ctags.open_link_functions`, by name.
M.link_functions = {
  find_tag = M.find_tag,
  rebuild_tags_file_then_find_tag = function(name)
    if vim.api.nvim_buf_get_name(0) ~= "" then
      M.create_tags()
    end
    return M.find_tag(name)
  end,
  ask_rebuild_tags_file_then_find_tag = function(name)
    local file = vim.api.nvim_buf_get_name(0)
    if file ~= "" then
      local dir = vim.fn.fnamemodify(file, ":p:h") .. "/"
      if utils.confirm(string.format("Tag `%s' not found.  Rebuild table `%stags' and look again?", name, dir)) then
        return M.link_functions.rebuild_tags_file_then_find_tag(name)
      end
    end
    return false
  end,
  append_topic = M.append_topic,
  ask_append_topic = function(name)
    if utils.confirm(string.format("Topic `%s' not found; append to end of buffer?", name)) then
      return M.append_topic(name)
    end
    return false
  end,
  visit_buffer_or_file = function(name)
    return M.visit_buffer_or_file(name)
  end,
  ask_visit_buffer_or_file = function(name)
    return M.visit_buffer_or_file(name, "ask")
  end,
  fail_silently = function()
    return true
  end,
}

--- Run `ctags.open_link_functions` for the plain link `name` until one
--- handles it (org-open-link-functions). Nil when org-ctags is off.
---@param name string
---@return boolean|nil handled
function M.open_link(name)
  if not cfg().enabled then
    return nil
  end
  for _, f in ipairs(cfg().open_link_functions or {}) do
    local fn = type(f) == "function" and f or M.link_functions[f]
    if fn and fn(name) then
      return true
    end
  end
  return false
end

--- Ask for a topic among the known tags and jump to it; an unknown one
--- goes through `ctags.open_link_functions` (org-ctags-find-tag-interactive).
function M.find_tag_interactive()
  local tags = M.all_tags()
  local tag = utils.input_complete("Topic: ", tags)
  if not tag or vim.trim(tag) == "" then
    return
  end
  tag = vim.trim(tag)
  if vim.tbl_contains(tags, tag) then
    return M.find_tag(tag)
  end
  for _, f in ipairs(cfg().open_link_functions or {}) do
    local fn = type(f) == "function" and f or M.link_functions[f]
    if fn and fn(tag) then
      return true
    end
  end
  return false
end

-- Interactive forms (the Emacs commands' prompts)

--- `:Org ctags_find_tag`: ask for a tag and jump to it.
function M.find_tag_prompt()
  local tag = utils.input_complete("Tag: ", M.all_tags())
  if tag and vim.trim(tag) ~= "" and not M.find_tag(vim.trim(tag)) then
    utils.warn("Tag not found: " .. vim.trim(tag))
  end
end

--- `:Org ctags_get_filename_for_tag`: show where a tag is defined.
function M.get_filename_for_tag_prompt()
  local tag = utils.input({ prompt = "Tag: " })
  if not tag or vim.trim(tag) == "" then
    return
  end
  local found = M.get_filename_for_tag(vim.trim(tag))
  utils.notify(found and (found.filename .. " " .. found.cmd) or ("No tag " .. vim.trim(tag)))
  return found
end

--- `:Org ctags_all_tags`: show the tags of the current tags files.
function M.all_tags_command()
  local tags = M.all_tags()
  utils.notify(#tags == 0 and "No tags" or table.concat(tags, ", "))
  return tags
end

--- `:Org ctags_open_file`: ask for a file and add a new topic to it.
function M.open_file_prompt()
  local name = utils.input({ prompt = "File name: ", completion = "file" })
  if name and vim.trim(name) ~= "" then
    return M.open_file(vim.trim(name))
  end
end

--- `:Org ctags_visit_buffer_or_file`: ask for a name and visit NAME.org.
function M.visit_buffer_or_file_prompt()
  local name = utils.input({ prompt = "Name: " })
  if name and vim.trim(name) ~= "" then
    return M.visit_buffer_or_file(vim.trim(name))
  end
end

--- `:Org ctags_append_topic`: ask for a topic and append it.
function M.append_topic_prompt()
  local name = utils.input({ prompt = "Topic: " })
  if name and vim.trim(name) ~= "" then
    return M.append_topic(vim.trim(name))
  end
end

return M
