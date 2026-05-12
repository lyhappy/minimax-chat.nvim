local M = {}

function M.find_next_marker(lines, start_idx)
  for i = start_idx + 1, #lines do
    local line = lines[i]
    if line == "[SYSTEM]" or line == "[USER]" or line == "[ASSISTANT]" then
      return i
    end
  end
  return nil
end

function M.parse_buffer(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local result = {
    system = nil,
    messages = {},
  }

  local current_role = nil
  local current_content_lines = {}

  local function flush_content()
    if current_role == nil or #current_content_lines == 0 then
      return
    end

    local content = vim.trim(table.concat(current_content_lines, "\n"))
    if content == "" then
      return
    end

    if current_role == "system" then
      result.system = content
    elseif current_role == "user" then
      local last = result.messages[#result.messages]
      if last and last.role == "user" then
        last.content = last.content .. "\n" .. content
      else
        table.insert(result.messages, { role = "user", content = content })
      end
    elseif current_role == "assistant" then
      table.insert(result.messages, { role = "assistant", content = content })
    end
  end

  for _, line in ipairs(lines) do
    if line == "[SYSTEM]" then
      flush_content()
      current_role = "system"
      current_content_lines = {}
    elseif line == "[USER]" then
      flush_content()
      current_role = "user"
      current_content_lines = {}
    elseif line == "[ASSISTANT]" then
      flush_content()
      current_role = "assistant"
      current_content_lines = {}
    elseif current_role then
      table.insert(current_content_lines, line)
    end
  end

  flush_content()
  return result
end

return M
