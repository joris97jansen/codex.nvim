local vim = vim
local installer = require 'codex.installer'
local state = require 'codex.state'

local M = {}
local apply_quit_keymaps
local apply_terminal_keymaps
local move_buf_to_panel
local update_winbar
local config

local function close_win_safe(win)
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return
  end
  local cfg = vim.api.nvim_win_get_config(win)
  local is_float = cfg and cfg.relative ~= ''
  local normal_wins = {}
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local c = vim.api.nvim_win_get_config(w)
    if c and c.relative == '' then
      table.insert(normal_wins, w)
    end
  end
  if not is_float and #normal_wins <= 1 then
    pcall(vim.cmd, 'quit')
    return
  end
  vim.api.nvim_win_close(win, true)
end

local function enter_terminal_mode()
  vim.schedule(function()
    local win = state.win
    if not (win and vim.api.nvim_win_is_valid(win)) then
      return
    end
    local buf = vim.api.nvim_win_get_buf(win)
    if not (buf and vim.api.nvim_buf_is_valid(buf)) then
      return
    end
    if vim.bo[buf].buftype ~= 'terminal' then
      return
    end
    local should = vim.b[buf].codex_should_auto_insert
    if should == nil then
      -- fallback to config defaults
      if win == state.panel_win then
        should = config.panel_auto_insert
      else
        should = config.auto_insert
      end
    end
    if not should then
      return
    end
    vim.api.nvim_set_current_win(win)
    vim.cmd('startinsert')
  end)
end

local function strip_ansi(s)
  if not s then return '' end
  return s:gsub('\27%[[0-9;]*[A-Za-z]', '')
end

config = {
  keymaps = {
    toggle = nil,
    quit = { '<C-q>', '<C-c>', 'ZZ' }, -- Default: Ctrl+q, Ctrl+c, or ZZ to quit
    history = '<leader>ch',
    history_list = nil,
    term_normal = '<Esc><Esc>', -- Enter terminal-normal mode
    last = '<leader>cl',
    pin = '<leader>cp',
    pinned = '<leader>cP',
    panel_toggle = nil, -- Keybind to toggle Codex side panel
  },
  border = 'single',
  width = 0.8,
  height = 0.8,
  panel_width = 0.15, -- Width for side-panel (percentage of total columns)
  cmd = 'codex',
  model = nil, -- Default to the latest model
  autoinstall = true,
  panel     = false,   -- if true, open Codex in a side-panel instead of floating window
  open_new_session_in_panel = false, -- if true, new sessions open in side panel even if panel=false
  open_new_session_in_panel_on_enter = false, -- if true, new sessions start floating and move to panel on first Enter
  use_buffer = false,  -- if true, capture Codex stdout into a normal buffer instead of a terminal
  auto_insert = true,  -- if true, enter terminal mode on open/focus
  panel_auto_insert = false, -- default: side panel opens in normal mode
  render_markdown = true, -- if true, render Codex output as markdown (forces use_buffer)
  history = {
    max_entries = 200,
    max_files = 1000,
    auto_close_active = true,
    ui = 'buffer', -- 'buffer' or 'telescope' (requires telescope.nvim)
    open_last_on_toggle = false, -- if true, toggle history key opens last session
    open_session_in_panel = false, -- if true, resume from history opens chat in side panel
    persist_pin = true,
    persist_last = true,
    skip_empty = true, -- hide history entries with no chat content
  },
}

