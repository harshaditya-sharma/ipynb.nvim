-- iron.nvim REPL fallback for languages / setups without a Jupyter kernel
-- Run with: nvim --headless -u tests/minimal_init.lua -l tests/test_repl.lua

local h = require('tests.helpers')
local kernel = require('ipynb.kernel')
local config = require('ipynb.config').get()

print('')
print(string.rep('=', 60))
print('Running REPL fallback tests')
print(string.rep('=', 60))
print('')

local function notebook(lang, source)
  local path = vim.fn.tempname() .. '.ipynb'
  vim.fn.writefile({ vim.json.encode({ nbformat = 4, nbformat_minor = 5,
    metadata = { language_info = { name = lang }, kernelspec = { name = lang, language = lang, display_name = lang } },
    cells = { { id = 'a', cell_type = 'code', source = source, metadata = vim.empty_dict(), outputs = {}, execution_count = vim.NIL } },
  }) }, path)
  return path
end

local function with_fake_iron(fn)
  local sent = {}
  package.loaded['iron.core'] = { send = function(ft, lines) table.insert(sent, { ft = ft, lines = lines }) end }
  local ok, err = pcall(fn, sent)
  package.loaded['iron.core'] = nil
  assert(ok, err)
end

h.run_test('no_kernel_runs_cell_in_iron_repl', function()
  with_fake_iron(function(sent)
    local path = notebook('python', 'for i in range(3):\n    print(i)')
    local state = h.open_notebook_path(path)
    h.assert_true(kernel.execute(state, 1), 'sent')
    h.assert_eq(sent[1].ft, 'python', 'python REPL')
    h.assert_eq(table.concat(sent[1].lines, '|'), 'for i in range(3):|    print(i)|', 'lines + blank to close the block')
    vim.fn.delete(path)
  end)
end)

h.run_test('repl_uses_notebook_language', function()
  with_fake_iron(function(sent)
    local path = notebook('R', 'x <- 1')
    local state = h.open_notebook_path(path)
    vim.cmd('NotebookReplSend')
    h.assert_eq(sent[1].ft, 'r', 'R notebook goes to the r REPL')
    vim.fn.delete(path)
  end)
end)

h.run_test('fallback_can_be_disabled', function()
  with_fake_iron(function(sent)
    config.repl.fallback = false
    local path = notebook('python', 'x = 1')
    local state = h.open_notebook_path(path)
    local ok = kernel.execute(state, 1)
    config.repl.fallback = true
    h.assert_false(ok, 'not run')
    h.assert_eq(#sent, 0, 'nothing sent')
    vim.fn.delete(path)
  end)
end)

h.run_test('without_iron_execute_just_warns', function()
  package.loaded['iron.core'] = nil
  local path = notebook('python', 'x = 1')
  local state = h.open_notebook_path(path)
  h.assert_false(kernel.execute(state, 1), 'not run')
  vim.fn.delete(path)
end)

h.run_test('real_iron_python_repl_runs_the_cell', function()
  local python = vim.env.IPYNB_TEST_PYTHON or vim.fn.exepath(vim.fn.has('win32') == 1 and 'python' or 'python3')
  local iron_dir = vim.fn.stdpath('data') .. '/lazy/iron.nvim'
  if vim.fn.isdirectory(iron_dir) == 0 then
    local tests = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h')
    iron_dir = vim.fn.glob(tests .. '/.nvim-test/share/*/lazy/iron.nvim')
  end
  if vim.fn.has('win32') == 1 and #vim.api.nvim_list_uis() == 0 then
    print('  SKIP: headless Neovim on Windows cannot drive terminal jobs; see tests/ui/iron_repl.lua')
    return
  end
  if iron_dir == '' or vim.fn.isdirectory(iron_dir) == 0 or python == '' then
    print('  SKIP: iron.nvim not in the test sandbox (clone it to ' .. iron_dir .. ')')
    return
  end
  vim.opt.rtp:append(iron_dir)
  local iron = require('iron.core')
  iron.setup({
    config = {
      repl_definition = { python = { command = { python, '-i', '-q', '-u' } } },
      repl_open_cmd = 'belowright 10 split',
    },
  })
  -- Headless terminals on Windows don't capture output, so the cell proves it
  -- ran by writing a file (a multi-line block also checks the closing blank line)
  local marker = vim.fn.tempname() .. '.txt'
  local path = notebook('python', table.concat({
    'with open(r"' .. marker .. '", "w") as f:',
    '    f.write(str(6 * 7))',
  }, '\n'))
  local state = h.open_notebook_path(path)
  h.assert_true(kernel.execute(state, 1), 'sent to iron')
  local found = vim.wait(15000, function()
    return vim.fn.filereadable(marker) == 1 and vim.fn.readfile(marker)[1] == '42'
  end, 100)
  vim.fn.delete(marker)
  h.assert_true(found, 'the REPL ran the cell')
  pcall(iron.close_repl, 'python')
  vim.fn.delete(path)
end)

local success = h.summary()
if success then
  vim.cmd('qa!')
else
  vim.cmd('cquit 1')
end
