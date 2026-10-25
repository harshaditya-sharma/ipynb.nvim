-- ipynb/folding.lua - Cell folding support

local M = {}

-- Cache for fold levels per buffer (module-level for foldexpr performance)
-- Cleaned up via M.clear_cache() called from state.remove()
local fold_cache = {}

---Execute a fold command at a specific line, preserving cursor position
---@param line number 1-indexed line number
---@param cmd string Normal mode command to execute
---@return boolean ok
---@return string|nil err
local function exec_fold_at(line, cmd)
  local saved_cursor = vim.api.nvim_win_get_cursor(0)
  vim.api.nvim_win_set_cursor(0, { line, 0 })
  local ok, err = pcall(function()
    vim.cmd('normal! ' .. cmd)
  end)
  vim.api.nvim_win_set_cursor(0, saved_cursor)
  return ok, err
end

---Custom foldtext showing line count
---@return string
local devicons_ok = pcall(require, 'nvim-web-devicons')
function M.foldtext()
  local line_count = vim.v.foldend - vim.v.foldstart + 1
  local first_line = vim.fn.getline(vim.v.foldstart)
  first_line = vim.trim(first_line)
  if #first_line > 60 then
    first_line = first_line:sub(1, 60) .. '...'
  end
  local icon = devicons_ok and '' or '⬍'
  return string.format('%s  (%s %d lines)', first_line, icon, line_count)
end

---Custom foldexpr using treesitter to find cell_content nodes
---@return string
function M.foldexpr()
  local bufnr = vim.api.nvim_get_current_buf()
  local lnum = vim.v.lnum - 1 -- Convert to 0-indexed

  -- Try to get cached fold info
  local cache = fold_cache[bufnr]
  if not cache or cache.changedtick ~= vim.b[bufnr].changedtick then
    cache = M.compute_folds(bufnr)
    fold_cache[bufnr] = cache
  end

  return cache.levels[lnum] or '0'
end

---Compute fold levels for all lines in buffer
---@param bufnr number
---@return table
function M.compute_folds(bufnr)
  local result = {
    changedtick = vim.b[bufnr].changedtick,
    levels = {},
  }

  -- Get treesitter parser
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, 'ipynb')
  if not ok or not parser then
    return result
  end

  local tree = parser:parse()[1]
  if not tree then
    return result
  end

  local root = tree:root()

  -- Query for cell_content nodes
  local query_ok, query = pcall(vim.treesitter.query.parse, 'ipynb', '(cell_content) @content')
  if not query_ok or not query then
    return result
  end

  local hide_output = require('ipynb.config').get().folding.hide_output

  -- Find all cell_content nodes and mark their lines for folding
  for _, node in query:iter_captures(root, bufnr, 0, -1) do
    local start_row, _, end_row, _ = node:range()
    -- Note: end_row from treesitter is exclusive, so actual last line is end_row - 1
    local last_row = end_row - 1

    -- If hide_output is enabled, extend fold to include end marker line
    -- This hides virt_lines (output) attached to the end marker
    if hide_output then
      last_row = last_row + 1
    end

    -- Only create fold if content spans multiple lines (at least 2)
    if last_row > start_row then
      -- First line of content starts the fold
      result.levels[start_row] = '>1'
      -- Middle lines are inside fold
      for row = start_row + 1, last_row - 1 do
        result.levels[row] = '1'
      end
      -- Last line ends the fold
      result.levels[last_row] = '<1'
    end
  end

  return result
end

---Clear fold cache for a buffer (called from state.remove)
---@param bufnr number
function M.clear_cache(bufnr)
  fold_cache[bufnr] = nil
end

---Fold or unfold all cells
---@param state NotebookState
---@param action "close" | "open"
function M.fold_all_cells(state, action)
  local cells_mod = require('ipynb.cells')
  local cmd = action == 'close' and 'zc' or 'zo'

  for cell_idx = 1, #state.cells do
    local content_start, content_end = cells_mod.get_content_range(state, cell_idx)
    -- Only fold cells with multiple lines of content
    if content_start and content_end and content_end > content_start then
      local content_start_1 = content_start + 1
      local fold_level = vim.fn.foldlevel(content_start_1)
      if fold_level > 0 then
        exec_fold_at(content_start_1, cmd)
      end
    end
  end
