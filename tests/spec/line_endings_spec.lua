-- Files are written with LF line endings on every platform: in text mode
-- ("w") Windows would turn each \n into \r\n, unlike vim.fn.writefile.
describe("line endings", function()
  local function raw(path)
    local f = assert(io.open(path, "rb"))
    local s = f:read("*a")
    f:close()
    return s
  end

  it("writes LF with utils.writefile", function()
    local path = vim.fn.tempname()
    require("org.utils").writefile(path, { "* TODO a", "b" })
    eq("* TODO a\nb\n", raw(path))
  end)

  it("opens no file for writing in text mode", function()
    local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
    local found = {}
    for _, file in ipairs(vim.fn.globpath(root .. "/lua/org", "**/*.lua", false, true)) do
      for lnum, line in ipairs(vim.fn.readfile(file)) do
        if line:find('io%.open%([^)]*,%s*"[wa]%+?"%)') then
          found[#found + 1] = file:sub(#root + 2) .. ":" .. lnum
        end
      end
    end
    eq({}, found)
  end)
end)