function M.setup(user_config)
  config = vim.tbl_deep_extend('force', config, user_config or {})

  if config.history and config.history.persist_pin then
    local ok, pinned = pcall(vim.fn.readfile, state.pinned_session_file or '')
    if ok and pinned and pinned[1] and pinned[1] ~= '' then
      state.pinned_session_id = pinned[1]
    end
  end

  if config.history and config.history.persist_last then
    local ok, last = pcall(vim.fn.readfile, state.last_session_file or '')
    if ok and last and last[1] and last[1] ~= '' then
      state.last_session_id = last[1]
    end
  end

  vim.api.nvim_create_user_command('Codex', function()
    M.toggle()
  end, { desc = 'Toggle Codex popup' })

  vim.api.nvim_create_user_command('CodexToggle', function()
    M.toggle()
  end, { desc = 'Toggle Codex popup (alias)' })

  vim.api.nvim_create_user_command('CodexPanelToggle', function()
    M.toggle_panel()
  end, { desc = 'Toggle Codex side panel' })

  vim.api.nvim_create_user_command('CodexHistory', function()
    M.open_history(false)
  end, { desc = 'Browse Codex chat history' })

  vim.api.nvim_create_user_command('CodexHistoryToggle', function()
    M.toggle_history()
  end, { desc = 'Toggle Codex history view' })

  vim.api.nvim_create_user_command('CodexLast', function()
    M.open_last()
  end, { desc = 'Resume last Codex session' })

  vim.api.nvim_create_user_command('CodexPin', function()
    M.pin_current()
  end, { desc = 'Pin current Codex session' })

  vim.api.nvim_create_user_command('CodexPinned', function()
    M.open_pinned()
  end, { desc = 'Resume pinned Codex session' })

  vim.api.nvim_create_user_command('CodexClearSessions', function()
    M.clear_sessions()
  end, { desc = 'Clear pinned/last Codex sessions' })

  if config.keymaps.toggle then
    vim.api.nvim_set_keymap('n', config.keymaps.toggle, '<cmd>CodexToggle<CR>', { noremap = true, silent = true })
  end

  if config.keymaps.history then
    vim.api.nvim_set_keymap('n', config.keymaps.history, '<cmd>CodexHistoryToggle<CR>', { noremap = true, silent = true })
    vim.api.nvim_set_keymap('t', config.keymaps.history, [[<C-\><C-n><cmd>CodexHistoryToggle<CR>]], { noremap = true, silent = true })
  end

  if config.keymaps.history_list then
    vim.api.nvim_set_keymap('n', config.keymaps.history_list, '<cmd>CodexHistory<CR>', { noremap = true, silent = true })
    vim.api.nvim_set_keymap('t', config.keymaps.history_list, [[<C-\><C-n><cmd>CodexHistory<CR>]], { noremap = true, silent = true })
  end

  if config.keymaps.last then
    vim.api.nvim_set_keymap('n', config.keymaps.last, '<cmd>CodexLast<CR>', { noremap = true, silent = true })
  end

  if config.keymaps.pin then
    vim.api.nvim_set_keymap('n', config.keymaps.pin, '<cmd>CodexPin<CR>', { noremap = true, silent = true })
  end

  if config.keymaps.pinned then
    vim.api.nvim_set_keymap('n', config.keymaps.pinned, '<cmd>CodexPinned<CR>', { noremap = true, silent = true })
  end

  if config.keymaps.panel_toggle then
    vim.api.nvim_set_keymap('n', config.keymaps.panel_toggle, '<cmd>CodexPanelToggle<CR>', { noremap = true, silent = true })
    vim.api.nvim_set_keymap('t', config.keymaps.panel_toggle, [[<C-\><C-n><cmd>CodexPanelToggle<CR>]], { noremap = true, silent = true })
  end

  -- Toggle history from the live Codex terminal
  local group = vim.api.nvim_create_augroup('CodexKeymaps', { clear = true })
  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    pattern = 'codex',
    callback = function(args)
      local buf = args.buf
      if config.keymaps.term_normal then
        vim.keymap.set('t', config.keymaps.term_normal, [[<C-\><C-n>]], { buffer = buf, silent = true })
      end
      apply_quit_keymaps(buf)
      apply_terminal_keymaps(buf)

      if config.auto_insert and not vim.b[buf].codex_no_auto_insert then
        vim.schedule(function()
          if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buftype == 'terminal' then
            vim.cmd('startinsert')
          end
        end)
      end
    end,
  })
  vim.api.nvim_create_autocmd('TermOpen', {
    group = group,
    pattern = '*',
    callback = function(args)
      local buf = args.buf
      if vim.bo[buf].filetype ~= 'codex' then
        return
      end
      apply_terminal_keymaps(buf)
    end,
  })
  if config.auto_insert then
    local auto_group = vim.api.nvim_create_augroup('CodexAutoInsert', { clear = true })
    vim.api.nvim_create_autocmd({ 'BufEnter', 'WinEnter', 'TermOpen', 'TermEnter' }, {
      group = auto_group,
      pattern = '*',
      callback = function(args)
        local buf = args.buf
        if vim.bo[buf].filetype ~= 'codex' or vim.bo[buf].buftype ~= 'terminal' then
          return
        end
        vim.schedule(function()
          if vim.api.nvim_buf_is_valid(buf) then
            vim.api.nvim_set_current_buf(buf)
            vim.cmd('startinsert')
          end
        end)
      end,
    })
  end
