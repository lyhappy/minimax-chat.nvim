---
--- minimax-chat Neovim plugin configuration and command registration
---
--- Usage:
---   require('minimax-chat').setup({ model = 'MiniMax-M2', stream = false })
---   :MmxSend           -- send current buffer to MiniMax API
---   :MmxChatNew        -- create new chat buffer with template
---

local M = {}

--- Default configuration
local defaults = {
	model = "MiniMax-M2.7",
	stream = true,
	timeout = 60,
	search_enabled = true,
}

---Module configuration, accessible via require('minimax-chat').config
M.config = vim.deepcopy(defaults)

---Setup function - merges user options with defaults
---@param opts? table Optional configuration overrides
function M.setup(opts)
	if opts then
		M.config = vim.tbl_deep_extend("force", defaults, opts)
	end
end

---Send current buffer to MiniMax API
local function send_current_buffer()
	local bufnr = vim.api.nvim_get_current_buf()
	require('minimax-chat.send').send(bufnr)
end

---Create new chat buffer with template
local function new_chat_buffer()
	vim.cmd.enew()
	local lines = { "[SYSTEM]", "", "[USER]", "" }
	vim.api.nvim_buf_set_lines(0, 0, 0, false, lines)
	vim.cmd("set filetype=minimax-chat")
end

---Register commands
vim.api.nvim_create_user_command("MmxSend", send_current_buffer, { nargs = 0 })
vim.api.nvim_create_user_command("MmxChatNew", new_chat_buffer, { nargs = 0 })

return M
