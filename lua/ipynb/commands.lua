-- ipynb/commands.lua - User commands (see :help ipynb-commands)

local M = {}

local kernel = require('ipynb.kernel')

---Validate kernel exists in Jupyter and set it
---Warns if Jupyter can't be located or kernel doesn't exist
---@param state NotebookState
---@param kernel_name string
local function validate_and_set_kernel(state, kernel_name)
  kernel.list_kernels(state.source_path, function(kernels, err)
    if err then
      vim.notify(
        string.format("Warning: unable to validate kernel '%s': %s", kernel_name, err),
        vim.log.levels.WARN
      )
      kernel.set_kernel_name(state, kernel_name)
      return
    end

    local found = false
    for _, k in ipairs(kernels) do
      if k.name == kernel_name then
        found = true
        break
      end
    end

    if not found then
      local available = {}
      for _, k in ipairs(kernels) do
        table.insert(available, k.name)
      end
      vim.notify(
        string.format(
          "Warning: kernel '%s' not found in Jupyter.\nAvailable: %s",
          kernel_name,
          #available > 0 and table.concat(available, ', ') or '(none)'
        ),
        vim.log.levels.WARN
      )
    end

    kernel.set_kernel_name(state, kernel_name)
  end)
end

---Setup buffer-local commands for a notebook
---@param state NotebookState
function M.setup_buffer(state)
  local buf = state.facade_buf
  local keymaps = require('ipynb.keymaps')
  local cells = require('ipynb.cells')

  local function current_cell()
    return cells.get_cell_at_line(state, vim.api.nvim_win_get_cursor(0)[1] - 1)
  end

  local function info_command()
    local idx, cell = current_cell()
    local info = {
      'Notebook: ' .. state.source_path,
      'Shadow buffer: ' .. (state.shadow_path or 'none'),
      'Total cells: ' .. #state.cells,
      '',
    }
    vim.list_extend(info, kernel.format_info(state))
    if idx and cell then
      local start_line, end_line = cells.get_cell_range(state, idx)
      vim.list_extend(info, {
        '',
        'Current cell: ' .. idx .. ' (id ' .. cell.id .. ')',
        'Cell type: ' .. cell.type,
        'Lines: ' .. (start_line + 1) .. '-' .. (end_line + 1),
      })
      if cell.execution_count then
        table.insert(info, 'Execution count: ' .. cell.execution_count)
      end
      if cell.execution_state and cell.execution_state ~= 'idle' then
        table.insert(info, 'Execution state: ' .. cell.execution_state)
      end
    end
    vim.notify(table.concat(info, '\n'), vim.log.levels.INFO)
  end

  local function delete_cell()
    if #state.cells <= 1 then
      vim.notify('Cannot delete the only cell', vim.log.levels.WARN)
      return
    end
    local idx = current_cell()
    if idx then
      require('ipynb.facade').delete_cell(state, idx)
    end
  end

  local function toggle_cell_type()
    local _, cell = current_cell()
    if cell then
      keymaps.set_cell_type(state, cell.type == 'code' and 'markdown' or 'code')
    end
  end

  local function call(mod, fn, ...)
    local args = { ... }
    return function()
      require(mod)[fn](unpack(args))
    end
  end

  -- { name, function(opts), description, extra command options }
  local commands = {
    { 'NotebookSave', function() require('ipynb.io').save_notebook(buf, nil) end, 'Save notebook' },
    { 'NotebookInfo', info_command, 'Show notebook info' },
    { 'NotebookJumpToCell', call('ipynb.picker', 'jump_to_cell'), 'Jump to cell (picker)' },
    -- Cells
    { 'NotebookInsertCellBelow', call('ipynb.keymaps', 'add_cell_below', state), 'Insert cell below current' },
    { 'NotebookInsertCellAbove', call('ipynb.keymaps', 'add_cell_above', state), 'Insert cell above current' },
    { 'NotebookDeleteCell', delete_cell, 'Delete current cell' },
    { 'NotebookCutCell', call('ipynb.keymaps', 'cut_cell', state), 'Cut cell to register' },
    { 'NotebookPasteCellBelow', call('ipynb.keymaps', 'paste_cell', state, 'below'), 'Paste cell below' },
    { 'NotebookPasteCellAbove', call('ipynb.keymaps', 'paste_cell', state, 'above'), 'Paste cell above' },
    { 'NotebookMoveCellUp', call('ipynb.keymaps', 'move_cell', state, -1), 'Move cell up' },
    { 'NotebookMoveCellDown', call('ipynb.keymaps', 'move_cell', state, 1), 'Move cell down' },
    { 'NotebookMakeCode', call('ipynb.keymaps', 'set_cell_type', state, 'code'), 'Make cell code type' },
    { 'NotebookMakeMarkdown', call('ipynb.keymaps', 'set_cell_type', state, 'markdown'), 'Make cell markdown type' },
    { 'NotebookMakeRaw', call('ipynb.keymaps', 'set_cell_type', state, 'raw'), 'Make cell raw type' },
    { 'NotebookToggleCellType', toggle_cell_type, 'Toggle cell type (code/markdown)' },
    -- Execution
    { 'NotebookExecuteCell', call('ipynb.keymaps', 'execute_cell', state), 'Execute current cell' },
    { 'NotebookExecuteAndNext', call('ipynb.keymaps', 'execute_and_next', state), 'Execute cell and move to next' },
    { 'NotebookExecuteAllBelow', call('ipynb.keymaps', 'execute_all_below', state), 'Execute all cells from current to end' },
    { 'NotebookExecuteAll', call('ipynb.kernel', 'execute_all_below', state, 1), 'Execute all code cells in the notebook' },
    { 'NotebookExecuteAllAbove', call('ipynb.kernel', 'execute_all_above', state), 'Execute all cells above the current one' },
    { 'NotebookRestartAndRunAll', call('ipynb.kernel', 'restart_and_run_all', state), 'Restart kernel, then run all cells' },
    -- More cell operations
    { 'NotebookCopyCell', call('ipynb.keymaps', 'copy_cell', state), 'Copy cell to register' },
    { 'NotebookMergeCellBelow', call('ipynb.keymaps', 'merge_cell_below', state), 'Merge cell with the one below' },
    { 'NotebookSplitCell', function()
      if not state.edit_state then
        require('ipynb.edit').open(state)
      end
      require('ipynb.edit').split_cell(state)
    end, 'Split cell at cursor' },
    { 'NotebookToggleSourceHidden', call('ipynb.folding', 'toggle_source_hidden', state), 'Hide/show cell code' },
    { 'NotebookToggleOutputsHidden', call('ipynb.output', 'toggle_outputs_hidden', state), 'Hide/show cell outputs' },
    { 'NotebookOpenOutput', call('ipynb.output', 'open_external', state), 'Open image/HTML/plot output externally' },
    { 'NotebookCellTags', function(opts)
      if opts.args == '' then
        keymaps.edit_tags(state)
        return
      end
      local _, cell = current_cell()
      if cell then
        require('ipynb.cellmeta').set_tags(cell, opts.fargs)
        vim.bo[buf].modified = true
        require('ipynb.visuals').render_all(state)
      end
    end, 'Edit cell tags', { nargs = '*' } },
    { 'NotebookExport', function(opts) kernel.export(state, opts.args) end, 'Export with nbconvert', {
      nargs = 1,
      complete = function() return kernel.EXPORT_FORMATS end,
    } },
    -- Kernel
    { 'NotebookKernelStart', function(opts)
      kernel.connect(state, { python_path = opts.args ~= '' and opts.args or nil })
    end, 'Start Jupyter kernel', { nargs = '?', complete = 'file' } },
    { 'NotebookKernelConnect', function(opts)
      kernel.connect(state, { connection_file = opts.args })
    end, 'Connect to existing Jupyter kernel', { nargs = 1, complete = 'file' } },
    { 'NotebookServerConnect', function(opts)
      kernel.connect_server(state, opts.fargs[1], opts.fargs[2])
    end, 'Use a kernel on a Jupyter server (URL [kernel id or name])', { nargs = '+' } },
    { 'NotebookKernelInterrupt', call('ipynb.kernel', 'interrupt', state), 'Interrupt kernel execution' },
    { 'NotebookKernelRestart', call('ipynb.kernel', 'restart', state, true), 'Restart kernel (clears outputs)' },
    { 'NotebookKernelShutdown', call('ipynb.kernel', 'shutdown', state), 'Shutdown kernel' },
    { 'NotebookKernelStatus', call('ipynb.keymaps', 'kernel_info', state), 'Show kernel status' },
    { 'NotebookSetKernel', function(opts) validate_and_set_kernel(state, opts.args) end,
      'Set kernel name in notebook metadata', { nargs = 1 } },
    -- Outputs
    { 'NotebookOutput', call('ipynb.output', 'open_output_float', state), 'Open cell output in floating buffer' },
    { 'NotebookClearOutput', call('ipynb.keymaps', 'clear_output', state), 'Clear current cell output' },
    { 'NotebookClearAllOutputs', call('ipynb.keymaps', 'clear_all_outputs', state), 'Clear all outputs' },
    -- Folding
    { 'NotebookFoldCell', call('ipynb.folding', 'toggle_cell_fold', state), 'Toggle fold for current cell' },
    { 'NotebookFoldAll', call('ipynb.folding', 'fold_all_cells', state, 'close'), 'Fold all cells' },
    { 'NotebookUnfoldAll', call('ipynb.folding', 'fold_all_cells', state, 'open'), 'Unfold all cells' },
    -- Inspector
    { 'NotebookInspect', call('ipynb.inspector', 'show_variable_at_cursor', state), 'Inspect variable at cursor' },
    { 'NotebookInspectCell', call('ipynb.inspector', 'show_cell_variables', state), 'Show all variables in cell' },
    { 'NotebookToggleAutoHover', call('ipynb.inspector', 'toggle_auto_hover'), 'Toggle auto-hover on CursorHold' },
    -- Formatting
    { 'NotebookFormatCell', call('ipynb.lsp', 'format_current_cell', state), 'Format current cell' },
    { 'NotebookFormatAll', call('ipynb.lsp', 'format_all_cells', state), 'Format all code cells' },
    { 'NotebookDebug', function() print('State:', vim.inspect(state)) end, 'Debug notebook state' },
  }

  for _, spec in ipairs(commands) do
    local opts = vim.tbl_extend('force', { desc = spec[3] }, spec[4] or {})
    vim.api.nvim_buf_create_user_command(buf, spec[1], spec[2], opts)
  end