end

local function keymap_list(value)
  if type(value) == 'table' then
    return value
  end
  if type(value) == 'string' and value ~= '' then
    return { value }
  end
  return {}
end

apply_quit_keymaps = function(buf)
  if not config.keymaps.quit then
    return
  end
  local function do_close()
    require('codex').close()
  end
  for _, lhs in ipairs(keymap_list(config.keymaps.quit)) do
    vim.keymap.set('n', lhs, do_close, { buffer = buf, silent = true })
    vim.keymap.set('t', lhs, [[<C-\><C-n><cmd>lua require('codex').close()<CR>]], {
      buffer = buf,
      silent = true,
      nowait = true,
    })
  end
end

apply_terminal_keymaps = function(buf)
  if vim.bo[buf].buftype ~= 'terminal' then
    return
  end
  local function send_to_term(keys)
    local job_id = vim.b[buf].terminal_job_id
    if job_id then
      vim.api.nvim_chan_send(job_id, keys)
      return true
    end
    return false
  end
  local function get_clipboard_text()
    if vim.fn.has('mac') == 1 and vim.fn.executable('pbpaste') == 1 then
      local ok, text = pcall(vim.fn.system, 'pbpaste')
      if ok and text and text ~= '' then
        return (text:gsub('\r\n', '\n'))
      end
    end
    local text = vim.fn.getreg('+')
    if text == '' then
      text = vim.fn.getreg('*')
    end
    if text == '' then
      text = vim.fn.getreg('"')
    end
    return text
  end
  local function paste_clipboard()
    local text = get_clipboard_text()
    if text == '' then
      return
    end
    local ok = send_to_term(text)
    if not ok then
      vim.api.nvim_paste(text, true, -1)
    end
  end
  vim.keymap.set('t', '<CR>', function()
    local moved = vim.b[buf].codex_move_to_panel_on_enter
    if moved then
      vim.b[buf].codex_move_to_panel_on_enter = nil
    end
    local ok = send_to_term('\r')
    if not ok then
      vim.api.nvim_feedkeys('\r', 'n', false)
    end
    if moved then
      vim.defer_fn(function()
        move_buf_to_panel(buf)
      end, 10)
    end
  end, { buffer = buf, silent = true })
  vim.keymap.set('t', '<C-v>', paste_clipboard, { buffer = buf, silent = true })
  vim.keymap.set('t', '<C-S-v>', paste_clipboard, { buffer = buf, silent = true })
  vim.keymap.set('t', '<C-Insert>', paste_clipboard, { buffer = buf, silent = true })
  vim.keymap.set('t', '<D-v>', paste_clipboard, { buffer = buf, silent = true })
  vim.keymap.set('n', '<C-v>', paste_clipboard, { buffer = buf, silent = true })
  vim.keymap.set('n', '<C-S-v>', paste_clipboard, { buffer = buf, silent = true })
  vim.keymap.set('n', '<C-Insert>', paste_clipboard, { buffer = buf, silent = true })
  vim.keymap.set('n', '<D-v>', paste_clipboard, { buffer = buf, silent = true })
  vim.keymap.set('n', '<CR>', function()
    send_to_term('\n')
  end, { buffer = buf, silent = true })
  for _, key in ipairs({ '0', '1', '2', '3', '4', '5', '6', '7', '8', '9' }) do
    vim.keymap.set('n', key, function()
      send_to_term(key)
    end, { buffer = buf, silent = true })
  end
