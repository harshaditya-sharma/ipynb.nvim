-- Real-UI check that cells reach an iron.nvim REPL and run. Headless Neovim on
-- Windows can't feed input to terminal jobs (no console for conpty), so this
-- runs in a normal Neovim window:
--
--   $env:IRON_RESULT = "$env:TEMP/iron.txt"; $env:IRON_DIR = "<path>/iron.nvim"
--   $env:IPYNB_TEST_PYTHON = "<python>"
--   nvim -u tests/minimal_init.lua -c "luafile tests/ui/iron_repl.lua"
--
-- It writes PASS/FAIL to $IRON_RESULT (and a step log to $IRON_RESULT.log).
local out = vim.env.IRON_RESULT
local log = {}
local function step(msg)
  table.insert(log, msg)
  vim.fn.writefile(log, out .. '.log')
end
local function finish(msg)
  step(msg)
  vim.fn.writefile({ msg }, out)
  vim.cmd('qa!')
end
vim.o.cmdheight = 20
vim.o.more = false
vim.notify = function(m) step('notify: ' .. tostring(m)) end
local ok, err = pcall(function()
  vim.opt.rtp:append(vim.fn.glob(vim.env.IRON_DIR))
  local iron = require('iron.core')
  local py = vim.env.IPYNB_TEST_PYTHON
  iron.setup({ config = { repl_definition = { python = { command = { py, '-i', '-q', '-u' } } }, repl_open_cmd = 'belowright 10 split' } })
  local marker = vim.fn.tempname() .. '.txt'
  local path = vim.fn.tempname() .. '.ipynb'
  local src = 'with open(r"' .. marker .. '", "w") as f:\n    f.write(str(6 * 7))'
  vim.fn.writefile({ vim.json.encode({ nbformat = 4, nbformat_minor = 5, metadata = { language_info = { name = 'python' } },
    cells = { { id = 'a', cell_type = 'code', source = src, metadata = vim.empty_dict(), outputs = {}, execution_count = vim.NIL } } }) }, path)
  step('setup done')
  vim.cmd('edit ' .. vim.fn.fnameescape(path))
  step('opened')
  local state = require('ipynb.state').get()
  step('execute -> ' .. tostring(require('ipynb.kernel').execute(state, 1)))
  local ran = vim.wait(20000, function()
    return vim.fn.filereadable(marker) == 1 and vim.fn.readfile(marker)[1] == '42'
  end, 100)
  finish(ran and 'PASS' or 'FAIL: cell did not run in the REPL')
end)
if not ok then
  finish('ERROR: ' .. tostring(err))
end
