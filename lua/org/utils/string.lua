---@mod org.utils.string String, Unicode, float formatting, UUID and SHA-256 helpers
---
--- Part of org.utils, which loads it.

local M = require("org.utils")

---------------------------------------------------------------------------
-- Small shared helpers (once copied into many modules)
---------------------------------------------------------------------------

--- Whether line `l` is empty or only whitespace (`%s`: space, tab, CR,
--- LF, VT, FF). A missing line (nil, past the end of a buffer) counts as
--- blank; callers that must treat it as not blank test `l ~= nil` first.
---@param l string|nil
---@return boolean
function M.is_blank(l)
  return l == nil or l:match("^%s*$") ~= nil
end

--- `s` in upper case, non-ASCII letters included (`string.upper` only
--- knows ASCII; Emacs's `upcase` and case-fold-search know Unicode).
---@param s string
---@return string
function M.upper(s)
  return s:find("[\128-\255]") and vim.fn.toupper(s) or s:upper()
end

--- `s` in lower case, non-ASCII letters included (see `upper`).
---@param s string
---@return string
function M.lower(s)
  return s:find("[\128-\255]") and vim.fn.tolower(s) or s:lower()
end

--- `s` without one pair of surrounding double quotes (`"a b"` gives
--- `a b`); `s` itself when it isn't quoted that way.
---@param s string
---@return string
function M.strip_quotes(s)
  return s:match('^"(.*)"$') or s
end

--- `s` with each bracket link shown as Org displays it: `[[link][desc]]`
--- as `desc`, `[[link]]` as `link`.
---@param s string
---@return string
function M.link_descriptions(s)
  s = s:gsub("%[%[([^%]]-)%]%[([^%]]-)%]%]", "%2")
  return (s:gsub("%[%[([^%]]-)%]%]", "%1"))
end

---------------------------------------------------------------------------
-- Strings
---------------------------------------------------------------------------

function M.trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.starts_with(s, prefix)
  return s:sub(1, #prefix) == prefix
end

function M.ends_with(s, suffix)
  return suffix == "" or s:sub(-#suffix) == suffix
end

function M.escape_pattern(s)
  return (s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"))
end

--- `s` as a literal gsub replacement: its `%` doubled, so a path, label or
--- user text that holds one isn't read as a capture reference.
---@param s string
---@return string
function M.gsub_escape(s)
  return (s:gsub("%%", "%%%%"))
end

-- The LuaJIT of Neovim 0.11 rounds exact ties away from zero
-- (string.format("%.2f", 0.125) is "0.13"); C printf, and so Emacs,
-- rounds them to even. There, format floats with the C library.
local c_snprintf
if string.format("%.2f", 0.125) ~= "0.12" and jit then
  local ffi = require("ffi")
  -- lint: allow pcall: declared already (ffi.cdef raises on a second declaration)
  pcall(ffi.cdef, "int snprintf(char *str, size_t size, const char *format, ...);")
  c_snprintf = function(spec, x)
    local size = 64
    while true do
      local buf = ffi.new("char[?]", size)
      local n = ffi.C.snprintf(buf, size, spec, ffi.cast("double", x))
      if n < size then
        return ffi.string(buf, n)
      end
      size = n + 1
    end
  end
end

--- `string.format(spec, x)` for one float directive (%f, %e, %g, with
--- flags, width and precision), rounding ties like C printf.
function M.format_float(spec, x)
  if c_snprintf and x == x and x ~= math.huge and x ~= -math.huge then
    return c_snprintf(spec, x)
  end
  return string.format(spec, x)
end

function M.width(s)
  return vim.api.nvim_strwidth(s)
end

--- Pad string to display width.
function M.pad_right(s, width)
  local w = M.width(s)
  if w >= width then
    return s
  end
  return s .. string.rep(" ", width - w)
end

function M.pad_left(s, width)
  local w = M.width(s)
  if w >= width then
    return s
  end
  return string.rep(" ", width - w) .. s
end

--- Truncate to display width, appending an ellipsis if needed.
function M.truncate(s, width)
  if M.width(s) <= width then
    return s
  end
  -- "…" is two cells wide with 'ambiwidth' "double"
  local ell = M.width("…") <= math.max(width, 1) and "…" or ""
  local room = width - M.width(ell)
  local out = vim.fn.strcharpart(s, 0, math.max(0, room))
  while out ~= "" and M.width(out) > room do
    out = vim.fn.strcharpart(out, 0, vim.fn.strchars(out) - 1)
  end
  return out .. ell
end

--- Random v4 UUID.
function M.uuid()
  local bytes = {}
  local ok, rnd = pcall(vim.uv.random, 16)
  for i = 1, 16 do
    bytes[i] = ok and rnd and rnd:byte(i) or math.random(0, 255)
  end
  bytes[7] = bit.bor(bit.band(bytes[7], 0x0f), 0x40)
  bytes[9] = bit.bor(bit.band(bytes[9], 0x3f), 0x80)
  local hex = {}
  for i = 1, 16 do
    hex[i] = string.format("%02x", bytes[i])
  end
  local s = table.concat(hex)
  return string.format("%s-%s-%s-%s-%s", s:sub(1, 8), s:sub(9, 12), s:sub(13, 16), s:sub(17, 20), s:sub(21, 32))
end

-- stylua: ignore
local SHA256_K = {
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

--- SHA-256 in Lua, for the strings older sha256() rejects.
local function sha256_lua(s)
  local band, bor, bxor, bnot, ror, rshift = bit.band, bit.bor, bit.bxor, bit.bnot, bit.ror, bit.rshift
  local len = #s
  s = s .. "\128" .. string.rep("\0", (55 - len) % 64)
  local bits = len * 8
  local tail = {}
  for i = 8, 1, -1 do
    tail[i] = string.char(bits % 256)
    bits = math.floor(bits / 256)
  end
  s = s .. table.concat(tail)
  local h = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 }
  local w = {}
  for chunk = 1, #s, 64 do
    for i = 0, 15 do
      local a, b, c, d = s:byte(chunk + i * 4, chunk + i * 4 + 3)
      w[i] = bor(bit.lshift(a, 24), bit.lshift(b, 16), bit.lshift(c, 8), d)
    end
    for i = 16, 63 do
      local x, y = w[i - 15], w[i - 2]
      local s0 = bxor(ror(x, 7), ror(x, 18), rshift(x, 3))
      local s1 = bxor(ror(y, 17), ror(y, 19), rshift(y, 10))
      w[i] = bit.tobit(w[i - 16] + s0 + w[i - 7] + s1)
    end
    local a, b, c, d, e, f, g, hh = unpack(h)
    for i = 0, 63 do
      local s1 = bxor(ror(e, 6), ror(e, 11), ror(e, 25))
      local ch = bxor(band(e, f), band(bnot(e), g))
      local t1 = hh + s1 + ch + SHA256_K[i + 1] + w[i]
      local s0 = bxor(ror(a, 2), ror(a, 13), ror(a, 22))
      local maj = bxor(band(a, b), band(a, c), band(b, c))
      hh, g, f, e = g, f, e, bit.tobit(d + t1)
      d, c, b, a = c, b, a, bit.tobit(t1 + s0 + maj)
    end
    for i, v in ipairs({ a, b, c, d, e, f, g, hh }) do
      h[i] = bit.tobit(h[i] + v)
    end
  end
  local out = {}
  for i = 1, 8 do
    out[i] = bit.tohex(h[i])
  end
  return table.concat(out)
end
M._sha256_lua = sha256_lua

local sha256_takes_blobs

--- Hex SHA-256 of the bytes of `s` (sha256()). Neovim passes a string with a
--- NUL byte to sha256() as a Blob, which 0.11.0 rejects (E976), 0.12 hashes.
---@param s string
---@return string
function M.sha256(s)
  if s:find("\0", 1, true) then
    if sha256_takes_blobs == nil then
      sha256_takes_blobs = pcall(vim.fn.sha256, "\0")
    end
    if not sha256_takes_blobs then
      return sha256_lua(s)
    end
  end
  return vim.fn.sha256(s)
end

local is_mac = vim.fn.has("mac") == 1

--- Whether string `a` sorts before `b` (org-string<), following
--- `sort_function` (org-sort-function): "collate" compares with the
--- collation locale (like string-collate-lessp, see |:language|),
--- "fallback" by character code (org-sort-function-fallback), or a
--- function(a, b, ignore_case) returning a boolean.
---@param a string
---@param b string
---@param ignore_case? boolean
---@return boolean
function M.string_lessp(a, b, ignore_case)
  local f = require("org.config").opts.sort_function or "collate"
  if type(f) == "function" then
    return f(a, b, ignore_case) and true or false
  end
  -- Emacs's string-collate-lessp compares character codes on macOS, whose
  -- wide-character collation for UTF-8 locales is not a real one
  if f == "fallback" or (f == "collate" and is_mac) then
    if ignore_case then
      a, b = a:upper(), b:upper()
    end
    return a < b
  end
  if ignore_case then
    a, b = a:lower(), b:lower()
  end
  if a == b then
    return false
  end
  -- sort() keeps equal items in order: `a` first only when it sorts lower
  local ok, r = pcall(vim.fn.sort, { b, a }, "l")
  if not ok then
    return a < b
  end
  return r[1] == a and r[2] == b
end
