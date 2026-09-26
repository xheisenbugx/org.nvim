---@mod org.health.terminal Terminal key checks of :checkhealth org
---
--- Legacy terminal input can't encode every key org maps: <C-CR>, <S-CR>,
--- <C-,> and friends arrive as plain <CR> or `,` unless the terminal sends
--- extended keys (CSI u / modifyOtherKeys), and tmux only passes those on
--- when configured to. Modified arrows need xterm-style encodings, Meta
--- keys need the terminal to send Option/Alt as ESC, and a terminal's own
--- keybinds take keys before Neovim sees them.
---
--- Shown only inside tmux or one of the terminals it knows (Ghostty, kitty,
--- WezTerm, Alacritty).

local M = {}

---------------------------------------------------------------------------
-- Keys
---------------------------------------------------------------------------

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

-- Key and modifier names as terminal configs write them (lowercase, no
-- underscores) -> Neovim key names.
local KEY_NAMES = {
  cr = "CR",
  bs = "BS",
  enter = "CR",
  ["return"] = "CR",
  tab = "Tab",
  backspace = "BS",
  back = "BS",
  escape = "Esc",
  esc = "Esc",
  space = "Space",
  up = "Up",
  arrowup = "Up",
  uparrow = "Up",
  down = "Down",
  arrowdown = "Down",
  downarrow = "Down",
  left = "Left",
  arrowleft = "Left",
  leftarrow = "Left",
  right = "Right",
  arrowright = "Right",
  rightarrow = "Right",
  home = "Home",
  ["end"] = "End",
  pageup = "PageUp",
  pagedown = "PageDown",
  insert = "Insert",
  delete = "Del",
  del = "Del",
  comma = ",",
  period = ".",
  semicolon = ";",
  apostrophe = "'",
  quote = "'",
  slash = "/",
  backslash = "\\",
  minus = "-",
  equal = "=",
  plus = "+",
  grave = "`",
  backquote = "`",
  bracketleft = "[",
  bracketright = "]",
  leftbracket = "[",
  rightbracket = "]",
}
local MOD_NAMES = {
  ctrl = "C",
  control = "C",
  alt = "M",
  opt = "M",
  option = "M",
  meta = "M",
  shift = "S",
  super = "D",
  cmd = "D",
  command = "D",
  win = "D",
}

