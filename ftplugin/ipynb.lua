-- ftplugin/ipynb.lua - Filetype settings for notebook buffers
-- Note: Treesitter highlighting is started by facade.lua using the ipynb grammar.
-- Fold and conceal settings are window options; facade.setup_window sets them
-- per notebook window and restores the previous values when another buffer is
-- shown there (vim.wo here would leak them into every later buffer).

vim.opt_local.fillchars:append({ fold = " " }) -- Clean fold fill
