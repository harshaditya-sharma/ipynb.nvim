-- Kernel message handling (Lua side of the bridge protocol), no Jupyter needed
-- Run with: nvim --headless -u tests/minimal_init.lua -l tests/test_kernel_messages.lua

local h = require('tests.helpers')
local kernel = require('ipynb.kernel')

print('')
print(string.rep('=', 60))
print('Running kernel message tests')
print(string.rep('=', 60))
print('')

local handle = kernel._handle_message

---Open a fixture with a fake connected kernel whose commands are recorded
local function setup()
  local state = h.open_notebook('three_cells.ipynb')
  state.kernel = {
    job_id = 1,
    connected = true,
    kernel_name = 'python3',
    execution_state = 'idle',
    pending_cells = {},
    cell_index_by_id = {},
    callbacks = { inspect = {} },
  }
  local sent = {}
  local chansend = vim.fn.chansend
  vim.fn.chansend = function(_, data)
    table.insert(sent, vim.json.decode(data))
    return #data
  end
  local function restore()
    vim.fn.chansend = chansend
    state.kernel = nil
  end
  local code = {}
  for i, cell in ipairs(state.cells) do
    if cell.type == 'code' then
      table.insert(code, i)
    end
  end
  return state, sent, restore, code
end

local function settle()
  vim.wait(50)
end

h.run_test('execute_marks_cell_queued_then_busy_then_idle_with_time', function()
  local state, sent, restore, code = setup()
  local ok, err = pcall(function()
    local cell = state.cells[code[1]]
    kernel.execute(state, code[1])
    h.assert_eq(cell.execution_state, 'queued', 'queued until the kernel starts it')
    h.assert_eq(sent[1].action, 'execute', 'execute command sent')
    handle(state, { type = 'execute_input', cell_id = cell.id, execution_count = 7, date = '2026-10-25T10:00:01.250000+00:00' })
    h.assert_eq(cell.execution_state, 'busy', 'busy once started')
    h.assert_eq(cell.execution_count, 7, 'execution count')
    handle(state, { type = 'execute_reply', cell_id = cell.id, status = 'ok', date = '2026-10-25T10:00:03.750000+00:00' })
    h.assert_eq(cell.execution_state, 'idle', 'idle after reply')
    h.assert_true(math.abs(cell.execution_time - 2.5) < 1e-6, 'duration 2.5s, got ' .. tostring(cell.execution_time))
    h.assert_eq(state.kernel.pending_cells[cell.id], nil, 'no longer pending')
    settle()
  end)
  restore()
  assert(ok, err)
end)

h.run_test('aborted_cells_return_to_idle_without_time', function()
  local state, _, restore, code = setup()
  local ok, err = pcall(function()
    local cell = state.cells[code[2]]
    kernel.execute(state, code[2])
    handle(state, { type = 'execute_reply', cell_id = cell.id, status = 'aborted', date = '2026-10-25T10:00:00+00:00' })
    h.assert_eq(cell.execution_state, 'idle', 'aborted cell not left spinning')
    h.assert_eq(cell.execution_time, nil, 'no time for a cell that never ran')
    settle()
  end)
  restore()
  assert(ok, err)
end)

