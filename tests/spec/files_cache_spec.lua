local files = require("org.files")

describe("parsed buffer cache", function()
  it("reparses renamed buffers even when their text did not change", function()
    local buf = org_buffer({ "* Task" })
    local before = vim.fn.tempname() .. ".org"
    local after = vim.fn.tempname() .. ".org"
    vim.api.nvim_buf_set_name(buf, before)
    local original = files.get_buffer(buf)
    local tick = vim.api.nvim_buf_get_changedtick(buf)
    eq(vim.fs.normalize(vim.api.nvim_buf_get_name(buf)), original.filename)
    vim.api.nvim_buf_set_name(buf, after)
    eq(tick, vim.api.nvim_buf_get_changedtick(buf))
    local renamed = files.get_buffer(buf)
    eq(vim.fs.normalize(vim.api.nvim_buf_get_name(buf)), renamed.filename)
    eq(renamed, files.get(renamed.filename))
    eq(renamed, renamed.headlines[1].file)
  end)

  it("reparses a cached unnamed buffer after its first filename is assigned", function()
    local buf = org_buffer({ "* Task" })
    eq(nil, files.get_buffer(buf).filename)
    local name = vim.fn.tempname() .. ".org"
    vim.api.nvim_buf_set_name(buf, name)
    eq(vim.fs.normalize(vim.api.nvim_buf_get_name(buf)), files.get_buffer(buf).filename)
  end)
end)
