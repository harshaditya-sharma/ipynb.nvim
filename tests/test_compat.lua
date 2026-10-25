-- Jupyter compatibility and Windows regression tests
-- Run with: nvim --headless -u tests/minimal_init.lua -l tests/test_compat.lua

local h = require('tests.helpers')

print('')
print(string.rep('=', 60))
print('Running Jupyter compatibility tests')
print(string.rep('=', 60))
print('')

local io_mod = require('ipynb.io')

local function read_raw(path)
  local f = assert(io.open(path, 'rb'))
  local s = f:read('*a')
  f:close()
  return s
end

local function write_raw(path, s)
  local f = assert(io.open(path, 'wb'))
  f:write(s)
  f:close()
end

local function write_json(path, tbl)
  write_raw(path, vim.json.encode(tbl))
end

local function roundtrip(path)
  local cells, metadata, _, fmt = io_mod.read_ipynb(path)
  local out = vim.fn.tempname() .. '.ipynb'
  io_mod.write_ipynb(out, cells, metadata, fmt)
  return out
end

--------------------------------------------------------------------------------
-- File format
--------------------------------------------------------------------------------

h.run_test('untouched_jupyter_notebook_saves_byte_identical', function()
  local src = h.fixture_path('jupyter_written.ipynb')
  local out = roundtrip(src)
  local a, b = read_raw(src), read_raw(out)
  vim.fn.delete(out)
  if a ~= b then
    local hunks = vim.diff(a, b, { ctxlen = 0 })
    error('saved bytes differ from the Jupyter-written file:\n' .. hunks:sub(1, 1500))
  end
end)

h.run_test('crlf_line_endings_are_preserved', function()
  local src = vim.fn.tempname() .. '.ipynb'
  write_raw(src, (read_raw(h.fixture_path('jupyter_written.ipynb')):gsub('\n', '\r\n')))
  local out = roundtrip(src)
  local a, b = read_raw(src), read_raw(out)
  vim.fn.delete(src)
  vim.fn.delete(out)
  h.assert_true(a == b, 'CRLF notebook should round-trip byte-identical')
end)

h.run_test('markdown_attachments_are_preserved', function()
  local out = roundtrip(h.fixture_path('jupyter_written.ipynb'))
  local nb = vim.json.decode(read_raw(out))
  vim.fn.delete(out)
  h.assert_true(nb.cells[1].attachments ~= nil, 'attachments should survive a save')
  h.assert_eq(nb.cells[1].attachments['p.png']['image/png'], 'iVBORw0KGgo=\n', 'attachment data')
end)

h.run_test('unexecuted_code_cell_writes_null_execution_count', function()
  local out = vim.fn.tempname() .. '.ipynb'
  io_mod.write_ipynb(out, {
    { id = 'abc', type = 'code', source = '', metadata = {}, outputs = {} },
  }, io_mod.default_metadata())
  local raw = read_raw(out)
  vim.fn.delete(out)
  h.assert_true(raw:find('"execution_count": null', 1, true) ~= nil,
    'nbformat requires execution_count on code cells; got:\n' .. raw)
end)

h.run_test('null_execution_count_reads_as_nil', function()
  local p = vim.fn.tempname() .. '.ipynb'
  write_json(p, { nbformat = 4, nbformat_minor = 5, metadata = vim.empty_dict(), cells = {
    { id = 'a', cell_type = 'code', source = 'x', metadata = vim.empty_dict(), outputs = {}, execution_count = vim.NIL },
  } })
  local cells = io_mod.read_ipynb(p)
  vim.fn.delete(p)
  h.assert_eq(cells[1].execution_count, nil, 'JSON null should become nil, not vim.NIL')
end)

h.run_test('stream_and_text_outputs_are_split_like_nbformat', function()
  local out = vim.fn.tempname() .. '.ipynb'
  io_mod.write_ipynb(out, {
    { id = 'abc', type = 'code', source = 'x', metadata = {}, execution_count = 1, outputs = {
      { output_type = 'stream', name = 'stdout', text = 'a\nb\n' },
      { output_type = 'execute_result', execution_count = 1, metadata = {},
        data = { ['text/plain'] = 'l1\nl2', ['application/json'] = { k = 'v' }, ['image/png'] = 'AAA\n' } },
    } },
  }, io_mod.default_metadata())
  local nb = vim.json.decode(read_raw(out))
  vim.fn.delete(out)
  local outputs = nb.cells[1].outputs
  h.assert_eq(vim.inspect(outputs[1].text), vim.inspect({ 'a\n', 'b\n' }), 'stream text')
  h.assert_eq(vim.inspect(outputs[2].data['text/plain']), vim.inspect({ 'l1\n', 'l2' }), 'text/plain')
  h.assert_eq(outputs[2].data['image/png'], 'AAA\n', 'base64 images stay strings')
  h.assert_eq(outputs[2].data['application/json'].k, 'v', 'json mime untouched')
end)

