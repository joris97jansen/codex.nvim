local M = {}

local function decode_json(line)
  local ok, data = pcall(vim.json.decode, line)
  if ok then return data end
  ok, data = pcall(vim.fn.json_decode, line)
  if ok then return data end
  return nil
end

local function codex_home()
  return os.getenv('CODEX_HOME') or vim.fn.expand('~/.codex')
end

local function session_files()
  local dir = codex_home() .. '/sessions'
  return vim.fn.globpath(dir, '**/*.jsonl', true, true)
end

local function parse_session_meta(file)
  local lines = vim.fn.readfile(file, '', 1)
  if not lines or #lines == 0 then return nil end
  local data = decode_json(lines[1])
  if not data or data.type ~= 'session_meta' then return nil end

  local payload = data.payload or {}
  local git = payload.git or {}

  return {
    id = payload.id,
    timestamp = payload.timestamp,
    cwd = payload.cwd,
    source = payload.source,
    originator = payload.originator,
    model_provider = payload.model_provider,
    branch = git.branch,
    repository_url = git.repository_url,
    file = file,
  }
end

local function short_time(iso)
  if not iso or iso == '' then return '' end
  local t = iso:gsub('T', ' '):gsub('Z', '')
  return t:sub(1, 16)
end

local function display_line(entry)
  local time = short_time(entry.timestamp)
  local id = entry.id or 'unknown'
  local cwd = entry.cwd or ''
  local branch = entry.branch or ''
  local source = entry.source or ''

  if source ~= '' then
    source = '[' .. source .. ']'
  end

  return string.format('%s  %s  %s  %s %s', time, id, cwd, branch, source)
end

local function load_entries(max_entries)
  local config = require('codex').get_config()
  local max_files = (config.history and config.history.max_files) or 1000
  local files = session_files()

  if max_files and #files > max_files then
    table.sort(files, function(a, b)
      local sa = vim.loop.fs_stat(a)
      local sb = vim.loop.fs_stat(b)
      local ma = sa and sa.mtime and sa.mtime.sec or 0
      local mb = sb and sb.mtime and sb.mtime.sec or 0
      return ma > mb
    end)
    local trimmed = {}
    for i = 1, max_files do
      trimmed[i] = files[i]
    end
    files = trimmed
  end

  local entries = {}
  for _, file in ipairs(files) do
    local entry = parse_session_meta(file)
    if entry and entry.id and entry.timestamp then
      table.insert(entries, entry)
    end
  end

  table.sort(entries, function(a, b)
    return (a.timestamp or '') > (b.timestamp or '')
  end)

  if max_entries and #entries > max_entries then
    local trimmed = {}
    for i = 1, max_entries do
      trimmed[i] = entries[i]
    end
    entries = trimmed
  end

  return entries
end

function M.latest_session_id()
  local config = require('codex').get_config()
  local list = load_entries(config.history and config.history.max_entries or 200)
  if #list == 0 then return nil end
  return list[1].id
end

local function open_telescope(entries)
  local ok_telescope = pcall(require, 'telescope')
  if not ok_telescope then
    return false
  end
  local ok, pickers = pcall(require, 'telescope.pickers')
  if not ok then
    return false
  end
  local finders = require('telescope.finders')
  local conf = require('telescope.config').values
  local actions = require('telescope.actions')
  local action_state = require('telescope.actions.state')

  pickers.new({}, {
    prompt_title = 'Codex History',
    finder = finders.new_table({
      results = entries,
      entry_maker = function(entry)
        return {
          value = entry,
          display = display_line(entry),
          ordinal = (entry.timestamp or '') .. ' ' .. (entry.cwd or '') .. ' ' .. (entry.id or ''),
        }
      end,
    }),
    sorter = conf.generic_sorter({}),
    attach_mappings = function(prompt_bufnr, map)
      local function resume_selected()
        local selection = action_state.get_selected_entry()
        if not selection or not selection.value then
          return
        end
        actions.close(prompt_bufnr)
        require('codex').resume(selection.value.id)
      end
      map('i', '<CR>', resume_selected)
      map('n', '<CR>', resume_selected)
      return true
    end,
  }):find()

  return true
end

local function close_window(win)
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
end

function M.build_buffer(entries)
  local config = require('codex').get_config()
  local list = entries or load_entries(config.history and config.history.max_entries or 200)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(buf, 'bufhidden', 'wipe')
  vim.api.nvim_buf_set_option(buf, 'buftype', 'nofile')
  vim.api.nvim_buf_set_option(buf, 'swapfile', false)
  vim.api.nvim_buf_set_option(buf, 'filetype', 'codex-history')

  local header = {
    'Codex History',
    'Enter: resume  q: close  /: search  Tab: toggle',
    '',
  }

  local lines = {}
  for _, line in ipairs(header) do
    table.insert(lines, line)
  end

  for _, entry in ipairs(list) do
    table.insert(lines, display_line(entry))
  end

  if #list == 0 then
    table.insert(lines, 'No Codex sessions found in ' .. codex_home() .. '/sessions')
  end

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(buf, 'modifiable', false)

  vim.b[buf].codex_history_entries = list
  vim.b[buf].codex_history_header_len = #header

  vim.keymap.set('n', 'q', function()
    close_window(vim.api.nvim_get_current_win())
  end, { buffer = buf, silent = true })

  local config = require('codex').get_config()
  if config.keymaps and config.keymaps.quit then
    vim.keymap.set('n', config.keymaps.quit, function()
      require('codex').close()
    end, { buffer = buf, silent = true })
  end

  if config.keymaps and config.keymaps.history then
    vim.keymap.set('n', config.keymaps.history, function()
      require('codex').toggle_history()
    end, { buffer = buf, silent = true })
  end

  vim.keymap.set('n', '<CR>', function()
    local win = vim.api.nvim_get_current_win()
    local line = vim.api.nvim_win_get_cursor(win)[1]
    local idx = line - (vim.b[buf].codex_history_header_len or 0)
    local entry = (vim.b[buf].codex_history_entries or {})[idx]
    if not entry then
      return
    end
    require('codex').resume(entry.id)
  end, { buffer = buf, silent = true })

  vim.keymap.set('n', '<Tab>', function()
    require('codex').toggle_history()
  end, { buffer = buf, silent = true })

  return buf
end

function M.open_split(entries)
  local buf = M.build_buffer(entries)
  vim.cmd('botright split')
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_win_set_height(win, math.min(15, vim.o.lines - 4))
  return buf, win
end

function M.open(entries)
  local config = require('codex').get_config()
  local list = entries or load_entries(config.history and config.history.max_entries or 200)
  if config.history and config.history.ui == 'telescope' then
    if open_telescope(list) then
      return
    end
    vim.notify('[codex.nvim] Telescope not available; falling back to buffer history view', vim.log.levels.WARN)
  end
  return M.open_split(list)
end

return M
