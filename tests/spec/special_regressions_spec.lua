local special = require("org.special")

local function save_exit(buf)
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    if map.desc == "org: save and exit edit buffer" then
      map.callback()
      return
    end
  end
  error("missing save and exit mapping")
end

describe("special edit source preservation", function()
  local edited
  after_each(function()
    if edited and vim.api.nvim_buf_is_valid(edited) then
      vim.api.nvim_buf_delete(edited, { force = true })
    end
    pcall(vim.cmd, "silent! only!")
  end)

  local function open(lines, opts)
    local src = org_buffer(lines)
    edited = special.open(vim.tbl_extend("force", {
      source_buf = src,
      start_line = 2,
      end_line = 2,
      lines = { lines[2] },
      window = "split",
    }, opts or {}))
    vim.api.nvim_buf_set_lines(edited, 0, -1, false, { "edited" })
    return src
  end

  it("keeps both versions when the source region changes", function()
    local src = open({ "before", "original", "after" })
    vim.api.nvim_buf_set_lines(src, 1, 2, false, { "external change" })
    save_exit(edited)
    eq({ "before", "external change", "after" }, buf_lines(src))
    ok(vim.api.nvim_buf_is_valid(edited))
    eq({ "edited" }, buf_lines(edited))
    ok(vim.bo[edited].modified)
  end)

  it("only overwrites a source conflict after an explicit forced write", function()
    local src = open({ "before", "original", "after" })
    vim.api.nvim_buf_set_text(src, 1, 0, 1, #"original", { "external change" })
    local written = pcall(vim.cmd, "write")
    eq(false, written)
    eq({ "before", "external change", "after" }, buf_lines(src))
    ok(vim.bo[edited].modified)
    vim.cmd("write!")
    eq({ "before", "edited", "after" }, buf_lines(src))
    ok(not vim.bo[edited].modified)
    vim.api.nvim_buf_set_lines(edited, 0, -1, false, { "edited again" })
    vim.cmd("write")
    eq({ "before", "edited again", "after" }, buf_lines(src))
  end)

  it("does not discard unsaved edits when write-and-quit fails", function()
    local src = open({ "before", "original", "after" })
    vim.api.nvim_buf_set_lines(src, 1, 2, false, {})
    eq(false, pcall(vim.cmd, "wq!"))
    eq({ "before", "after" }, buf_lines(src))
    ok(vim.api.nvim_buf_is_valid(edited))
    eq(edited, vim.api.nvim_get_current_buf())
    ok(vim.bo[edited].modified)
  end)

  it("does not force a write after the entire source region was replaced", function()
    local src = open({ "before", "original", "after" })
    vim.api.nvim_buf_set_lines(src, 1, 2, false, { "replacement" })
    eq(false, pcall(vim.cmd, "write!"))
    eq({ "before", "replacement", "after" }, buf_lines(src))
    ok(vim.bo[edited].modified)
  end)

  it("does not force a write when source conversion rejects the edit", function()
    local src = open({ "before", "original", "after" }, {
      to_source = function()
        return nil
      end,
    })
    eq(false, pcall(vim.cmd, "write!"))
    eq({ "before", "original", "after" }, buf_lines(src))
    ok(vim.bo[edited].modified)
  end)

  it("does not force a write to a wiped source buffer", function()
    local src = open({ "before", "original", "after" })
    vim.api.nvim_buf_delete(src, { force = true })
    eq(false, pcall(vim.cmd, "write!"))
    ok(vim.api.nvim_buf_is_valid(edited))
    eq({ "edited" }, buf_lines(edited))
    ok(vim.bo[edited].modified)
  end)

  it("does not replace the following region when the source is deleted", function()
    local src = open({ "before", "original", "after" })
    vim.api.nvim_buf_set_lines(src, 1, 2, false, {})
    save_exit(edited)
    eq({ "before", "after" }, buf_lines(src))
    ok(vim.api.nvim_buf_is_valid(edited))
    ok(vim.bo[edited].modified)
  end)

  it("keeps unsaved edits when source conversion rejects the edit", function()
    local src = open({ "before", "original", "after" }, {
      to_source = function()
        return nil
      end,
    })
    save_exit(edited)
    eq({ "before", "original", "after" }, buf_lines(src))
    ok(vim.api.nvim_buf_is_valid(edited))
    ok(vim.bo[edited].modified)
  end)

  it("keeps unsaved edits when the source buffer is wiped", function()
    local src = open({ "before", "original", "after" })
    vim.api.nvim_buf_delete(src, { force = true })
    save_exit(edited)
    ok(vim.api.nvim_buf_is_valid(edited))
    eq({ "edited" }, buf_lines(edited))
    ok(vim.bo[edited].modified)
  end)

  it("follows source lines when text is inserted immediately above them", function()
    local src = open({ "before", "original", "after" })
    vim.api.nvim_buf_set_lines(src, 1, 1, false, { "inserted outside" })
    save_exit(edited)
    eq({ "before", "inserted outside", "edited", "after" }, buf_lines(src))
    ok(not vim.api.nvim_buf_is_valid(edited))
  end)

  it("supports repeated writes after the edited region changes size", function()
    local src = open({ "before", "original", "after" })
    vim.api.nvim_buf_set_lines(edited, 0, -1, false, { "first", "second" })
    vim.cmd("write")
    eq({ "before", "first", "second", "after" }, buf_lines(src))
    vim.api.nvim_buf_set_lines(edited, 0, -1, false, { "final" })
    save_exit(edited)
    eq({ "before", "final", "after" }, buf_lines(src))
  end)

  it("preserves surrounding inline text across repeated writes", function()
    local src = open({ "before", "prefix original suffix", "after" }, {
      start_col = 7,
      end_col = 15,
      lines = { "original" },
    })
    vim.api.nvim_buf_set_text(src, 1, 0, 1, 0, { "new " })
    vim.cmd("write")
    eq("new prefix edited suffix", buf_lines(src)[2])
    vim.api.nvim_buf_set_lines(edited, 0, -1, false, { "final" })
    save_exit(edited)
    eq("new prefix final suffix", buf_lines(src)[2])
  end)

  it("detects changes within inline objects", function()
    local src = open({ "before", "prefix original suffix", "after" }, {
      start_col = 7,
      end_col = 15,
      lines = { "original" },
    })
    vim.api.nvim_buf_set_text(src, 1, 7, 1, 15, { "external" })
    save_exit(edited)
    eq("prefix external suffix", buf_lines(src)[2])
    ok(vim.api.nvim_buf_is_valid(edited))
    ok(vim.bo[edited].modified)
  end)

  it("writes into an initially empty region", function()
    local src = open({ "before", "after" }, { start_line = 2, end_line = 1, lines = { "" } })
    save_exit(edited)
    eq({ "before", "edited", "after" }, buf_lines(src))
  end)
end)

describe("special edit element boundaries", function()
  with_config({ edit_src_content_indentation = 2, src_preserve_indentation = false })
  local edited
  after_each(function()
    if edited and vim.api.nvim_buf_is_valid(edited) then
      vim.api.nvim_buf_delete(edited, { force = true })
    end
    pcall(vim.cmd, "silent! only!")
  end)

  it("keeps fake block endings in the body even when editing below them", function()
    for _, kind in ipairs({ "example", "export", "comment" }) do
      local src = org_buffer({
        "#+begin_" .. kind .. (kind == "export" and " html" or ""),
        "first",
        "#+end_" .. kind .. " extra",
        "#+end_" .. kind .. "_suffix",
        "last",
        "#+END_" .. kind:upper() .. " \t",
      })
      special.edit_element(src, 5)
      edited = vim.api.nvim_get_current_buf()
      ok(edited ~= src)
      eq({ "first", "#+end_" .. kind .. " extra", "#+end_" .. kind .. "_suffix", "last" }, buf_lines(edited))
      vim.api.nvim_buf_delete(edited, { force = true })
    end
  end)

  it("does not edit an unterminated block across a headline", function()
    local src = org_buffer({ "#+begin_example", "first", "* Heading", "last", "#+end_example" })
    eq(false, special.edit_element(src, 2))
    eq(src, vim.api.nvim_get_current_buf())
  end)

  it("does not mistake nested-looking delimiters for a separate literal block", function()
    local src = org_buffer({ "#+begin_comment", "#+begin_example", "inside", "#+end_example", "#+end_comment" })
    special.edit_element(src, 3)
    edited = vim.api.nvim_get_current_buf()
    eq("comment", vim.b[edited].org_special_kind)
    eq({ "#+begin_example", "inside", "#+end_example" }, buf_lines(edited))
  end)

  it("edits the surrounding example when its body resembles a fixed-width area", function()
    local src = org_buffer({ "#+begin_example", ": first", "last", "#+end_example" })
    special.edit_element(src, 2)
    edited = vim.api.nvim_get_current_buf()
    eq("example", vim.b[edited].org_special_kind)
    eq({ ": first", "last" }, buf_lines(edited))
  end)

  it("does not parse nested blocks in verse bodies", function()
    local src = org_buffer({ "#+begin_verse", "#+begin_example", "inside", "#+end_example", "#+end_verse" })
    eq(false, special.edit_element(src, 3))
    eq(src, vim.api.nvim_get_current_buf())
  end)

  it("still edits examples inside greater block containers", function()
    for _, kind in ipairs({ "quote", "center", "special" }) do
      local src = org_buffer({ "#+begin_" .. kind, "#+begin_example", "inside", "#+end_example", "#+end_" .. kind })
      special.edit_element(src, 3)
      edited = vim.api.nvim_get_current_buf()
      eq("example", vim.b[edited].org_special_kind)
      eq({ "inside" }, buf_lines(edited))
      vim.api.nvim_buf_delete(edited, { force = true })
    end
  end)

  it("applies the configured source content indentation to examples", function()
    local src = org_buffer({ "  #+begin_example", "    first", "      second", "  #+end_example" })
    special.edit_element(src, 2)
    edited = vim.api.nvim_get_current_buf()
    eq({ "first", "  second" }, buf_lines(edited))
    vim.api.nvim_buf_set_lines(edited, 0, -1, false, { "changed", "", "  second" })
    vim.cmd("write")
    eq({ "  #+begin_example", "    changed", "", "      second", "  #+end_example" }, buf_lines(src))
  end)

  it("preserves example indentation with -i or the global preservation option", function()
    for _, switches in ipairs({ "-i", "" }) do
      require("org.config").opts.src_preserve_indentation = switches == ""
      local src = org_buffer({ "  #+begin_example " .. switches, "    first", "      second", "  #+end_example" })
      special.edit_element(src, 2)
      edited = vim.api.nvim_get_current_buf()
      eq({ "    first", "      second" }, buf_lines(edited))
      vim.api.nvim_buf_set_lines(edited, 0, -1, false, { "   changed" })
      vim.cmd("write")
      eq("   changed", buf_lines(src)[2])
      vim.api.nvim_buf_delete(edited, { force = true })
    end
  end)

  it("dedents mixed tabs and spaces by display columns", function()
    local src = org_buffer({ "#+begin_example", "\tfirst", "    second", "#+end_example" })
    special.edit_element(src, 2)
    edited = vim.api.nvim_get_current_buf()
    eq({ "    first", "second" }, buf_lines(edited))
  end)

  it("does not treat a colon followed by a tab as a fixed-width element", function()
    local src = org_buffer({ ":\tfirst", ": second" })
    eq(false, special.edit_element(src, 1))
    eq(src, vim.api.nvim_get_current_buf())
    eq({ ":\tfirst", ": second" }, buf_lines(src))
  end)
end)
