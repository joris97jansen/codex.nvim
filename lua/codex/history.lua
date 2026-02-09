local M = {}

local function decode_json(line)
  local ok, data = pcall(vim.json.decode, line)
  if ok then return data end
  ok, data = pcall(vim.fn.json_decode, line)
  if ok then return data end
  return nil
end

local function system_first(args)
  local out = vim.fn.systemlist(args)
  if vim.v.shell_error ~= 0 then
    return nil
  end
  if not out or not out[1] or out[1] == '' then
    return nil
  end
  return out[1]
end

local function codex_home()
  return os.getenv('CODEX_HOME') or vim.fn.expand('~/.codex')
end

local function session_files()
  local dir = codex_home() .. '/sessions'
  return vim.fn.globpath(dir, '**/*.jsonl', true, true)
end

local function normalize_repo_url(url)
  if not url or url == '' then
    return nil
  end
  local out = url
  out = out:gsub('%.git$', '')
  out = out:gsub('^git@', '')
  out = out:gsub('^https?://', '')
  out = out:gsub(':', '/')
  return out
end

local function current_repo()
  local cwd = vim.fn.getcwd()
  local root = system_first({ 'git', '-C', cwd, 'rev-parse', '--show-toplevel' })
  local url = system_first({ 'git', '-C', cwd, 'config', '--get', 'remote.origin.url' })
  local branch = system_first({ 'git', '-C', cwd, 'rev-parse', '--abbrev-ref', 'HEAD' })
  return {
    cwd = cwd,
    root = root,
    url = url,
    branch = branch,
  }
end

local function repo_key()
  local repo = current_repo()
  if repo.url and repo.url ~= '' then
    return normalize_repo_url(repo.url)
  end
  if repo.root and repo.root ~= '' then
    return repo.root
  end
  if repo.cwd and repo.cwd ~= '' then
    return repo.cwd
  end
  return nil
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
    title = payload.title,
    cwd = payload.cwd,
    source = payload.source,
    originator = payload.originator,
    model_provider = payload.model_provider,
    branch = git.branch,
    repository_url = git.repository_url,
    file = file,
  }
end

local function session_has_content(file)
  local lines = vim.fn.readfile(file)
  if not lines or #lines <= 1 then
    return false
  end
  for i = 2, #lines do
    local data = decode_json(lines[i])
    if data then
      if data.type and data.type ~= 'session_meta' then
        return true
      end
      if data.payload and (data.payload.messages or data.payload.content) then
        return true
      end
    elseif lines[i] ~= '' then
      return true
    end
  end
  return false
end

local function is_boilerplate(text)
  if not text or text == '' then
    return true
  end
  if text:match('^# AGENTS%.md instructions') then
    return true
  end
  if text:match('^<environment_context>') then
    return true
  end
  if text:match('^<permissions instructions>') then
    return true
  end
  if text:match('^<INSTRUCTIONS>') then
    return true
  end
  return false
end

local function session_has_meaningful_content(file)
  local lines = vim.fn.readfile(file)
  if not lines or #lines <= 1 then
    return false
  end
  for i = 2, #lines do
    local data = decode_json(lines[i])
    if data and data.type == 'response_item' and data.payload and data.payload.type == 'message' then
      local payload = data.payload
      if payload.role == 'user' and payload.content then
        for _, item in ipairs(payload.content) do
          local text = item.text or item.input_text or ''
          if text ~= '' and not is_boilerplate(text) then
            return true
          end
        end
      end
    end
  end
  return false
end

local function parse_iso_time(iso)
  if not iso or iso == '' then
    return nil
  end
  local ts = iso:gsub('Z$', ''):gsub('%.%d+$', '')
  local ok, value = pcall(vim.fn.strptime, '%Y-%m-%dT%H:%M:%S', ts)
  if ok and value and value > 0 then
    return value
  end
  local y, m, d, hh, mm, ss = ts:match('^(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+)$')
  if not y then
    return nil
  end
  return os.time({
    year = tonumber(y),
    month = tonumber(m),
    day = tonumber(d),
    hour = tonumber(hh),
    min = tonumber(mm),
    sec = tonumber(ss),
  })
end

local function relative_time(iso)
  local t = parse_iso_time(iso)
  if not t then
    return ''
  end
  local now = os.time()
  local delta = now - t
  if delta < 0 then
    delta = 0
  end
  if delta < 60 then
    return 'just now'
  end
  local mins = math.floor(delta / 60)
  if mins < 60 then
    return mins .. ' min ago'
  end
  local hours = math.floor(mins / 60)
  if hours < 24 then
    return hours .. ' hr ago'
  end
  local days = math.floor(hours / 24)
  if days < 30 then
    return days .. ' day' .. (days == 1 and '' or 's') .. ' ago'
  end
  local months = math.floor(days / 30)
  if months < 12 then
    return months .. ' mo ago'
  end
  local years = math.floor(months / 12)
  return years .. ' yr ago'
end

local function clean_summary(text, max_len)
  if not text or text == '' then
    return ''
  end
  local out = text:gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', '')
  if max_len and max_len > 0 and #out > max_len then
    if max_len > 3 then
      out = out:sub(1, max_len - 3) .. '...'
    else
      out = out:sub(1, max_len)
    end
  end
  return out
end

local function extract_summary(file, max_lines, max_len)
  local lines = vim.fn.readfile(file, '', max_lines or 200)
  if not lines or #lines <= 1 then
    return nil
  end
  for i = 2, #lines do
    local data = decode_json(lines[i])
    if data and data.type == 'response_item' and data.payload and data.payload.type == 'message' then
      local payload = data.payload
      if payload.role == 'user' and payload.content then
        for _, item in ipairs(payload.content) do
          local text = item.text or item.input_text or ''
          if text ~= '' and not is_boilerplate(text) then
            return clean_summary(text, max_len)
          end
        end
      end
    end
  end
  return nil
