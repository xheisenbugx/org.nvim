---@mod org.extensions.gcal.oauth Google OAuth for the gcal extension
---
--- OAuth 2.0 for installed apps: the consent page redirects to a loopback
--- listener on 127.0.0.1, the code is exchanged with PKCE (RFC 7636), and
--- the tokens are kept in `token_file` (mode 0600) together with the
--- calendar sync tokens. Token values are never shown; `redact` scrubs
--- them from any message.

local M = {}

M.AUTH_URL = "https://accounts.google.com/o/oauth2/v2/auth"
M.TOKEN_URL = "https://oauth2.googleapis.com/token"
M.SCOPE = "https://www.googleapis.com/auth/calendar"

local function gcal()
  return require("org.extensions.gcal")
end

---------------------------------------------------------------------------
-- Encoding
---------------------------------------------------------------------------

--- Percent-encode for URLs and form bodies (RFC 3986 unreserved kept).
---@param s string
---@return string
function M.urlencode(s)
  return (
    tostring(s):gsub("[^%w%-%._~]", function(c)
      return string.format("%%%02X", c:byte())
    end)
  )
end

---@param s string
---@return string
function M.urldecode(s)
  return (s:gsub("%+", " "):gsub("%%(%x%x)", function(h)
    return string.char(tonumber(h, 16))
  end))
end

