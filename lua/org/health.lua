--- :checkhealth org
local M = {}

-- Terminal key encodings -------------------------------------------------
--
-- Legacy terminal input can't encode every key org maps: <C-CR>, <S-CR>,
-- <C-,> and friends arrive as plain <CR> or `,` unless the terminal sends
-- extended keys (CSI u / modifyOtherKeys), and tmux only passes those on
-- when configured to. Modified arrows need xterm-style encodings, and
-- Meta keys need the terminal to send Option/Alt as ESC.

local SPECIAL = {
  cr = "CR",
  enter = "CR",
  ["return"] = "CR",
  tab = "Tab",
  bs = "BS",
  backspace = "BS",
  esc = "Esc",
  escape = "Esc",
  space = "Space",
  up = "Up",
  down = "Down",
  left = "Left",
  right = "Right",
  home = "Home",
  ["end"] = "End",
  pageup = "PageUp",
  pagedown = "PageDown",
  insert = "Insert",
  del = "Del",
  delete = "Del",
}

--- Modifiers and base key of a key token like `<C-S-CR>` or `x`.
---@return table<string, boolean> mods, string base
local function parse_key(token)
  local inner = token:match("^<(.+)>$")
  if not inner then
    return {}, token
  end
  local mods = {}
  local base = inner
  while true do
    local m, rest = base:match("^([CSMADcsmad])%-(.+)$")
    if not m then
      break
    end
    m = m:upper()
    mods[m == "A" and "M" or m] = true
    base = rest
  end
  local special = SPECIAL[base:lower()]
  if special then
    return mods, special
  end
  if base:match("^[Ff]%d+$") then
    return mods, base:upper()
  end
  return mods, base
end

--- What the terminal must support for a key token to reach Neovim:
--- "extended" (CSI u / modifyOtherKeys), "modified" (xterm-style
--- modified arrows and function keys), "meta" (Alt sent as ESC) or nil.
---@param token string
---@return "extended"|"modified"|"meta"|nil
function M.key_needs(token)
  local mods, base = parse_key(token)
  if not next(mods) or mods.D then
    return mods.D and "extended" or nil
  end
  local C, S, Mt = mods.C, mods.S, mods.M
  if base == "CR" or base == "Esc" or base == "BS" then
    if C or S then
      return "extended"
    end
  elseif base == "Tab" then
    if C or (S and Mt) then
      return "extended"
    elseif S then
      return nil -- CSI Z
    end
  elseif base == "Space" then
    if S then
      return "extended"
    elseif C and not Mt then
      return nil -- NUL
    end
  elseif base:match("^[A-Z][a-z]") or base:match("^F%d+$") then
    -- arrows, Home/End, PageUp/PageDown, function keys
    return "modified"
  elseif #base == 1 then
    if C and (S or not base:match("[%a@%[%]\\^_?]")) then
      return "extended"
    end
    if S and not C and not Mt then
      return nil -- the shifted character itself
    end
  end
  return Mt and "meta" or nil
end