end

local function short_time(iso)
  if not iso or iso == '' then return '' end
  local t = iso:gsub('T', ' '):gsub('Z', '')
  return t:sub(1, 16)
end

local function pad_right(text, width)
  local s = text or ''
  if #s >= width then
    return s
  end
  return s .. string.rep(' ', width - #s)
end

local function fit(text, width)
  local s = text or ''
  if #s <= width then
    return pad_right(s, width)
  end
  if width <= 3 then
    return s:sub(1, width)
  end
  return s:sub(1, width - 3) .. '...'
end

local function compute_widths(entries, config)
  local updated_w = #'Updated'
  local branch_w = #'Branch'
  local max_branch = (config.history and config.history.branch_width) or 20
  for _, entry in ipairs(entries) do
    local updated = relative_time(entry.timestamp)
    if #updated > updated_w then
      updated_w = #updated
    end
    local branch = entry.branch or ''
    if #branch > branch_w then
      branch_w = #branch
    end
  end
  if branch_w > max_branch then
    branch_w = max_branch
  end
  return {
    updated = updated_w,
    branch = branch_w,
  }
end

local function display_line(entry, widths)
  local updated = relative_time(entry.timestamp)
  local branch = entry.branch or ''
  local summary = entry.summary or entry.title or entry.id or 'unknown'

  local parts = {
    fit(updated, widths.updated),
    fit(branch, widths.branch),
    summary,
  }
  return table.concat(parts, '  ')
end

local function load_entries(max_entries)
  local config = require('codex').get_config()
  local max_files = (config.history and config.history.max_files) or 1000
  local files = session_files()
  local scope = (config.history and config.history.scope) or 'repo'
  local repo = nil
  if scope ~= 'all' then
    repo = current_repo()
  end

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
    local ok_content = true
    if config.history and config.history.skip_empty then
      ok_content = session_has_meaningful_content(file)
    end
    if entry and entry.id and entry.timestamp and ok_content then
      local keep = true
      if scope == 'repo' and repo then
        if repo.url and entry.repository_url then
          keep = normalize_repo_url(repo.url) == normalize_repo_url(entry.repository_url)
        elseif repo.root and entry.cwd then
          keep = entry.cwd:sub(1, #repo.root) == repo.root
        elseif repo.cwd and entry.cwd then
          keep = entry.cwd == repo.cwd
        end
      elseif scope == 'cwd' then
        local cwd = vim.fn.getcwd()
        if entry.cwd then
          keep = entry.cwd:sub(1, #cwd) == cwd
        end
      end
      if keep then
        if config.history and config.history.show_summary ~= false then
          local max_lines = (config.history and config.history.summary_max_lines) or 200
          local max_len = (config.history and config.history.summary_max_len) or 140
          entry.summary = extract_summary(file, max_lines, max_len)
        end
        if config.history and config.history.skip_empty and (not entry.summary or entry.summary == '') then
          keep = false
        end
        table.insert(entries, entry)
      end
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
  local state = require('codex').get_state()
  local default_index = nil
  if state and state.last_session_id then
    for i, entry in ipairs(entries or {}) do
      if entry.id == state.last_session_id then
        default_index = i
        break
      end
    end
  end

  local widths = compute_widths(entries or {}, require('codex').get_config())
  pickers.new({}, {
    prompt_title = 'Codex History',
    finder = finders.new_table({
      results = entries,
      entry_maker = function(entry)
        return {
          value = entry,
          display = display_line(entry, widths),
          ordinal = table.concat({
            entry.timestamp or '',
            entry.summary or '',
            entry.title or '',
            entry.cwd or '',
            entry.id or '',
          }, ' '),
        }
      end,
    }),
    sorter = conf.generic_sorter({}),
    default_selection_index = default_index,
    attach_mappings = function(prompt_bufnr, map)
      local function resume_selected()
        local selection = action_state.get_selected_entry()
        if not selection or not selection.value then
          return
        end
        actions.close(prompt_bufnr)
        local config = require('codex').get_config()
        local opts = nil
        if config.history and config.history.open_session_in_panel then
          opts = { panel = true }
        end
        require('codex').resume(selection.value.id, opts)
      end
      local function close_picker()
        actions.close(prompt_bufnr)
      end
      map('i', '<CR>', resume_selected)
      map('n', '<CR>', resume_selected)
      map('i', '<C-c>', close_picker)
      map('n', '<C-c>', close_picker)
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

  local widths = compute_widths(list, config)
  local header = {
    'Codex History',
    'Enter: resume  q: close  /: search',
    '',
    table.concat({
      pad_right('Updated', widths.updated),
      pad_right('Branch', widths.branch),
      'Conversation',
    }, '  '),
  }

  local lines = {}
  for _, line in ipairs(header) do
    table.insert(lines, line)
  end

  for _, entry in ipairs(list) do
    table.insert(lines, display_line(entry, widths))
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
    local quit_maps = config.keymaps.quit
    if type(quit_maps) == 'string' then
      quit_maps = { quit_maps }
    end
    for _, lhs in ipairs(quit_maps) do
      vim.keymap.set('n', lhs, function()
        require('codex').close()
      end, { buffer = buf, silent = true })
    end
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
    local config = require('codex').get_config()
    local opts = nil
    if config.history and config.history.open_session_in_panel then
      opts = { panel = true }
    end
    require('codex').resume(entry.id, opts)
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

function M.repo_key()
  return repo_key()
end

return M
