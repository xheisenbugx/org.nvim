---@mod org.babel.sha1 SHA-1 (for `:cache` hashes compatible with Emacs `sha1`)

local bit = require("bit")
local band, bor, bxor, bnot = bit.band, bit.bor, bit.bxor, bit.bnot
local rol, lsh, rsh = bit.rol, bit.lshift, bit.rshift

local M = {}

local function add(...)
  local s = 0
  for i = 1, select("#", ...) do
    s = (s + select(i, ...)) % 4294967296
  end
  return s
end

local function u32(x)
  return x % 4294967296
end

--- Hex SHA-1 digest of the bytes of `msg`.
---@param msg string
---@return string
function M.hex(msg)
  local h0, h1, h2, h3, h4 = 0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0
  local len = #msg
  local bits = len * 8
  msg = msg .. "\128" .. string.rep("\0", (55 - len) % 64)
  -- 64-bit big-endian length
  local hi = math.floor(bits / 4294967296)
  local lo = bits % 4294967296
  msg = msg
    .. string.char(
      rsh(hi, 24) % 256,
      rsh(hi, 16) % 256,
      rsh(hi, 8) % 256,
      hi % 256,
      math.floor(lo / 16777216) % 256,
      math.floor(lo / 65536) % 256,
      math.floor(lo / 256) % 256,
      lo % 256
    )
  local w = {}
  for chunk = 1, #msg, 64 do
    for i = 0, 15 do
      local a, b, c, d = msg:byte(chunk + i * 4, chunk + i * 4 + 3)
      w[i] = bor(lsh(a, 24), lsh(b, 16), lsh(c, 8), d)
    end
    for i = 16, 79 do
      w[i] = rol(bxor(w[i - 3], w[i - 8], w[i - 14], w[i - 16]), 1)
    end
    local a, b, c, d, e = h0, h1, h2, h3, h4
    for i = 0, 79 do
      local f, k
      if i < 20 then
        f, k = bor(band(b, c), band(bnot(b), d)), 0x5A827999
      elseif i < 40 then
        f, k = bxor(b, c, d), 0x6ED9EBA1
      elseif i < 60 then
        f, k = bor(band(b, c), band(b, d), band(c, d)), 0x8F1BBCDC
      else
        f, k = bxor(b, c, d), 0xCA62C1D6
      end
      local temp = add(u32(rol(a, 5)), u32(f), e, k, u32(w[i]))
      e, d, c, b, a = d, c, u32(rol(b, 30)), a, temp
    end
    h0, h1, h2, h3, h4 = add(h0, a), add(h1, b), add(h2, c), add(h3, d), add(h4, e)
  end
  return string.format("%08x%08x%08x%08x%08x", h0, h1, h2, h3, h4)
end

return M
