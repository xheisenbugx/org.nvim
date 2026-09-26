local health = require("org.health")

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
      eq(need, health.key_needs(key), key)
    end
    for _, key in ipairs({ "<C-c>", "<C-x>", "<S-Tab>", "<C-Space>", "<CR>", "<Tab>", "<leader>", "<C-_>" }) do
      eq(nil, health.key_needs(key), key)
    end
  end)

  it("collects the key tokens of the configured mappings", function()
    local keys = health.mapped_keys()
    ok(keys["<C-CR>"], "<C-CR> is mapped by default")
    ok(vim.tbl_contains(keys["<C-CR>"], "emacs.insert_heading"), vim.inspect(keys["<C-CR>"]))
    ok(keys["<C-c>"])
  end)

  it("converts Ghostty triggers to Neovim keys", function()
    local function key(t)
      return (health.ghostty_trigger_key(t))
    end
    eq("<C-S-CR>", key("ctrl+shift+enter"))
    eq("<C-Tab>", key("ctrl+tab"))
    eq("<M-Left>", key("alt+arrow_left"))
    eq("<M-H>", key("alt+shift+h"))
    eq("<C-,>", key("ctrl+comma"))
    eq("<C-,>", key("ctrl+,"))
    eq("<C-a>", key("ctrl+a>n"), "first key of a sequence")
    eq("<D-=>", key("super+="))
    eq(nil, key("a"))
    eq(nil, key("copy"))
    local token, flags = health.ghostty_trigger_key("performable:global:ctrl+enter")
    eq("<C-CR>", token)
    eq({ performable = true, global = true }, flags)
  end)

  it("finds Ghostty keybinds that take mapped keys", function()
    local keys = {
      ["<C-Tab>"] = { "emacs.force_cycle_archived" },
      ["<S-Up>"] = { "org.shift_up" },
      ["<M-Left>"] = {
        "org.meta_left",
      },
      ["<C-CR>"] = { "org.insert_heading" },
    }
    -- `+show-config` output: defaults included, prefix flags dropped
    local effective = health.ghostty_parse({
      "macos-option-as-alt = true",
      "keybind = super+==increase_font_size:1",
      "keybind = shift+arrow_up=adjust_selection:up",
      "keybind = ctrl+tab=next_tab",
      "keybind = alt+arrow_left=esc:b",
      "keybind = ctrl+enter=toggle_fullscreen",
    })
    eq("true", effective.option_as_alt)
    local user = health.ghostty_parse({ "keybind = unconsumed:ctrl+enter=toggle_fullscreen" })
    local found = vim.tbl_map(function(c)
      return c.trigger .. " " .. c.key
    end, health.ghostty_conflicts(effective, user, keys))
    -- shift+arrow_up is performable by default; the user's ctrl+enter is unconsumed
    eq({ "alt+arrow_left <M-Left>", "ctrl+tab <C-Tab>" }, found)
    -- a user's own binding of a default-performable key does consume it
    user = health.ghostty_parse({ "keybind = shift+arrow_up=adjust_selection:up" })
    found = vim.tbl_map(function(c)
      return c.key
    end, health.ghostty_conflicts(effective, user, keys))
    ok(vim.tbl_contains(found, "<S-Up>"), vim.inspect(found))
    -- unbind removes it
    effective = health.ghostty_parse({ "keybind = ctrl+tab=next_tab", "keybind = ctrl+tab=unbind" })
    eq({}, health.ghostty_conflicts(effective, health.ghostty_parse({}), keys))
  end)

  it("matches tmux terminal-features patterns", function()
    eq(true, health.tmux_declares_extkeys({ "xterm*:clipboard:extkeys:focus" }, "xterm-ghostty"))
    eq(true, health.tmux_declares_extkeys({ "screen*:title", "xterm-ghostty:extkeys" }, "xterm-ghostty"))
    eq(false, health.tmux_declares_extkeys({ "xterm*:clipboard:focus" }, "xterm-ghostty"))
    eq(false, health.tmux_declares_extkeys({ "rxvt*:extkeys" }, "xterm-ghostty"))
  end)

  it("reads the tmux state", function()
    local replies = {
      ["tmux -V"] = "tmux 3.5a",
      ["tmux show -sv extended-keys"] = "off",
      ["tmux show -sv extended-keys-format"] = "csi-u",
      ["tmux show -gv xterm-keys"] = "on",
      ["tmux display -p #{client_termname}\t#{client_termfeatures}\t#{config_files}"] = "xterm-ghostty\tRGB,title\t"
        .. vim.env.HOME
        .. "/.config/tmux/tmux.conf",
      ["tmux show -sv terminal-features"] = "xterm*:clipboard\nxterm-ghostty:extkeys",
    }
    local st = health.tmux_state(function(cmd)
      return replies[table.concat(cmd, " ")]
    end)
    eq(3.5, st.version)
    eq("off", st.extended_keys)
    eq("xterm-ghostty", st.termname)
    eq("RGB,title", st.features)
    eq("~/.config/tmux/tmux.conf", st.config)
    eq({ "xterm*:clipboard", "xterm-ghostty:extkeys" }, st.terminal_features)
  end)

  --- `:checkhealth org` output with the given terminal environment and
  --- (inside tmux) tmux state.
  local function run_health(env, tmux_state)
    local names = { "TMUX", "TERM_PROGRAM", "GHOSTTY_RESOURCES_DIR", "TERM" }
    local saved_env, saved_state = {}, health.tmux_state
    for _, n in ipairs(names) do
      saved_env[n] = vim.env[n]
      vim.env[n] = env[n]
    end
    health.tmux_state = function()
      return tmux_state
    end
    local ok_, text = pcall(function()
      vim.cmd("checkhealth org")
      local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
      vim.cmd("bwipeout!")
      return table.concat(lines, "\n")
    end)
    health.tmux_state = saved_state
    for _, n in ipairs(names) do
      vim.env[n] = saved_env[n]
    end
    assert(ok_, text)
    return text
  end

  it(":checkhealth warns about tmux without extended keys", function()
    local text = run_health({ TMUX = "/tmp/tmux-test,1,0", TERM_PROGRAM = "tmux", TERM = "tmux-256color" }, {
      version = 3.4,
      extended_keys = "off",
      xterm_keys = "off",
      termname = "xterm-256color",
      features = "RGB",
      config = "~/.tmux.conf",
      terminal_features = {},
    })
    ok(text:find("org.nvim terminal keys", 1, true), text)
    ok(text:find("tmux extended-keys is off", 1, true), text)
    ok(text:find("set -s extended-keys on", 1, true), text)
    ok(text:find("set -as terminal-features 'xterm-256color:extkeys'", 1, true), text)
    ok(text:find("set -g xterm-keys on", 1, true), text)
    ok(not text:find("Ghostty", 1, true), "no Ghostty checks outside Ghostty")
  end)

  it(":checkhealth shows the terminal keys section only in tmux or Ghostty", function()
    for _, env in ipairs({
      { TERM_PROGRAM = "Apple_Terminal", TERM = "xterm-256color" },
      { TERM_PROGRAM = "WezTerm", TERM = "xterm-256color" },
      { TERM = "xterm-kitty" },
    }) do
      local text = run_health(env)
      ok(text:find("org.nvim external tools", 1, true), text)
      ok(not text:find("terminal keys", 1, true), vim.inspect(env) .. "\n" .. text)
    end
    local text = run_health({ TERM_PROGRAM = "ghostty", TERM = "xterm-ghostty" })
    ok(text:find("org.nvim terminal keys", 1, true), text)
    ok(not text:find("tmux", 1, true), "no tmux checks outside tmux:\n" .. text)
  end)

  it("detects tmux and Ghostty from the environment", function()
    local names = { "TMUX", "TERM_PROGRAM", "GHOSTTY_RESOURCES_DIR", "TERM" }
    local saved = {}
    for _, n in ipairs(names) do
      saved[n] = vim.env[n]
      vim.env[n] = nil
    end
    local results = {}
    local function probe(env)
      for _, n in ipairs(names) do
        vim.env[n] = env[n]
      end
      results[#results + 1] = { health.terminal_env() }
    end
    probe({})
    probe({ TMUX = "" })
    probe({ TMUX = "/tmp/tmux-501/default,1,0" })
    probe({ TERM = "xterm-ghostty" })
    probe({ GHOSTTY_RESOURCES_DIR = "/Applications/Ghostty.app/Contents/Resources/ghostty" })
    for _, n in ipairs(names) do
      vim.env[n] = saved[n]
    end
    eq({ { false, false }, { false, false }, { true, false }, { false, true }, { false, true } }, results)
  end)
end)