end

---Find a window showing the notebook (current window preferred)
---@param state NotebookState
---@return number|nil
local function facade_window(state)
  if vim.api.nvim_win_get_buf(0) == state.facade_buf then
    return vim.api.nvim_get_current_win()
  end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == state.facade_buf then
      return win
    end
  end
end

---Open or close the content fold of one cell
---@param state NotebookState
---@param cell_idx number
---@param close boolean
---@return boolean folded_or_opened
function M.set_cell_folded(state, cell_idx, close)
  local cells_mod = require('ipynb.cells')
  local win = facade_window(state)
  local content_start, content_end = cells_mod.get_content_range(state, cell_idx)
  if not win or not content_start or content_end <= content_start then
    return false
  end
  return vim.api.nvim_win_call(win, function()
    vim.cmd('silent! normal! zx') -- make sure folds reflect the current text
    local line = content_start + 1
    if vim.fn.foldlevel(line) == 0 then
      return false
    end
    local closed = vim.fn.foldclosed(line) ~= -1
    if close ~= closed then
      exec_fold_at(line, close and 'zc' or 'zo')
    end
    return true
  end)
end

---Close the folds of cells whose code is hidden (JupyterLab source_hidden,
---Colab forms). Called when the notebook is shown in a window.
---@param state NotebookState
function M.apply_hidden_sources(state)
  local cellmeta = require('ipynb.cellmeta')
  for i, cell in ipairs(state.cells) do
    if cellmeta.is_source_hidden(cell) then
      M.set_cell_folded(state, i, true)
    end
  end
end

---Toggle "hide code" for the cell at cursor; saved like JupyterLab does
---@param state NotebookState
function M.toggle_source_hidden(state)
  local cells_mod = require('ipynb.cells')
  local cellmeta = require('ipynb.cellmeta')
  local idx, cell = cells_mod.get_cell_at_line(state, vim.api.nvim_win_get_cursor(0)[1] - 1)
  if not cell then
    return
  end
  local hide = not cellmeta.is_source_hidden(cell)
  cellmeta.set_source_hidden(cell, hide)
  if not M.set_cell_folded(state, idx, hide) and hide then
    vim.notify('Code hidden in the saved notebook (single-line cells cannot be folded here)', vim.log.levels.INFO)
  end
  vim.bo[state.facade_buf].modified = true
end

---Toggle fold for the cell at cursor (not language constructs)
---Works regardless of whether cursor is on content or border lines
---@param state NotebookState
function M.toggle_cell_fold(state)
  local cells_mod = require('ipynb.cells')
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1] - 1
  local cell_idx = cells_mod.get_cell_at_line(state, cursor_line)

  if not cell_idx then
    vim.notify('No cell at cursor', vim.log.levels.WARN)
    return
  end

  -- Get content range (excluding markers)
  local content_start, content_end = cells_mod.get_content_range(state, cell_idx)

  -- Check if cell has content to fold (need at least 2 lines for a fold)
  if not content_start or not content_end or content_end <= content_start then
    vim.notify('Cell has no content to fold (single line or empty)', vim.log.levels.INFO)
    return
  end

  -- Use 1-indexed line numbers for vim functions
  local content_start_1 = content_start + 1

  -- Check if fold exists at content start
  local fold_start = vim.fn.foldclosed(content_start_1)

  if fold_start == -1 then
    -- Fold is open or doesn't exist - close it
    local fold_level = vim.fn.foldlevel(content_start_1)
    if fold_level == 0 then
      vim.notify('No fold defined for this cell (try :set foldmethod?)', vim.log.levels.WARN)
      return
    end

    local ok, err = exec_fold_at(content_start_1, 'zc')
    if not ok then
      vim.notify('Could not close fold: ' .. tostring(err), vim.log.levels.WARN)
    end
  else
    -- Fold is closed - open it
    exec_fold_at(content_start_1, 'zo')
  end
end

return M
