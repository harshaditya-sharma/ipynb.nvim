-- Split-window cell editor (float.layout = "split") and edit-window cleanup
-- Run with: nvim --headless -u tests/minimal_init.lua -l tests/test_split_editor.lua

local h = require('tests.helpers')
local config = require('ipynb.config').get()
local edit = require('ipynb.edit')
local io_mod = require('ipynb.io')

print('')
print(string.rep('=', 60))
print('Running split editor tests')
print(string.rep('=', 60))
print('')

local function notebook(sources)
  local cells = {}
  for i, src in ipairs(sources) do
    cells[i] = { id = 'c' .. i, cell_type = 'code', source = src, metadata = vim.empty_dict(), outputs = {}, execution_count = vim.NIL }
  end
  local path = vim.fn.tempname() .. '.ipynb'
  vim.fn.writefile({ vim.json.encode({ nbformat = 4, nbformat_minor = 5, metadata = vim.empty_dict(), cells = cells }) }, path)
  return path
end

local function goto_cell(state, idx)
  local start = require('ipynb.cells').get_cell_range(state, idx)
  vim.api.nvim_win_set_cursor(state.edit_state and state.edit_state.parent_win or 0, { start + 2, 0 })
end

local function is_float(win)
  return vim.api.nvim_win_get_config(win).relative ~= ''
end

local function with_layout(layout, fn)
  local saved = config.float.layout
  config.float.layout = layout
  local ok, err = pcall(fn)
  config.float.layout = saved
  assert(ok, err)
end

h.run_test('split_layout_opens_a_real_window_next_to_the_notebook', function()
  with_layout('split', function()
    local path = notebook({ 'a = 1', 'b = 2' })
    local state = h.open_notebook_path(path)
    local notebook_win = vim.api.nvim_get_current_win()
    goto_cell(state, 1)
    edit.open(state)
    local win = state.edit_state.win
    h.assert_false(is_float(win), 'editor should be a split, not a float')
    h.assert_true(win ~= notebook_win, 'separate window')
    h.assert_eq(vim.api.nvim_win_get_buf(notebook_win), state.facade_buf, 'notebook stays visible')
    h.assert_eq(vim.api.nvim_get_current_win(), win, 'focus in editor')
    edit.close(state)
    vim.fn.delete(path)
  end)
end)

h.run_test('split_edits_sync_and_save', function()
  with_layout('split', function()
    local path = notebook({ 'a = 1', 'b = 2' })
    local state = h.open_notebook_path(path)
    goto_cell(state, 1)
    edit.open(state)
    vim.api.nvim_buf_set_lines(state.edit_state.buf, 0, -1, false, { 'a = 10', 'c = 3' })
    vim.api.nvim_exec_autocmds('TextChanged', { buffer = state.edit_state.buf })
    edit.close(state)
    vim.cmd('write')
    local cells = io_mod.read_ipynb(path)
    h.assert_eq(cells[1].source, 'a = 10\nc = 3', 'edited cell saved')
    h.assert_eq(cells[2].source, 'b = 2', 'other cell intact')
    vim.fn.delete(path)
  end)
end)

h.run_test('notebook_side_is_read_only_while_editing_in_split', function()
  with_layout('split', function()
    local path = notebook({ 'a = 1', 'b = 2' })
    local state = h.open_notebook_path(path)
    local notebook_win = vim.api.nvim_get_current_win()
    goto_cell(state, 1)
    edit.open(state)
    local editor_win = state.edit_state.win
    vim.api.nvim_set_current_win(notebook_win)
    h.assert_false(vim.bo[state.facade_buf].modifiable, 'facade locked when focused')
    h.assert_true(state.edit_state ~= nil, 'edit session survives looking at the notebook')
    vim.api.nvim_set_current_win(editor_win)
    h.assert_true(vim.bo[state.facade_buf].modifiable, 'facade writable for sync while editing')
    vim.api.nvim_buf_set_lines(state.edit_state.buf, 0, -1, false, { 'a = 2' })
    vim.api.nvim_exec_autocmds('TextChanged', { buffer = state.edit_state.buf })
    h.assert_eq(vim.api.nvim_buf_get_lines(state.facade_buf, 1, 2, false)[1], 'a = 2', 'sync still works')
    edit.close(state)
    vim.fn.delete(path)
  end)
end)

