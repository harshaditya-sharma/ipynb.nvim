-- ipynb/facade.lua - Facade buffer rendering

local M = {}

---Set lines on facade buffer, suppressing LSP change tracking errors
---LSP change tracking fails because facade isn't registered with the shadow buffer's LSP clients
---@param buf number Facade buffer
---@param start_line number 0-indexed start line
---@param end_line number 0-indexed end line (exclusive)
---@param lines string[] New lines
local function set_facade_lines(buf, start_line, end_line, lines)
  local ok, err = pcall(vim.api.nvim_buf_set_lines, buf, start_line, end_line, false, lines)
  if not ok and err and not err:match('_changetracking') then
    error(err)
  end
end

---Start notebook highlighting, retrying while the parser is still being
---compiled (first run): the notebook itself works without it.
---@param buf number
function M.start_treesitter(buf)
  if pcall(vim.treesitter.start, buf, 'ipynb') then
    return
  end
  local timer = vim.uv.new_timer()
  if not timer then
    return
  end
  local tries = 0
  timer:start(500, 1000, vim.schedule_wrap(function()
    tries = tries + 1
    local done = not vim.api.nvim_buf_is_valid(buf) or tries > 120
      or pcall(vim.treesitter.start, buf, 'ipynb')
    if done and not timer:is_closing() then
      timer:stop()
      timer:close()
    end
  end))
end

local WINDOW_OPTIONS = {
  conceallevel = 2, -- rounded borders
  concealcursor = 'nc', -- conceal in normal and command mode
  signcolumn = 'auto', -- diagnostics
  -- Cell folding (content only; markers stay visible), all open by default
  foldmethod = 'expr',
  foldexpr = "v:lua.require'ipynb.folding'.foldexpr()",
  foldtext = "v:lua.require'ipynb.folding'.foldtext()",
  foldlevel = 99,
  foldenable = true,
}

local function win_option(win, name)
  return vim.api.nvim_get_option_value(name, { win = win })
end

---Put back the options a window had before it showed the notebook
---@param win number
function M.reset_window(win)
  local saved = vim.w[win].ipynb_saved_options
  vim.w[win].ipynb_saved_options = nil
  if type(saved) ~= 'table' then
    return
  end
  for name, value in pairs(saved) do
    pcall(vim.api.nvim_set_option_value, name, value, { win = win })
  end
end

---Window options for a window showing the notebook. Neovim copies a window's
---options to any new buffer opened in it, so the previous values are saved
---and restored when a non-notebook buffer takes over the window.
---@param win number
function M.setup_window(win)
  if vim.w[win].ipynb_saved_options == nil then
    local saved = {}
    for name in pairs(WINDOW_OPTIONS) do
      saved[name] = win_option(win, name)
    end
    vim.w[win].ipynb_saved_options = saved
  end
  for name, value in pairs(WINDOW_OPTIONS) do
    vim.api.nvim_set_option_value(name, value, { scope = 'local', win = win })
  end

  if not M._window_reset_installed then
    M._window_reset_installed = true
    vim.api.nvim_create_autocmd('BufWinEnter', {
      group = vim.api.nvim_create_augroup('IpynbWindowReset', { clear = true }),
      callback = function(args)
        local w = vim.api.nvim_get_current_win()
        if vim.w[w].ipynb_saved_options ~= nil and not vim.b[args.buf].notebook_facade then
          M.reset_window(w)
        end
      end,
    })
  end
end