end

---Setup global commands (called once during plugin setup)
function M.setup()
  -- NotebookCreate - available globally to create new notebooks
  vim.api.nvim_create_user_command('NotebookCreate', function(opts)
    local path = opts.fargs[1] or ''
    local kernel_name = opts.fargs[2]

    if path == '' then
      -- Default to untitled.ipynb in current directory
      local cwd = vim.fn.getcwd()
      local base = 'untitled'
      local ext = '.ipynb'
      path = cwd .. '/' .. base .. ext

      -- Find unique name if file exists
      local counter = 1
      while vim.fn.filereadable(path) == 1 do
        path = cwd .. '/' .. base .. counter .. ext
        counter = counter + 1
      end
    end

    -- Ensure .ipynb extension
    if not path:match('%.ipynb$') then
      path = path .. '.ipynb'
    end

    -- Open the new notebook (io.lua handles creation)
    vim.cmd.edit(path)

    -- Set kernel if specified (must be done after notebook is loaded)
    if kernel_name then
      vim.schedule(function()
        local state = require('ipynb.state').get()
        if state then
          validate_and_set_kernel(state, kernel_name)
        end
      end)
    end
  end, {
    desc = 'Create a new Jupyter notebook',
    nargs = '*',
    complete = 'file',
  })

  -- NotebookListKernels - query jupyter for available kernelspecs
  vim.api.nvim_create_user_command('NotebookListKernels', function()
    -- Use current notebook path if available for Python discovery
    local state = require('ipynb.state').get()
    local notebook_path = state and state.source_path or nil

    kernel.list_kernels(notebook_path, function(kernels, err)
      if err then
        vim.notify('Failed to list kernels: ' .. err, vim.log.levels.ERROR)
        return
      end

      local lines = { 'Available Jupyter kernels:', '' }
      for _, k in ipairs(kernels) do
        local lang = k.language or '?'
        table.insert(lines, string.format('  %s (%s) - %s', k.name, lang, k.display_name))
      end

      if #kernels == 0 then
        table.insert(lines, '  (none found)')
      end

      vim.notify(table.concat(lines, '\n'), vim.log.levels.INFO)
    end)
  end, { desc = 'List available Jupyter kernels' })
end

return M