--- The Neovim key token of a key as a terminal config names it
--- (`{ "ctrl", "shift" }, "enter"` -> `<C-S-CR>`); nil for unknown
--- modifiers or keys, and for unmodified printable keys.
---@param mod_names string[]
---@param key_name string
---@return string?
function M.key_token(mod_names, key_name)
  local mods = {}
  for _, m in ipairs(mod_names) do
    local v = MOD_NAMES[m:lower()]
    if not v then
      return nil
    end
    if not vim.tbl_contains(mods, v) then
      mods[#mods + 1] = v
    end
  end
  local raw = key_name:gsub("^phys:", ""):gsub("^mapped:", "")
  local norm = raw:lower():gsub("_", ""):gsub("^key(%a)$", "%1"):gsub("^digit(%d)$", "%1")
  local key = KEY_NAMES[norm] or (norm:match("^f%d%d?$") and norm:upper()) or nil
  if not key and vim.fn.strchars(raw) == 1 then
    key = raw:match("^%a$") and raw:lower() or raw
  elseif not key and vim.fn.strchars(norm) == 1 then
    key = norm
  end
  if not key or (#mods == 0 and vim.fn.strchars(key) == 1) then
    return nil
  end
  if key:match("^%a$") and vim.tbl_contains(mods, "S") and not vim.tbl_contains(mods, "C") then
    -- alt+shift+h is <M-H>
    key = key:upper()
    mods = vim.tbl_filter(function(m)
      return m ~= "S"
    end, mods)
  end
  table.sort(mods)
  return "<" .. table.concat(mods, "-") .. (#mods > 0 and "-" or "") .. key .. ">"
end

--- Modifier names and key of a `+`-joined trigger (`ctrl+shift+enter`,
--- `ctrl++`); for a sequence (`ctrl+a>n`) the first key.
---@return string[] mods, string? key
local function split_plus(trigger)
  trigger = trigger:match("^(.-)>.") or trigger
  local mods, key = {}, nil
  for part in (trigger .. "+"):gmatch("(.-)%+") do
    if part == "" and not key then
      part = "+"
    end
    if MOD_NAMES[part:lower()] then
      mods[#mods + 1] = part
    elseif part ~= "" then
      key = part
    end
  end
  return mods, key
end

--- Terminal keybinds that take a mapped key away from Neovim.
---@param binds { trigger: string, action: string, token: string, advice: string }[] keys the terminal consumes
---@param keys table<string, string[]> `mapped_keys()`
---@return { trigger: string, action: string, key: string, names: string[], advice: string }[]
function M.conflicts(binds, keys)
  local by_code = {}
  for token, names in pairs(keys) do
    by_code[vim.keycode(token)] = { token = token, names = names }
  end
  local out, seen = {}, {}
  for _, b in ipairs(binds) do
    local m = by_code[vim.keycode(b.token)]
    if m and not seen[m.token] then
      seen[m.token] = true
      out[#out + 1] = { trigger = b.trigger, action = b.action, key = m.token, names = m.names, advice = b.advice }
    end
  end
  table.sort(out, function(a, b)
    return a.trigger < b.trigger
  end)
  return out
end

local function run(cmd, timeout)
  local ok, res = pcall(vim.system, cmd, { text = true })
  if not ok then
    return nil
  end
  local r = res:wait(timeout or 2000)
  if r.code ~= 0 then
    return nil
  end
  return vim.trim(r.stdout or "")
end

local function home(...)
  return vim.fs.joinpath(vim.env.HOME or "~", ...)
end

local function xdg_config(...)
  return vim.fs.joinpath(vim.env.XDG_CONFIG_HOME or home(".config"), ...)
end

--- Lines of the first readable file of `paths` (all of them with `all`).
--- (`paths` may have holes: unset environment variables.)
local function read_lines(paths, all)
  local lines = {}
  for i = 1, table.maxn(paths) do
    local path = paths[i]
    if path and vim.fn.filereadable(path) == 1 then
      vim.list_extend(lines, vim.fn.readfile(path))
      if not all then
        break
      end
    end
  end
  return lines
end

--- A terminal's executable: on PATH or in its macOS app bundle.
local function executable(name, app)
  local exe = vim.fn.exepath(name)
  if exe == "" and vim.fn.has("mac") == 1 then
    exe = "/Applications/" .. app .. ".app/Contents/MacOS/" .. name
  end
  return vim.fn.executable(exe) == 1 and exe or nil
end

---------------------------------------------------------------------------
-- tmux
---------------------------------------------------------------------------

--- tmux settings that decide which keys reach Neovim.
---@param exec? fun(cmd: string[]): string? (tests)
function M.tmux_state(exec)
  exec = exec or run
  local st = {}
  local v = exec({ "tmux", "-V" })
  st.version = v and tonumber(v:match("(%d+%.%d+)"))
  st.extended_keys = exec({ "tmux", "show", "-sv", "extended-keys" })
  st.format = exec({ "tmux", "show", "-sv", "extended-keys-format" })
  st.xterm_keys = exec({ "tmux", "show", "-gv", "xterm-keys" })
  local client = exec({
    "tmux",
    "display",
    "-p",
    "#{client_termname}\t#{client_termfeatures}\t#{config_files}\t#{client_termtype}",
  })
  if client then
    local parts = vim.split(client, "\t")
    st.termname, st.features = parts[1], parts[2]
    st.config = parts[3] and parts[3] ~= "" and vim.fn.fnamemodify(vim.split(parts[3], ",")[1], ":~") or nil
    st.termtype = parts[4] ~= "" and parts[4] or nil
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

local function check_tmux(h, needs, describe)
  local st = M.tmux_state()
  local conf = st.config or "~/.tmux.conf"
  if not st.version and not st.extended_keys then
    h.warn("Inside tmux, but `tmux` can't be queried; its key settings are not checked")
    return st
  end
  if st.version and st.version < 3.2 then
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
  return st
end

---------------------------------------------------------------------------
-- Ghostty
---------------------------------------------------------------------------

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
  local mods, key = split_plus(trigger)
  return key and M.key_token(mods, key) or nil, flags
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
          out.keybinds[code] = action ~= "unbind"
              and { trigger = trigger, action = action, flags = flags, token = token }
            or nil
        end
      end
    end
  end
  return out
end

--- The keys Ghostty consumes.
---@param effective table `ghostty_parse` of the effective configuration
---@param user table `ghostty_parse` of the user's config files
function M.ghostty_binds(effective, user)
  local performable = {}
  for _, t in ipairs(GHOSTTY_DEFAULT_PERFORMABLE) do
    performable[vim.keycode(t)] = true
  end
  local out = {}
  for code, bind in pairs(effective.keybinds) do
    local own = user.keybinds[code]
    local flags = own and own.flags or bind.flags
    if not (flags.performable or flags.unconsumed or (not own and performable[code])) then
      out[#out + 1] = {
        trigger = bind.trigger,
        action = bind.action,
        token = bind.token,
        advice = string.format("Free it in the Ghostty config: keybind = %s=unbind", bind.trigger),
      }
    end
  end
  return out
end

local function load_ghostty()
  local user = M.ghostty_parse(read_lines({
    xdg_config("ghostty", "config"),
    xdg_config("ghostty", "config.ghostty"),
    home("Library", "Application Support", "com.mitchellh.ghostty", "config"),
  }, true))
  local effective
  local exe = executable("ghostty", "Ghostty")
  local out = exe and run({ exe, "+show-config" })
  if out then
    effective = M.ghostty_parse(vim.split(out, "\n"))
  end
  local g = effective or user
  local alt = ({ ["true"] = "both", left = "left", right = "right" })[g.option_as_alt or ""] or "none"
  return {
    binds = M.ghostty_binds(g, user),
    option_as_alt = alt,
    option_advice = "Add to the Ghostty config: macos-option-as-alt = true",
    partial = not effective,
  }
end

---------------------------------------------------------------------------
-- kitty
---------------------------------------------------------------------------

-- kitty's key codes of functional keys (keyboard protocol) -> Neovim names
local KITTY_FUNCTIONAL = {
  [57344] = "Esc",
  [57345] = "CR",
  [57346] = "Tab",
  [57347] = "BS",
  [57348] = "Insert",
  [57349] = "Del",
  [57350] = "Left",
  [57351] = "Right",
  [57352] = "Up",
  [57353] = "Down",
  [57354] = "PageUp",
  [57355] = "PageDown",
  [57356] = "Home",
  [57357] = "End",
}
for i = 1, 12 do
  KITTY_FUNCTIONAL[57363 + i] = "F" .. i
end
local KITTY_KEY_NAMES = {
  Esc = "escape",
  CR = "enter",
  Tab = "tab",
  BS = "backspace",
  Insert = "insert",
  Del = "delete",
  Left = "left",
  Right = "right",
  Up = "up",
  Down = "down",
  PageUp = "page_up",
  PageDown = "page_down",
  Home = "home",
  End = "end",
}

-- kitty's default shortcuts that can collide with org keys (the full
-- list is used when kitty itself can report its configuration).
local KITTY_DEFAULTS = {
  { "kitty_mod+enter", "new_window" },
  { "kitty_mod+up", "scroll_line_up" },
  { "kitty_mod+down", "scroll_line_down" },
  { "kitty_mod+page_up", "scroll_page_up" },
  { "kitty_mod+page_down", "scroll_page_down" },
  { "kitty_mod+home", "scroll_home" },
  { "kitty_mod+end", "scroll_end" },
  { "kitty_mod+right", "next_tab" },
  { "kitty_mod+left", "previous_tab" },
  { "ctrl+tab", "next_tab" },
  { "kitty_mod+tab", "previous_tab" },
  { "kitty_mod+.", "move_tab_forward" },
  { "kitty_mod+,", "move_tab_backward" },
  { "kitty_mod+delete", "clear_terminal reset active" },
  { "kitty_mod+escape", "kitty_shell window" },
  { "kitty_mod+backspace", "change_font_size all 0" },
  { "shift+insert", "paste_from_selection" },
}

-- Prints kitty's effective option-as-alt and shortcuts (the last
-- definition of each key wins; no_op is the empty definition).
local KITTY_DUMP = [[
import os
from kitty.config import load_config
from kitty.constants import config_dir
p = os.path.join(config_dir, "kitty.conf")
o = load_config(*([p] if os.path.exists(p) else []))
print("opt\t%d" % int(o.macos_option_as_alt))
for k, v in o.keyboard_modes[""].keymap.items():
    if v:
        print("bind\t%d\t%d\t%s" % (k.mods, k.key, v[-1].definition))
]]

local KITTY_ALT = { [0] = "none", [1] = "right", [2] = "left", [3] = "both" }

--- Actions that take the key (no_op and sending keys/text on purpose don't).
local function kitty_consumes(action)
  local a = vim.trim(action or "")
  return a ~= "" and a ~= "no_op" and not a:match("^send_text") and not a:match("^send_key")
end

--- `kitty +runpy` dump lines -> binds and option-as-alt.
---@param lines string[]
function M.kitty_parse_dump(lines)
  local out = { binds = {} }
  for _, line in ipairs(lines) do
    local f = vim.split(line, "\t")
    if f[1] == "opt" then
      out.option_as_alt = KITTY_ALT[tonumber(f[2])]
    elseif f[1] == "bind" and #f >= 4 then
      local mods, code, action = tonumber(f[2]), tonumber(f[3]), table.concat(f, "\t", 4)
      if mods and code and mods < 16 and kitty_consumes(action) then
        local names = {}
        for _, m in ipairs({ { 4, "ctrl" }, { 2, "alt" }, { 1, "shift" }, { 8, "super" } }) do
          if bit.band(mods, m[1]) ~= 0 then
            names[#names + 1] = m[2]
          end
        end
        local key = KITTY_FUNCTIONAL[code] or (code < 57344 and vim.fn.nr2char(code)) or nil
        local token = key and M.key_token(names, key)
        if token then
          names[#names + 1] = KITTY_KEY_NAMES[key] or key
          local trigger = table.concat(names, "+")
          out.binds[#out.binds + 1] = { trigger = trigger, action = action, token = token }
        end
      end
    end
  end
  return out
end

--- kitty.conf lines -> binds (kitty's defaults with the user's maps) and
--- option-as-alt, when kitty can't report its configuration itself.
---@param lines string[]
function M.kitty_parse_conf(lines)
  local kitty_mod, clear, alt = "ctrl+shift", false, "none"
  local maps = {}
  for _, line in ipairs(lines) do
    local opt, value = line:match("^%s*([%w_]+)%s+(.-)%s*$")
    if opt == "kitty_mod" then
      kitty_mod = value
    elseif opt == "clear_all_shortcuts" then
      clear = value == "yes"
    elseif opt == "macos_option_as_alt" then
      alt = ({ yes = "both", both = "both", left = "left", right = "right" })[value] or "none"
    elseif opt == "map" then
      local words = vim.split(value, "%s+", { trimempty = true })
      local i = 1
      while words[i] and words[i]:match("^%-%-") do
        -- --when-focus-on=x / --mode x / --new-mode x
        i = i + (words[i]:find("=", 1, true) and 1 or 2)
      end
      if words[i] then
        maps[#maps + 1] = { words[i], table.concat(words, " ", i + 1) }
      end
    end
  end
  local by_code = {}
  local function put(trigger, action)
    local expanded = trigger:gsub("kitty_mod", kitty_mod)
    local mods, key = split_plus(expanded)
    local token = key and M.key_token(mods, key)
    if token then
      by_code[vim.keycode(token)] = { trigger = expanded, action = action, token = token }
    end
  end
  if not clear then
    for _, d in ipairs(KITTY_DEFAULTS) do
      put(d[1], d[2])
    end
  end
  for _, m in ipairs(maps) do
    put(m[1], m[2])
  end
  local binds = {}
  for _, b in pairs(by_code) do
    if kitty_consumes(b.action) then
      binds[#binds + 1] = b
    end
  end
  return { binds = binds, option_as_alt = alt }
end

local function load_kitty()
  local r
  local exe = executable("kitty", "kitty")
  local out = exe and run({ exe, "+runpy", KITTY_DUMP }, 5000)
  if out and out:match("^opt\t") then
    r = M.kitty_parse_dump(vim.split(out, "\n"))
  else
    local dir = vim.env.KITTY_CONFIG_DIRECTORY or xdg_config("kitty")
    r = M.kitty_parse_conf(read_lines({ vim.fs.joinpath(dir, "kitty.conf") }))
    r.partial = true
  end
  for _, b in ipairs(r.binds) do
    b.advice = string.format("Pass it to Neovim, in kitty.conf: map %s no_op", b.trigger)
  end
  r.option_advice = "Add to kitty.conf: macos_option_as_alt yes"
  return r
end

---------------------------------------------------------------------------
-- WezTerm
---------------------------------------------------------------------------

-- WezTerm's default key assignments that can collide with org keys (the
-- full list is used when `wezterm show-keys` can report it).
local WEZTERM_DEFAULTS = {
  { "ALT", "Enter", "ToggleFullScreen" },
  { "CTRL", "Tab", "ActivateTabRelative(1)" },
  { "CTRL|SHIFT", "Tab", "ActivateTabRelative(-1)" },
  { "CTRL", "PageUp", "ActivateTabRelative(-1)" },
  { "CTRL", "PageDown", "ActivateTabRelative(1)" },
  { "CTRL|SHIFT", "PageUp", "MoveTabRelative(-1)" },
  { "CTRL|SHIFT", "PageDown", "MoveTabRelative(1)" },
  { "CTRL|SHIFT", "LeftArrow", "ActivatePaneDirection('Left')" },
  { "CTRL|SHIFT", "RightArrow", "ActivatePaneDirection('Right')" },
  { "CTRL|SHIFT", "UpArrow", "ActivatePaneDirection('Up')" },
  { "CTRL|SHIFT", "DownArrow", "ActivatePaneDirection('Down')" },
  { "CTRL|ALT|SHIFT", "LeftArrow", "AdjustPaneSize('Left', 1)" },
  { "CTRL|ALT|SHIFT", "RightArrow", "AdjustPaneSize('Right', 1)" },
  { "CTRL|ALT|SHIFT", "UpArrow", "AdjustPaneSize('Up', 1)" },
  { "CTRL|ALT|SHIFT", "DownArrow", "AdjustPaneSize('Down', 1)" },
  { "SHIFT", "Insert", "PasteFrom('PrimarySelection')" },
  { "CTRL", "Insert", "CopyTo('PrimarySelection')" },
  { "CTRL|SHIFT", "Space", "QuickSelect" },
}

--- Key assignments of a WezTerm `keys = { ... }` table (from `wezterm
--- show-keys --lua` or a wezterm.lua) and its settings.
---@param text string
function M.wezterm_parse(text)
  local out = { entries = {} }
  out.disable_defaults = text:match("disable_default_key_bindings%s*=%s*true") ~= nil
  local left = text:match("send_composed_key_when_left_alt_is_pressed%s*=%s*(%a+)")
  local right = text:match("send_composed_key_when_right_alt_is_pressed%s*=%s*(%a+)")
  out.left_composed = left and left == "true" or nil
  out.right_composed = right and right == "true" or nil
  local keys = ("\n" .. text):match("[^_%w]keys%s*=%s*(%b{})")
  if not keys then
    return out
  end
  for entry in keys:sub(2, -2):gmatch("%b{}") do
    local key = entry:match("key%s*=%s*'([^']*)'") or entry:match('key%s*=%s*"([^"]*)"')
    local mods = entry:match("mods%s*=%s*'([^']*)'") or entry:match('mods%s*=%s*"([^"]*)"') or "NONE"
    local action = vim.trim(entry:match("action%s*=%s*(.-)%s*,?%s*}$") or "")
    if key then
      out.entries[#out.entries + 1] = { key = key, mods = mods, action = action }
    end
  end
  return out
end

--- The keys WezTerm consumes.
---@param effective table `wezterm_parse` of `show-keys` output, or nil
---@param user table `wezterm_parse` of the user's config
function M.wezterm_binds(effective, user)
  local entries = {}
  if effective then
    entries = effective.entries
  else
    if not user.disable_defaults then
      for _, d in ipairs(WEZTERM_DEFAULTS) do
        entries[#entries + 1] = { mods = d[1], key = d[2], action = d[3] }
      end
    end
    vim.list_extend(entries, user.entries)
  end
  local by_code = {}
  for _, e in ipairs(entries) do
    local mods = {}
    local ok = true
    for m in e.mods:gmatch("[^|%s]+") do
      if m:upper() == "LEADER" then
        ok = false
      elseif m:upper() ~= "NONE" then
        mods[#mods + 1] = m
      end
    end
    local token = ok and M.key_token(mods, e.key)
    if token then
      local code = vim.keycode(token)
      if e.action:match("DisableDefaultAssignment") then
        by_code[code] = nil
      elseif e.action:match("SendKey") or e.action:match("SendString") then
        by_code[code] = nil -- sends a key to the program on purpose
      else
        by_code[code] = {
          trigger = e.mods .. "+" .. e.key,
          action = e.action:gsub("^act%.", ""):gsub("^wezterm%.action%.", ""),
          token = token,
          advice = string.format(
            "Pass it to Neovim, in wezterm.lua keys: { key = '%s', mods = '%s', action = wezterm.action.DisableDefaultAssignment }",
            e.key,
            e.mods
          ),
        }
      end
    end
  end
  return vim.tbl_values(by_code)
end

local function load_wezterm()
  local user = M.wezterm_parse(table.concat(
    read_lines({
      vim.env.WEZTERM_CONFIG_FILE,
      xdg_config("wezterm", "wezterm.lua"),
      home(".wezterm.lua"),
    }),
    "\n"
  ))
  local effective
  local exe = executable("wezterm", "WezTerm")
  local out = exe and run({ exe, "show-keys", "--lua" }, 5000)
  if out then
    effective = M.wezterm_parse(out)
  end
  -- Option: left sends Alt and right composes unless configured
  local left_alt = not user.left_composed
  local right_alt = user.right_composed == false
  return {
    binds = M.wezterm_binds(effective, user),
    option_as_alt = left_alt and right_alt and "both" or left_alt and "left" or right_alt and "right" or "none",
    option_advice = "Add to wezterm.lua: config.send_composed_key_when_left_alt_is_pressed = false",
    partial = not effective,
  }
end

---------------------------------------------------------------------------
-- Alacritty
---------------------------------------------------------------------------

--- Key bindings and settings of an alacritty.toml.
---@param lines string[]
function M.alacritty_parse(lines)
  local out = { bindings = {} }
  local function field(s, name)
    return s:match(name .. '%s*=%s*"([^"]*)"') or s:match(name .. "%s*=%s*'([^']*)'")
  end
  local function add(s)
    local key = field(s, "key")
    if key then
      out.bindings[#out.bindings + 1] = {
        key = key,
        mods = field(s, "mods") or "",
        action = field(s, "action"),
        mode = field(s, "mode") or "",
        chars = s:match("chars%s*=") ~= nil,
        command = s:match("command%s*=") ~= nil,
      }
    end
  end
  local block
  for _, line in ipairs(lines) do
    local code = line:gsub("#.*$", "")
    local v = field(code, "option_as_alt")
    if v then
      out.option_as_alt = ({ Both = "both", OnlyLeft = "left", OnlyRight = "right" })[v] or "none"
    end
    if code:match("^%s*%[%[keyboard%.bindings%]%]") then
      if block then
        add(block)
      end
      block = ""
    elseif block and code:match("^%s*%[") then
      add(block)
      block = nil
    elseif block then
      block = block .. "\n" .. code
    end
    for tbl in code:gmatch("%b{}") do
      add(tbl)
    end
  end
  if block then
    add(block)
  end
  return out
end

--- The keys Alacritty consumes: its defaults (only Alt+Enter on Windows
--- touches org keys) with the user's bindings.
---@param user table `alacritty_parse` of the user's config
---@param windows? boolean
function M.alacritty_binds(user, windows)
  local by_code = {}
  local function put(b)
    local mods = vim.split(b.mods, "|", { trimempty = true })
    local token = M.key_token(
      vim.tbl_map(function(m)
        return vim.trim(m)
      end, mods),
      b.key
    )
    if not token then
      return
    end
    local code = vim.keycode(token)
    local mode = b.mode or ""
    local in_nvim = not mode:match("~AltScreen")
      and not mode:match("^Vi")
      and not mode:match("[^~]Vi")
      and not mode:match("^Search")
      and not mode:match("[^~]Search")
    if b.chars or b.action == "ReceiveChar" or not in_nvim or not (b.action or b.command) then
      by_code[code] = nil
    else
      by_code[code] = {
        trigger = (b.mods ~= "" and (b.mods .. "+") or "") .. b.key,
        action = b.action or "command",
        token = token,
        advice = string.format(
          'Pass it to Neovim, in alacritty.toml [keyboard] bindings: { key = "%s", mods = "%s", action = "ReceiveChar" }',
          b.key,
          b.mods
        ),
      }
    end
  end
  if windows then
    put({ key = "Enter", mods = "Alt", action = "ToggleFullscreen" })
  end
  for _, b in ipairs(user.bindings) do
    put(b)
  end
  return vim.tbl_values(by_code)
end

local function load_alacritty()
  local user = M.alacritty_parse(read_lines({
    xdg_config("alacritty", "alacritty.toml"),
    home(".alacritty.toml"),
    vim.env.APPDATA and vim.fs.joinpath(vim.env.APPDATA, "alacritty", "alacritty.toml") or nil,
  }))
  return {
    binds = M.alacritty_binds(user, vim.fn.has("win32") == 1),
    option_as_alt = user.option_as_alt or "none",
    option_advice = 'Add to alacritty.toml: [window] option_as_alt = "Both"',
  }
end

---------------------------------------------------------------------------
-- Terminal detection
---------------------------------------------------------------------------

--- Terminals with checks: `load()` returns `{ binds, option_as_alt,
--- option_advice, partial }` (overridden in tests).
M.terminals = {
  ghostty = { name = "Ghostty", load = load_ghostty },
  kitty = { name = "kitty", load = load_kitty },
  wezterm = { name = "WezTerm", load = load_wezterm },
  alacritty = { name = "Alacritty", load = load_alacritty },
}

--- The terminal the environment names: TERM_PROGRAM / TERM first, then
--- the variables each terminal exports (which tmux may have inherited).
---@param env? table defaults to vim.env
---@return string? id ghostty|kitty|wezterm|alacritty
function M.detect_env(env)
  env = env or vim.env
  local function set(name)
    return (env[name] or "") ~= ""
  end
  local program = (env.TERM_PROGRAM or ""):lower()
  local term = env.TERM or ""
  if program == "ghostty" or term == "xterm-ghostty" then
    return "ghostty"
  elseif program == "wezterm" or term == "wezterm" then
    return "wezterm"
  elseif program == "kitty" or term == "xterm-kitty" then
    return "kitty"
  elseif term:match("^alacritty") then
    return "alacritty"
  elseif set("GHOSTTY_RESOURCES_DIR") then
    return "ghostty"
  elseif set("KITTY_WINDOW_ID") or set("KITTY_PID") then
    return "kitty"
  elseif set("WEZTERM_PANE") or set("WEZTERM_EXECUTABLE") then
    return "wezterm"
  elseif set("ALACRITTY_WINDOW_ID") or set("ALACRITTY_SOCKET") or set("ALACRITTY_LOG") then
    return "alacritty"
  end
end

--- The terminal of the attached tmux client, from its TERM and XTVERSION.
---@return string?
function M.detect_client(termname, termtype)
  local s = ((termtype or "") .. " " .. (termname or "")):lower()
  for _, id in ipairs({ "ghostty", "kitty", "wezterm", "alacritty" }) do
    if s:find(id, 1, true) then
      return id
    end
  end
end

--- Whether Neovim runs inside tmux, and the terminal the environment names.
---@return boolean tmux, string? terminal
function M.terminal_env()
  return (vim.env.TMUX or "") ~= "", M.detect_env()
end

---------------------------------------------------------------------------
-- The check
---------------------------------------------------------------------------

local TEST_KEY = "test a key in insert mode with <C-v> followed by the key: Neovim inserts what it received"

local function check_terminal(h, id, keys, needs, describe)
  local t = M.terminals[id]
  local ok, cfg = pcall(t.load)
  if not ok then
    h.info(string.format("%s detected, but its configuration can't be read: %s", t.name, cfg))
    return
  end
  if vim.fn.has("mac") == 1 and #needs.meta > 0 then
    local v = cfg.option_as_alt
    if v == "both" then
      h.ok(t.name .. ": Option sends Alt")
    elseif v == "left" or v == "right" then
      h.info(string.format("%s: only the %s Option key sends Alt, so Meta mappings need that one", t.name, v))
    else
      h.warn(
        t.name .. " sends Option+key as a special character: these mappings won't work: " .. describe(needs.meta),
        { cfg.option_advice }
      )
    end
  end
  local conflicts = M.conflicts(cfg.binds, keys)
  for _, c in ipairs(conflicts) do
    h.warn(
      string.format(
        "%s keybind %s (%s) takes %s from %s",
        t.name,
        c.trigger,
        c.action,
        c.key,
        table.concat(c.names, ", ")
      ),
      { c.advice }
    )
  end
  if #conflicts == 0 then
    h.ok(
      string.format("No %s keybind takes a mapped key", t.name)
        .. (cfg.partial and " (from the config file and the known defaults)" or "")
    )
  end
end

---@param h table vim.health
function M.check(h)
  local in_tmux, term = M.terminal_env()
  if not in_tmux and not term then
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
    local st = check_tmux(h, needs, describe)
    -- the attached client is the terminal in use; the environment may
    -- be the one tmux was started from
    term = M.detect_client(st.termname, st.termtype) or term
  end
  if term then
    check_terminal(h, term, keys, needs, describe)
  end
  h.info("If a mapping does nothing, " .. TEST_KEY)
end

return M