h.run_test('clear_output_clears_now_or_on_next_output', function()
  local state, _, restore, code = setup()
  local ok, err = pcall(function()
    local cell = state.cells[code[1]]
    local function out(text)
      handle(state, { type = 'output', cell_id = cell.id, output = { output_type = 'stream', name = 'stdout', text = text } })
    end
    out('old\n')
    h.assert_eq(#cell.outputs, 1, 'one output')
    handle(state, { type = 'clear_output', cell_id = cell.id, wait = true })
    h.assert_eq(#cell.outputs, 1, 'wait=True keeps output until the next one')
    out('new\n')
    h.assert_eq(#cell.outputs, 1, 'replaced, not appended')
    h.assert_eq(cell.outputs[1].text, 'new\n', 'new text')
    handle(state, { type = 'clear_output', cell_id = cell.id, wait = false })
    settle()
    h.assert_eq(#cell.outputs, 0, 'wait=False clears immediately')
  end)
  restore()
  assert(ok, err)
end)

h.run_test('update_display_replaces_matching_outputs_in_any_cell', function()
  local state, _, restore, code = setup()
  local ok, err = pcall(function()
    local a, b = state.cells[code[1]], state.cells[code[2]]
    local shown = { output_type = 'display_data', data = { ['text/plain'] = "'a'" }, metadata = {}, transient = { display_id = 'd1' } }
    handle(state, { type = 'output', cell_id = a.id, output = vim.deepcopy(shown) })
    handle(state, { type = 'output', cell_id = b.id, output = vim.deepcopy(shown) })
    handle(state, { type = 'update_display', display_id = 'd1',
      output = { output_type = 'display_data', data = { ['text/plain'] = "'b'" }, metadata = {} } })
    h.assert_eq(a.outputs[1].data['text/plain'], "'b'", 'first cell updated')
    h.assert_eq(b.outputs[1].data['text/plain'], "'b'", 'second cell updated')
    h.assert_eq(a.outputs[1].transient.display_id, 'd1', 'display id kept for later updates')
    settle()
  end)
  restore()
  assert(ok, err)
end)

h.run_test('display_ids_are_not_saved_to_the_file', function()
  local io_mod = require('ipynb.io')
  local out = vim.fn.tempname() .. '.ipynb'
  io_mod.write_ipynb(out, { { id = 'x', type = 'code', source = '', metadata = {}, execution_count = 1, outputs = {
    { output_type = 'display_data', data = { ['text/plain'] = 'a' }, metadata = {}, transient = { display_id = 'd' } },
  } } }, io_mod.default_metadata())
  local raw = table.concat(vim.fn.readfile(out), '\n')
  vim.fn.delete(out)
  h.assert_false(raw:find('transient', 1, true) ~= nil, 'transient must be stripped like nbformat does')
end)

h.run_test('output_for_deleted_cell_is_dropped', function()
  local state, _, restore = setup()
  local ok, err = pcall(function()
    handle(state, { type = 'output', cell_id = 'gone', output = { output_type = 'stream', name = 'stdout', text = 'x' } })
    for _, cell in ipairs(state.cells) do
      h.assert_true(not cell.outputs or #cell.outputs == 0 or cell.outputs[1].text ~= 'x', 'not routed elsewhere')
    end
  end)
  restore()
  assert(ok, err)
end)

h.run_test('record_timing_writes_jupyterlab_metadata', function()
  local config = require('ipynb.config').get()
  local state, _, restore, code = setup()
  config.kernel.record_timing = true
  local ok, err = pcall(function()
    local cell = state.cells[code[1]]
    kernel.execute(state, code[1])
    handle(state, { type = 'execute_input', cell_id = cell.id, execution_count = 1, date = '2026-10-25T10:00:00+00:00' })
    handle(state, { type = 'execute_reply', cell_id = cell.id, status = 'ok', date = '2026-10-25T10:00:01+00:00' })
    h.assert_eq(cell.metadata.execution['iopub.execute_input'], '2026-10-25T10:00:00+00:00', 'start time')
    h.assert_eq(cell.metadata.execution['shell.execute_reply'], '2026-10-25T10:00:01+00:00', 'end time')
    settle()
  end)
  config.kernel.record_timing = false
  restore()
  assert(ok, err)
end)

h.run_test('duration_formatting', function()
  local f = require('ipynb.visuals').format_duration
  h.assert_eq(f(0.0849), '85ms', 'ms')
  h.assert_eq(f(1.24), '1.2s', 's')
  h.assert_eq(f(123), '2m 03s', 'm')
  h.assert_eq(f(3725), '1h 02m', 'h')
end)

local success = h.summary()
if success then
  vim.cmd('qa!')
else
  vim.cmd('cquit 1')
end
