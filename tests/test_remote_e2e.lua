-- End-to-end: notebook -> :NotebookServerConnect -> kernel on a real Jupyter server
-- Needs IPYNB_TEST_PYTHON with jupyter_server, jupyter_client and ipykernel.
-- Run with: nvim --headless -u tests/minimal_init.lua -l tests/test_remote_e2e.lua

local h = require('tests.helpers')
local kernel = require('ipynb.kernel')

print('')
print(string.rep('=', 60))
print('Running Jupyter server end-to-end tests')
print(string.rep('=', 60))
print('')

local python = vim.env.IPYNB_TEST_PYTHON or ''
if python == '' or vim.system({ python, '-c', 'import jupyter_server, ipykernel' }):wait().code ~= 0 then
  print('SKIP: set IPYNB_TEST_PYTHON to a Python with jupyter_server and ipykernel')
  vim.cmd('qa!')
  return
end

local token = 'e2e-token'
local port = 18000 + (vim.uv.os_getpid() % 1000)
local root = vim.fn.tempname()
vim.fn.mkdir(root, 'p')
local server = vim.system({ python, '-m', 'jupyter', 'server', '--no-browser', '--ip=127.0.0.1', '--port=' .. port,
  '--port-retries=0', '--IdentityProvider.token=' .. token, '--ServerApp.root_dir=' .. root })
local base = 'http://127.0.0.1:' .. port
local up = vim.wait(60000, function()
  local r = vim.system({ python, '-c', 'import urllib.request,sys; urllib.request.urlopen(sys.argv[1], timeout=2)', base .. '/api/status?token=' .. token }):wait()
  return r.code == 0
end, 500)

local path = vim.fn.tempname() .. '.ipynb'
vim.fn.writefile({ vim.json.encode({ nbformat = 4, nbformat_minor = 5, metadata = vim.empty_dict(), cells = {
  { id = 'a', cell_type = 'code', source = "import os\nprint('server pid', os.getpid())", metadata = vim.empty_dict(), outputs = {}, execution_count = vim.NIL },
} }) }, path)
local state = h.open_notebook_path(path)

h.run_step('server_started', function()
  h.assert_true(up, 'jupyter server reachable')
end)

h.run_step('connect_picks_new_kernel_from_prompt', function()
  require('ipynb.config').get().kernel.python_path = python
  local select = vim.ui.select
  local offered
  vim.ui.select = function(items, _, cb)
    offered = items
    cb(items[1])
  end
  vim.cmd('NotebookServerConnect ' .. base .. '/lab?token=' .. token)
  local ok = vim.wait(60000, function() return kernel.is_connected(state) end, 100)
  vim.ui.select = select
  h.assert_true(offered and offered[1].label:find('Start a new', 1, true) ~= nil, 'offered to start a kernel')
  h.assert_true(ok, 'connected to server kernel')
end)

h.run_step('run_cell_on_server_kernel', function()
  kernel.execute(state, 1)
  local cell = state.cells[1]
  h.assert_true(vim.wait(30000, function() return cell.execution_state == 'idle' and cell.execution_count ~= nil end, 50), 'ran')
  local text = cell.outputs[1] and cell.outputs[1].text or ''
  h.assert_true(text:find('server pid', 1, true) ~= nil, 'output from server kernel: ' .. text)
end)

kernel.shutdown(state)
vim.wait(2000)
server:kill(15)
vim.fn.delete(path)
vim.fn.delete(root, 'rf')
require('ipynb.config').get().kernel.python_path = nil

local success = h.summary()
if success then
  vim.cmd('qa!')
else
  vim.cmd('cquit 1')
end
