-- outline.nvim external provider `"org"`: outline.nvim requires
-- `outline.providers.<name>` itself, so this only runs when it is
-- installed. The provider is org.nvim's (`:h org-integrations`).
return require("org.integrations.outline")
