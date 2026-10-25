-- Other Jupyter kernels end to end (R, Go, ...): run, outputs, errors, language
-- Needs IPYNB_TEST_PYTHON (bridge) and the kernels named in IPYNB_TEST_KERNELS
-- (comma separated, e.g. "ir,gonb") installed where Jupyter finds them.
-- Run with: nvim --headless -u tests/minimal_init.lua -l tests/test_kernels_multi.lua

local h = require('tests.helpers')
local kernel = require('ipynb.kernel')

print('')
print(string.rep('=', 60))
print('Running multi-language kernel tests')
print(string.rep('=', 60))
print('')

local python = vim.env.IPYNB_TEST_PYTHON or ''
local wanted = vim.split(vim.env.IPYNB_TEST_KERNELS or '', ',', { trimempty = true })
if python == '' or #wanted == 0 then
  print('SKIP: set IPYNB_TEST_PYTHON and IPYNB_TEST_KERNELS (e.g. "ir,gonb")')
  vim.cmd('qa!')
  return
end

-- Per-kernel cells: code, expected stdout/result text, expected error name, language
local CASES = {
  ir = {
    language = 'r',
    run = { 'x <- c(1, 2, 3)', 'cat("sum", sum(x), "\\n")' },
    expect = 'sum 6',
    rich = 'data.frame(a = 1:2, b = c("x", "y"))',
    rich_expect = 'a',
    error = 'stop("boom")',
  },
  gonb = {
    language = 'go',
    run = { 'import "fmt"', '%%', 'fmt.Println("sum", 1+2+3)' },
    expect = 'sum 6',
    error = '%%\nvar x int = "not an int"\n_ = x',
  },
}

local function notebook(name, lang, sources)
  local cells = {}
  for i, src in ipairs(sources) do
    cells[i] = { id = 'c' .. i, cell_type = 'code', source = src, metadata = vim.empty_dict(), outputs = {}, execution_count = vim.NIL }
  end
  local path = vim.fn.tempname() .. '.ipynb'
  vim.fn.writefile({ vim.json.encode({ nbformat = 4, nbformat_minor = 5,
    metadata = { kernelspec = { name = name, display_name = name, language = lang }, language_info = { name = lang } },
    cells = cells }) }, path)
  return path
end

local function wait_cell(cell, timeout)
  return vim.wait(timeout or 120000, function()
    return cell.execution_state == 'idle' and cell.execution_count ~= nil
  end, 100)
end

local function text_of(cell)
  local parts = {}
  for _, o in ipairs(cell.outputs or {}) do
    if o.output_type == 'stream' then
      parts[#parts + 1] = o.text
    elseif o.output_type == 'error' then
      parts[#parts + 1] = 'ERROR:' .. (o.ename or '') .. ':' .. (o.evalue or '')
    elseif o.data then
      parts[#parts + 1] = require('ipynb.output').bundle_text(o.data) or ''
    end
  end
  return table.concat(parts, '\n')
end

require('ipynb.config').get().kernel.python_path = python

for _, name in ipairs(wanted) do
  local case = CASES[name]
  if not case then
    print('  SKIP: no test case for kernel ' .. name)
  else
    local sources = { table.concat(case.run, '\n'), case.error }
    if case.rich then
      table.insert(sources, case.rich)
    end
    local path = notebook(name, case.language, sources)
    local state

    h.run_step(name .. ': kernel starts and sets the language', function()
      state = h.open_notebook_path(path)
      kernel.connect(state, {})
      h.assert_true(vim.wait(120000, function() return kernel.is_connected(state) end, 200), 'connected')
      vim.wait(500)
      h.assert_eq(state.shadow_lang or vim.b[state.facade_buf].ipynb_language, case.language, 'language from kernelspec')
    end)

    h.run_step(name .. ': cell output', function()
      kernel.execute(state, 1)
      h.assert_true(wait_cell(state.cells[1]), 'finished')
      h.assert_true(text_of(state.cells[1]):find(case.expect, 1, true) ~= nil, 'output: ' .. text_of(state.cells[1]))
    end)

    h.run_step(name .. ': errors are shown', function()
      kernel.execute(state, 2)
      local cell = state.cells[2]
      h.assert_true(vim.wait(120000, function() return cell.execution_state == 'idle' and #(cell.outputs or {}) > 0 end, 100), 'finished')
      local has_error = false
      for _, o in ipairs(cell.outputs) do
        if o.output_type == 'error' or (o.output_type == 'stream' and o.name == 'stderr') then
          has_error = true
        end
      end
      h.assert_true(has_error, 'error output: ' .. text_of(cell))
    end)

    if case.rich then
      h.run_step(name .. ': rich output has readable text', function()
        kernel.execute(state, 3)
        h.assert_true(wait_cell(state.cells[3]), 'finished')
        h.assert_true(text_of(state.cells[3]):find(case.rich_expect, 1, true) ~= nil, 'rich: ' .. text_of(state.cells[3]))
      end)
    end

    h.run_step(name .. ': code is not masked as IPython', function()
      local shadow = table.concat(vim.api.nvim_buf_get_lines(state.shadow_buf, 0, -1, false), '\n')
      h.assert_false(shadow:find('ipynb-magic', 1, true) ~= nil, 'no IPython masking for ' .. name)
    end)

    h.run_step(name .. ': saved notebook is valid', function()
      vim.cmd('write')
      local r = vim.system({ python, '-c', 'import nbformat,sys; nbformat.validate(nbformat.read(sys.argv[1], as_version=4))', path }, { text = true }):wait()
      h.assert_eq(r.code, 0, r.stderr or '')
    end)

    if state then
      kernel.shutdown(state)
    end
    vim.wait(1000)
    vim.fn.delete(path)
  end
end

require('ipynb.config').get().kernel.python_path = nil

local success = h.summary()
if success then
  vim.cmd('qa!')
else
  vim.cmd('cquit 1')
end