--- Key tokens of every configured mapping: `{ [token] = { name, ... } }`.
---@return table<string, string[]>
function M.mapped_keys()
  local config = require("org.config")
  local out = {}
  for section, maps in pairs(config.opts.mappings) do
    if type(maps) == "table" then
      for name, value in pairs(maps) do
        for _, lhs in ipairs(config.lhs_list(value)) do
          if type(lhs) == "string" then
            for token in lhs:gmatch("<[^<>]+>") do
              local list = out[token] or {}
              out[token] = list
              local label = section .. "." .. name
              if not vim.tbl_contains(list, label) then
                list[#list + 1] = label
              end
            end
          end
        end
      end
    end
  end
  return out
end

--- Mapped keys grouped by what they need, each group sorted.
---@return table<string, string[]>
local function keys_by_need(keys)
  local out = { extended = {}, modified = {}, meta = {} }
  for token in pairs(keys) do
    local need = M.key_needs(token)
    if need then
      table.insert(out[need], token)
    end
  end
  for _, list in pairs(out) do
    table.sort(list)
  end
  return out
end

local function run(cmd)
  local ok, res = pcall(vim.system, cmd, { text = true })
  if not ok then
    return nil
  end
  local r = res:wait(2000)
  if r.code ~= 0 then
    return nil
  end
  return vim.trim(r.stdout or "")
end

--- tmux settings that decide which keys reach Neovim.
---@param exec? fun(cmd: string[]): string? (tests)
---@return { version: number?, extended_keys: string?, xterm_keys: string?, format: string?, termname: string?, features: string? }
function M.tmux_state(exec)
  exec = exec or run
  local st = {}
  local v = exec({ "tmux", "-V" })
  st.version = v and tonumber(v:match("(%d+%.%d+)"))
  st.extended_keys = exec({ "tmux", "show", "-sv", "extended-keys" })
  st.format = exec({ "tmux", "show", "-sv", "extended-keys-format" })
  st.xterm_keys = exec({ "tmux", "show", "-gv", "xterm-keys" })
  local client = exec({ "tmux", "display", "-p", "#{client_termname}\t#{client_termfeatures}\t#{config_files}" })
  if client then
    local parts = vim.split(client, "\t")
    st.termname, st.features = parts[1], parts[2]
    st.config = parts[3] and parts[3] ~= "" and vim.fn.fnamemodify(vim.split(parts[3], ",")[1], ":~") or nil
  end
  local tf = exec({ "tmux", "show", "-sv", "terminal-features" })
  st.terminal_features = tf and vim.split(tf, "\n") or {}
  return st
end

--- Whether tmux's terminal-features option gives `termname` extended keys.
---@param entries string[] values of the terminal-features option
function M.tmux_declares_extkeys(entries, termname)
  for _, entry in ipairs(entries) do
    local pattern, features = entry:match("^([^:]+):(.*)$")
    if pattern and (":" .. features .. ":"):match(":extkeys:") then
      local lua_pat = "^" .. pattern:gsub("[%^%$%(%)%%%.%[%]%+%-]", "%%%0"):gsub("%*", ".*"):gsub("%?", ".") .. "$"
      if termname:match(lua_pat) then
        return true
      end
    end
  end
  return false
end

local GHOSTTY_KEYS = {
  enter = "CR",
  ["return"] = "CR",
  tab = "Tab",
  backspace = "BS",
  escape = "Esc",
  space = "Space",
  arrow_up = "Up",
  arrow_down = "Down",
  arrow_left = "Left",
  arrow_right = "Right",
  up = "Up",
  down = "Down",
  left = "Left",
  right = "Right",
  home = "Home",
  ["end"] = "End",
  page_up = "PageUp",
  page_down = "PageDown",
  insert = "Insert",
  delete = "Del",
  comma = ",",
  period = ".",
  semicolon = ";",
  apostrophe = "'",
  quote = "'",
  slash = "/",
  backslash = "\\",
  minus = "-",
  equal = "=",
  grave = "`",
  backquote = "`",
  bracket_left = "[",
  bracket_right = "]",
}
local GHOSTTY_MODS = {
  ctrl = "C",
  control = "C",
  alt = "M",
  opt = "M",
  option = "M",
  shift = "S",
  super = "D",
  cmd = "D",
  command = "D",
}

--- Ghostty's default keybinds that are `performable:` (the key goes to
--- the application when the action can't run, e.g. adjust_selection
--- without a selection). `ghostty +show-config` drops that flag.
local GHOSTTY_DEFAULT_PERFORMABLE = {
  "<S-Left>",
  "<S-Right>",
  "<S-Up>",
  "<S-Down>",
  "<S-PageUp>",
  "<S-PageDown>",
  "<S-Home>",
  "<S-End>",
  "<C-S-Left>",
  "<C-S-Right>",
  "<C-PageUp>",
  "<C-PageDown>",
  "<C-M-Up>",
  "<C-M-Down>",
  "<C-M-Left>",
  "<C-M-Right>",
  "<Esc>",
}

