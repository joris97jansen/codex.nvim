# Codex Neovim Plugin
<img width="1480" alt="image" src="https://github.com/user-attachments/assets/eac126c5-e71c-4de9-817a-bf4e8f2f6af9" />

## A Neovim plugin integrating the open-sourced Codex CLI (`codex`)
> Latest version: ![GitHub tag (latest SemVer)](https://img.shields.io/github/v/tag/johnseth97/codex.nvim?sort=semver)

### Features:
- ✅ Toggle Codex window or side-panel with `:CodexToggle`
- ✅ Optional keymap mapping via `setup` call
- ✅ Background running when window hidden
- ✅ Statusline integration via `require('codex').status()`
- ✅ Browse Codex chat history with `:CodexHistory`

### Installation:

- Install the `codex` CLI via npm, or mark autoinstall as true in the config function

```bash
npm install -g @openai/codex
```

- Grab an API key from OpenAI and set it in your environment variables:
  - Note: You can also set it in your `~/.bashrc` or `~/.zshrc` file to persist across sessions, but be careful with security. Especially if you share your config files.

```bash
export OPENAI_API_KEY=your_api_key
```

- Use your plugin manager, e.g. lazy.nvim:

```lua
return {
  'kkrampis/codex.nvim',
  lazy = true,
  cmd = { 'Codex', 'CodexToggle', 'CodexHistory', 'CodexHistoryToggle', 'CodexLast', 'CodexPin', 'CodexPinned', 'CodexClearSessions' }, -- Optional: Load only on command execution
  keys = {
    {
      '<leader>cc', -- Change this to your preferred keybinding
      function() require('codex').toggle() end,
      desc = 'Toggle Codex popup or side-panel',
      mode = { 'n', 't' }
    },
  },
  opts = {
    keymaps     = {
      toggle = nil, -- Keybind to toggle Codex window (Disabled by default, watch out for conflicts)
      quit = { '<C-q>', '<C-c>', 'ZZ' }, -- Keybinds to close the Codex window
      history = '<leader>ch', -- Keybind to toggle Codex history
      history_list = nil, -- Keybind to open Codex history list directly
      term_normal = '<Esc><Esc>', -- Enter terminal-normal mode
      last = '<leader>cl', -- Resume last Codex session
      pin = '<leader>cp', -- Pin current Codex session
      pinned = '<leader>cP', -- Resume pinned Codex session
      panel_toggle = nil, -- Toggle Codex side panel
    },         -- Disable internal default keymap (<leader>cc -> :CodexToggle)
    border      = 'rounded',  -- Options: 'single', 'double', or 'rounded'
    width       = 0.8,        -- Width of the floating window (0.0 to 1.0)
    height      = 0.8,        -- Height of the floating window (0.0 to 1.0)
    panel_width = 0.20,       -- Width of the side-panel (0.0 to 1.0)
    model       = nil,        -- Optional: pass a string to use a specific model (e.g., 'o3-mini')
    autoinstall = true,       -- Automatically install the Codex CLI if not found
    panel       = false,      -- Open Codex in a side-panel (vertical split) instead of floating window
    open_new_session_in_panel = false, -- New sessions open in side panel even if panel=false
    open_new_session_in_panel_on_enter = false, -- New sessions start floating and move to panel on first Enter
    use_buffer  = false,      -- Capture Codex stdout into a normal buffer instead of a terminal buffer
    auto_insert = true,       -- Enter terminal mode on open/focus (floating)
    panel_auto_insert = false,-- Enter insert mode in side-panel (default: stay in normal mode)
    render_markdown = true,   -- Render Codex output as markdown (forces use_buffer; falls back to terminal if TTY required)
    history     = {
      max_entries = 200,      -- Limit entries in history list
      max_files = 1000,       -- Limit session files scanned for history (perf)
      auto_close_active = true, -- Close active session when resuming from history
      ui = 'buffer',          -- 'buffer' or 'telescope' (requires telescope.nvim)
      open_last_on_toggle = false, -- Toggle history key opens last session
      open_session_in_panel = false, -- Resume from history opens chat in side panel
      skip_empty = true,      -- Hide history entries with no chat content
      persist_pin = true,     -- Persist pinned session across restarts
      persist_last = true,    -- Persist last session across restarts
    },
  },
}```

### Usage:
- Call `:Codex` (or `:CodexToggle`) to open or close the Codex popup or side-panel.
- Call `:CodexPanelToggle` to toggle the Codex side panel.
- Call `:CodexHistory` to browse past Codex sessions and resume them.
- Call `:CodexHistoryToggle` to switch between the live Codex session and history in the same window.
- Call `:CodexLast` to resume the most recent Codex session.
- Call `:CodexPin` to pin the current resumed session, and `:CodexPinned` to jump back to it.
- Call `:CodexClearSessions` to clear pinned and last sessions.
- Use `Tab` to toggle between Codex and history when the Codex window is focused.
- If `history.ui = 'telescope'`, the toggle command opens the Telescope picker instead of swapping the Codex window.
- Map your own keybindings via the `keymaps.toggle` setting.
- To choose floating popup vs side-panel, set `panel = false` (popup) or `panel = true` (panel) in your setup options.
- To capture Codex output in an editable buffer instead of a terminal, set `use_buffer = true` (or `false` to keep terminal) in your setup options.
- Add the following code to show backgrounded Codex window in lualine:

```lua
require('codex').status() -- drop in to your lualine sections
```

### Configuration:
- All plugin configurations can be seen in the `opts` table of the plugin setup, as shown in the installation section.

- **For deeper customization, please refer to the [Codex CLI documentation](https://github.com/openai/codex?tab=readme-ov-file#full-configuration-example) full configuration example. These features change quickly as Codex CLI is in active beta development.*
