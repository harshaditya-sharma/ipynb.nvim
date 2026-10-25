-- End-to-end: notebook buffer -> kernel bridge -> real Jupyter kernel -> saved file
-- Needs a Python with jupyter_client + ipykernel: set IPYNB_TEST_PYTHON to it.
-- Run with: nvim --headless -u tests/minimal_init.lua -l tests/test_kernel_e2e.lua

local h = require('tests.helpers')

print('')
print(string.rep('=', 60))
print('Running kernel end-to-end tests')
print(string.rep('=', 60))
print('')

local python = vim.env.IPYNB_TEST_PYTHON
if not python or python == '' then
  local probe = vim.fn.has('win32') == 1 and 'python' or 'python3'
  python = vim.fn.exepath(probe)
end
local check = python ~= '' and vim.system({ python, '-c', 'import jupyter_client, ipykernel' }):wait() or { code = 1 }
if check.code ~= 0 then
  print('SKIP: no Python with jupyter_client and ipykernel (set IPYNB_TEST_PYTHON)')
  vim.cmd('qa!')
  return
end

local kernel = require('ipynb.kernel')

local function write_notebook(cells)
  local nb_cells = {}
  for i, src in ipairs(cells) do
    nb_cells[i] = { id = 'cell' .. i, cell_type = 'code', source = src, metadata = vim.empty_dict(), outputs = {}, execution_count = vim.NIL }
  end
  local path = vim.fn.tempname() .. '.ipynb'
  vim.fn.writefile({ vim.json.encode({ nbformat = 4, nbformat_minor = 5, metadata = vim.empty_dict(), cells = nb_cells }) }, path)
  return path
end

local function wait_idle(cell, timeout)
  return vim.wait(timeout or 30000, function()
    return cell.execution_state == 'idle' and cell.execution_count ~= nil
  end, 50)
end

local function stream_text(cell)
  local parts = {}
  for _, o in ipairs(cell.outputs or {}) do
    if o.output_type == 'stream' then
      parts[#parts + 1] = o.text
    end
  end
  return table.concat(parts)
end

local path = write_notebook({
  "print('hello from kernel')",
  "from IPython.display import clear_output, display\nprint('old')\nclear_output(wait=True)\nprint('new')\nh = display('a', display_id=True)\nh.update('b')",
  "raise ValueError('boom')",
  "print('never runs')",
  "import time\nfor _ in range(200): time.sleep(0.1)",
})
local state = h.open_notebook_path(path)

h.run_step('kernel_starts_with_configured_python', function()
  kernel.connect(state, { python_path = python })
  h.assert_true(vim.wait(90000, function() return kernel.is_connected(state) end, 100), 'kernel connected')
end)

h.run_step('run_cell_shows_output_count_and_time', function()
  kernel.execute(state, 1)
  local cell = state.cells[1]
  h.assert_true(wait_idle(cell), 'cell finished')
  h.assert_eq(stream_text(cell), 'hello from kernel\n', 'stream output')
  h.assert_true(cell.execution_count >= 1, 'execution count set')
  h.assert_true(type(cell.execution_time) == 'number', 'run time recorded')
end)

h.run_step('clear_output_and_display_update_end_to_end', function()
  kernel.execute(state, 2)
  local cell = state.cells[2]
  h.assert_true(wait_idle(cell), 'cell finished')
  h.assert_eq(stream_text(cell), 'new\n', 'cleared output replaced by new one')
  local display = cell.outputs[#cell.outputs]
  h.assert_eq(display.data['text/plain'], "'b'", 'display handle update applied')
end)

h.run_step('run_all_below_stops_after_error', function()
  kernel.execute_all_below(state, 3)
  local err_cell, next_cell = state.cells[3], state.cells[4]
  h.assert_true(vim.wait(30000, function()
    return err_cell.execution_state == 'idle' and next_cell.execution_state == 'idle'
  end, 50), 'both cells settled')
  h.assert_eq(err_cell.outputs[1].ename, 'ValueError', 'error shown')
  h.assert_eq(stream_text(next_cell), '', 'queued cell after error did not run')
  -- the long cell was queued too; it must have been aborted, not left running
  h.assert_true(vim.wait(10000, function() return state.cells[5].execution_state == 'idle' end, 50), 'later cells aborted')
end)

h.run_step('interrupt_stops_long_cell', function()
  kernel.execute(state, 5)
  local cell = state.cells[5]
  h.assert_true(vim.wait(20000, function() return cell.execution_state == 'busy' end, 50), 'cell started')
  kernel.interrupt(state)
  h.assert_true(vim.wait(15000, function() return cell.execution_state == 'idle' end, 50), 'cell stopped')
  h.assert_eq(cell.outputs[#cell.outputs].ename, 'KeyboardInterrupt', 'interrupted')
end)

h.run_step('saved_file_is_valid_nbformat_with_outputs', function()
  vim.cmd('write')
  local r = vim.system({ python, '-c', [[
import sys, nbformat
nb = nbformat.read(sys.argv[1], as_version=4)
nbformat.validate(nb)
print(nb.cells[0].outputs[0].text, end='')
]], path }, { text = true }):wait()
  h.assert_eq(r.code, 0, 'nbformat.validate failed: ' .. (r.stderr or ''))
  h.assert_eq(r.stdout, 'hello from kernel\n', 'output saved')
end)

kernel.shutdown(state)
vim.fn.delete(path)

local success = h.summary()
if success then
  vim.cmd('qa!')
else
  vim.cmd('cquit 1')
end
