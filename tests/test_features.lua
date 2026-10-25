-- Notebook features shared with JupyterLab / Colab / Databricks
-- Run with: nvim --headless -u tests/minimal_init.lua -l tests/test_features.lua

local h = require('tests.helpers')
local io_mod = require('ipynb.io')
local kernel = require('ipynb.kernel')
local keymaps = require('ipynb.keymaps')
local output = require('ipynb.output')
local cellmeta = require('ipynb.cellmeta')

print('')
print(string.rep('=', 60))
print('Running notebook feature tests')
print(string.rep('=', 60))
print('')

---@param cells table[] { source=, type=, metadata=, outputs= }
local function notebook(cells)
  local nb_cells = {}
  for i, c in ipairs(cells) do
    local cell = {
      id = 'c' .. i,
      cell_type = c.type or 'code',
      source = io_mod.splitlines(c.source or ''), -- as nbformat writes it
      metadata = c.metadata or vim.empty_dict(),
    }
    if cell.cell_type == 'code' then
      cell.outputs = c.outputs or {}
      cell.execution_count = c.execution_count or vim.NIL
    end
    nb_cells[i] = cell
  end
  local path = vim.fn.tempname() .. '.ipynb'
  local f = assert(io.open(path, 'wb'))
  f:write(io_mod.encode_json({ nbformat = 4, nbformat_minor = 5, metadata = vim.empty_dict(), cells = nb_cells }) .. '\n')
  f:close()
  return path
end

local function goto_cell(state, idx)
  local start = require('ipynb.cells').get_cell_range(state, idx)
  vim.api.nvim_win_set_cursor(0, { start + 2, 0 })
end

local function fake_kernel(state)
  state.kernel = {
    job_id = 1, connected = true, kernel_name = 'python3', execution_state = 'idle',
    pending_cells = {}, cell_index_by_id = {}, callbacks = { inspect = {} },
  }
  local sent = {}
  local chansend = vim.fn.chansend
  vim.fn.chansend = function(_, data)
    table.insert(sent, vim.json.decode(data))
    return #data
  end
  return sent, function()
    vim.fn.chansend = chansend
    state.kernel = nil
  end
end

