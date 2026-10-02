-- Citations in the buffer: org-cite-insert, org-cite-follow and
-- org-cite-activate with the basic processor (oc.el, oc-basic.el).
-- Expected buffer text, cursor positions, prompts and completion
-- candidates come from Emacs Org 9.8.10 (org-cite-insert and
-- org-open-at-point with completing-read stubbed).

local cite = require("org.cite")
local utils = require("org.utils")

local root = vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h"))
local dir = root .. "/fixtures/cite"
local header = { "#+bibliography: refs.bib", "#+bibliography: refs.json", "" }

local counter = 0

--- A buffer named in the fixture directory so relative #+BIBLIOGRAPHY
--- files resolve; `text` goes after the header, cursor at 0-based offset
--- `pos` in `text`.
local function buffer(text, pos)
  local lines = vim.list_extend(vim.deepcopy(header), vim.split(text, "\n", { plain = true }))
  local buf = org_buffer(lines)
  counter = counter + 1
  vim.api.nvim_buf_set_name(buf, dir .. "/cite-test-" .. counter .. ".org")
  local before = text:sub(1, pos)
  local row = #header + select(2, before:gsub("\n", "")) + 1
  local col = #(before:match("[^\n]*$"))
  vim.api.nvim_win_set_cursor(0, { row, col })
  return buf
end

