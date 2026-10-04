-- aerial.nvim backend `"org"`: aerial requires `aerial.backends.<name>`
-- itself, so this only runs when aerial is installed. The backend is
-- org.nvim's (`:h org-integrations`).
return require("org.integrations.aerial")
