local term = require("org.health.terminal")

--- The Neovim keys of a list of terminal binds, sorted.
local function tokens(binds)
  local out = vim.tbl_map(function(b)
    return b.token
  end, binds)
  table.sort(out)
  return out
end

describe("health: terminal keys", function()
  it("classifies what each key needs from the terminal", function()
    local cases = {
      ["<C-CR>"] = "extended",
      ["<S-CR>"] = "extended",
      ["<C-S-CR>"] = "extended",
      ["<M-S-CR>"] = "extended",
      ["<C-Tab>"] = "extended",
      ["<C-,>"] = "extended",
      ["<C-'>"] = "extended",
      ["<C-#>"] = "extended",
      ["<C-S-a>"] = "extended",
      ["<S-Up>"] = "modified",
      ["<C-S-Left>"] = "modified",
      ["<M-Down>"] = "modified",
      ["<M-CR>"] = "meta",
      ["<M-h>"] = "meta",
      ["<M-H>"] = "meta",
      ["<C-M-t>"] = "meta",
      ["<M-{>"] = "meta",
    }
    for key, need in pairs(cases) do
      eq(need, term.key_needs(key), key)
    end
    for _, key in ipairs({ "<C-c>", "<C-x>", "<S-Tab>", "<C-Space>", "<CR>", "<Tab>", "<leader>", "<C-_>" }) do
      eq(nil, term.key_needs(key), key)
    end
  end)

  it("collects the key tokens of the configured mappings", function()
    local keys = term.mapped_keys()
    ok(keys["<C-CR>"], "<C-CR> is mapped by default")
    ok(vim.tbl_contains(keys["<C-CR>"], "emacs.insert_heading"), vim.inspect(keys["<C-CR>"]))
    ok(keys["<C-c>"])
  end)

  it("converts terminal key names to Neovim keys", function()
    eq("<C-S-CR>", term.key_token({ "ctrl", "shift" }, "enter"))
    eq("<C-S-CR>", term.key_token({ "CTRL", "SHIFT" }, "Return"))
    eq("<M-Left>", term.key_token({ "alt" }, "arrow_left"))
    eq("<M-Left>", term.key_token({ "ALT" }, "LeftArrow"))
    eq("<M-Left>", term.key_token({ "Alt" }, "ArrowLeft"))
    eq("<C-Tab>", term.key_token({ "Control" }, "Tab"))
    eq("<C-,>", term.key_token({ "ctrl" }, "comma"))
    eq("<C-,>", term.key_token({ "ctrl" }, ","))
    eq("<M-H>", term.key_token({ "alt", "shift" }, "h"))
    eq("<C-S-Space>", term.key_token({ "CTRL", "SHIFT" }, "phys:Space"))
    eq("<S-F5>", term.key_token({ "shift" }, "F5"))
    eq("<D-t>", term.key_token({ "super" }, "t"))
    eq(nil, term.key_token({}, "a"), "unmodified printable key")
    eq(nil, term.key_token({ "LEADER" }, "a"), "unknown modifier")
    eq(nil, term.key_token({ "ctrl" }, "copy"), "unknown key")
  end)

  it("finds the terminal keybinds that take mapped keys", function()
    local keys = { ["<C-Tab>"] = { "emacs.force_cycle_archived" }, ["<C-CR>"] = { "emacs.insert_heading" } }
    local found = term.conflicts({
      { trigger = "ctrl+tab", action = "next_tab", token = "<C-Tab>", advice = "unbind" },
      { trigger = "ctrl+t", action = "new_tab", token = "<C-t>", advice = "unbind" },
    }, keys)
    eq(
      { { trigger = "ctrl+tab", action = "next_tab", key = "<C-Tab>", names = keys["<C-Tab>"], advice = "unbind" } },
      found
    )
  end)

  describe("Ghostty", function()
    it("converts triggers", function()
      local function key(t)
        return (term.ghostty_trigger_key(t))
      end
      eq("<C-S-CR>", key("ctrl+shift+enter"))
      eq("<M-Left>", key("alt+arrow_left"))
      eq("<C-,>", key("ctrl+comma"))
      eq("<C-a>", key("ctrl+a>n"), "first key of a sequence")
      eq("<D-=>", key("super+="))
      eq(nil, key("a"))
      eq(nil, key("copy"))
      local token, flags = term.ghostty_trigger_key("performable:global:ctrl+enter")
      eq("<C-CR>", token)
      eq({ performable = true, global = true }, flags)
    end)

    it("knows which keybinds consume keys", function()
      -- `+show-config` output: defaults included, prefix flags dropped
      local effective = term.ghostty_parse({
        "macos-option-as-alt = true",
        "keybind = super+==increase_font_size:1",
        "keybind = shift+arrow_up=adjust_selection:up",
        "keybind = ctrl+tab=next_tab",
        "keybind = alt+arrow_left=esc:b",
        "keybind = ctrl+enter=toggle_fullscreen",
      })
      eq("true", effective.option_as_alt)
      -- shift+arrow_up is performable by default; the user's ctrl+enter is unconsumed
      local user = term.ghostty_parse({ "keybind = unconsumed:ctrl+enter=toggle_fullscreen" })
      eq({ "<C-Tab>", "<D-=>", "<M-Left>" }, tokens(term.ghostty_binds(effective, user)))
      -- a user's own binding of a default-performable key does consume it
      user = term.ghostty_parse({ "keybind = shift+arrow_up=adjust_selection:up" })
      ok(vim.tbl_contains(tokens(term.ghostty_binds(effective, user)), "<S-Up>"))
      -- unbind removes it
      effective = term.ghostty_parse({ "keybind = ctrl+tab=next_tab", "keybind = ctrl+tab=unbind" })
      eq({}, term.ghostty_binds(effective, term.ghostty_parse({})))
    end)
  end)

  describe("kitty", function()
    it("reads kitty's own report of its configuration", function()
      local r = term.kitty_parse_dump({
        "opt\t2",
        "bind\t5\t57345\tnew_window",
        "bind\t5\t57352\t", -- map ctrl+shift+up no_op
        "bind\t4\t57346\tdiscard_event",
        "bind\t2\t57345\tsend_text all \\x1b\\r",
        "bind\t5\t44\tmove_tab_backward",
        "bind\t16\t97\thyper_thing",
      })
      eq("left", r.option_as_alt)
      eq({ "<C-S-,>", "<C-S-CR>", "<C-Tab>" }, tokens(r.binds))
      local enter = vim.tbl_filter(function(b)
        return b.token == "<C-S-CR>"
      end, r.binds)[1]
      eq("ctrl+shift+enter", enter.trigger)
      eq("new_window", enter.action)
    end)

    it("falls back to kitty.conf over the known defaults", function()
      local r = term.kitty_parse_conf({
        "kitty_mod ctrl+alt",
        "macos_option_as_alt yes",
        "map kitty_mod+enter no_op",
        "map --when-focus-on title:vim ctrl+tab no_op",
        "map ctrl+shift+enter new_os_window",
      })
      eq("both", r.option_as_alt)
      local t = tokens(r.binds)
      ok(vim.tbl_contains(t, "<C-M-Right>"), "kitty_mod+right with kitty_mod ctrl+alt: " .. vim.inspect(t))
      ok(vim.tbl_contains(t, "<C-S-CR>"), vim.inspect(t))
      ok(not vim.tbl_contains(t, "<C-M-CR>"), "no_op passes the key on")
      ok(not vim.tbl_contains(t, "<C-Tab>"), "no_op passes the key on")
      r = term.kitty_parse_conf({ "clear_all_shortcuts yes", "map ctrl+shift+enter new_window" })
      eq({ "<C-S-CR>" }, tokens(r.binds))
      eq("none", r.option_as_alt)
    end)
  end)

  describe("WezTerm", function()
    it("reads `wezterm show-keys --lua`", function()
      local effective = term.wezterm_parse([[
local wezterm = require 'wezterm'
local act = wezterm.action

return {
  keys = {
    { key = 'Enter', mods = 'ALT', action = act.ToggleFullScreen },
    { key = 'Tab', mods = 'CTRL', action = act.ActivateTabRelative(1) },
    { key = 'a', mods = 'LEADER', action = act.Nop },
    { key = 'Enter', mods = 'SHIFT', action = act.SendString '\x1b[13;2u' },
  },
  key_tables = {
    copy_mode = {
      { key = 'Tab', mods = 'NONE', action = act.CopyMode 'MoveForwardWord' },
    },
  },
}
]])
      local binds = term.wezterm_binds(effective, term.wezterm_parse(""))
      eq({ "<C-Tab>", "<M-CR>" }, tokens(binds))
      local alt = vim.tbl_filter(function(b)
        return b.token == "<M-CR>"
      end, binds)[1]
      eq("ALT+Enter", alt.trigger)
      eq("ToggleFullScreen", alt.action)
    end)

    it("falls back to wezterm.lua over the known defaults", function()
      local user = term.wezterm_parse([[
local wezterm = require("wezterm")
local config = wezterm.config_builder()
config.send_composed_key_when_left_alt_is_pressed = true
config.keys = {
  { key = "Enter", mods = "ALT", action = wezterm.action.DisableDefaultAssignment },
  { key = ",", mods = "CTRL", action = wezterm.action.ActivateCommandPalette },
}
return config
]])
      eq(true, user.left_composed)
      local t = tokens(term.wezterm_binds(nil, user))
      ok(not vim.tbl_contains(t, "<M-CR>"), "DisableDefaultAssignment frees it")
      ok(vim.tbl_contains(t, "<C-,>"), vim.inspect(t))
      ok(vim.tbl_contains(t, "<C-S-Left>"), "default ActivatePaneDirection")
      user = term.wezterm_parse("config.disable_default_key_bindings = true")
      eq({}, term.wezterm_binds(nil, user))
    end)
  end)

  describe("Alacritty", function()
    local toml = {
      "[window]",
      'option_as_alt = "OnlyLeft"',
      "",
      "[keyboard]",
      "bindings = [",
      '  { key = "Enter", mods = "Control|Shift", action = "SpawnNewInstance" },',
      '  { key = "Tab", mods = "Control", chars = "\\u001b[9;5u" },',
      '  { key = "PageUp", mods = "Shift", mode = "~AltScreen", action = "ScrollPageUp" },',
      '  { key = "Comma", mods = "Control", action = "ReceiveChar" },',
      "]",
      "",
      "[[keyboard.bindings]]",
      'key = "Left"',
      'mods = "Control|Shift"',
      'action = "SelectPreviousTab" # tabs',
    }

    it("reads alacritty.toml bindings", function()
      local user = term.alacritty_parse(toml)
      eq("left", user.option_as_alt)
      eq({ "<C-S-CR>", "<C-S-Left>" }, tokens(term.alacritty_binds(user)))
    end)

    it("knows the Windows default Alt+Enter and its override", function()
      eq({ "<M-CR>" }, tokens(term.alacritty_binds(term.alacritty_parse({}), true)))
      local user = term.alacritty_parse({
        "[keyboard]",
        'bindings = [ { key = "Enter", mods = "Alt", action = "ReceiveChar" } ]',
      })
      eq({}, term.alacritty_binds(user, true))
      eq(nil, term.alacritty_parse({}).option_as_alt)
    end)
  end)

  it("loads WezTerm and Alacritty configs from XDG_CONFIG_HOME", function()
    -- Regression: an unset $WEZTERM_CONFIG_FILE ahead of the other paths
    -- stopped the search, so wezterm.lua was never read.
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir .. "/wezterm", "p")
    vim.fn.mkdir(dir .. "/alacritty", "p")
    vim.fn.writefile({
      'local wezterm = require("wezterm")',
      "local config = wezterm.config_builder()",
      "config.keys = {",
      '  { key = "Enter", mods = "ALT", action = wezterm.action.DisableDefaultAssignment },',
      "}",
      "return config",
    }, dir .. "/wezterm/wezterm.lua")
    vim.fn.writefile({
      "[window]",
      'option_as_alt = "Both"',
      "[keyboard]",
      'bindings = [ { key = "Enter", mods = "Control|Shift", action = "SpawnNewInstance" } ]',
    }, dir .. "/alacritty/alacritty.toml")
    local saved = { vim.env.XDG_CONFIG_HOME, vim.env.WEZTERM_CONFIG_FILE }
    vim.env.XDG_CONFIG_HOME, vim.env.WEZTERM_CONFIG_FILE = dir, nil
    local ok_, err = pcall(function()
      local w = term.terminals.wezterm.load()
      ok(not vim.tbl_contains(tokens(w.binds), "<M-CR>"), vim.inspect(tokens(w.binds)))
      local a = term.terminals.alacritty.load()
      eq("both", a.option_as_alt)
      ok(vim.tbl_contains(tokens(a.binds), "<C-S-CR>"), vim.inspect(tokens(a.binds)))
    end)
    vim.env.XDG_CONFIG_HOME, vim.env.WEZTERM_CONFIG_FILE = saved[1], saved[2]
    vim.fn.delete(dir, "rf")
    assert(ok_, err)
  end)

  it("detects the terminal from the environment and the tmux client", function()
    eq("ghostty", term.detect_env({ TERM_PROGRAM = "ghostty" }))
    eq("ghostty", term.detect_env({ TERM = "xterm-ghostty" }))
    eq("kitty", term.detect_env({ TERM = "xterm-kitty" }))
    eq("kitty", term.detect_env({ KITTY_WINDOW_ID = "1" }))
    eq("wezterm", term.detect_env({ TERM_PROGRAM = "WezTerm", TERM = "xterm-256color" }))
    eq("wezterm", term.detect_env({ WEZTERM_PANE = "0" }))
    eq("alacritty", term.detect_env({ TERM = "alacritty" }))
    eq("alacritty", term.detect_env({ ALACRITTY_WINDOW_ID = "1" }))
    eq(nil, term.detect_env({ TERM_PROGRAM = "Apple_Terminal", TERM = "xterm-256color" }))
    eq(nil, term.detect_env({ TERM_PROGRAM = "iTerm.app" }))
    eq(nil, term.detect_env({ GHOSTTY_RESOURCES_DIR = "" }))
    -- TERM_PROGRAM wins over variables inherited by tmux
    eq("kitty", term.detect_env({ TERM = "xterm-kitty", GHOSTTY_RESOURCES_DIR = "/x" }))
    eq("ghostty", term.detect_client("xterm-ghostty", "ghostty 1.3.1"))
    eq("kitty", term.detect_client("xterm-kitty", "kitty(0.48.2)"))
    eq("wezterm", term.detect_client("xterm-256color", "WezTerm 20240203-110809-5046fc22"))
    eq("alacritty", term.detect_client("alacritty", nil))
    eq(nil, term.detect_client("xterm-256color", "iTerm2 3.5.0"))
  end)

  it("matches tmux terminal-features patterns", function()
    eq(true, term.tmux_declares_extkeys({ "xterm*:clipboard:extkeys:focus" }, "xterm-ghostty"))
    eq(true, term.tmux_declares_extkeys({ "screen*:title", "xterm-ghostty:extkeys" }, "xterm-ghostty"))
    eq(false, term.tmux_declares_extkeys({ "xterm*:clipboard:focus" }, "xterm-ghostty"))
    eq(false, term.tmux_declares_extkeys({ "rxvt*:extkeys" }, "xterm-ghostty"))
  end)

  it("reads the tmux state", function()
    local replies = {
      ["tmux -V"] = "tmux 3.5a",
      ["tmux show -sv extended-keys"] = "off",
      ["tmux show -sv extended-keys-format"] = "csi-u",
      ["tmux show -gv xterm-keys"] = "on",
      ["tmux display -p #{client_termname}\t#{client_termfeatures}\t#{config_files}\t#{client_termtype}"] = "xterm-ghostty\tRGB,title\t"
        .. vim.env.HOME
        .. "/.config/tmux/tmux.conf\tghostty 1.3.1",
      ["tmux show -sv terminal-features"] = "xterm*:clipboard\nxterm-ghostty:extkeys",
    }
    local st = term.tmux_state(function(cmd)
      return replies[table.concat(cmd, " ")]
    end)
    eq(3.5, st.version)
    eq("off", st.extended_keys)
    eq("xterm-ghostty", st.termname)
    eq("ghostty 1.3.1", st.termtype)
    eq("RGB,title", st.features)
    eq("~/.config/tmux/tmux.conf", st.config)
    eq({ "xterm*:clipboard", "xterm-ghostty:extkeys" }, st.terminal_features)
  end)

  describe(":checkhealth org", function()
    local ENV = {
      "TMUX",
      "TERM_PROGRAM",
      "TERM",
      "GHOSTTY_RESOURCES_DIR",
      "KITTY_WINDOW_ID",
      "KITTY_PID",
      "WEZTERM_PANE",
      "WEZTERM_EXECUTABLE",
      "ALACRITTY_WINDOW_ID",
      "ALACRITTY_SOCKET",
      "ALACRITTY_LOG",
    }

    --- `:checkhealth org` output with the given environment, tmux state
    --- and terminal configurations (`{ [id] = load() result }`).
    local function run_health(env, tmux_state, configs)
      local saved_env, saved_state, saved_loads = {}, term.tmux_state, {}
      for _, n in ipairs(ENV) do
        saved_env[n] = vim.env[n]
        vim.env[n] = env[n]
      end
      term.tmux_state = function()
        return tmux_state or {}
      end
      for id, t in pairs(term.terminals) do
        saved_loads[id] = t.load
        t.load = function()
          return (configs or {})[id] or { binds = {}, option_as_alt = "both" }
        end
      end
      local ok_, text = pcall(function()
        vim.cmd("checkhealth org")
        local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        vim.cmd("bwipeout!")
        return table.concat(lines, "\n")
      end)
      term.tmux_state = saved_state
      for id, t in pairs(term.terminals) do
        t.load = saved_loads[id]
      end
      for _, n in ipairs(ENV) do
        vim.env[n] = saved_env[n]
      end
      assert(ok_, text)
      return text
    end

    it("has no terminal keys section outside tmux and the known terminals", function()
      for _, env in ipairs({
        { TERM_PROGRAM = "Apple_Terminal", TERM = "xterm-256color" },
        { TERM_PROGRAM = "iTerm.app", TERM = "xterm-256color" },
        { TERM = "xterm-256color" },
      }) do
        local text = run_health(env)
        ok(text:find("org.nvim external tools", 1, true), text)
        ok(not text:find("terminal keys", 1, true), vim.inspect(env) .. "\n" .. text)
      end
    end)

    it("checks each known terminal outside tmux", function()
      local cases = {
        { { TERM_PROGRAM = "ghostty", TERM = "xterm-ghostty" }, "ghostty", "Ghostty" },
        { { TERM = "xterm-kitty", KITTY_WINDOW_ID = "1" }, "kitty", "kitty" },
        { { TERM_PROGRAM = "WezTerm", TERM = "xterm-256color" }, "wezterm", "WezTerm" },
        { { TERM = "alacritty" }, "alacritty", "Alacritty" },
      }
      for _, c in ipairs(cases) do
        local text = run_health(c[1], nil, {
          [c[2]] = {
            binds = { { trigger = "ctrl+tab", action = "next_tab", token = "<C-Tab>", advice = "free ctrl+tab" } },
            option_as_alt = "none",
            option_advice = "set option as alt",
          },
        })
        ok(text:find("org.nvim terminal keys", 1, true), text)
        ok(text:find(c[3] .. " keybind ctrl+tab (next_tab) takes <C-Tab>", 1, true), text)
        ok(text:find("free ctrl+tab", 1, true), text)
        if vim.fn.has("mac") == 1 then
          ok(text:find(c[3] .. " sends Option+key as a special character", 1, true), text)
        end
        ok(not text:find("tmux", 1, true), "no tmux checks outside tmux:\n" .. text)
      end
    end)

    it("warns about tmux without extended keys, and checks the attached client's terminal", function()
      local text = run_health(
        -- tmux was started from Ghostty, the client is kitty
        { TMUX = "/tmp/tmux-test,1,0", TERM_PROGRAM = "tmux", TERM = "tmux-256color", GHOSTTY_RESOURCES_DIR = "/x" },
        {
          version = 3.4,
          extended_keys = "off",
          xterm_keys = "off",
          termname = "xterm-kitty",
          termtype = "kitty(0.48.2)",
          features = "RGB",
          config = "~/.tmux.conf",
          terminal_features = {},
        },
        {
          kitty = {
            binds = { { trigger = "ctrl+shift+enter", action = "new_window", token = "<C-S-CR>", advice = "no_op" } },
            option_as_alt = "both",
          },
        }
      )
      ok(text:find("tmux extended-keys is off", 1, true), text)
      ok(text:find("set -s extended-keys on", 1, true), text)
      ok(text:find("set -as terminal-features 'xterm-kitty:extkeys'", 1, true), text)
      ok(text:find("set -g xterm-keys on", 1, true), text)
      ok(text:find("kitty keybind ctrl+shift+enter (new_window) takes <C-S-CR>", 1, true), text)
      ok(not text:find("Ghostty", 1, true), "the client's terminal, not the inherited environment:\n" .. text)
    end)

    it("runs the tmux checks inside tmux with an unknown outer terminal", function()
      local text = run_health({ TMUX = "/tmp/tmux-test,1,0", TERM = "tmux-256color" }, {
        version = 3.5,
        extended_keys = "on",
        xterm_keys = "on",
        termname = "xterm-256color",
        termtype = "iTerm2 3.5.0",
        features = "RGB,extkeys",
        terminal_features = {},
      })
      ok(text:find("tmux extended-keys on", 1, true), text)
      ok(text:find("tmux sends extended keys to the outer terminal", 1, true), text)
      ok(not text:find(" keybind ", 1, true), text)
    end)
  end)
end)