end

local function open_window(buf)
  local target_buf = buf or state.buf
  local width = math.floor(vim.o.columns * config.width)
  local height = math.floor(vim.o.lines * config.height)
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local styles = {
    single = {
      { '┌', 'FloatBorder' },
      { '─', 'FloatBorder' },
      { '┐', 'FloatBorder' },
      { '│', 'FloatBorder' },
      { '┘', 'FloatBorder' },
      { '─', 'FloatBorder' },
      { '└', 'FloatBorder' },
      { '│', 'FloatBorder' },
    },
    double = {
      { '╔', 'FloatBorder' },
      { '═', 'FloatBorder' },
      { '╗', 'FloatBorder' },
      { '║', 'FloatBorder' },
      { '╝', 'FloatBorder' },
      { '═', 'FloatBorder' },
      { '╚', 'FloatBorder' },
      { '║', 'FloatBorder' },
    },
    rounded = {
      { '╭', 'FloatBorder' },
      { '─', 'FloatBorder' },
      { '╮', 'FloatBorder' },
      { '│', 'FloatBorder' },
      { '╯', 'FloatBorder' },
      { '─', 'FloatBorder' },
      { '╰', 'FloatBorder' },
      { '│', 'FloatBorder' },
    },
    none = nil,
  }

  local border = type(config.border) == 'string' and styles[config.border] or config.border

  state.win = vim.api.nvim_open_win(target_buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = row,
    col = col,
    style = 'minimal',
    border = border,
  })
end

local function apply_markdown_ui(win, buf)
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return
  end
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  vim.bo[buf].filetype = 'markdown'
  vim.bo[buf].modifiable = false
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].breakindent = true
  vim.wo[win].conceallevel = 2
  vim.wo[win].concealcursor = 'nc'
  vim.wo[win].scrolloff = 2
  vim.wo[win].sidescrolloff = 2
end

local function append_lines(buf, lines)
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  local was_modifiable = vim.bo[buf].modifiable
  if not was_modifiable then
    vim.bo[buf].modifiable = true
  end
  vim.api.nvim_buf_set_lines(buf, -1, -1, false, lines)
  vim.bo[buf].modified = false
  if not was_modifiable then
    vim.bo[buf].modifiable = false
  end
end

local function replace_lines(buf, lines)
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  local was_modifiable = vim.bo[buf].modifiable
  if not was_modifiable then
    vim.bo[buf].modifiable = true
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false
  if not was_modifiable then
    vim.bo[buf].modifiable = false
  end
end

--- Open Codex in a side-panel (vertical split) instead of floating window
local function open_panel(buf)
  if state.panel_win and vim.api.nvim_win_is_valid(state.panel_win) then
    vim.api.nvim_set_current_win(state.panel_win)
    vim.api.nvim_win_set_buf(state.panel_win, buf or state.buf)
    state.win = state.panel_win
    return
  end
  -- Create a vertical split on the right and show the buffer
  vim.cmd('vertical rightbelow vsplit')
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf or state.buf)
  -- Adjust width according to config (percentage of total columns)
  local panel_width = config.panel_width or config.width
  local width = math.floor(vim.o.columns * panel_width)
  vim.api.nvim_win_set_width(win, width)
  state.win = win
  state.panel_win = win
end

