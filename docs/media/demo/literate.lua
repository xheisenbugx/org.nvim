-- Demo config for docs/media/tapes/literate.tape: init.lua plus the
-- literate extension, with a literate config in $ORG_DEMO_DIR/nvim/init.org
-- that tangles to lua/config.lua.
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
dofile(here .. "/init.lua")

local dir = (vim.env.ORG_DEMO_DIR or "/tmp/org-nvim-demo") .. "/nvim"
vim.fn.mkdir(dir, "p")
vim.fn.writefile({
  "#+title: My Neovim config",
  "#+PROPERTY: header-args:lua :tangle lua/config.lua :mkdirp yes",
  "",
  "* Options",
  "Line numbers, and the line under the cursor.",
  "#+begin_src lua",
  "vim.o.number = false",
  "vim.o.cursorline = false",
  "#+end_src",
  "",
  "* Keymaps",
  "#+begin_src lua",
  'vim.keymap.set("n", "<leader>w", "<Cmd>write<CR>")',
  "#+end_src",
}, dir .. "/init.org")

vim.diagnostic.config({ virtual_text = { prefix = "●" }, signs = false, underline = true })

local opts = vim.deepcopy(require("org.config").opts)
opts.extensions = { literate = { files = { dir .. "/init.org" } } }
require("org").setup(opts)
