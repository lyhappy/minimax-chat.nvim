-- minimax-chat.nvim plugin loader
-- Sets up default keymappings for the minimax-chat plugin

vim.g.minimax_chat_loaded = true

vim.keymap.set('n', '<S-Enter>', ':<C-u>MmxSend<CR>', {
  noremap = true,
  silent = true,
  desc = 'Send to Minimax',
})

vim.g.minimax_chat_mappings = true