move_buf_to_panel = function(buf)
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  local cur = vim.api.nvim_get_current_win()
  local cur_cfg = vim.api.nvim_win_get_config(cur)
  local was_float = cur_cfg and cur_cfg.relative ~= ''
  if state.panel_win and vim.api.nvim_win_is_valid(state.panel_win) then
    vim.api.nvim_set_current_win(state.panel_win)
    vim.api.nvim_win_set_buf(state.panel_win, buf)
    state.win = state.panel_win
    update_winbar(state.win)
    if was_float and cur ~= state.panel_win and vim.api.nvim_win_is_valid(cur) then
      close_win_safe(cur)
    end
    return
  end
  if was_float then
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      local cfg = vim.api.nvim_win_get_config(w)
      if cfg and cfg.relative == '' then
        vim.api.nvim_set_current_win(w)
        break
      end
    end
  end
  open_panel(buf)
  update_winbar(state.win)
  if vim.bo[buf].buftype == 'terminal' and (config.panel_auto_insert or vim.b[buf].codex_force_insert_on_move) then
    local target_win = state.win
    vim.b[buf].codex_force_insert_on_move = nil
    vim.schedule(function()
      if not (target_win and vim.api.nvim_win_is_valid(target_win)) then
        return
      end
      if not (buf and vim.api.nvim_buf_is_valid(buf)) then
        return
      end
      vim.api.nvim_set_current_win(target_win)
      vim.cmd('startinsert')
    end)
  end
  if was_float and cur ~= state.panel_win and vim.api.nvim_win_is_valid(cur) then
    close_win_safe(cur)
  end
end

update_winbar = function(win)
  if not win or not vim.api.nvim_win_is_valid(win) then return end
  local buf = vim.api.nvim_win_get_buf(win)
  local ft = vim.bo[buf].filetype
  if ft == 'codex-history' then
    vim.api.nvim_win_set_option(win, 'winbar', ' Codex History ')
  elseif ft == 'codex' then
    vim.api.nvim_win_set_option(win, 'winbar', ' Codex ')
  else
    vim.api.nvim_win_set_option(win, 'winbar', '')
  end
end

local function focus_last_history_entry(buf, win)
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return
  end
  local last_id = state.last_session_id
  if not last_id or last_id == '' then
    return
  end
  local entries = vim.b[buf].codex_history_entries
  local header_len = vim.b[buf].codex_history_header_len or 0
  if type(entries) ~= 'table' then
    return
  end
  for i, entry in ipairs(entries) do
    if entry.id == last_id then
      vim.api.nvim_win_set_cursor(win, { header_len + i, 0 })
      return
    end
  end
end

local function resolve_check_cmd(cmd)
  if type(cmd) == 'table' then
    return cmd[1]
  end
  if type(cmd) == 'string' then
    return cmd:match('^%S+')
  end
  return nil
end

