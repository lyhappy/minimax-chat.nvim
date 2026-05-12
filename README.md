# minimax-chat.nvim

Neovim plugin for chatting with MiniMax AI models via the `mmx` CLI.

## Requirements

- Neovim >= 0.8
- [mmx CLI](https://github.com/MiniMax-AI/cli) installed (`npm install -g mmx-cli`)
- MiniMax API key configured (`mmx auth login`)

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
    "user/minimax-chat.nvim",
    config = function()
        require("minimax-chat").setup({
            model = "MiniMax-M2.7",
        })
    end,
}
```

## Configuration

```lua
require("minimax-chat").setup({
    model = "MiniMax-M2.7",        -- default model
    stream = true,                 -- stream responses
    timeout = 60,                  -- job timeout in seconds
    search_enabled = true,         -- enable [SEARCH] marker support (legacy)
    tools = {                      -- native tool calling (recommended)
        {
            name = "web_search",
            description = "Search the web for current information",
            input_schema = {
                type = "object",
                properties = {
                    query = {
                        type = "string",
                        description = "The search query"
                    }
                },
                required = {"query"}
            }
        }
    }
})
```

## Usage

### Conversation Format

Write your conversation in any buffer using markers:

```
[SYSTEM]
You are a helpful assistant.

[USER]
What is Lua?

[ASSISTANT]
(model response appears here after sending)
```

### Sending Messages

Press **Shift+Enter** in normal mode or run `:MmxSend` to send the entire
buffer content to MiniMax. The response is streamed to the buffer.

### Commands

| Command | Description |
|---|---|
| `:MmxSend` | Send buffer to MiniMax |
| `:MmxChatNew` | Create new chat buffer with template |

### Markers

| Marker | Description |
|---|---|
| `[SYSTEM]` | System prompt (optional, at top) |
| `[USER]` | User message |
| `[ASSISTANT]` | Assistant response |
| `[THINKING]` | Model reasoning (auto-generated) |
| `[TOOL_CALL]` | Tool call invocation (auto-generated) |
| `[TOOL_RESULT]` | Tool result content (auto-generated) |

### Native Tool Calling

The plugin supports native tool calling via the MiniMax API. When tools are configured, the model can autonomously decide to call a tool (like `web_search`) to gather information before responding.

**How it works:**

1. Press Shift+Enter → buffer is parsed and sent to `mmx text chat` with tool definitions
2. If the model decides to call a tool (e.g., `web_search`), the plugin executes `mmx search query --q "..." --output json`
3. Search results are returned to the model via a follow-up message
4. The model generates a final response with the tool results as context

**Configuration:**

- By default, `web_search` tool is enabled if `tools` is not explicitly set
- Set `tools = nil` to disable tool calling
- Set `tools = {...}` with custom tool definitions to enable specific tools

**Note:** The legacy `[SEARCH]<query>` marker system is still supported via `search_enabled = true` but native tool calling is the recommended approach.

### Flow Diagram

```
User message → mmx text chat (with tools)
                 ↓
        Model decides to call web_search
                 ↓
        Plugin executes: mmx search query --q "..." --output json
                 ↓
        Results sent back to model in follow-up message
                 ↓
        Final response displayed with [ASSISTANT] marker
```

## License

MIT
