--- Send module for minimax-chat plugin.
-- Sends buffer content to mmx CLI and streams the response back into the buffer.

local M = {
  current_job_id = nil,
}

--- Extract [SEARCH]<query> marker from content and return cleaned content.
-- @param content string: Message content to scan
-- @return table: { query = string|nil, cleaned = string }
local function extract_search_query(content)
  local query = nil
  local cleaned = content:gsub("%]%s*\n", "]\n")  -- normalize
  cleaned = cleaned:gsub("%[SEARCH%](.-)\n?", function(match)
    local q = vim.trim(match)
    if q ~= "" then
      query = q
    end
    return ""
  end)
  cleaned = vim.trim(cleaned)
  return { query = query, cleaned = cleaned }
end

--- Format JSON search results as [CONTEXT] block.
-- @param json_str string: JSON string from mmx search
-- @return string: Formatted context block
local function format_context(json_str)
  local ok, data = pcall(vim.fn.json_decode, json_str)
  if not ok or not data then
    return "[CONTEXT]\nFailed to parse search results.\n"
  end

  local organic = data.organic
  if not organic or #organic == 0 then
    return "[CONTEXT]\nNo search results found.\n"
  end

  local results = {}
  local max_entries = math.min(5, #organic)

  table.insert(results, "[CONTEXT]")
  table.insert(results, "Search results:\n")

  for i = 1, max_entries do
    local entry = organic[i]
    local title = entry.title or "No title"
    local snippet = entry.snippet or ""
    local link = entry.link or ""

    -- Truncate snippet to 200 chars
    if #snippet > 200 then
      snippet = snippet:sub(1, 200) .. "..."
    end

    table.insert(results, string.format("%d. **%s**\n   %s\n   %s\n", i, title, snippet, link))
  end

  return table.concat(results, "\n")
end

--- Execute web search via mmx CLI.
-- @param query string: Search query
-- @param callback function: Callback(context_string, err_message)
local function execute_search(query, callback)
  local args = { "mmx", "search", "query", "--q", query, "--output", "json" }
  local output_parts = {}
  local search_job_id = nil
  local callback_fired = false

  local timer = vim.fn.timer_start(15000, function()
    if not callback_fired then
      callback_fired = true
      if search_job_id and vim.fn.jobpid(search_job_id) then
        vim.fn.jobstop(search_job_id)
      end
      callback(nil, "Search timed out")
    end
  end)

  local function on_stdout(_, data, _)
    if data then
      for _, line in ipairs(data) do
        table.insert(output_parts, line)
      end
    end
  end

  local function on_exit(_, exit_code, _)
    vim.fn.timer_stop(timer)
    if not callback_fired then
      callback_fired = true
      local json_str = table.concat(output_parts, "")
      local context = format_context(json_str)
      callback(context, nil)
    end
  end

  search_job_id = vim.fn.jobstart(args, {
    on_stdout = on_stdout,
    on_exit = on_exit,
    stdout_buffered = false,
  })
end

--- Start chat with optional context injected into last user message.
-- @param bufnr number: Neovim buffer number
-- @param messages table: Parsed messages array
-- @param context string|nil: Optional context to prepend to last user message
-- @param system string|nil: Optional system prompt
-- @return number: Job ID
local function start_chat(bufnr, messages, context, system)
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
  if system and system ~= "" then
    vim.list_extend(args, { "--system", system })
  end

  -- Build message args with optional context prepended to last user message
  local last_user_idx = nil
  for i = #messages, 1, -1 do
    if messages[i].role == "user" then
      last_user_idx = i
      break
    end
  end
  for i, msg in ipairs(messages) do
    local content = msg.content
    if context and msg.role == "user" and i == last_user_idx then
      content = context .. "\n\n" .. content
    end
    vim.list_extend(args, { "--message", msg.role .. ":" .. content })
  end

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

  -- Append blank line separator before sending for readability
  vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { "", "---" })

  -- Start the job
  M.current_job_id = vim.fn.jobstart(args, {
    on_stdout = on_stdout,
    on_stderr = on_stderr,
    on_exit = on_exit,
    stdout_buffered = false,
  })

  return M.current_job_id
end

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

  -- Read config
  local ok, mod = pcall(require, "minimax-chat")
  local config = (ok and mod and mod.config) or { model = "MiniMax-M2.7", stream = true, search_enabled = true }

  -- Check for [SEARCH] markers in user messages (scan in reverse to find LAST one)
  local search_query = nil
  for i = #parsed.messages, 1, -1 do
    local msg = parsed.messages[i]
    if msg.role == "user" then
      local result = extract_search_query(msg.content)
      if result.query then
        search_query = result.query
        msg.content = result.cleaned
        break  -- Use the LAST (most recent) search query found
      end
    end
  end

  -- Two-phase flow: if search_enabled and we found a search query
  if config.search_enabled and search_query then
    execute_search(search_query, function(context, err)
      if err then
        vim.notify("[minimax-chat] Search failed: " .. err, vim.log.levels.WARN)
      end
      start_chat(bufnr, parsed.messages, context, parsed.system)
    end)
  else
    -- Direct chat without search
    start_chat(bufnr, parsed.messages, nil, parsed.system)
  end
end

return M