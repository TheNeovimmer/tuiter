-- .graphql filetype plugin: tuiter turns each operation into a POST request
-- (endpoint from `# @url`; optional `# @variables` JSON per operation).
vim.bo.commentstring = "# %s"
vim.bo.omnifunc = "v:lua.require('tuiter').complete"
require("tuiter").setup_keymaps(0)