h.run_test('source_split_matches_python_splitlines', function()
  -- Python's str.splitlines(True) also breaks on \r, \r\n, \v, \f, \x1c-\x1e, \x85, \u2028, \u2029
  local cases = {
    { 'a\r\nb', { 'a\r\n', 'b' } },
    { 'a\rb', { 'a\r', 'b' } },
    { 'a\fb', { 'a\f', 'b' } },
    { 'a\u{2028}b', { 'a\u{2028}', 'b' } },
    { 'a\u{85}b', { 'a\u{85}', 'b' } },
    { 'é\n', { 'é\n' } },
  }
  for _, c in ipairs(cases) do
    h.assert_eq(vim.inspect(io_mod.splitlines(c[1])), vim.inspect(c[2]), 'splitlines ' .. vim.inspect(c[1]))
  end
end)

h.run_test('invalid_cell_ids_are_repaired_on_read', function()
  local p = vim.fn.tempname() .. '.ipynb'
  write_json(p, { nbformat = 4, nbformat_minor = 5, metadata = vim.empty_dict(), cells = {
    { id = '../../evil', cell_type = 'markdown', source = 'a', metadata = vim.empty_dict() },
    { id = 'ok_id-1', cell_type = 'markdown', source = 'b', metadata = vim.empty_dict() },
    { id = string.rep('x', 65), cell_type = 'markdown', source = 'c', metadata = vim.empty_dict() },
  } })
  local cells = io_mod.read_ipynb(p)
  vim.fn.delete(p)
  h.assert_true(cells[1].id:match('^[%w_-]+$') ~= nil, 'path-like id must be replaced: ' .. cells[1].id)
  h.assert_eq(cells[2].id, 'ok_id-1', 'valid id kept')
  h.assert_true(#cells[3].id <= 64, 'over-long id replaced')
end)

h.run_test('generated_cell_ids_match_jupyter_format', function()
  local id = require('ipynb.state').generate_cell_id({})
  h.assert_true(id:match('^%x%x%x%x%x%x%x%x$') ~= nil, 'expected 8 hex chars like Jupyter, got ' .. id)
end)

--------------------------------------------------------------------------------
-- Facade marker collisions
--------------------------------------------------------------------------------

local MARKER_SOURCE = table.concat({
  'print(1)',
  '# <</ipynb_nvim>>',
  '# <<ipynb_nvim:markdown>>',
  '\\# <</ipynb_nvim>>',
  'print(2)',
}, '\n')

h.run_test('marker_text_in_source_survives_facade_parse', function()
  local lines = io_mod.cells_to_jupytext({ { type = 'code', source = MARKER_SOURCE } })
  local parsed = io_mod.jupytext_to_cells(lines)
  h.assert_eq(#parsed, 1, 'still one cell')
  h.assert_eq(parsed[1].source, MARKER_SOURCE, 'source intact')
end)

h.run_test('marker_text_in_source_survives_open_and_save', function()
  local p = vim.fn.tempname() .. '.ipynb'
  write_json(p, { nbformat = 4, nbformat_minor = 5, metadata = vim.empty_dict(), cells = {
    { id = 'c1', cell_type = 'code', source = MARKER_SOURCE, metadata = vim.empty_dict(), outputs = {}, execution_count = vim.NIL },
    { id = 'c2', cell_type = 'code', source = 'y = 2', metadata = vim.empty_dict(), outputs = {}, execution_count = vim.NIL },
  } })
  local state = h.open_notebook_path(p)
  h.assert_eq(#state.cells, 2, 'two cells after open')
  vim.cmd('write')
  local cells = io_mod.read_ipynb(p)
  h.assert_eq(#cells, 2, 'two cells after save')
  h.assert_eq(cells[1].source, MARKER_SOURCE, 'first cell intact after save')
  h.assert_eq(cells[2].source, 'y = 2', 'second cell intact after save')
  vim.fn.delete(p)
end)

h.run_test('marker_text_typed_in_edit_buffer_is_saved_intact', function()
  local p = vim.fn.tempname() .. '.ipynb'
  write_json(p, { nbformat = 4, nbformat_minor = 5, metadata = vim.empty_dict(), cells = {
    { id = 'c1', cell_type = 'code', source = 'x = 1', metadata = vim.empty_dict(), outputs = {}, execution_count = vim.NIL },
    { id = 'c2', cell_type = 'code', source = 'y = 2', metadata = vim.empty_dict(), outputs = {}, execution_count = vim.NIL },
  } })
  local state = h.open_notebook_path(p)
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  require('ipynb.edit').open(state)
  local edit_buf = state.edit_state.buf
  vim.api.nvim_buf_set_lines(edit_buf, 0, -1, false, vim.split(MARKER_SOURCE, '\n'))
  vim.api.nvim_exec_autocmds('TextChanged', { buffer = edit_buf })
  require('ipynb.edit').close(state)
  vim.cmd('write')
  local cells = io_mod.read_ipynb(p)
  h.assert_eq(#cells, 2, 'two cells after save')
  h.assert_eq(cells[1].source, MARKER_SOURCE, 'edited cell intact')
  h.assert_eq(cells[2].source, 'y = 2', 'next cell intact')

  -- Re-opening the cell shows the real text, not the escaped facade text
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  require('ipynb.edit').open(state)
  local shown = vim.api.nvim_buf_get_lines(state.edit_state.buf, 0, -1, false)
  require('ipynb.edit').close(state)
  h.assert_eq(table.concat(shown, '\n'), MARKER_SOURCE, 'edit buffer shows unescaped source')
  vim.fn.delete(p)
end)

h.run_test('notebook_opens_before_parser_is_installed', function()
  -- First run: the parser is still compiling, so treesitter.start fails
  local real_start = vim.treesitter.start
  local calls = 0
  vim.treesitter.start = function(...)
    calls = calls + 1
    if calls == 1 then
      error('Parser could not be created for buffer and language "ipynb"')
    end
    return real_start(...)
  end
  local ok, state = pcall(h.open_notebook, 'simple.ipynb')
  local retried = ok and vim.wait(3000, function() return calls >= 2 end, 50)
  vim.treesitter.start = real_start
  h.assert_true(ok, 'notebook should open without the parser: ' .. tostring(state))
  h.assert_true(#state.cells > 0, 'cells loaded')
  h.assert_true(retried, 'highlighting should start once the parser is available')
end)

h.run_test('saved_images_with_line_breaks_decode', function()
  local decode = require('ipynb.images')._base64_decode
  h.assert_eq(decode('QUJD\n'), 'ABC', 'trailing newline (how Jupyter saves PNGs)')
  h.assert_eq(decode('QUJD\nREVG\n'), 'ABCDEF', 'wrapped base64')
  h.assert_eq(decode('QUJD\r\n'), 'ABC', 'CRLF')
end)

--------------------------------------------------------------------------------
-- IPython syntax vs Python language servers
--------------------------------------------------------------------------------

h.run_test('ipython_syntax_is_masked_for_lsp', function()
  local magics = require('ipynb.magics')
  local src = {
    '%matplotlib inline',
    '!pip install numpy',
    'files = !ls',
    'x = 1',
    'os.path?',
    '    %time f()',
    'a == !b',
  }
  local masked = magics.mask(src)
  h.assert_eq(#masked, #src, 'same line count')
  h.assert_true(masked[1]:match('^pass') ~= nil, 'line magic')
  h.assert_true(masked[2]:match('^pass') ~= nil, 'shell command')
  h.assert_true(masked[3]:match('^files = None') ~= nil, 'shell assignment: ' .. masked[3])
  h.assert_eq(masked[4], 'x = 1', 'plain python untouched')
  h.assert_true(masked[5]:match('^pass') ~= nil, 'help')
  h.assert_true(masked[6]:match('^    pass') ~= nil, 'indentation kept')
  h.assert_eq(magics.restore(masked, src)[3], 'files = !ls', 'restore')

  local bash = magics.mask({ '%%bash', 'echo hi', 'ls -la' })
  h.assert_eq(bash[2] .. bash[3], '', 'non-python cell magic body hidden')
  local timed = magics.mask({ '%%time', 'x = compute()' })
  h.assert_eq(timed[2], 'x = compute()', '%%time body is still python')
end)

h.run_test('shadow_buffer_masks_magics_and_keeps_line_mapping', function()
  local p = vim.fn.tempname() .. '.ipynb'
  write_json(p, { nbformat = 4, nbformat_minor = 5, metadata = { language_info = { name = 'python' } }, cells = {
    { id = 'c1', cell_type = 'code', source = '%time x = 1\n!echo hi\ny = 2', metadata = vim.empty_dict(), outputs = {}, execution_count = vim.NIL },
  } })
  local state = h.open_notebook_path(p)
  local shadow = vim.api.nvim_buf_get_lines(state.shadow_buf, 0, -1, false)
  local facade = vim.api.nvim_buf_get_lines(state.facade_buf, 0, -1, false)
  vim.fn.delete(p)
  h.assert_true(#shadow == #facade or #shadow == #facade - 1, 'line mapping kept')
  h.assert_true(shadow[2]:match('^pass') ~= nil, 'magic masked in shadow: ' .. shadow[2])
  h.assert_true(shadow[3]:match('^pass') ~= nil, 'shell masked in shadow')
  h.assert_eq(shadow[4], 'y = 2', 'code untouched')
  h.assert_eq(facade[2], '%time x = 1', 'facade shows the real line')
end)

h.run_test('formatting_keeps_magics_intact', function()
  local format = require('ipynb.lsp.format')
  local magics = require('ipynb.magics')
  local original = { '%time   f()', 'x=1', '!ls' }
  -- What a formatter does with the masked text: rewrite the whole range
  local masked = magics.mask(original)
  local formatted = { masked[1], 'x = 1', masked[3] }
  local lines = vim.deepcopy(masked)
  format.apply_edits_to_lines(lines, { {
    range = { start = { line = 0, character = 0 }, ['end'] = { line = 3, character = 0 } },
    newText = table.concat(formatted, '\n') .. '\n',
  } })
  local restored = magics.restore(lines, original)
  h.assert_eq(restored[1], '%time   f()', 'magic restored')
  h.assert_eq(restored[2], 'x = 1', 'code formatted')
  h.assert_eq(restored[3], '!ls', 'shell restored')
end)

h.run_test('real_ruff_format_cell_keeps_magics', function()
  local p = vim.fn.tempname() .. '.ipynb'
  write_json(p, { nbformat = 4, nbformat_minor = 5, metadata = { language_info = { name = 'python' } }, cells = {
    { id = 'c1', cell_type = 'code', source = '%matplotlib inline\nx=[1,2 ,3]\n!echo hi', metadata = vim.empty_dict(), outputs = {}, execution_count = vim.NIL },
  } })
  local state = h.open_notebook_path(p)
  local has_formatter = vim.wait(15000, function()
    for _, c in ipairs(vim.lsp.get_clients({ bufnr = state.shadow_buf })) do
      if c:supports_method('textDocument/rangeFormatting') then
        return true
      end
    end
    return false
  end, 100)
  if not has_formatter then
    print('  SKIP: no range formatter (ruff) attached')
    vim.fn.delete(p)
    return
  end
  local done = false
  require('ipynb.lsp').format_cell(state, 1, function() done = true end)
  vim.wait(10000, function() return done end, 50)
  vim.fn.delete(p)
  h.assert_eq(state.cells[1].source, '%matplotlib inline\nx = [1, 2, 3]\n!echo hi', 'formatted with magics intact')
end)

--------------------------------------------------------------------------------
-- Null execution counts in UI code
--------------------------------------------------------------------------------

h.run_test('notebook_info_and_picker_handle_null_execution_count', function()
  local p = vim.fn.tempname() .. '.ipynb'
  write_json(p, { nbformat = 4, nbformat_minor = 5, metadata = vim.empty_dict(), cells = {
    { id = 'c1', cell_type = 'code', source = 'x', metadata = vim.empty_dict(), outputs = {}, execution_count = vim.NIL },
  } })
  h.open_notebook_path(p)
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  vim.cmd('NotebookInfo')
  local select = vim.ui.select
  local items
  vim.ui.select = function(list) items = list end
  local ok, err = pcall(require('ipynb.picker').jump_to_cell)
  vim.ui.select = select
  vim.fn.delete(p)
  h.assert_true(ok, 'picker should not error: ' .. tostring(err))
  h.assert_true(items and #items == 1, 'picker lists the cell')
end)

h.run_test('all_documented_commands_exist', function()
  local readme = table.concat(vim.fn.readfile(vim.fn.fnamemodify(h.fixture_path(''), ':h:h:h') .. '/README.md'), '\n')
  h.open_notebook('mixed.ipynb')
  local buffer_cmds = vim.api.nvim_buf_get_commands(0, {})
  local global_cmds = vim.api.nvim_get_commands({})
  local count = 0
  for name in readme:gmatch('| `:(Notebook%a+)') do
    count = count + 1
    h.assert_true(buffer_cmds[name] ~= nil or global_cmds[name] ~= nil, 'missing command :' .. name)
  end
  h.assert_true(count >= 35, 'README command table parsed (' .. count .. ')')
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  vim.cmd('NotebookInfo')
  vim.cmd('NotebookKernelStatus')
end)

--------------------------------------------------------------------------------
-- Kernel / Python discovery
--------------------------------------------------------------------------------

h.run_test('kernel_name_maps_to_language', function()
  local map = require('ipynb.kernel')._kernel_to_language
  h.assert_eq(map('python3'), 'python', 'python3')
  h.assert_eq(map('ir'), 'r', 'IRkernel')
  h.assert_eq(map('julia-1.10'), 'julia', 'julia')
  h.assert_eq(map('rust'), 'rust', 'evcxr rust kernel must not map to R')
  h.assert_eq(map('ruby'), 'ruby', 'ruby must not map to R')
end)

h.run_test('finds_project_venv_python', function()
  local root = vim.fn.tempname()
  local bin = vim.fn.has('win32') == 1 and (root .. '/.venv/Scripts') or (root .. '/.venv/bin')
  local exe = vim.fn.has('win32') == 1 and (bin .. '/python.exe') or (bin .. '/python')
  vim.fn.mkdir(bin, 'p')
  vim.uv.fs_copyfile(vim.v.progpath, exe)
  vim.uv.fs_chmod(exe, 493)
  vim.fn.mkdir(root .. '/sub', 'p')
  local found, source = require('ipynb.kernel').get_python_info(root .. '/sub/nb.ipynb')
  vim.fn.delete(root, 'rf')
  h.assert_eq(source, 'venv', 'should find the project venv, got ' .. tostring(found))
end)

h.run_test('never_picks_windows_store_python_stub', function()
  if vim.fn.has('win32') == 0 then
    return
  end
  local found = require('ipynb.kernel').get_python_info(vim.fn.tempname() .. '/nb.ipynb')
  h.assert_true(found == nil or not found:lower():find('windowsapps', 1, true),
    'WindowsApps python3.exe is a Store stub, got ' .. tostring(found))
end)

--------------------------------------------------------------------------------
-- LSP URIs from servers that percent-encode or lowercase drive letters
--------------------------------------------------------------------------------

h.run_test('lsp_result_uris_match_shadow_regardless_of_encoding', function()
  local uri_mod = require('ipynb.lsp.uri')
  local shadow = vim.fn.has('win32') == 1 and 'C:\\Temp\\nvim\\x_shadow.py' or '/tmp/nvim/x_shadow.py'
  local facade = vim.fn.has('win32') == 1 and 'C:\\Temp\\nb.ipynb' or '/tmp/nb.ipynb'
  local state = { shadow_path = shadow, facade_path = facade }
  local variant = vim.uri_from_fname(shadow)
  if vim.fn.has('win32') == 1 then
    variant = variant:gsub('^file:///C:', 'file:///c%%3A')
  end
  local res = uri_mod.rewrite_result_uris({ { uri = variant, range = {} } }, state, 'textDocument/definition')
  h.assert_eq(vim.fs.normalize(vim.uri_to_fname(res[1].uri)):lower(), vim.fs.normalize(facade):lower(),
    'uri rewritten to facade')
end)

--------------------------------------------------------------------------------
local success = h.summary()
if success then
  vim.cmd('qa!')
else
  vim.cmd('cquit 1')
end