---Create and configure the facade buffer
---@param state NotebookState
---@param buf number|nil Existing buffer to use, or nil to create new
---@return number buf
function M.create(state, buf)
  -- Use provided buffer or create new one
  buf = buf or vim.api.nvim_create_buf(true, false)
  state.facade_buf = buf

  -- Keep original .ipynb path for buffer name (set by :edit command)
  -- This ensures root detection, statusline, and other plugins work correctly
  state.facade_path = state.source_path

  -- Convert cells to jupytext format
  local io_mod = require('ipynb.io')
  local lines = io_mod.cells_to_jupytext(state.cells)

  -- Ensure buffer is modifiable before populating (might be reused)
  vim.bo[buf].modifiable = true

  -- Populate buffer with undo history cleared
  -- Setting undolevels=-1 before the change prevents it from being undoable
  local old_undolevels = vim.bo[buf].undolevels
  vim.bo[buf].undolevels = -1
  set_facade_lines(buf, 0, -1, lines)
  vim.bo[buf].undolevels = old_undolevels
  vim.bo[buf].modified = false

  -- Configure buffer options
  -- NOTE: filetype is NOT python - we don't want LSP to attach to facade
  -- LSP attaches to shadow buffer instead
  vim.bo[buf].filetype = 'ipynb' -- Custom filetype, no LSP
  vim.bo[buf].modifiable = false -- User can't directly edit
  -- Don't set readonly - it causes warnings on :w even with BufWriteCmd handler
  -- modifiable=false is sufficient to prevent edits
  vim.bo[buf].buftype = '' -- Normal buffer (not scratch)
  vim.bo[buf].swapfile = false

  -- Store state reference in buffer variable
  vim.b[buf].notebook_facade = true

  -- Set language for injection directive (read from notebook metadata)
  -- The custom directive #inject-notebook-language! reads this to determine code cell language
  local lang = 'python' -- default
  if state.metadata and state.metadata.language_info and state.metadata.language_info.name then
    lang = state.metadata.language_info.name
  end
  vim.b[buf].ipynb_language = lang

  -- Start treesitter highlighting for the notebook grammar
  -- This enables syntax highlighting via our custom parser and injection queries
  M.start_treesitter(buf)

  -- Create shadow buffer for LSP (also installs global LSP proxy)
  local lsp_mod = require('ipynb.lsp')
  lsp_mod.create_shadow(state)

  -- Setup window options when buffer is displayed
  vim.api.nvim_create_autocmd('BufWinEnter', {
    buffer = buf,
    callback = function()
      M.setup_window(vim.api.nvim_get_current_win())
      require('ipynb.folding').apply_hidden_sources(state)
    end,
  })

  -- Cleanup orphaned nb:// preview buffers when returning to facade
  -- (e.g., after picker closes without selection)
  -- Uses WinEnter because BufWinEnter only fires for new windows, not when
  -- focus returns to an existing window after a floating picker closes
  vim.api.nvim_create_autocmd('WinEnter', {
    buffer = buf,
    callback = function()
      lsp_mod.cleanup_preview_buffers(state)
    end,
  })

  -- Setup cleanup autocmd
  vim.api.nvim_create_autocmd('BufUnload', {
    buffer = buf,
    callback = function()
      require('ipynb.state').remove(buf)
    end,
  })

  return buf
end

---Refresh the entire facade buffer from state
---@param state NotebookState
function M.refresh(state)
  local buf = state.facade_buf
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  local io_mod = require('ipynb.io')
  local lines = io_mod.cells_to_jupytext(state.cells)

  vim.bo[buf].modifiable = true
  set_facade_lines(buf, 0, -1, lines)
  -- Only lock facade if not in edit buffer
  if not state.edit_state then
    vim.bo[buf].modifiable = false
  end

  -- Refresh shadow buffer for LSP
  local lsp_mod = require('ipynb.lsp')
  lsp_mod.refresh_shadow(state)

  -- Refresh markers and visuals
  local cells_mod = require('ipynb.cells')
  cells_mod.place_markers(state)

  local visuals = require('ipynb.visuals')
  visuals.render_all(state)

  -- Re-render outputs (includes recreating images)
  local output_mod = require('ipynb.output')
  output_mod.render_all(state)
end

---Insert a cell into the facade buffer and refresh
---@param state NotebookState
---@param after_idx number Insert after this cell (0 for beginning)
---@param cell_type "code" | "markdown" | "raw"
---@return number new_cell_idx
function M.insert_cell(state, after_idx, cell_type)
  local state_mod = require('ipynb.state')
  local new_idx = state_mod.insert_cell(state, after_idx, cell_type)
  M.refresh(state)
  return new_idx
end

---Delete a cell from the facade buffer and refresh
---@param state NotebookState
---@param cell_idx number
function M.delete_cell(state, cell_idx)
  local state_mod = require('ipynb.state')
  state_mod.delete_cell(state, cell_idx)
  M.refresh(state)
end

---Move a cell and refresh
---@param state NotebookState
---@param cell_idx number
---@param direction -1 | 1
---@return number|nil new_idx
function M.move_cell(state, cell_idx, direction)
  local state_mod = require('ipynb.state')
  local new_idx = state_mod.move_cell(state, cell_idx, direction)
  if new_idx then
    M.refresh(state)
  end
  return new_idx
end

---Set cell type explicitly and refresh
---@param state NotebookState
---@param cell_idx number
---@param cell_type "code" | "markdown" | "raw"
function M.set_cell_type(state, cell_idx, cell_type)
  local state_mod = require('ipynb.state')
  state_mod.set_cell_type(state, cell_idx, cell_type)
  M.refresh(state)
end

return M
