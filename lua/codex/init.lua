local vim = vim
local installer = require 'codex.installer'
local state = require 'codex.state'

local M = {}

local function enter_terminal_mode()
  vim.schedule(function()
    if
      config.auto_insert
      and state.win and vim.api.nvim_win_is_valid(state.win)
      and state.buf and vim.api.nvim_buf_is_valid(state.buf)
      and vim.bo[state.buf].buftype == 'terminal'
    then
      vim.api.nvim_set_current_win(state.win)
      vim.cmd('startinsert')
    end
  end)
end

local config = {
  keymaps = {
    toggle = nil,
    quit = '<C-q>', -- Default: Ctrl+q to quit
    history = '<leader>ch',
    term_normal = '<Esc><Esc>', -- Enter terminal-normal mode
    last = '<leader>cl',
    pin = '<leader>cp',
    pinned = '<leader>cP',
  },
  border = 'single',
  width = 0.8,
  height = 0.8,
  cmd = 'codex',
  model = nil, -- Default to the latest model
  autoinstall = true,
  panel     = false,   -- if true, open Codex in a side-panel instead of floating window
  use_buffer = false,  -- if true, capture Codex stdout into a normal buffer instead of a terminal
  auto_insert = true,  -- if true, enter terminal mode on open/focus
  history = {
    max_entries = 200,
    max_files = 1000,
    auto_close_active = true,
    ui = 'buffer', -- 'buffer' or 'telescope' (requires telescope.nvim)
    persist_pin = true,
    persist_last = true,
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

  if config.keymaps.last then
    vim.api.nvim_set_keymap('n', config.keymaps.last, '<cmd>CodexLast<CR>', { noremap = true, silent = true })
  end

  if config.keymaps.pin then
    vim.api.nvim_set_keymap('n', config.keymaps.pin, '<cmd>CodexPin<CR>', { noremap = true, silent = true })
  end

  if config.keymaps.pinned then
    vim.api.nvim_set_keymap('n', config.keymaps.pinned, '<cmd>CodexPinned<CR>', { noremap = true, silent = true })
  end

  -- Toggle history from the live Codex terminal
  local group = vim.api.nvim_create_augroup('CodexKeymaps', { clear = true })
  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    pattern = 'codex',
    callback = function(args)
      local buf = args.buf
      vim.keymap.set('n', '<Tab>', function()
        require('codex').toggle_history()
      end, { buffer = buf, silent = true })
      vim.keymap.set('t', '<Tab>', function()
        require('codex').toggle_history()
      end, { buffer = buf, silent = true })

      if config.keymaps.term_normal then
        vim.keymap.set('t', config.keymaps.term_normal, [[<C-\><C-n>]], { buffer = buf, silent = true })
      end

      if config.auto_insert then
        vim.schedule(function()
          if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buftype == 'terminal' then
            vim.cmd('startinsert')
          end
        end)
      end
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

--- Open Codex in a side-panel (vertical split) instead of floating window
local function open_panel(buf)
  -- Create a vertical split on the right and show the buffer
  vim.cmd('vertical rightbelow vsplit')
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf or state.buf)
  -- Adjust width according to config (percentage of total columns)
  local width = math.floor(vim.o.columns * config.width)
  vim.api.nvim_win_set_width(win, width)
  state.win = win
end

local function update_winbar(win)
  if not win or not vim.api.nvim_win_is_valid(win) then return end
  local buf = vim.api.nvim_win_get_buf(win)
  local ft = vim.bo[buf].filetype
  if ft == 'codex-history' then
    vim.api.nvim_win_set_option(win, 'winbar', ' Codex History  |  Tab: Codex ')
  elseif ft == 'codex' then
    vim.api.nvim_win_set_option(win, 'winbar', ' Codex  |  Tab: History ')
  else
    vim.api.nvim_win_set_option(win, 'winbar', '')
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

function M.open(cmd_args)
  local function create_clean_buf()
    local buf = vim.api.nvim_create_buf(false, false)

    vim.api.nvim_buf_set_option(buf, 'bufhidden', 'hide')
    vim.api.nvim_buf_set_option(buf, 'swapfile', false)
    vim.api.nvim_buf_set_option(buf, 'filetype', 'codex')

    -- Apply configured quit keybinding

    if config.keymaps.quit then
      local quit_cmd = [[<cmd>lua require('codex').close()<CR>]]
      vim.api.nvim_buf_set_keymap(buf, 't', config.keymaps.quit, [[<C-\><C-n>]] .. quit_cmd, { noremap = true, silent = true })
      vim.api.nvim_buf_set_keymap(buf, 'n', config.keymaps.quit, quit_cmd, { noremap = true, silent = true })
    end

    return buf
  end

  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_set_current_win(state.win)
    local win_buf = vim.api.nvim_win_get_buf(state.win)
    if win_buf == state.history_buf or vim.bo[win_buf].filetype == 'codex-history' then
      if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
        state.buf = create_clean_buf()
      end
      vim.api.nvim_win_set_buf(state.win, state.buf)
      update_winbar(state.win)
    else
      enter_terminal_mode()
      return
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
          vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, {
            'Autoinstall cancelled or failed.',
            '',
            'You can install manually with:',
            '  npm install -g @openai/codex',
          })
          if config.panel then open_panel() else open_window() end
        end
      end)
      return
    else
      -- Show fallback message
      if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
        state.buf = vim.api.nvim_create_buf(false, false)
      end
      vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, {
        'Codex CLI not found, autoinstall disabled.',
        '',
        'Install with:',
        '  npm install -g @openai/codex',
        '',
        'Or enable autoinstall in setup: require("codex").setup{ autoinstall = true }',
      })
      if config.panel then open_panel() else open_window() end
      return
    end
  end

  local function is_buf_reusable(buf)
    return type(buf) == 'number' and vim.api.nvim_buf_is_valid(buf)
  end

  if not is_buf_reusable(state.buf) then
    state.buf = create_clean_buf()
  end

  if config.panel then open_panel() else open_window() end
  update_winbar(state.win)

  -- Ensure terminal buffer is clean before starting job
  if vim.api.nvim_buf_is_valid(state.buf) then
    vim.bo[state.buf].modified = false
    vim.api.nvim_set_current_buf(state.buf)
  end

  if not state.job then
    if config.use_buffer then
      -- capture stdout/stderr into normal buffer
      state.job = vim.fn.jobstart(cmd_to_run, {
        cwd = vim.loop.cwd(),
        stdout_buffered = true,
        on_stdout = function(_, data)
          if not data then return end
          for _, line in ipairs(data) do
            if line ~= '' then
              vim.api.nvim_buf_set_lines(state.buf, -1, -1, false, { line })
            end
          end
        end,
        on_stderr = function(_, data)
          if not data then return end
          for _, line in ipairs(data) do
            if line ~= '' then
              vim.api.nvim_buf_set_lines(state.buf, -1, -1, false, { '[ERR] ' .. line })
            end
          end
        end,
        on_exit = function(_, code)
          state.job = nil
          vim.api.nvim_buf_set_lines(state.buf, -1, -1, false, {
            ('[Codex exit: %d]'):format(code),
          })
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
    return
  end

  if config.panel then
    open_panel(buf)
  else
    open_window(buf)
  end
  update_winbar(state.win)
end

function M.toggle_history()
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

function M.resume(session_id)
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
  M.open(cmd)
end

function M.open_last()
  local history = require('codex.history')
  local id = state.last_session_id or history.latest_session_id()
  if not id then
    vim.notify('[codex.nvim] No Codex sessions found', vim.log.levels.WARN)
    return
  end
  M.resume(id)
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
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
  state.win = nil
end

function M.toggle()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    M.close()
  else
    M.open(nil)
  end
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
