local root = vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))

describe("test runner", function()
  it("fails a describe whose body errors, without leaking it into later files", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local a, b = dir .. "/a_spec.lua", dir .. "/b_spec.lua"
    vim.fn.writefile({
      'describe("outer", function()',
      "  before_each(function() error('leaked hook') end)",
      "  error('boom')",
      "end)",
    }, a)
    vim.fn.writefile({
      'describe("later", function()',
      '  it("runs alone", function() end)',
      "end)",
    }, b)
    local res = vim
      .system({ vim.v.progpath, "--headless", "-u", root .. "/tests/minimal_init.lua", "-l", root .. "/tests/run.lua", a, b })
      :wait()
    vim.fn.delete(dir, "rf")
    -- stdout is in text mode on Windows: \r\n
    res.stdout = res.stdout:gsub("\r\n", "\n")
    eq(1, res.code)
    ok(res.stdout:find("FAIL: outer\n    [^\n]*boom"), res.stdout)
    ok(res.stdout:find("1 passed, 1 failed", 1, true), res.stdout)
  end)
end)