function M.open(cmd_args, opts)
  local new_session = cmd_args == nil
  local use_panel
  if opts and opts.panel ~= nil then
    use_panel = opts.panel
  elseif config.panel then
    use_panel = true
  elseif new_session and config.open_new_session_in_panel_on_enter then
    use_panel = false
  elseif new_session and config.open_new_session_in_panel then
    use_panel = true
  else
    use_panel = false
  end
  local force_terminal = opts and opts.force_terminal or false
  local function resolve_auto_insert()
    if opts and opts.no_auto_insert then
      return false
    end
    if use_panel then
      return config.panel_auto_insert
    end
    return config.auto_insert
  end
  local should_auto_insert = resolve_auto_insert()
  -- Prefer terminal for side panels to avoid TTY issues
  local use_buffer = (config.use_buffer or config.render_markdown)
    and not force_terminal
    and not use_panel
  local function create_clean_buf()
    local buf = vim.api.nvim_create_buf(false, false)

    vim.api.nvim_buf_set_option(buf, 'bufhidden', use_buffer and 'wipe' or 'hide')
    vim.api.nvim_buf_set_option(buf, 'swapfile', false)
    vim.api.nvim_buf_set_option(buf, 'filetype', 'codex')
    if use_buffer then
      vim.api.nvim_buf_set_option(buf, 'buftype', 'nofile')
    else
      -- ensure terminal-friendly buffer
      vim.api.nvim_buf_set_option(buf, 'buftype', '')
      vim.api.nvim_buf_set_option(buf, 'modifiable', true)
    end
    vim.b[buf].codex_no_auto_insert = not should_auto_insert

    -- Apply configured quit keybinding

    apply_quit_keymaps(buf)

    return buf
  end

  local target_win = nil
  if use_panel and state.panel_win and vim.api.nvim_win_is_valid(state.panel_win) then
    target_win = state.panel_win
  elseif state.win and vim.api.nvim_win_is_valid(state.win) then
    target_win = state.win
  end

  if target_win then
    vim.api.nvim_set_current_win(target_win)
    local win_buf = vim.api.nvim_win_get_buf(target_win)
    if win_buf == state.history_buf or vim.bo[win_buf].filetype == 'codex-history' then
      if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
        state.buf = create_clean_buf()
      end
      vim.api.nvim_win_set_buf(target_win, state.buf)
      update_winbar(target_win)
    else
      -- keep using existing panel window; ensure it shows codex buffer
      if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
        vim.api.nvim_win_set_buf(target_win, state.buf)
        update_winbar(target_win)
      end
    end
  end

  local cmd_to_run
  if cmd_args then
    cmd_to_run = cmd_args
  else
    if type(config.cmd) == 'string' then
      if config.cmd:find '%s' then
        cmd_to_run = config.cmd
      else
        cmd_to_run = { config.cmd }
      end
    else
      cmd_to_run = vim.deepcopy(config.cmd)
    end

    if type(cmd_to_run) == 'table' and config.model then
      table.insert(cmd_to_run, '-m')
      table.insert(cmd_to_run, config.model)
    end
  end

  local check_cmd = resolve_check_cmd(cmd_to_run)

  if check_cmd and vim.fn.executable(check_cmd) == 0 then
    if config.autoinstall then
      installer.prompt_autoinstall(function(success)
        if success then
          M.open(cmd_args) -- Try again after installing
        else
          -- Show failure message *after* buffer is created
          if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
            state.buf = create_clean_buf()
          end
          replace_lines(state.buf, {
            'Autoinstall cancelled or failed.',
            '',
            'You can install manually with:',
            '  npm install -g @openai/codex',
          })
          if use_panel then open_panel() else open_window() end
        end
      end)
      return
    else
      -- Show fallback message
      if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
        state.buf = vim.api.nvim_create_buf(false, false)
      end
      replace_lines(state.buf, {
        'Codex CLI not found, autoinstall disabled.',
        '',
        'Install with:',
        '  npm install -g @openai/codex',
        '',
        'Or enable autoinstall in setup: require("codex").setup{ autoinstall = true }',
      })
      if use_panel then open_panel() else open_window() end
      return
    end
  end

  local function is_buf_reusable(buf, need_buffer_mode)
    if type(buf) ~= 'number' or not vim.api.nvim_buf_is_valid(buf) then
      return false
    end
    local bt = vim.bo[buf].buftype
    if need_buffer_mode then
      return bt == 'nofile'
    else
      return bt ~= 'nofile'
    end
  end

  if not is_buf_reusable(state.buf, use_buffer) then
    state.buf = create_clean_buf()
  end
  vim.b[state.buf].codex_no_auto_insert = not should_auto_insert
  if new_session and config.open_new_session_in_panel_on_enter and not use_panel and not use_buffer then
    vim.b[state.buf].codex_move_to_panel_on_enter = true
    vim.b[state.buf].codex_force_insert_on_move = true
  end

  if use_panel then open_panel() else open_window() end
  update_winbar(state.win)
  if use_buffer and config.render_markdown then
    apply_markdown_ui(state.win, state.buf)
  end

  -- Ensure terminal buffer is clean before starting job
  if vim.api.nvim_buf_is_valid(state.buf) then
    vim.bo[state.buf].modified = false
    vim.api.nvim_set_current_buf(state.buf)
  end

  if not state.job then
    if use_buffer then
      -- capture stdout/stderr into normal buffer; fallback to terminal if CLI needs a real TTY
      local needs_tty_fallback = false
      state.job = vim.fn.jobstart(cmd_to_run, {
        cwd = vim.loop.cwd(),
        stdout_buffered = true,
        on_stdout = function(_, data)
          if not data then return end
          for _, line in ipairs(data) do
            if line ~= '' then
              local norm = strip_ansi(line)
              append_lines(state.buf, { norm })
              if norm:match('cursor position could not be read') then
                needs_tty_fallback = true
              end
            end
          end
        end,
        on_stderr = function(_, data)
          if not data then return end
          for _, line in ipairs(data) do
            if line ~= '' then
              local norm = strip_ansi(line)
              if norm:match('stdin is not a terminal') or norm:match('cursor position could not be read') then
                needs_tty_fallback = true
                -- Suppress noisy non-tty errors; we will fall back to a terminal.
                goto continue
              end
              append_lines(state.buf, { '[ERR] ' .. norm })
            end
            ::continue::
          end
        end,
        on_exit = function(_, code)
          state.job = nil
          if needs_tty_fallback and not force_terminal then
            vim.schedule(function()
              M.open(cmd_args, { panel = use_panel, force_terminal = true, no_auto_insert = true })
            end)
            return
          end
          append_lines(state.buf, { ('[Codex exit: %d]'):format(code) })
        end,
      })
    else
      -- use a terminal buffer
      state.job = vim.fn.termopen(cmd_to_run, {
        cwd = vim.loop.cwd(),
        on_exit = function()
          state.job = nil
        end,
      })
      enter_terminal_mode()
    end
  else
    enter_terminal_mode()
  end
