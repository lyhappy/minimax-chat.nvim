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

## How It Works

1. Press Shift+Enter → `[SYSTEM]`, `[USER]`, and `[ASSISTANT]` markers are parsed
2. Messages are sent to `mmx text chat --stream`
3. Response is streamed back and appended to the buffer with `[THINKING]`/`[ASSISTANT]` markers

## License

MIT