--- `k=v&...` with sorted keys; nil values are left out.
---@param t table<string, any>
---@return string
function M.form(t)
  local keys = vim.tbl_keys(t)
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do
    parts[#parts + 1] = M.urlencode(k) .. "=" .. M.urlencode(t[k])
  end
  return table.concat(parts, "&")
end

--- Parse `a=1&b=2` into a table.
---@param s string
---@return table<string, string>
function M.parse_query(s)
  local out = {}
  for pair in (s or ""):gmatch("[^&]+") do
    local k, v = pair:match("^([^=]*)=?(.*)$")
    out[M.urldecode(k)] = M.urldecode(v)
  end
  return out
end

--- Base64url without padding.
---@param s string
---@return string
function M.b64url(s)
  return (vim.base64.encode(s):gsub("%+", "-"):gsub("/", "_"):gsub("=+$", ""))
end

local function hex_to_bytes(hex)
  return (hex:gsub("%x%x", function(h)
    return string.char(tonumber(h, 16))
  end))
end

---@param n integer
---@return string
function M.random_bytes(n)
  local ok, bytes = pcall(vim.uv.random, n)
  if ok and type(bytes) == "string" and #bytes == n then
    return bytes
  end
  local fd = io.open("/dev/urandom", "rb")
  if fd then
    bytes = fd:read(n)
    fd:close()
    if bytes and #bytes == n then
      return bytes
    end
  end
  error("org gcal: no secure random source available")
end

--- A PKCE verifier and its S256 challenge.
---@param verifier? string
---@return string verifier, string challenge
function M.pkce(verifier)
  verifier = verifier or M.b64url(M.random_bytes(32))
  return verifier, M.b64url(hex_to_bytes(vim.fn.sha256(verifier)))
end

--- The consent page URL.
---@param p { client_id: string, redirect_uri: string, challenge: string, state: string }
---@return string
function M.auth_url(p)
  return M.AUTH_URL
    .. "?"
    .. M.form({
      client_id = p.client_id,
      redirect_uri = p.redirect_uri,
      response_type = "code",
      scope = M.SCOPE,
      code_challenge = p.challenge,
      code_challenge_method = "S256",
      state = p.state,
      access_type = "offline",
      prompt = "consent",
    })
end

---------------------------------------------------------------------------
-- Secrets and redaction
---------------------------------------------------------------------------

--- `client_secret` from a string or a function (e.g. a password manager).
---@param opts table
---@return string|nil
function M.client_secret(opts)
  local s = opts.client_secret
  if type(s) == "function" then
    local ok, v = pcall(s)
    s = ok and v or nil
  end
  if type(s) == "string" then
    s = vim.trim(s)
  end
  if type(s) ~= "string" or s == "" then
    return nil
  end
  M.remember_secret(s)
  return s
end

-- secret values seen this session, scrubbed from every message
local secrets = {}

---@param v string|nil
function M.remember_secret(v)
  if type(v) == "string" and #v >= 8 then
    secrets[v] = true
  end
end

--- Remove token values, secrets and codes from a message.
---@param msg any
---@return string
function M.redact(msg)
  msg = tostring(msg)
  for s in pairs(secrets) do
    local i = msg:find(s, 1, true)
    while i do
      msg = msg:sub(1, i - 1) .. "[REDACTED]" .. msg:sub(i + #s)
      i = msg:find(s, i + 10, true)
    end
  end
  msg = msg
    :gsub('("[%w_]*token"%s*:%s*")[^"]*"', '%1[REDACTED]"')
    :gsub('("client_secret"%s*:%s*")[^"]*"', '%1[REDACTED]"')
    :gsub("([Bb]earer%s+)[%w%-%._~%+/=]+", "%1[REDACTED]")
    :gsub("((%f[%w][%w_]*token)=)[^&%s\"]+", "%1[REDACTED]")
    :gsub("((%f[%w]client_secret)=)[^&%s\"]+", "%1[REDACTED]")
    :gsub("((%f[%w]code)=)[^&%s\"]+", "%1[REDACTED]")
    :gsub("((%f[%w]code_verifier)=)[^&%s\"]+", "%1[REDACTED]")
  return msg
end

---------------------------------------------------------------------------
-- Token file
---------------------------------------------------------------------------

---@param opts table
---@return string
function M.token_path(opts)
  return require("org.utils").expand(opts.token_file, vim.fn.getcwd())
end

--- The stored state: { access_token, refresh_token, expires_at, sync_tokens }.
---@param opts table
---@return table
function M.load(opts)
  local path = M.token_path(opts)
  local fd = io.open(path, "r")
  local data
  if fd then
    local ok, v = pcall(vim.json.decode, fd:read("*a"))
    fd:close()
    data = ok and type(v) == "table" and v or nil
  end
  data = data or {}
  data.sync_tokens = type(data.sync_tokens) == "table" and data.sync_tokens or {}
  M.remember_secret(data.access_token)
  M.remember_secret(data.refresh_token)
  return data
end

--- Write the state with mode 0600 (the directory is created 0700).
---@param opts table
---@param data table
function M.save(opts, data)
  local path = M.token_path(opts)
  local dir = vim.fn.fnamemodify(path, ":h")
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, "p", tonumber("700", 8))
  end
  local encoded = vim.json.encode(data)
  local tmp = path .. ".tmp"
  -- a leftover temp file may have other permissions (or be a link)
  os.remove(tmp)
  local fd = assert(vim.uv.fs_open(tmp, "wx", tonumber("600", 8)))
  local ok, err = vim.uv.fs_write(fd, encoded)
  vim.uv.fs_close(fd)
  if not ok then
    os.remove(tmp)
    error("org gcal: cannot write the token file: " .. tostring(err))
  end
  vim.uv.fs_chmod(tmp, tonumber("600", 8))
  assert(vim.uv.fs_rename(tmp, path))
end

---------------------------------------------------------------------------
-- Token requests (run inside org.utils.run)
---------------------------------------------------------------------------

local function token_request(opts, params)
  local resp, err = gcal().await_request({
    method = "POST",
    url = M.TOKEN_URL,
    headers = { ["Content-Type"] = "application/x-www-form-urlencoded" },
    body = M.form(params),
  })
  if not resp then
    return nil, err
  end
  local ok, data = pcall(vim.json.decode, resp.body or "")
  data = ok and type(data) == "table" and data or {}
  if resp.status ~= 200 or not data.access_token then
    return nil, string.format("token request failed (%s): %s", resp.status, data.error or "no access token"), data
  end
  M.remember_secret(data.access_token)
  M.remember_secret(data.refresh_token)
  return data
end

local function store_tokens(opts, state, data)
  state.access_token = data.access_token
  if data.refresh_token then
    state.refresh_token = data.refresh_token
  end
  state.expires_at = gcal().now() + (tonumber(data.expires_in) or 3600)
  M.save(opts, state)
end

--- Exchange an authorization code.
---@return boolean ok, string? err
function M.exchange(opts, code, verifier, redirect_uri)
  local data, err = token_request(opts, {
    grant_type = "authorization_code",
    code = code,
    code_verifier = verifier,
    redirect_uri = redirect_uri,
    client_id = opts.client_id,
    client_secret = M.client_secret(opts),
  })
  if not data then
    return false, err
  end
  local state = M.load(opts)
  store_tokens(opts, state, data)
  return true
end

--- Refresh the access token. A revoked refresh token clears the tokens.
---@return string|nil access_token, string? err
function M.refresh(opts)
  local state = M.load(opts)
  if not state.refresh_token then
    return nil, "not authorized: run :Org gcal_auth"
  end
  local data, err, body = token_request(opts, {
    grant_type = "refresh_token",
    refresh_token = state.refresh_token,
    client_id = opts.client_id,
    client_secret = M.client_secret(opts),
  })
  if not data then
    if body and body.error == "invalid_grant" then
      state.access_token, state.refresh_token, state.expires_at = nil, nil, nil
      M.save(opts, state)
      return nil, "authorization expired or was revoked: run :Org gcal_auth"
    end
    return nil, err
  end
  store_tokens(opts, state, data)
  return data.access_token
end

--- A valid access token, refreshed when it expires within a minute.
---@return string|nil access_token, string? err
function M.access_token(opts)
  local state = M.load(opts)
  if state.access_token and (tonumber(state.expires_at) or 0) - 60 > gcal().now() then
    return state.access_token
  end
  return M.refresh(opts)
end

---------------------------------------------------------------------------
-- Loopback listener
---------------------------------------------------------------------------

local PAGE = "<!doctype html><title>org.nvim</title><p>%s You can close this tab and return to Neovim.</p>"

--- Listen on 127.0.0.1 (random port) for one redirect. `on_result` gets
--- the query table or nil, err. With `state`, requests carrying another
--- state are refused (another local process can't end the flow). Returns
--- the redirect URI and a close fn.
---@param on_result fun(query: table|nil, err?: string)
---@param timeout_ms? integer
---@param state? string
---@return string|nil redirect_uri, fun()|string close_or_err
function M.listen(on_result, timeout_ms, state)
  local server = vim.uv.new_tcp()
  local ok, err = server:bind("127.0.0.1", 0)
  if not ok then
    server:close()
    return nil, "cannot bind loopback port: " .. tostring(err)
  end
  local port = server:getsockname().port
  local done = false
  local timer = vim.uv.new_timer()
  local function close()
    if not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    if not server:is_closing() then
      server:close()
    end
  end
  local function finish(query, e)
    if done then
      return
    end
    done = true
    close()
    vim.schedule(function()
      on_result(query, e)
    end)
  end
  timer:start(timeout_ms or 300000, 0, function()
    finish(nil, "timed out waiting for the Google consent page")
  end)
  server:listen(8, function(lerr)
    if lerr then
      finish(nil, lerr)
      return
    end
    local client = vim.uv.new_tcp()
    if not client or not pcall(server.accept, server, client) then
      if client then
        client:close()
      end
      return
    end
    local buf = ""
    local answered = false
    client:read_start(function(rerr, chunk)
      if rerr or not chunk then
        if not client:is_closing() then
          client:close()
        end
        return
      end
      if answered then
        return
      end
      buf = buf .. chunk
      local target = buf:match("^GET ([^ ]+) HTTP/")
      if not target and not buf:find("\r\n") and #buf < 8192 then
        return
      end
      answered = true
      local query = M.parse_query(target and target:match("%?(.*)$") or "")
      local ours = state == nil or query.state == state
      local good = ours and query.code ~= nil
      local body = PAGE:format(good and "Authorization received." or "Authorization failed.")
      client:write(
        (ours and "HTTP/1.1 200 OK" or "HTTP/1.1 400 Bad Request")
          .. "\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: "
          .. #body
          .. "\r\nConnection: close\r\n\r\n"
          .. body,
        function()
          if not client:is_closing() then
            client:close()
          end
        end
      )
      if query.code then
        M.remember_secret(query.code)
      end
      -- favicons, and requests with another state, are ignored
      if ours and (query.code or query.error) then
        finish(query)
      end
    end)
  end)
  return "http://127.0.0.1:" .. port, close
end

--- Run the whole consent flow (inside org.utils.run).
---@return boolean ok, string? err
function M.authorize(opts)
  local utils = require("org.utils")
  if not opts.client_id or opts.client_id == "" then
    return false, "set extensions.gcal.client_id (see :h org-extensions-gcal)"
  end
  local verifier, challenge = M.pkce()
  local state = M.b64url(M.random_bytes(16))
  local redirect_uri
  local query, err = utils.await(function(cb)
    local redirect, close_or_err = M.listen(cb, opts.auth_timeout and opts.auth_timeout * 1000 or nil, state)
    if not redirect then
      cb(nil, close_or_err)
      return
    end
    redirect_uri = redirect
    local url =
      M.auth_url({ client_id = opts.client_id, redirect_uri = redirect, challenge = challenge, state = state })
    utils.notify("org gcal: authorize in your browser:\n" .. url)
    pcall(vim.ui.open, url)
  end)
  if not query then
    return false, err
  end
  if query.error then
    return false, "authorization denied: " .. query.error
  end
  if query.state ~= state then
    return false, "authorization state mismatch"
  end
  return M.exchange(opts, query.code, verifier, redirect_uri)
end

return M