h.run_test('opening_another_cell_reuses_the_split_window', function()
  with_layout('split', function()
    local path = notebook({ 'a = 1', 'b = 2' })
    local state = h.open_notebook_path(path)
    local notebook_win = vim.api.nvim_get_current_win()
    goto_cell(state, 1)
    edit.open(state)
    local editor_win = state.edit_state.win
    local wins_before = #vim.api.nvim_tabpage_list_wins(0)
    vim.api.nvim_set_current_win(notebook_win)
    goto_cell(state, 2)
    edit.open(state)
    h.assert_eq(state.edit_state.win, editor_win, 'same split window')
    h.assert_eq(#vim.api.nvim_tabpage_list_wins(0), wins_before, 'no extra window')
    h.assert_eq(table.concat(vim.api.nvim_buf_get_lines(state.edit_state.buf, 0, -1, false), '\n'), 'b = 2', 'shows cell 2')
    edit.close(state)
    vim.fn.delete(path)
  end)
end)

h.run_test('next_cell_from_editor_reuses_the_split_window', function()
  with_layout('split', function()
    local path = notebook({ 'a = 1', 'b = 2' })
    local state = h.open_notebook_path(path)
    goto_cell(state, 1)
    edit.open(state)
    local editor_win = state.edit_state.win
    edit.edit_next_cell(state)
    h.assert_true(vim.wait(1000, function()
      return state.edit_state ~= nil and state.edit_state.cell_idx == 2
    end, 10), 'moved to cell 2')
    h.assert_eq(state.edit_state.win, editor_win, 'same split window')
    edit.close(state)
    vim.fn.delete(path)
  end)
end)

h.run_test('closing_split_returns_to_notebook_and_locks_it', function()
  with_layout('split', function()
    local path = notebook({ 'a = 1' })
    local state = h.open_notebook_path(path)
    local notebook_win = vim.api.nvim_get_current_win()
    goto_cell(state, 1)
    edit.open(state)
    local editor_win = state.edit_state.win
    edit.close(state)
    h.assert_false(vim.api.nvim_win_is_valid(editor_win), 'split closed')
    h.assert_eq(vim.api.nvim_get_current_win(), notebook_win, 'focus back on notebook')
    h.assert_false(vim.bo[state.facade_buf].modifiable, 'facade locked again')
    vim.fn.delete(path)
  end)
end)

for _, layout in ipairs({ 'overlay', 'split' }) do
  h.run_test('quitting_editor_window_with_q_cleans_up_' .. layout, function()
    with_layout(layout, function()
      local path = notebook({ 'a = 1', 'b = 2' })
      local state = h.open_notebook_path(path)
      goto_cell(state, 1)
      edit.open(state)
      vim.api.nvim_buf_set_lines(state.edit_state.buf, 0, -1, false, { 'a = 5' })
      vim.api.nvim_exec_autocmds('TextChanged', { buffer = state.edit_state.buf })
      vim.cmd('quit')
      vim.wait(200, function() return state.edit_state == nil end, 10)
      h.assert_eq(state.edit_state, nil, 'edit session ended')
      h.assert_false(vim.bo[state.facade_buf].modifiable, 'facade locked after :q')
      h.assert_eq(state.cells[1].source, 'a = 5', 'edit kept')
      vim.fn.delete(path)
    end)
  end)
end

h.run_test('overlay_layout_is_still_a_float', function()
  with_layout('overlay', function()
    local path = notebook({ 'a = 1' })
    local state = h.open_notebook_path(path)
    goto_cell(state, 1)
    edit.open(state)
    h.assert_true(is_float(state.edit_state.win), 'overlay uses a float')
    edit.close(state)
    vim.fn.delete(path)
  end)
end)

local success = h.summary()
if success then
  vim.cmd('qa!')
else
  vim.cmd('cquit 1')
end