end

function M.open_history(reuse_win)
  local history = require('codex.history')
  if config.history and config.history.ui == 'telescope' then
    history.open()
    return
  end

  local buf = history.build_buffer()
  state.history_buf = buf

  if reuse_win and state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_set_current_win(state.win)
    vim.api.nvim_win_set_buf(state.win, buf)
    update_winbar(state.win)
    focus_last_history_entry(buf, state.win)
    return
  end

  if config.panel then
    open_panel(buf)
  else
    open_window(buf)
  end
  update_winbar(state.win)
  focus_last_history_entry(buf, state.win)
end

function M.toggle_history()
  if config.history and config.history.open_last_on_toggle and state.last_session_id then
    M.open_last()
    return
  end

  if config.history and config.history.ui == 'telescope' then
    require('codex.history').open()
    return
  end

  if state.win and vim.api.nvim_win_is_valid(state.win) then
    local win_buf = vim.api.nvim_win_get_buf(state.win)
    if win_buf == state.history_buf or vim.bo[win_buf].filetype == 'codex-history' then
      if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
        vim.api.nvim_win_set_buf(state.win, state.buf)
        update_winbar(state.win)
        if config.auto_insert and vim.bo[state.buf].buftype == 'terminal' then
          vim.cmd('startinsert')
        end
        return
      end
      M.open(nil)
      return
    end
    M.open_history(true)
    return
  end

  M.open_history(false)
end