local function text_of(buf)
  local lines = buf_lines(buf)
  return table.concat(vim.list_slice(lines, #header + 1), "\n")
end

--- Cursor as a 0-based offset in the text after the header.
local function cursor_offset(buf)
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local lines = buf_lines(buf)
  local off = 0
  for r = #header + 1, row - 1 do
    off = off + #lines[r] + 1
  end
  return off + col
end

local prompts, errors

--- Run org-cite-insert with the selections `answers` (keys, styles; ""
--- or nil cancels a key prompt).
local function run(fn, answers)
  prompts, errors = {}, {}
  local saved_select, saved_error = utils.select, utils.error
  utils.select = function(items, opts)
    local a = table.remove(answers, 1)
    local shown = {}
    for i, item in ipairs(items) do
      shown[i] = opts.format_item and opts.format_item(item) or item
    end
    table.insert(prompts, { opts.prompt, shown })
    for _, item in ipairs(items) do
      if type(item) == "table" and item[2] == a then
        return item
      elseif item == a then
        return item
      end
    end
    return nil
  end
  utils.error = function(msg)
    table.insert(errors, msg)
  end
  local okr, err = pcall(utils.run, fn)
  utils.select, utils.error = saved_select, saved_error
  assert(okr, err)
end

local function insert(text, pos, answers, arg)
  local buf = buffer(text, pos)
  run(function()
    cite.insert(arg or false)
  end, answers or {})
  return text_of(buf), cursor_offset(buf), buf
end

local CANDIDATES = {
  "Doe Jane                   2001  JSON Book",
  "Donald E. Knuth            1984  The {TeX}book",
  "Leslie Lamport; John Doe   1986  A Document Preparation System",
  "Smith, Jane                2020  A web page",
}
local STYLES = { '""', "author", "noauthor", "nocite", "note", "numeric", "text", "nil" }

describe("citation syntax", function()
  it("parses citations like org-element-citation-parser", function()
    local s = "A [cite/t:see ;@a p. 1;@b; and more] b"
    local c = cite.parse(s, 3)
    eq("t", c.style)
    eq(true, c.prefix)
    eq(true, c.suffix)
    eq(2, #c.references)
    eq("a", c.references[1].key)
    eq(" p. 1", s:sub(c.references[1].key_end, c.references[1].stop - 2))
    eq("b", c.references[2].key)
    eq(s:find("]", 1, true) + 1, c.stop)
    ok(cite.parse("[cite:no key]", 1) == nil)
  end)
  it("finds the context at point like org-element-context", function()
    local s = "A [cite/t:@a;@b] c"
    eq("citation", (cite.context_in(s, 5)))
    local t, _, r = cite.context_in(s, 12)
    eq("citation-reference", t)
    eq("a", r.key)
    t, _, r = cite.context_in(s, 16)
    eq("b", r.key)
    eq(nil, (cite.context_in(s, 1)))
  end)
end)

describe("org-cite-insert (basic)", function()
  it("inserts a citation, one prompt per key until an empty input", function()
    local text, point = insert("Hello  world", 6, { "knuth1984", "" })
    eq("Hello [cite:@knuth1984] world", text)
    eq(23, point)
    eq({
      { "Key (empty input exits): ", CANDIDATES },
      { "Key (empty input exits) knuth1984: ", CANDIDATES },
    }, prompts)
  end)
  it("keeps Emacs' order of several keys (last chosen first)", function()
    local text, point = insert("Hello  world", 6, { "knuth1984", "doe2001", "" })
    eq("Hello [cite:@doe2001; @knuth1984] world", text)
    eq(33, point)
    eq("Key (empty input exits) knuth1984;doe2001: ", prompts[3][1])
  end)
  it("aborts without keys", function()
    local text = insert("Hello  world", 6, { "" })
    eq("Hello  world", text)
    eq({ "Aborted" }, errors)
  end)
  it("asks for a style with a count", function()
    local text, point = insert("Hello  world", 6, { "knuth1984", "", "text" }, true)
    eq("Hello [cite/text:@knuth1984] world", text)
    eq(28, point)
    eq({ 'Style ("" for default): ', STYLES }, prompts[3])
    text = insert("Hello  world", 6, { "knuth1984", "", "" }, true)
    eq("Hello [cite:@knuth1984] world", text)
  end)
  it("replaces the key at point", function()
    local text, point = insert("A [cite:@knuth1984] b", 12, { "doe2001" })
    eq("A [cite:@doe2001] b", text)
    eq(8, point)
    eq({ { "Key: ", CANDIDATES } }, prompts)
    text, point = insert("A [cite:@knuthh] b", 10, { "knuth1984" })
    eq("A [cite:@knuth1984] b", text)
    eq(8, point)
    text, point = insert("A [cite:@knuth1984] b", 9, { "doe2001" })
    eq("A [cite:@doe2001] b", text)
    eq(8, point)
  end)
  it("inserts a reference before the key when right before the @", function()
    local text, point = insert("A [cite:@knuth1984] b", 8, { "doe2001" })
    eq("A [cite:@doe2001;@knuth1984] b", text)
    eq(8, point)
  end)
  it("inserts a reference after the key at its end or on its suffix", function()
    local text, point = insert("A [cite:@knuth1984 p. 3] b", 18, { "doe2001" })
    eq("A [cite:@knuth1984 p. 3;@doe2001] b", text)
    eq(18, point)
    text, point = insert("A [cite:@knuth1984 p. 3] b", 20, { "doe2001" })
    eq("A [cite:@knuth1984 p. 3;@doe2001] b", text)
    eq(20, point)
  end)
  it("edits the style on the style part", function()
    local text, point = insert("A [cite/t:@knuth1984] b", 5, { "author" })
    eq("A [cite/author:@knuth1984] b", text)
    eq(5, point)
    eq({ { 'Style ("" for default): ', STYLES } }, prompts)
    text = insert("A [cite/t:@knuth1984] b", 5, { "" })
    eq("A [cite:@knuth1984] b", text)
    text, point = insert("A [cite:@knuth1984] b", 4, { "text" })
    eq("A [cite/text:@knuth1984] b", text)
    eq(4, point)
  end)
  it("adds a reference on the global prefix or suffix", function()
    local text, point = insert("A [cite:see ;@knuth1984;@doe2001] b", 9, { "lamport1986" })
    eq("A [cite:see ;@lamport1986;@knuth1984;@doe2001] b", text)
    eq(9, point)
    text, point = insert("A [cite:@knuth1984;@doe2001; and more] b", 31, { "lamport1986" })
    eq("A [cite:@knuth1984;@doe2001;@lamport1986; and more] b", text)
    eq(44, point)
  end)
  it("deletes the reference or citation with a count", function()
    local text, point = insert("A [cite:@knuth1984;@doe2001] b", 12, {}, true)
    eq("A [cite:@doe2001] b", text)
    eq(8, point)
    text, point = insert("A [cite:@knuth1984; @doe2001] b", 22, {}, true)
    eq("A [cite:@knuth1984] b", text)
    eq(18, point)
    text, point = insert("A [cite:@knuth1984] b", 12, {}, true)
    eq("A b", text)
    eq(1, point)
    text, point = insert("A [cite/t:@knuth1984] b", 4, {}, true)
    eq("A b", text)
    eq(1, point)
    text, point = insert("[cite:@knuth1984]\nnext", 2, {}, true)
    eq("next", text)
    eq(0, point)
  end)
  it("inserts a new citation right after another one", function()
    local text, point = insert("A [cite:@knuth1984] b", 19, { "doe2001", "" })
    eq("A [cite:@knuth1984][cite:@doe2001] b", text)
    eq(34, point)
  end)
  it("inserts in a heading title", function()
    local text, point = insert("* Head", 3, { "knuth1984", "" })
    eq("* H[cite:@knuth1984]ead", text)
    eq(20, point)
  end)
  it("refuses other places", function()
    local text = insert("#+begin_src emacs-lisp\nfoo\n#+end_src", 24, { "knuth1984", "" })
    eq("#+begin_src emacs-lisp\nfoo\n#+end_src", text)
    eq({ "Cannot insert a citation here" }, errors)
  end)
  it("reads several keys at one prompt with a crm separator", function()
    local c = require("org.config").opts.export.cite
    c.basic_complete_key_crm_separator = "[ \\t]*;;[ \\t]*"
    local saved = vim.fn.input
    local prompt
    vim.fn.input = function(o)
      prompt = o.prompt
      return "knuth1984 ;; doe2001"
    end
    local okr, text = pcall(insert, "Hello  world", 6, {})
    vim.fn.input = saved
    c.basic_complete_key_crm_separator = nil
    assert(okr, text)
    eq("Hello [cite:@knuth1984; @doe2001] world", text)
    eq("[list separated by ;;] Keys: ", prompt)
  end)
  -- Emacs 9.8.10 (tests/fixtures/cite/refs.bib, crm separator 'dynamic):
  -- the prompt is "[list separated by ;;] Keys: " since the candidates
  -- are the "author year title" strings and "Leslie Lamport; John Doe"
  -- contains ";"; the chosen strings map back to their keys.
  it("computes the dynamic crm separator from the completion strings", function()
    local c = require("org.config").opts.export.cite
    c.basic_complete_key_crm_separator = "dynamic"
    local saved = vim.fn.input
    local prompt, completions
    vim.fn.input = function(o)
      prompt = o.prompt
      completions = cite._crm_complete("")
      return CANDIDATES[2] .. " ;; " .. CANDIDATES[3]
    end
    local okr, text = pcall(insert, "Hello  world", 6, {})
    vim.fn.input = saved
    c.basic_complete_key_crm_separator = nil
    assert(okr, text)
    eq("[list separated by ;;] Keys: ", prompt)
    eq(CANDIDATES, completions)
    eq("Hello [cite:@knuth1984; @lamport1986] world", text)
  end)
  it("errors without bibliography", function()
    local buf = org_buffer({ "Hello" }, { 1, 2 })
    run(function()
      cite.insert(false)
    end, {})
    eq({ "Hello" }, buf_lines(buf))
    eq({ "No bibliography set" }, errors)
  end)
  it("honours the insert processor option", function()
    local c = require("org.config").opts.export.cite
    c.insert_processor = false
    insert("Hello  world", 6, {})
    eq({ "No processor set to insert citations" }, errors)
    c.insert_processor = "nope"
    insert("Hello  world", 6, {})
    eq({ "Unknown processor nope" }, errors)
    c.insert_processor = "basic"
  end)
  it("uses the author column and separator options", function()
    local c = require("org.config").opts.export.cite
    c.basic_author_column_end, c.basic_column_separator = 10, " | "
    insert("Hello  world", 6, { "knuth1984", "" })
    c.basic_author_column_end, c.basic_column_separator = 25, "  "
    eq("Donald E.  | 1984 | The {TeX}book", prompts[1][2][2])
  end)
end)

describe("org-cite-follow (basic)", function()
  local function follow(text, pos, answers)
    local buf = buffer(text, pos)
    vim.bo[buf].modified = false
    run(function()
      require("org.context").open_at_point()
    end, answers or {})
    local cur = vim.api.nvim_get_current_buf()
    local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(cur), ":t")
    local row, col = unpack(vim.api.nvim_win_get_cursor(0))
    return name, row, col
  end
  it("opens the BibTeX entry of the reference", function()
    eq({ "refs.bib", 8, 0 }, { follow("A [cite:@lamport1986] b", 10) })
    eq({ "refs.bib", 8, 0 }, { follow("A [cite:see @lamport1986 p. 3; @web2020] b", 9) })
    eq({ "refs.bib", 8, 0 }, { follow("A [cite:see @lamport1986 p. 3; @web2020] b", 26) })
  end)
  it("opens a CSL-JSON entry at its brace", function()
    eq({ "refs.json", 2, 1 }, { follow("A [cite:@doe2001] b", 10) })
  end)
  it("asks which key to follow on the style part", function()
    eq({ "refs.json", 2, 1 }, { follow("A [cite/t:@knuth1984;@doe2001] b", 4, { "doe2001" }) })
    eq({ "Select citation key: ", { "knuth1984", "doe2001" } }, prompts[1])
    eq({ "refs.bib", 1, 0 }, { follow("A [cite/t:@knuth1984] b", 4) })
  end)
  it("reports unknown keys", function()
    follow("A [cite:@nope] b", 10)
    eq({ 'Cannot find citation key: "nope"' }, errors)
  end)
end)

describe("org-cite-activate (basic)", function()
  it("highlights citations and keys, flagging unknown keys", function()
    local buf = buffer("A [cite:@knuth1984;@knuthh] b", 0)
    local marks = cite.marks(buf, 0, 10)
    eq({
      { 2, 27, "OrgCite", 100 },
      { 8, 18, "OrgCiteKey", 101 },
      { 19, 26, "OrgCiteKeyUnknown", 101 },
    }, marks[3])
  end)
  it("does not check keys without an activate processor", function()
    local c = require("org.config").opts.export.cite
    c.activate_processor = false
    local buf = buffer("A [cite:@knuthh] b", 0)
    local marks = cite.marks(buf, 0, 10)
    c.activate_processor = "basic"
    eq({ { 2, 16, "OrgCite", 100 }, { 8, 15, "OrgCiteKey", 101 } }, marks[3])
  end)
  it("suggests close keys within the maximum distance", function()
    eq({ "knuth1984" }, cite.basic.close_keys("knuthh1984", { "knuth1984", "doe2001" }))
    local c = require("org.config").opts.export.cite
    c.basic_max_key_distance = 0
    eq({}, cite.basic.close_keys("knuthh1984", { "knuth1984", "doe2001" }))
    c.basic_max_key_distance = 2
    eq(1, cite.string_distance("kitten", "kittn"))
    eq(3, cite.string_distance("kitten", "sitting"))
  end)
  it("substitutes an unknown key on mouse-1", function()
    local buf = buffer("A [cite:@knuthh1984] b", 0)
    local saved = vim.fn.getmousepos
    vim.fn.getmousepos = function()
      return { winid = vim.api.nvim_get_current_win(), line = 4, column = 12 }
    end
    run(function()
      cite.mouse_click()
    end, {})
    vim.fn.getmousepos = saved
    eq("A [cite:@knuth1984] b", text_of(buf))
  end)
  -- links.mouse_1_follows_link maps <LeftRelease> too: a release on a
  -- citation key must still reach the citation (oc-basic's key <mouse-1>)
  it("the link mouse handler hands a click on a key to the citation", function()
    local buf = buffer("A [cite:@knuthh1984] b", 0)
    local saved = vim.fn.getmousepos
    vim.fn.getmousepos = function()
      return { winid = vim.api.nvim_get_current_win(), line = 4, column = 12, screenrow = 4, screencol = 12 }
    end
    run(function()
      require("org.mouse")._after_release({ time = 0, row = 4, col = 12 })
    end, {})
    vim.fn.getmousepos = saved
    eq("A [cite:@knuth1984] b", text_of(buf))
  end)
end)