local function border_text(state, idx)
  local ns = vim.api.nvim_create_namespace('notebook_visuals')
  local start = require('ipynb.cells').get_cell_range(state, idx)
  local marks = vim.api.nvim_buf_get_extmarks(state.facade_buf, -1, { start, 0 }, { start, -1 }, { details = true })
  local text = {}
  for _, m in ipairs(marks) do
    for _, chunk in ipairs(m[4].virt_text or {}) do
      text[#text + 1] = chunk[1]
    end
  end
  return table.concat(text), ns
end

local function output_virt_lines(state, idx)
  local cell = state.cells[idx]
  local ns = vim.api.nvim_create_namespace('notebook_outputs')
  local mark = cell.output_extmark and vim.api.nvim_buf_get_extmark_by_id(state.facade_buf, ns, cell.output_extmark, { details = true })
  return mark and mark[3] and mark[3].virt_lines or {}
end

local function virt_text(line)
  local parts = {}
  for _, chunk in ipairs(line) do
    parts[#parts + 1] = chunk[1]
  end
  return table.concat(parts)
end

--------------------------------------------------------------------------------
-- Cell operations
--------------------------------------------------------------------------------

h.run_test('copy_and_paste_cell_keeps_metadata_and_outputs', function()
  local path = notebook({
    { source = 'x = 1', metadata = { tags = { 'keep' } }, execution_count = 4,
      outputs = { { output_type = 'stream', name = 'stdout', text = { 'hi\n' } } } },
    { source = 'y = 2' },
  })
  local state = h.open_notebook_path(path)
  goto_cell(state, 1)
  keymaps.copy_cell(state)
  h.assert_eq(#state.cells, 2, 'copy does not remove the cell')
  goto_cell(state, 2)
  keymaps.paste_cell(state, 'below')
  h.assert_eq(#state.cells, 3, 'pasted')
  local pasted = state.cells[3]
  h.assert_eq(pasted.source, 'x = 1', 'source')
  h.assert_eq(pasted.metadata.tags[1], 'keep', 'metadata copied')
  h.assert_eq(pasted.outputs[1].text[1], 'hi\n', 'outputs copied')
  h.assert_true(pasted.id ~= state.cells[1].id, 'new id')
  vim.fn.delete(path)
end)

h.run_test('merge_cell_below_joins_sources_and_clears_outputs', function()
  local path = notebook({
    { source = 'a = 1', execution_count = 1, outputs = { { output_type = 'stream', name = 'stdout', text = 'x' } } },
    { source = 'b = 2' },
    { source = 'c = 3' },
  })
  local state = h.open_notebook_path(path)
  goto_cell(state, 1)
  keymaps.merge_cell_below(state)
  h.assert_eq(#state.cells, 2, 'one cell fewer')
  h.assert_eq(state.cells[1].source, 'a = 1\nb = 2', 'joined')
  h.assert_eq(#state.cells[1].outputs, 0, 'outputs cleared')
  h.assert_eq(state.cells[2].source, 'c = 3', 'next cell intact')
  vim.cmd('write')
  local cells = io_mod.read_ipynb(path)
  h.assert_eq(#cells, 2, 'saved')
  vim.fn.delete(path)
end)

h.run_test('split_cell_at_cursor', function()
  local path = notebook({ { source = 'import os\nx = 1\ny = 2' }, { source = 'z = 3' } })
  local state = h.open_notebook_path(path)
  goto_cell(state, 1)
  require('ipynb.edit').open(state)
  vim.api.nvim_win_set_cursor(state.edit_state.win, { 2, 0 })
  require('ipynb.edit').split_cell(state)
  h.assert_eq(#state.cells, 3, 'one more cell')
  h.assert_eq(state.cells[1].source, 'import os', 'before cursor stays')
  h.assert_eq(state.cells[2].source, 'x = 1\ny = 2', 'rest moves to new cell')
  h.assert_eq(state.cells[3].source, 'z = 3', 'next cell intact')
  h.assert_true(state.edit_state ~= nil and state.edit_state.cell_idx == 2, 'editing the new cell')
  require('ipynb.edit').close(state)

  -- mid-line split
  goto_cell(state, 2)
  require('ipynb.edit').open(state)
  vim.api.nvim_win_set_cursor(state.edit_state.win, { 1, 3 })
  require('ipynb.edit').split_cell(state)
  h.assert_eq(state.cells[2].source, 'x =', 'text before column stays')
  h.assert_eq(state.cells[3].source, ' 1\ny = 2', 'text after column moves')
  require('ipynb.edit').close(state)
  vim.fn.delete(path)
end)

--------------------------------------------------------------------------------
-- Running
--------------------------------------------------------------------------------

h.run_test('run_all_above_runs_only_earlier_code_cells', function()
  local path = notebook({ { source = 'a' }, { type = 'markdown', source = '# t' }, { source = 'b' }, { source = 'c' } })
  local state = h.open_notebook_path(path)
  local sent, restore = fake_kernel(state)
  local ok, err = pcall(function()
    goto_cell(state, 4)
    kernel.execute_all_above(state)
    local codes = {}
    for _, m in ipairs(sent) do
      codes[#codes + 1] = m.code
    end
    h.assert_eq(table.concat(codes, ','), 'a,b', 'cells above, code only')
  end)
  restore()
  vim.fn.delete(path)
  assert(ok, err)
end)

h.run_test('restart_and_run_all_waits_for_restart', function()
  local path = notebook({ { source = 'a' }, { source = 'b' } })
  local state = h.open_notebook_path(path)
  local sent, restore = fake_kernel(state)
  local ok, err = pcall(function()
    kernel.restart_and_run_all(state)
    h.assert_eq(#sent, 1, 'only restart sent before the kernel is back')
    h.assert_eq(sent[1].action, 'restart', 'restart first')
    kernel._handle_message(state, { type = 'restarted' })
    vim.wait(500, function() return #sent >= 3 end, 10)
    h.assert_eq(sent[2].code .. sent[3].code, 'ab', 'then every cell in order')
  end)
  restore()
  vim.fn.delete(path)
  assert(ok, err)
end)

h.run_test('run_selection_sends_only_selected_code', function()
  local path = notebook({ { source = 'a = 1\nb = 2\nc = 3' } })
  local state = h.open_notebook_path(path)
  local sent, restore = fake_kernel(state)
  local ok, err = pcall(function()
    goto_cell(state, 1)
    require('ipynb.edit').open(state)
    vim.api.nvim_win_set_cursor(state.edit_state.win, { 2, 0 })
    vim.cmd('normal! Vj')
    require('ipynb.edit').execute_selection(state)
    h.assert_eq(sent[#sent].code, 'b = 2\nc = 3', 'selected lines only')
    h.assert_eq(sent[#sent].cell_id, state.cells[1].id, 'output goes to this cell')
    require('ipynb.edit').close(state)
  end)
  restore()
  vim.fn.delete(path)
  assert(ok, err)
end)

--------------------------------------------------------------------------------
-- Metadata other frontends use
--------------------------------------------------------------------------------

h.run_test('titles_from_databricks_and_colab', function()
  h.assert_eq(cellmeta.title({ source = '', metadata = { ['application/vnd.databricks.v1+cell'] = { title = 'Load data' } } }),
    'Load data', 'Databricks title')
  h.assert_eq(cellmeta.title({ source = '#@title Train model { display-mode: "form" }\nfit()', metadata = {} }),
    'Train model', 'Colab #@title')
  h.assert_eq(cellmeta.title({ source = 'x = 1', metadata = {} }), nil, 'no title')
end)

h.run_test('tags_and_title_show_on_cell_border_and_save', function()
  local path = notebook({ { source = '#@title Setup\nimport os', metadata = { tags = { 'parameters' } } } })
  local state = h.open_notebook_path(path)
  local text = border_text(state, 1)
  h.assert_true(text:find('Setup', 1, true) ~= nil, 'title on border: ' .. text)
  h.assert_true(text:find('#parameters', 1, true) ~= nil, 'tag on border: ' .. text)
  goto_cell(state, 1)
  vim.cmd('NotebookCellTags parameters slow')
  vim.cmd('write')
  local cells = io_mod.read_ipynb(path)
  h.assert_eq(table.concat(cells[1].metadata.tags, ','), 'parameters,slow', 'tags saved')
  -- Without arguments: prompt prefilled with current tags
  local input = vim.ui.input
  local prompted
  vim.ui.input = function(opts, cb)
    prompted = opts.default
    cb('only')
  end
  goto_cell(state, 1)
  vim.cmd('NotebookCellTags')
  vim.ui.input = input
  h.assert_eq(prompted, 'parameters slow', 'prompt shows current tags')
  h.assert_eq(table.concat(state.cells[1].metadata.tags, ','), 'only', 'tags replaced')
  vim.fn.delete(path)
end)

h.run_test('hidden_code_from_jupyterlab_is_folded_and_toggle_round_trips', function()
  local path = notebook({
    { source = 'a = 1\nb = 2\nc = 3', metadata = { jupyter = { source_hidden = true } } },
    { source = 'd = 4\ne = 5' },
  })
  local original = table.concat(vim.fn.readfile(path, 'b'), '\n')
  local state = h.open_notebook_path(path)
  local cells_mod = require('ipynb.cells')
  local s1 = cells_mod.get_content_range(state, 1)
  local s2 = cells_mod.get_content_range(state, 2)
  h.assert_true(vim.fn.foldclosed(s1 + 1) ~= -1, 'hidden cell folded on open')
  h.assert_eq(vim.fn.foldclosed(s2 + 1), -1, 'other cells open')
  goto_cell(state, 1)
  require('ipynb.folding').toggle_source_hidden(state)
  h.assert_eq(vim.fn.foldclosed(s1 + 1), -1, 'shown again')
  h.assert_false(cellmeta.is_source_hidden(state.cells[1]), 'metadata cleared')
  require('ipynb.folding').toggle_source_hidden(state)
  vim.cmd('write')
  local saved = table.concat(vim.fn.readfile(path, 'b'), '\n')
  h.assert_eq(saved, original, 'hide -> show -> hide saves the same file')
  vim.fn.delete(path)
end)

h.run_test('folding_works_without_user_fold_settings', function()
  local path = notebook({ { source = 'a = 1\nb = 2\nc = 3' } })
  local state = h.open_notebook_path(path)
  h.assert_eq(vim.wo.foldmethod, 'expr', 'notebook window gets fold settings')
  goto_cell(state, 1)
  require('ipynb.folding').toggle_cell_fold(state)
  local s = require('ipynb.cells').get_content_range(state, 1)
  h.assert_true(vim.fn.foldclosed(s + 1) ~= -1, 'cell folded')
  vim.cmd('enew')
  h.assert_eq(vim.wo.foldmethod, 'manual', 'fold settings do not leak to other buffers')
  vim.fn.delete(path)
end)

h.run_test('hidden_outputs_render_as_one_line_and_save_like_jupyterlab', function()
  local path = notebook({ { source = 'print(1)', execution_count = 1,
    outputs = { { output_type = 'stream', name = 'stdout', text = 'a\nb\n' } } } })
  local state = h.open_notebook_path(path)
  goto_cell(state, 1)
  output.toggle_outputs_hidden(state)
  local lines = output_virt_lines(state, 1)
  h.assert_eq(#lines, 2, 'separator + one summary line')
  h.assert_true(virt_text(lines[2]):find('hidden', 1, true) ~= nil, 'summary')
  vim.cmd('write')
  local cells = io_mod.read_ipynb(path)
  h.assert_eq(cells[1].metadata.jupyter.outputs_hidden, true, 'jupyter.outputs_hidden')
  h.assert_eq(cells[1].metadata.collapsed, true, 'legacy collapsed')
  h.assert_eq(#cells[1].outputs, 1, 'outputs still saved')
  vim.fn.delete(path)
end)

--------------------------------------------------------------------------------
-- Output display
--------------------------------------------------------------------------------

h.run_test('long_output_is_truncated_with_a_note', function()
  local text = {}
  for i = 1, 300 do
    text[i] = 'line ' .. i .. '\n'
  end
  local path = notebook({ { source = 'x', execution_count = 1, outputs = { { output_type = 'stream', name = 'stdout', text = text } } } })
  local state = h.open_notebook_path(path)
  local max = require('ipynb.config').get().output.max_lines
  local lines = output_virt_lines(state, 1)
  h.assert_eq(#lines, max + 2, 'separator + max lines + note')
  h.assert_true(virt_text(lines[#lines]):find(tostring(300 - max) .. ' more lines', 1, true) ~= nil, 'note: ' .. virt_text(lines[#lines]))
  h.assert_eq(#output.build_output_text(state.cells[1]), 300, 'full text still available')
  vim.fn.delete(path)
end)

h.run_test('ansi_colours_become_highlights', function()
  local ansi = require('ipynb.ansi')
  local chunks = ansi.chunks('\27[0;31mValueError\27[0m: boom \27[1;32mok\27[0m', 'IpynbOutput')
  h.assert_eq(#chunks, 3, 'three chunks')
  h.assert_eq(chunks[1][1], 'ValueError', 'text without escapes')
  h.assert_true(chunks[1][2]:match('^IpynbAnsi') ~= nil, 'coloured group')
  h.assert_eq(chunks[2][2], 'IpynbOutput', 'reset to base')
  h.assert_eq(ansi.strip('\27[31mred\27[0m \27]8;;http://x\7link\27]8;;\7'), 'red link', 'strip incl. hyperlinks')
  local fg = vim.api.nvim_get_hl(0, { name = chunks[1][2] }).fg
  h.assert_true(fg ~= nil, 'group has a colour')
end)

h.run_test('rich_outputs_fall_back_to_readable_text', function()
  local text = output.bundle_text({ ['text/plain'] = '<IPython.core.display.HTML object>', ['text/html'] = '<b>Hello</b> &amp; bye' })
  h.assert_eq(text, 'Hello & bye', 'HTML object shows its content, not the placeholder')
  text = output.bundle_text({ ['text/plain'] = '<IPython.core.display.Markdown object>', ['text/markdown'] = '**bold**' })
  h.assert_eq(text, '**bold**', 'markdown')
  local tbl = output.html_to_text('<table><tr><th>a</th><th>long</th></tr><tr><td>1</td><td>2</td></tr></table>')
  h.assert_eq(tbl, 'a  long\n1  2', 'table aligned')
  h.assert_eq(output.bundle_text({ ['text/plain'] = '42', ['text/html'] = '<b>42</b>' }), '42', 'plain preferred when real')
end)

h.run_test('open_output_externally_writes_viewable_files', function()
  local png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==\n'
  local path = notebook({ { source = 'x', execution_count = 1, outputs = {
    { output_type = 'display_data', metadata = vim.empty_dict(), data = { ['image/png'] = png, ['text/plain'] = '<Figure>' } },
  } }, { source = 'y', execution_count = 2, outputs = {
    { output_type = 'display_data', metadata = vim.empty_dict(), data = { ['application/vnd.plotly.v1+json'] = { data = {}, layout = vim.empty_dict() } } },
  } } })
  local state = h.open_notebook_path(path)
  local opened
  local ui_open = vim.ui.open
  vim.ui.open = function(p) opened = p return {}, nil end
  local ok, err = pcall(function()
    goto_cell(state, 1)
    output.open_external(state)
    h.assert_true(opened and opened:match('%.png$') ~= nil, 'png opened: ' .. tostring(opened))
    local f = assert(io.open(opened, 'rb'))
    local bytes = f:read('*a')
    f:close()
    h.assert_eq(bytes:sub(2, 4), 'PNG', 'decoded PNG bytes')
    goto_cell(state, 2)
    output.open_external(state)
    h.assert_true(opened:match('%.html$') ~= nil, 'plotly as html page')
    local page = table.concat(vim.fn.readfile(opened), '\n')
    h.assert_true(page:find('Plotly.newPlot', 1, true) ~= nil, 'plotly page')
    local lines = output_virt_lines(state, 1)
    h.assert_true(virt_text(lines[#lines]):find('image/png', 1, true) ~= nil, 'inline hint for the image')
  end)
  vim.ui.open = ui_open
  vim.fn.delete(path)
  assert(ok, err)
end)

h.run_test('new_commands_exist', function()
  local path = notebook({ { source = 'x' } })
  h.open_notebook_path(path)
  local cmds = vim.api.nvim_buf_get_commands(0, {})
  for _, name in ipairs({ 'NotebookExecuteAllAbove', 'NotebookRestartAndRunAll', 'NotebookCopyCell', 'NotebookMergeCellBelow',
    'NotebookSplitCell', 'NotebookToggleSourceHidden', 'NotebookToggleOutputsHidden', 'NotebookOpenOutput',
    'NotebookCellTags', 'NotebookExport' }) do
    h.assert_true(cmds[name] ~= nil, 'missing :' .. name)
  end
  vim.fn.delete(path)
end)

h.run_test('export_with_nbconvert', function()
  local python = vim.env.IPYNB_TEST_PYTHON
  if not python or vim.system({ python, '-c', 'import nbconvert' }):wait().code ~= 0 then
    print('  SKIP: no IPYNB_TEST_PYTHON with nbconvert')
    return
  end
  local config = require('ipynb.config').get()
  config.kernel.python_path = python
  local path = notebook({ { type = 'markdown', source = '# Hello export' }, { source = 'x = 1' } })
  local state = h.open_notebook_path(path)
  kernel.export(state, 'html')
  local html = path:gsub('%.ipynb$', '.html')
  local done = vim.wait(60000, function() return vim.fn.filereadable(html) == 1 end, 100)
  config.kernel.python_path = nil
  h.assert_true(done, 'html written')
  h.assert_true(table.concat(vim.fn.readfile(html), '\n'):find('Hello export', 1, true) ~= nil, 'content exported')
  vim.fn.delete(html)
  vim.fn.delete(path)
end)

local success = h.summary()
if success then
  vim.cmd('qa!')
else
  vim.cmd('cquit 1')
end
