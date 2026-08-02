-- .http filetype plugin
vim.bo.commentstring = "# %s"
vim.bo.omnifunc = "v:lua.require('tuiter').complete"
require("tuiter").setup_keymaps(0)
