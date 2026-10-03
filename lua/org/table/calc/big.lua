---@mod org.table.calc.big Calc: big integers

---------------------------------------------------------------------------
-- Big integers (base 1e7 limbs, little endian)
---------------------------------------------------------------------------

local BASE, BASE_DIGITS = 10000000, 7
local MAX_EXACT = 2 ^ 53

local Big = {}
Big.__index = Big

local function big_from_int(n)
  local b = setmetatable({ tag = "big", sign = n < 0 and -1 or 1, d = {} }, Big)
  n = math.abs(n)
  repeat
    b.d[#b.d + 1] = n % BASE
    n = math.floor(n / BASE)
  until n == 0
  return b
end

local function big_from_string(s)
  local b = setmetatable({ tag = "big", sign = 1, d = {} }, Big)
  if s:sub(1, 1) == "-" then
    b.sign, s = -1, s:sub(2)
  end
  s = s:gsub("^0+", "")
  local i = #s
  while i > 0 do
    local j = math.max(1, i - BASE_DIGITS + 1)
    b.d[#b.d + 1] = tonumber(s:sub(j, i))
    i = j - 1
  end
  if #b.d == 0 then
    b.d[1], b.sign = 0, 1
  end
  return b
end

local function big_trim(b)
  while #b.d > 1 and b.d[#b.d] == 0 do
    b.d[#b.d] = nil
  end
  if #b.d == 1 and b.d[1] == 0 then
    b.sign = 1
  end
  return b
end

local function big_cmp_abs(a, b)
  if #a.d ~= #b.d then
    return #a.d < #b.d and -1 or 1
  end
  for i = #a.d, 1, -1 do
    if a.d[i] ~= b.d[i] then
      return a.d[i] < b.d[i] and -1 or 1
    end
  end
  return 0
end

local function big_add_abs(a, b)
  local r, carry = {}, 0
  for i = 1, math.max(#a.d, #b.d) do
    local s = (a.d[i] or 0) + (b.d[i] or 0) + carry
    r[i], carry = s % BASE, math.floor(s / BASE)
  end
  if carry > 0 then
    r[#r + 1] = carry
  end
  return r
end

local function big_sub_abs(a, b) -- |a| >= |b|
  local r, borrow = {}, 0
  for i = 1, #a.d do
    local s = a.d[i] - (b.d[i] or 0) - borrow
    if s < 0 then
      s, borrow = s + BASE, 1
    else
      borrow = 0
    end
    r[i] = s
  end
  return r
end

local function big_add(a, b)
  if a.sign == b.sign then
    return big_trim(setmetatable({ tag = "big", sign = a.sign, d = big_add_abs(a, b) }, Big))
  end
  local c = big_cmp_abs(a, b)
  if c == 0 then
    return big_from_int(0)
  elseif c > 0 then
    return big_trim(setmetatable({ tag = "big", sign = a.sign, d = big_sub_abs(a, b) }, Big))
  end
  return big_trim(setmetatable({ tag = "big", sign = b.sign, d = big_sub_abs(b, a) }, Big))
end

local function big_mul(a, b)
  local r = {}
  for i = 1, #a.d + #b.d do
    r[i] = 0
  end
  for i = 1, #a.d do
    local carry = 0
    for j = 1, #b.d do
      local cur = r[i + j - 1] + a.d[i] * b.d[j] + carry
      r[i + j - 1], carry = cur % BASE, math.floor(cur / BASE)
    end
    local k = i + #b.d
    while carry > 0 do
      local cur = r[k] + carry
      r[k], carry = cur % BASE, math.floor(cur / BASE)
      k = k + 1
    end
  end
  return big_trim(setmetatable({ tag = "big", sign = a.sign * b.sign, d = r }, Big))
end

local function big_tostring(b)
  local parts = { tostring(b.d[#b.d]) }
  for i = #b.d - 1, 1, -1 do
    parts[#parts + 1] = string.format("%07d", b.d[i])
  end
  return (b.sign < 0 and "-" or "") .. table.concat(parts)
end

local function big_tofloat(b)
  local v = 0
  for i = #b.d, 1, -1 do
    v = v * BASE + b.d[i]
  end
  return v * b.sign
end

--- A big integer back to a Lua number when it is small enough.
local function big_norm(b)
  if #b.d <= 3 then
    local v = big_tofloat(b)
    if math.abs(v) < MAX_EXACT then
      return v
    end
  end
  return b
end

return {
  MAX_EXACT = MAX_EXACT,
  big_from_int = big_from_int,
  big_from_string = big_from_string,
  big_cmp_abs = big_cmp_abs,
  big_add = big_add,
  big_mul = big_mul,
  big_tostring = big_tostring,
  big_tofloat = big_tofloat,
  big_norm = big_norm,
}
