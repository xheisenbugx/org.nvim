local utils = require("org.utils")

describe("utils.sha256", function()
  it("hashes the bytes of strings with NUL bytes, on Neovim 0.11.0 too", function()
    eq("59b271ae1bbcb1d31d41929817f4b16fb439eb4f31520b5ad1d5ce98920a7138", utils.sha256("a\0b"))
    eq(vim.fn.sha256("ab"), utils.sha256("ab"))
  end)

  it("agrees with sha256() in Lua, across block boundaries", function()
    local inputs = { "", "abc", string.rep("q", 55), string.rep("q", 56), string.rep("q", 64), string.rep("xyz", 100) }
    for _, s in ipairs(inputs) do
      eq(vim.fn.sha256(s), utils._sha256_lua(s))
    end
    eq("59b271ae1bbcb1d31d41929817f4b16fb439eb4f31520b5ad1d5ce98920a7138", utils._sha256_lua("a\0b"))
  end)
end)
