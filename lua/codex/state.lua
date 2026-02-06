-- lua/codex/state.lua

local M = {
  buf = nil,
  win = nil,
  panel_win = nil,
  job = nil,
  history_buf = nil,
  last_session_id = nil,
  pinned_session_id = nil,
  pinned_session_file = nil,
  last_session_file = nil,
}

M.pinned_session_file = vim.fn.stdpath('data') .. '/codex.nvim/pinned_session'
M.last_session_file = vim.fn.stdpath('data') .. '/codex.nvim/last_session'

return M
