---@mod org.export.zip Minimal ZIP archives (stored entries)
---
--- A pure-Lua writer for ZIP files whose entries are stored without
--- compression, enough for OpenDocument packages: the `mimetype` entry has
--- to be the first one and uncompressed anyway, and the XML parts are
--- small. The reader extracts stored entries itself and falls back to the
--- `unzip` program for compressed ones (as Emacs does for styles taken
--- from an .odt/.ott file).

local bit = require("bit")

local M = {}

local CRC
local function crc_table()
  if CRC then
    return CRC
  end
  CRC = {}
  for i = 0, 255 do
    local c = i
    for _ = 1, 8 do
      if bit.band(c, 1) == 1 then
        c = bit.bxor(bit.rshift(c, 1), 0xEDB88320)
      else
        c = bit.rshift(c, 1)
      end
    end
    CRC[i] = c
  end
  return CRC
end

--- CRC-32 (ISO 3309) of a string, as a non-negative integer.
---@param s string
---@return integer
function M.crc32(s)
  local t = crc_table()
  local c = 0xFFFFFFFF
  local byte = string.byte
  for i = 1, #s do
    c = bit.bxor(t[bit.band(bit.bxor(c, byte(s, i)), 0xFF)], bit.rshift(c, 8))
  end
  c = bit.bnot(c)
  if c < 0 then
    c = c + 4294967296
  end
  return c
end

local function u16(n)
  return string.char(n % 256, math.floor(n / 256) % 256)
end

local function u32(n)
  return string.char(n % 256, math.floor(n / 256) % 256, math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256)
end

local function dos_time(t)
  local d = os.date("*t", t)
  local time = d.hour * 2048 + d.min * 32 + math.floor(d.sec / 2)
  local date = math.max(d.year - 1980, 0) * 512 + d.month * 32 + d.day
  return time, date
end

--- Build a ZIP archive in memory.
---@param entries { name: string, data?: string }[] in archive order; a
--- name ending in "/" is a directory entry
---@param time? integer modification time of the entries (default: now)
---@return string
function M.build(entries, time)
  local dtime, ddate = dos_time(time or os.time())
  local out, central = {}, {}
  local offset = 0
  for _, e in ipairs(entries) do
    local data = e.data or ""
    local crc = M.crc32(data)
    local name = e.name
    local head = table.concat({
      u32(0x04034b50),
      u16(10), -- version needed: 1.0 (stored)
      u16(0), -- flags
      u16(0), -- method: stored
      u16(dtime),
      u16(ddate),
      u32(crc),
      u32(#data),
      u32(#data),
      u16(#name),
      u16(0), -- extra length
      name,
    })
    out[#out + 1] = head
    out[#out + 1] = data
    central[#central + 1] = table.concat({
      u32(0x02014b50),
      u16(0x0314), -- made by: Unix, 2.0
      u16(10),
      u16(0),
      u16(0),
      u16(dtime),
      u16(ddate),
      u32(crc),
      u32(#data),
      u32(#data),
      u16(#name),
      u16(0), -- extra
      u16(0), -- comment
      u16(0), -- disk
      u16(0), -- internal attributes
      u32(name:sub(-1) == "/" and 0x41ED0010 or 0x81A40000), -- drwxr-xr-x / -rw-r--r--
      u32(offset),
      name,
    })
    offset = offset + #head + #data
  end
  local cd = table.concat(central)
  return table.concat(out)
    .. cd
    .. table.concat({
      u32(0x06054b50),
      u16(0),
      u16(0),
      u16(#entries),
      u16(#entries),
      u32(#cd),
      u32(offset),
      u16(0),
    })
end

--- Write a ZIP archive to `path` (see `build`).
---@return boolean ok, string? err
function M.write(path, entries, time)
  local f, err = io.open(path, "wb")
  if not f then
    return false, err
  end
  f:write(M.build(entries, time))
  f:close()
  return true
end

local function r16(s, i)
  local a, b = s:byte(i, i + 1)
  return a + b * 256
end

local function r32(s, i)
  local a, b, c, d = s:byte(i, i + 3)
  return a + b * 256 + c * 65536 + d * 16777216
end

--- Entries of the archive at `path`, from its central directory:
--- { name, method, size, csize, offset }.
---@return table[]? entries, string? err
function M.list(path)
  local f = io.open(path, "rb")
  if not f then
    return nil, "cannot read " .. path
  end
  local s = f:read("*a")
  f:close()
  local eocd
  for i = #s - 21, math.max(1, #s - 65557), -1 do
    if r32(s, i) == 0x06054b50 then
      eocd = i
      break
    end
  end
  if not eocd then
    return nil, path .. " is not a zip file"
  end
  local n, pos = r16(s, eocd + 10), r32(s, eocd + 16) + 1
  local out = {}
  for _ = 1, n do
    if r32(s, pos) ~= 0x02014b50 then
      break
    end
    local nlen, xlen, clen = r16(s, pos + 28), r16(s, pos + 30), r16(s, pos + 32)
    out[#out + 1] = {
      name = s:sub(pos + 46, pos + 45 + nlen),
      method = r16(s, pos + 10),
      csize = r32(s, pos + 20),
      size = r32(s, pos + 24),
      offset = r32(s, pos + 42),
      _archive = s,
    }
    pos = pos + 46 + nlen + xlen + clen
  end
  return out
end

--- Contents of member `name` of the archive at `path`: stored members are
--- read directly, compressed ones with `unzip -p`.
---@return string? data, string? err
function M.read(path, name)
  local entries, err = M.list(path)
  if not entries then
    return nil, err
  end
  for _, e in ipairs(entries) do
    if e.name == name then
      if e.method == 0 then
        local s = e._archive
        local off = e.offset + 1
        local start = off + 30 + r16(s, off + 26) + r16(s, off + 28)
        return s:sub(start, start + e.size - 1)
      end
      if vim.fn.executable("unzip") == 0 then
        return nil, "the unzip program is needed to extract " .. name .. " from " .. path
      end
      local res = vim.system({ "unzip", "-p", path, name }):wait()
      if res.code ~= 0 then
        return nil, "unzip failed: " .. (res.stderr or "")
      end
      return res.stdout
    end
  end
  return nil, name .. " not found in " .. path
end

return M