function M.resume(session_id, opts)
  if not session_id or session_id == '' then
    vim.notify('[codex.nvim] Missing session id for resume', vim.log.levels.ERROR)
    return
  end

  if state.job then
    if config.history and config.history.auto_close_active then
      pcall(vim.fn.jobstop, state.job)
      pcall(vim.fn.chanclose, state.job)
      M.close()
      state.job = nil
    else
      vim.notify('[codex.nvim] Close the active Codex session before resuming another', vim.log.levels.WARN)
      return
    end
  end

  local cmd
  if type(config.cmd) == 'table' then
    cmd = vim.deepcopy(config.cmd)
    table.insert(cmd, 'resume')
    table.insert(cmd, session_id)
  elseif type(config.cmd) == 'string' then
    if config.cmd:find '%s' then
      vim.notify('[codex.nvim] config.cmd contains spaces; using "codex" for resume', vim.log.levels.WARN)
      cmd = { 'codex', 'resume', session_id }
    else
      cmd = { config.cmd, 'resume', session_id }
    end
  else
    cmd = { 'codex', 'resume', session_id }
  end

  state.last_session_id = session_id
  if config.history and config.history.persist_last then
    local dir = vim.fn.stdpath('data') .. '/codex.nvim'
    vim.fn.mkdir(dir, 'p')
    vim.fn.writefile({ session_id }, state.last_session_file)
  end
  M.open(cmd, opts)
end

function M.open_last()
  local history = require('codex.history')
  local id = state.last_session_id or history.latest_session_id()
  if not id then
    vim.notify('[codex.nvim] No Codex sessions found', vim.log.levels.WARN)
    return
  end
  local opts = nil
  if config.history and config.history.open_session_in_panel then
    opts = { panel = true }
  end
  M.resume(id, opts)
end

function M.pin_current()
  local id = state.last_session_id
  if not id then
    vim.notify('[codex.nvim] No active session to pin. Resume a session first.', vim.log.levels.WARN)
    return
  end
  state.pinned_session_id = id
  if config.history and config.history.persist_pin then
    local dir = vim.fn.stdpath('data') .. '/codex.nvim'
    vim.fn.mkdir(dir, 'p')
    vim.fn.writefile({ id }, state.pinned_session_file)
  end
  vim.notify('[codex.nvim] Pinned session: ' .. id, vim.log.levels.INFO)
end

function M.open_pinned()
  local id = state.pinned_session_id
  if not id or id == '' then
    vim.notify('[codex.nvim] No pinned session. Use :CodexPin first.', vim.log.levels.WARN)
    return
  end
  M.resume(id)
end

function M.clear_sessions()
  state.last_session_id = nil
  state.pinned_session_id = nil
  if state.last_session_file then
    pcall(vim.fn.delete, state.last_session_file)
  end
  if state.pinned_session_file then
    pcall(vim.fn.delete, state.pinned_session_file)
  end
  vim.notify('[codex.nvim] Cleared pinned and last sessions', vim.log.levels.INFO)
end

function M.close()
  local target_win = nil
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    local wins = vim.fn.win_findbuf(state.buf)
    if wins and #wins > 0 then
      target_win = wins[1]
    end
  end
  if not target_win then
    target_win = state.win
  end
  if target_win then
    close_win_safe(target_win)
  end
  if state.win == target_win then
    state.win = nil
  end
  if state.panel_win == target_win then
    state.panel_win = nil
  end
end

function M.toggle()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    M.close()
  else
    M.open(nil)
  end
end

function M.toggle_panel()
  if state.panel_win and vim.api.nvim_win_is_valid(state.panel_win) then
    close_win_safe(state.panel_win)
    if state.win == state.panel_win then
      state.win = nil
    end
    state.panel_win = nil
    return
  end

  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    open_panel(state.buf)
    update_winbar(state.win)
    if config.panel_auto_insert and vim.bo[state.buf].buftype == 'terminal' then
      vim.cmd('startinsert')
    end
    return
  end

  M.open(nil, { panel = true })
end

function M.get_config()
  return config
end

function M.get_state()
  return state
end

function M.statusline()
  if state.job and not (state.win and vim.api.nvim_win_is_valid(state.win)) then
    return '[Codex]'
  end
  return ''
end

function M.status()
  return {
    function()
      return M.statusline()
    end,
    cond = function()
      return M.statusline() ~= ''
    end,
    icon = '',
    color = { fg = '#51afef' },
  }
end

return setmetatable(M, {
  __call = function(_, opts)
    M.setup(opts)
    return M
  end,
})
