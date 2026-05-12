--- Send module for minimax-chat plugin.
-- Sends buffer content to mmx CLI and streams the response back into the buffer.

local M = {
  current_job_id = nil,
}

--- Main entry point for sending buffer content to mmx CLI.
-- @param bufnr number: Neovim buffer number
function M.send(bufnr)
  -- Guard against duplicate sends
  if M.current_job_id ~= nil then
    vim.notify("[minimax-chat] Already sending, please wait for current job to complete", vim.log.levels.WARN)
    return
  end

  -- Check if mmx is available
  if vim.fn.executable("mmx") ~= 1 then
    vim.notify("[minimax-chat] 'mmx' command not found. Please install MiniMax CLI.", vim.log.levels.ERROR)
    return
  end

  -- Parse buffer to get messages
  local parse_mod = require("minimax-chat.parse")
  local parsed = parse_mod.parse_buffer(bufnr)

  -- Validate we have messages to send
  if #parsed.messages == 0 then
    vim.notify("[minimax-chat] Nothing to send", vim.log.levels.WARN)
    return
  end

  -- Read config (with pcall for safety if init not loaded yet)
  local ok, mod = pcall(require, "minimax-chat")
  local config = (ok and mod and mod.config) or { model = "MiniMax-M2.7", stream = true }

  -- Build mmx command arguments as a list (NOT shell string)
  local args = { "mmx", "text", "chat", "--stream", "--no-color", "--non-interactive" }

  -- Add model from config if specified
  if config.model then
    vim.list_extend(args, { "--model", config.model })
  end

  -- Add system prompt if exists
  if parsed.system and parsed.system ~= "" then
    vim.list_extend(args, { "--system", parsed.system })
  end

  -- Add each message with role prefix
  for _, msg in ipairs(parsed.messages) do
    vim.list_extend(args, { "--message", msg.role .. ":" .. msg.content })
  end

  -- Append blank line separator before sending for readability
  vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { "", "---" })

  local skip_json = false
  local partial_line = ""

  local function on_stdout(_, data, _)
    if data == nil or #data == 0 then
      return
    end

    -- Merge with previous partial line
    if partial_line ~= "" then
      data[1] = partial_line .. data[1]
      partial_line = ""
    end

    local n = #data
    local last_is_empty = (data[n] == "")
    local complete_end = last_is_empty and n or (n - 1)

    for i = 1, complete_end do
      local line = data[i]:gsub("%s+$", "")
      if skip_json then
      elseif line == "" then
      elseif line:find("^{\"") or line:find("^{%s*$") or line:find("^}%s*$") or line:find("\"content\"") then
        skip_json = true
      else
        vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { line })
      end
    end

    -- Save partial line for next callback
    if not last_is_empty and n > 0 then
      partial_line = data[n]
    end
  end

  local function on_stderr(_, data, _)
    if data == nil then
      return
    end
    for _, line in ipairs(data) do
      line = line:gsub("%s+$", "")
      if line == "" then
      elseif line:lower():find("^thinking:") then
        vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { "[THINKING]" })
      elseif line:lower():find("^response:") then
        vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { "[ASSISTANT]" })
      end
    end
  end

  local function on_exit(_, exit_code, _)
    M.current_job_id = nil

    -- Flush any remaining partial line
    if partial_line ~= "" then
      local line = partial_line:gsub("%s+$", "")
      if not skip_json and line ~= "" and not (line:find("^{\"") or line:find("^{%s*$") or line:find("^}%s*$") or line:find("\"content\"")) then
        vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { line })
      end
      partial_line = ""
    end

    if exit_code ~= 0 then
      vim.notify("[minimax-chat] mmx exited with code " .. exit_code, vim.log.levels.ERROR)
    end
  end

  -- Start the job
  M.current_job_id = vim.fn.jobstart(args, {
    on_stdout = on_stdout,
    on_stderr = on_stderr,
    on_exit = on_exit,
    stdout_buffered = false,
  })
end

return M