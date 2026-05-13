--- Send module for minimax-chat plugin.
-- Sends buffer content to mmx CLI and streams the response back into the buffer.

local M = {
  current_job_id = nil,
}

-- Tool definition for MiniMax Messages API (flattened format, NOT Anthropic SDK format)
local WEB_SEARCH_TOOL = {
  name = "web_search",
  description = "Search the web for current information. Use this when you need to find up-to-date facts, weather, news, or anything that requires real-time data.",
  input_schema = {
    type = "object",
    properties = {
      query = {
        type = "string",
        description = "The search query. Be specific and include key details like location, date, etc."
      }
    },
    required = { "query" }
  }
}

--- Check if content array contains a tool_use block.
local function has_tool_call(content)
  if not content then return nil, nil end
  for _, item in ipairs(content) do
    if item.type == "tool_use" then
      return item.name, item.input
    end
  end
  return nil, nil
end

--- Build a tool result content block from raw JSON result.
local function build_tool_result_content(name, input, raw_result)
  local ok, data = pcall(vim.fn.json_decode, raw_result)
  if not ok or not data then
    return string.format("Tool: %s failed: could not parse result", name)
  end

  local organic = data.organic or {}
  local lines = { string.format("Tool: %s", name) }

  -- Helper to sanitize string for JSON encoding (remove invalid UTF-8 bytes)
  local function sanitize(s)
    if not s then return "" end
    -- Replace any byte that doesn't start valid UTF-8 sequence with '?'
    local result = s:gsub("[^\x09\x0A\x0D\x20-\x7E\xC0-\xFF]", "?")
    return result
  end

  if name == "web_search" then
    local query = input and input.query or "unknown"
    table.insert(lines, string.format("Query: %s", query))
    table.insert(lines, "Results:")

    if #organic == 0 then
      table.insert(lines, "  No results found.")
    else
      local max_entries = math.min(5, #organic)
      for i = 1, max_entries do
        local item = organic[i]
        local title = sanitize(item.title or "No title")
        local snippet = sanitize((item.snippet or ""):sub(1, 150))
        local link = sanitize(item.link or "")
        table.insert(lines, string.format("%d. %s: %s (%s)", i, title, snippet, link))
      end
    end
  else
    -- For unknown tools, use json_encode but wrap in pcall
    local ok2, encoded = pcall(vim.fn.json_encode, data)
    if ok2 then
      table.insert(lines, encoded)
    else
      table.insert(lines, "[raw result]")
    end
  end

  return table.concat(lines, "\n")
end

--- Execute web search via mmx CLI.
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
      if exit_code ~= 0 then
        callback(nil, "Search failed with exit code " .. exit_code)
      else
        local raw_result = table.concat(output_parts, "")
        callback(raw_result, nil)
      end
    end
  end

  search_job_id = vim.fn.jobstart(args, {
    on_stdout = on_stdout,
    on_exit = on_exit,
    stdout_buffered = false,
  })

  if search_job_id <= 0 then
    callback(nil, "Failed to start search job")
  end
end

--- Execute HTTP request to MiniMax API via curl.
local function call_api(request_json, callback)
  local api_key = nil
  local ok, mod = pcall(require, "minimax-chat")
  if ok and mod and mod.config and mod.config.api_key then
    api_key = mod.config.api_key
  end

  if not api_key then
    local config_file = vim.fn.expand("~/.mmx/config.json")
    local f = io.open(config_file, "r")
    if f then
      local content = f:read("*a")
      f:close()
      local ok2, config = pcall(vim.fn.json_decode, content)
      if ok2 and config and config.api_key then
        api_key = config.api_key
      end
    end
  end

  if not api_key then
    callback(nil, "No API key found")
    return
  end

  local request_file = string.format("/tmp/mmx-api-request-%d.json", math.random(1000000))
  local f = io.open(request_file, "w")
  if not f then
    callback(nil, "Failed to write request file")
    return
  end
  f:write(request_json)
  f:close()

  local args = {
    "curl", "-s", "-X", "POST",
    "https://api.minimaxi.com/anthropic/v1/messages",
    "-H", "Authorization: Bearer " .. api_key,
    "-H", "Content-Type: application/json",
    "-H", "anthropic-version: 2023-06-01",
    "-d", "@" .. request_file
  }

  local output_parts = {}

  local function on_stdout(_, data, _)
    if data then
      for _, line in ipairs(data) do
        table.insert(output_parts, line)
      end
    end
  end

  local function on_exit(_, exit_code, _)
    os.remove(request_file)
    if exit_code ~= 0 then
      callback(nil, "curl exited with code " .. exit_code)
    else
      local response_json = table.concat(output_parts, "")
      local ok2, response = pcall(vim.fn.json_decode, response_json)
      if not ok2 or not response then
        callback(nil, "Failed to parse API response")
      else
        callback(response, nil)
      end
    end
  end

  local job_id = vim.fn.jobstart(args, {
    on_stdout = on_stdout,
    on_exit = on_exit,
    stdout_buffered = false,
  })

  if job_id <= 0 then
    os.remove(request_file)
    callback(nil, "Failed to start curl job")
  end
end

--- Send non-streaming chat request with tools and handle tool calls.
local function chat_with_tools(bufnr, messages, system, tools, is_followup)
  local ok, mod = pcall(require, "minimax-chat")
  local config = (ok and mod and mod.config) or {}

  local model = config.model or "MiniMax-M2.7"

  local request = {
    model = model,
    messages = messages,
    max_tokens = 4096,
    tools = tools or { WEB_SEARCH_TOOL },
  }

  local request_json = vim.fn.json_encode(request)

  vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { "", "---" })

  call_api(request_json, function(response, err)
    M.current_job_id = nil

    if err then
      vim.notify("[minimax-chat] API call failed: " .. err, vim.log.levels.ERROR)
      vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { "[ERROR] " .. err })
      return
    end

    local content = response.content or {}
    local stop_reason = response.stop_reason or "end_turn"

    local tool_name, tool_input = has_tool_call(content)

    if stop_reason == "tool_use" and tool_name and tool_input then
      local tool_callback = function(raw_result, err2)
        if err2 then
          vim.notify("[minimax-chat] Tool execution failed: " .. err2, vim.log.levels.WARN)
          vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { string.format("[TOOL_ERROR] %s: %s", tool_name, err2) })
          return
        end

        local tool_result_content = build_tool_result_content(tool_name, tool_input, raw_result)

        vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, {
          string.format("[TOOL_CALL] %s(%s)", tool_name, vim.fn.json_encode(tool_input))
        })

        local tool_result_msg = {
          role = "assistant",
          content = content,
        }
        local tool_result_as_content = {
          type = "tool_result",
          tool_name = tool_name,
          content = tool_result_content,
        }

        local followup_messages = vim.deepcopy(messages)
        table.insert(followup_messages, tool_result_msg)
        table.insert(followup_messages, {
          role = "user",
          content = { tool_result_as_content }
        })

        vim.api.nvim_buf_set_lines(bufnr, -1, -1, false,
          vim.list_extend({ "[TOOL_RESULT]" }, vim.split(tool_result_content, "\n", { plain = true })))

        chat_with_tools(bufnr, followup_messages, system, tools, true)
      end

      if tool_name == "web_search" then
        local query = tool_input and tool_input.query
        if query then
          execute_search(query, tool_callback)
        else
          vim.notify("[minimax-chat] Tool web_search called without query input", vim.log.levels.WARN)
        end
      else
        vim.notify("[minimax-chat] Unknown tool: " .. tool_name, vim.log.levels.WARN)
      end
    else
      vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { "[ASSISTANT]" })

      for _, item in ipairs(content) do
        if item.type == "text" then
          local lines = vim.split(item.text or "", "\n", { plain = true })
          for _, line in ipairs(lines) do
            vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { line })
          end
        elseif item.type == "thinking" then
          vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { "[THINKING] " .. (item.thinking or "") })
        elseif item.type == "tool_use" then
          vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, {
            string.format("[TOOL_CALL] %s(%s)", item.name or "unknown", vim.fn.json_encode(item.input or {}))
          })
        end
      end

      if is_followup then
        vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { "[END]" })
      end
    end
  end)

  M.current_job_id = 1
end

--- Main entry point for sending buffer content to mmx CLI.
function M.send(bufnr)
  if M.current_job_id ~= nil then
    vim.notify("[minimax-chat] Already sending, please wait for current job to complete", vim.log.levels.WARN)
    return
  end

  if vim.fn.executable("curl") ~= 1 then
    vim.notify("[minimax-chat] 'curl' command not found", vim.log.levels.ERROR)
    return
  end

  local parse_mod = require("minimax-chat.parse")
  local parsed = parse_mod.parse_buffer(bufnr)

  if #parsed.messages == 0 then
    vim.notify("[minimax-chat] Nothing to send", vim.log.levels.WARN)
    return
  end

  local ok, mod = pcall(require, "minimax-chat")
  local config = (ok and mod and mod.config) or {}

  local tools = config.tools
  if tools == nil then
    tools = { WEB_SEARCH_TOOL }
  end

  chat_with_tools(bufnr, parsed.messages, parsed.system, tools, false)
end

return M