--- The Neovim key token of a Ghostty keybind trigger (`ctrl+shift+enter`
--- -> `<C-S-CR>`, the first key of a sequence) and its prefix flags
--- (`performable:`, `unconsumed:`, ...).
---@return string? token, table<string, boolean> flags
function M.ghostty_trigger_key(trigger)
  local flags = {}
  while true do
    local p, rest = trigger:match("^(%a+):(.+)$")
    if not p then
      break
    end
    flags[p] = true
    trigger = rest
  end
  trigger = trigger:match("^(.-)>") or trigger
  local mods, key = {}, nil
  for part in (trigger .. "+"):gmatch("(.-)%+") do
    if part == "" and not key then
      part = "+"
    end
    local m = GHOSTTY_MODS[part:lower()]
    if m then
      mods[#mods + 1] = m
    elseif part ~= "" then
      key = part
    end
  end
  if not key then
    return nil, flags
  end
  local k = key:lower():gsub("^key_", ""):gsub("^digit_", "")
  key = GHOSTTY_KEYS[k] or (vim.fn.strchars(k) == 1 and k) or nil
  if not key or #mods == 0 and #key == 1 then
    return nil, flags
  end
  if key:match("^%a$") and vim.tbl_contains(mods, "S") and not vim.tbl_contains(mods, "C") then
    -- alt+shift+h is <M-H>
    key = key:upper()
    mods = vim.tbl_filter(function(m)
      return m ~= "S"
    end, mods)
  end
  table.sort(mods)
  return "<" .. table.concat(mods, "-") .. (#mods > 0 and "-" or "") .. key .. ">", flags
end

--- Ghostty configuration lines (`ghostty +show-config` output or config
--- files): `{ option_as_alt, keybinds = { [keycode] = { trigger, action, flags } } }`.
---@param lines string[]
function M.ghostty_parse(lines)
  local out = { keybinds = {} }
  for _, line in ipairs(lines) do
    local key, value = line:match("^%s*([%w%-]+)%s*=%s*(.-)%s*$")
    if key == "macos-option-as-alt" then
      out.option_as_alt = value
    elseif key == "keybind" then
      if value == "clear" then
        out.keybinds = {}
      else
        local trigger, action = value:match("^(.-[^+])=(.*)$")
        local token, flags = M.ghostty_trigger_key(trigger or "")
        if token then
          local code = vim.keycode(token)
          out.keybinds[code] = action ~= "unbind" and { trigger = trigger, action = action, flags = flags } or nil
        end
      end
    end
  end
  return out
end

--- Ghostty keybinds that take a mapped key away from Neovim.
---@param effective table `ghostty_parse` of the effective configuration
---@param user table `ghostty_parse` of the user's config files
---@param keys table<string, string[]> `mapped_keys()`
---@return { trigger: string, action: string, key: string, names: string[] }[]
function M.ghostty_conflicts(effective, user, keys)
  local performable = {}
  for _, t in ipairs(GHOSTTY_DEFAULT_PERFORMABLE) do
    performable[vim.keycode(t)] = true
  end
  local out = {}
  for token, names in pairs(keys) do
    local code = vim.keycode(token)
    local bind = effective.keybinds[code]
    if bind then
      local own = user.keybinds[code]
      local flags = own and own.flags or bind.flags
      if not (flags.performable or flags.unconsumed or (not own and performable[code])) then
        out[#out + 1] = { trigger = bind.trigger, action = bind.action, key = token, names = names }
      end
    end
  end
  table.sort(out, function(a, b)
    return a.trigger < b.trigger
  end)
  return out
end

--- Ghostty's effective configuration (from the CLI when it is installed
--- here, else nil) and the user's config files, as `ghostty_parse` tables.
---@return table? effective, table user
local function ghostty_config()
  local xdg = vim.env.XDG_CONFIG_HOME or vim.fs.joinpath(vim.env.HOME or "~", ".config")
  local lines = {}
  for _, path in ipairs({
    vim.fs.joinpath(xdg, "ghostty", "config"),
    vim.fs.joinpath(xdg, "ghostty", "config.ghostty"),
    vim.fs.joinpath(vim.env.HOME or "~", "Library", "Application Support", "com.mitchellh.ghostty", "config"),
  }) do
    if vim.fn.filereadable(path) == 1 then
      vim.list_extend(lines, vim.fn.readfile(path))
    end
  end
  local user = M.ghostty_parse(lines)
  local exe = vim.fn.exepath("ghostty")
  if exe == "" and vim.fn.has("mac") == 1 then
    exe = "/Applications/Ghostty.app/Contents/MacOS/ghostty"
  end
  if vim.fn.executable(exe) == 1 then
    local out = run({ exe, "+show-config" })
    if out then
      return M.ghostty_parse(vim.split(out, "\n")), user
    end
  end
  return nil, user
end

local TEST_KEY = "test a key in insert mode with <C-v> followed by the key: Neovim inserts what it received"

--- Whether Neovim runs inside tmux, and whether in Ghostty as far as the
--- environment tells (inside tmux, the attached client says so too).
function M.terminal_env()
  local tmux = (vim.env.TMUX or "") ~= ""
  local ghostty = vim.env.TERM_PROGRAM == "ghostty"
    or vim.env.TERM == "xterm-ghostty"
    or (vim.env.GHOSTTY_RESOURCES_DIR or "") ~= ""
  return tmux, ghostty
end

--- Only shown in tmux or Ghostty: the setups it knows how to check.
local function check_terminal_keys(h)
  local in_tmux, ghostty = M.terminal_env()
  if not in_tmux and not ghostty then
    return
  end
  h.start("org.nvim terminal keys")
  local keys = M.mapped_keys()
  local needs = keys_by_need(keys)
  local function describe(list)
    return table.concat(
      vim.tbl_map(function(t)
        return t .. " (" .. table.concat(keys[t], ", ") .. ")"
      end, list),
      "; "
    )
  end
  if #needs.extended == 0 and #needs.modified == 0 and #needs.meta == 0 then
    h.ok("No mapping needs special terminal key support")
    return
  end
  if #needs.extended > 0 then
    h.info("Keys that need extended key reporting (CSI u): " .. table.concat(needs.extended, " "))
  end

  if in_tmux then
    local st = M.tmux_state()
    ghostty = ghostty or (st.termname or ""):match("ghostty") ~= nil
    local conf = st.config or "~/.tmux.conf"
    if not st.version and not st.extended_keys then
      h.warn("Inside tmux, but `tmux` can't be queried; its key settings are not checked")
    elseif st.version and st.version < 3.2 then
      if #needs.extended > 0 then
        h.warn(
          string.format(
            "tmux %s can't pass extended keys; these mappings won't work: %s",
            st.version,
            describe(needs.extended)
          ),
          { "Upgrade to tmux 3.2 or later" }
        )
      end
    else
      if st.extended_keys == "on" or st.extended_keys == "always" then
        h.ok("tmux extended-keys " .. st.extended_keys .. (st.format and (" (format " .. st.format .. ")") or ""))
      elseif #needs.extended > 0 then
        h.warn("tmux extended-keys is off: these mappings can't be typed: " .. describe(needs.extended), {
          "Add to " .. conf .. ": set -s extended-keys on",
          "Then restart tmux (tmux kill-server) or run: tmux source-file " .. conf,
        })
      end
      if st.termname and st.termname ~= "" and #needs.extended > 0 then
        if (st.features or ""):match("extkeys") then
          h.ok(string.format("tmux sends extended keys to the outer terminal (%s)", st.termname))
        else
          h.warn(
            string.format(
              "tmux doesn't know the outer terminal (%s) supports extended keys, so it never turns them on there;"
                .. " %s arrive as plain keys",
              st.termname,
              table.concat(needs.extended, " ")
            ),
            M.tmux_declares_extkeys(st.terminal_features, st.termname)
                and {
                  "terminal-features already has it, but this client attached before it was set:"
                    .. " detach and reattach (or restart tmux)",
                }
              or {
                string.format("Add to %s: set -as terminal-features '%s:extkeys'", conf, st.termname),
                "Then detach and reattach (or restart tmux): features are read when a client attaches",
              }
          )
        end
      end
    end
    if st.xterm_keys == "off" and #needs.modified > 0 then
      h.warn("tmux xterm-keys is off: modified arrows may not work: " .. describe(needs.modified), {
        "Add to " .. conf .. ": set -g xterm-keys on",
      })
    elseif st.xterm_keys == "on" then
      h.ok("tmux xterm-keys on")
    end
  end

  if ghostty then
    local effective, user = ghostty_config()
    local g = effective or user
    if vim.fn.has("mac") == 1 and #needs.meta > 0 then
      local v = g.option_as_alt
      if v == "true" then
        h.ok("Ghostty macos-option-as-alt = true")
      elseif v == "left" or v == "right" then
        h.info(string.format("Ghostty macos-option-as-alt = %s: Meta mappings only work with the %s Option key", v, v))
      else
        h.warn("Ghostty sends Option+key as a special character: these mappings won't work: " .. describe(needs.meta), {
          "Add to the Ghostty config: macos-option-as-alt = true",
        })
      end
    end
    local conflicts = M.ghostty_conflicts(g, user, keys)
    for _, c in ipairs(conflicts) do
      h.warn(
        string.format("Ghostty keybind %s=%s takes %s from %s", c.trigger, c.action, c.key, table.concat(c.names, ", ")),
        { string.format("Free it in the Ghostty config: keybind = %s=unbind", c.trigger) }
      )
    end
    if #conflicts == 0 then
      h.ok("No Ghostty keybind takes a mapped key" .. (effective and "" or " (only the config file was checked)"))
    end
  end
  h.info("If a mapping does nothing, " .. TEST_KEY)
end

function M.check()
  local h = vim.health
  h.start("org.nvim")
  if vim.fn.has("nvim-0.10") == 1 then
    h.ok("Neovim " .. tostring(vim.version()))
  else
    h.error("Neovim >= 0.10 is required")
  end

  local cfg = require("org.config").opts
  local utils = require("org.utils")
  local dir = utils.expand(cfg.org_directory, vim.fn.getcwd())
  if utils.is_dir(dir) then
    h.ok("org_directory: " .. dir)
  else
    h.warn("org_directory does not exist: " .. dir, { "mkdir -p " .. dir })
  end
  local files = require("org.files").agenda_file_paths()
  if #files > 0 then
    h.ok(string.format("%d agenda file(s) found", #files))
  else
    h.warn("No agenda files match `agenda_files`", { vim.inspect(cfg.agenda_files) })
  end
  local notes = utils.expand(cfg.default_notes_file)
  if utils.exists(notes) then
    h.ok("default_notes_file: " .. notes)
  else
    h.info("default_notes_file will be created on first capture: " .. notes)
  end

  -- keyword config
  local ok, err = pcall(function()
    local t = require("org.todo_keywords").global()
    assert(#t.keywords > 0, "no keywords")
  end)
  if ok then
    h.ok("todo_keywords: " .. table.concat(require("org.todo_keywords").global():names(), " "))
  else
    h.error("todo_keywords invalid: " .. tostring(err))
  end

  -- conflicting plugins
  if package.loaded["orgmode"] then
    h.warn("nvim-orgmode is also loaded; both plugins handle *.org files")
  end

  h.start("org.nvim external tools")
  local pandoc = (cfg.export.pandoc or {}).cmd or "pandoc"
  if type(pandoc) == "table" then
    pandoc = pandoc[1]
  end
  if vim.fn.executable(pandoc) == 1 then
    h.ok("pandoc found (LaTeX/PDF/DOCX/ODT/... export)")
  else
    h.warn("pandoc not found: export to LaTeX/PDF/DOCX/ODT via pandoc unavailable (HTML/Markdown/text work)")
  end
  local seen = {}
  for lang, spec in pairs(cfg.babel.languages or {}) do
    local cmd = type(spec) == "table" and spec.cmd
    local exe = type(cmd) == "table" and cmd[1] or type(cmd) == "string" and vim.split(cmd, "%s+")[1] or nil
    if exe and not seen[exe] then
      seen[exe] = true
      if exe == "nvim" or vim.fn.executable(exe) == 1 then
        h.ok(string.format("babel: %s (%s)", exe, lang))
      else
        h.info(string.format("babel: %s not found (src blocks in %s can't run)", exe, lang))
      end
    end
  end
  if vim.fn.has("mac") == 1 then
    h.info("notifications use osascript on macOS")
  elseif vim.fn.executable("notify-send") == 1 then
    h.ok("notify-send available for notifications")
  end

  h.start("org.nvim completion")
  if pcall(require, "blink.cmp") then
    local ok_cfg, bcfg = pcall(require, "blink.cmp.config")
    local provider = ok_cfg and bcfg.sources and bcfg.sources.providers and bcfg.sources.providers.org
    if provider and provider.module == "org.completion.blink" then
      h.ok("blink.cmp org source configured")
    else
      h.info('blink.cmp detected: add provider `org = { name = "Org", module = "org.completion.blink" }`')
    end
  elseif pcall(require, "cmp") then
    h.info('nvim-cmp detected: register_source("org", require("org.completion.cmp").new())')
  else
    h.info("Use <C-x><C-o> (omnifunc) for completion")
  end

  check_terminal_keys(h)
end

return M
