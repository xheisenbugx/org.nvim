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
