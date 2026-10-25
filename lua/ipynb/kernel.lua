-- ipynb/kernel.lua - Jupyter kernel connection via Python bridge
-- Each notebook has its own kernel state and bridge process

local M = {}

---@class KernelState
---@field job_id number|nil Job handle for Python bridge
---@field connected boolean Whether kernel is connected
---@field kernel_id string|nil Kernel ID
---@field kernel_name string Kernel name (e.g., "python3")
---@field execution_state string Current state: "idle", "busy", "starting"
---@field pending_cells table<string, {cell_id: string}> Cells waiting for execution
---@field cell_index_by_id table<string, number> Cached cell_id -> index map
---@field callbacks table Async operation callbacks

---Create a new kernel state for a notebook
---@return KernelState
local function create_kernel_state()
  return {
    job_id = nil,
    connected = false,
    kernel_id = nil,
    kernel_name = "python3",
    execution_state = "idle",
    pending_cells = {},
    cell_index_by_id = {},
    callbacks = {
      complete = nil,
      inspect = {},
      ping = nil,
      is_alive = nil,
    },
  }
end

-- Get the path to the Python bridge script
local function get_bridge_path()
  local source = debug.getinfo(1, "S").source:sub(2)
  local plugin_dir = vim.fn.fnamemodify(source, ":h:h:h")
  return plugin_dir .. "/python/kernel_bridge.py"
end

---Send a command to the Python bridge for a notebook
---@param state NotebookState
---@param cmd table Command to send
---@return boolean success
local function send_command(state, cmd)
  if not state.kernel or not state.kernel.job_id then
    vim.notify("Kernel bridge not running", vim.log.levels.ERROR)
    return false
  end

  local json = vim.json.encode(cmd)
  vim.fn.chansend(state.kernel.job_id, json .. "\n")
  return true
end

---Send an input reply to the Python bridge.
---@param state NotebookState
---@param request_id string
---@param value string
---@return boolean success
local function send_input_reply(state, request_id, value)
  return send_command(state, {
    action = "input_reply",
    request_id = request_id,
    value = value,
  })
end

---Close any active notebook input prompt.
---@param state NotebookState
local function close_input_prompt(state)
  local ok, input_mod = pcall(require, "ipynb.input")
  if ok then
    input_mod.close(state)
  end
end

---Re-render cell borders once per event-loop tick, however many kernel
---messages arrive in between (a busy cell can produce hundreds).
---@param state NotebookState
local function request_render(state)
  if state._render_scheduled then
    return
  end
  state._render_scheduled = true
  vim.schedule(function()
    state._render_scheduled = false
    if state.facade_buf and vim.api.nvim_buf_is_valid(state.facade_buf) then
      require("ipynb.visuals").render_all(state)
    end
  end)
end

---Re-render one cell's outputs on the next tick (coalesced per cell)
---@param state NotebookState
---@param cell Cell
local function request_output_render(state, cell)
  state._dirty_outputs = state._dirty_outputs or {}
  if next(state._dirty_outputs) == nil then
    vim.schedule(function()
      local dirty = state._dirty_outputs
      state._dirty_outputs = {}
      if state.facade_buf and not vim.api.nvim_buf_is_valid(state.facade_buf) then
        return -- notebook closed meanwhile
      end
      local output_mod = require("ipynb.output")
      for idx, c in ipairs(state.cells or {}) do
        if dirty[c] then
          output_mod.render_outputs(state, idx)
        end
      end
    end)
  end
  state._dirty_outputs[cell] = true
end

---Parse an ISO-8601 timestamp to seconds (only differences are used)
---@param iso string|nil
---@return number|nil
local function iso_seconds(iso)
  if type(iso) ~= "string" then
    return nil
  end
  local y, mo, d, h, mi, sec = iso:match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+%.?%d*)")
  if not y then
    return nil
  end
  local base = os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d), hour = tonumber(h), min = tonumber(mi), sec = 0 })
  return base + tonumber(sec)
end
M._iso_seconds = iso_seconds

---Rebuild the cell_id -> index cache for fast kernel message routing.
---@param state NotebookState
local function rebuild_cell_index_map(state)
  if not state.kernel then
    return
  end
  local map = {}
  for i, cell in ipairs(state.cells or {}) do
    if cell.id and type(cell.id) == "string" then
      map[cell.id] = i
    end
  end
  state.kernel.cell_index_by_id = map
end

---Resolve a kernel message target to the current cell index by stable cell_id.
---@param state NotebookState
---@param msg table
---@return number|nil cell_idx, Cell|nil cell
local function resolve_message_cell(state, msg)
  if msg.cell_id and type(msg.cell_id) == "string" then
    local map = state.kernel and state.kernel.cell_index_by_id or nil
    local idx = map and map[msg.cell_id] or nil
    if idx then
      local cell = state.cells and state.cells[idx] or nil
      if cell and cell.id == msg.cell_id then
        return idx, cell
      end
    end

    -- Cache may be stale after insert/delete/move/undo; rebuild and retry once.
    rebuild_cell_index_map(state)
    map = state.kernel and state.kernel.cell_index_by_id or nil
    idx = map and map[msg.cell_id] or nil
    if idx then
      local cell = state.cells and state.cells[idx] or nil
      if cell and cell.id == msg.cell_id then
        return idx, cell
      end
    end

    -- Message was keyed by cell_id but target no longer exists (e.g. deleted).
    -- Drop the message to avoid misrouting output to the wrong cell.
    return nil, nil
  end

  return nil, nil
end

---Set the notebook language (updates metadata, treesitter, and LSP)
---@param state NotebookState
---@param lang string Language name (e.g., "python", "julia", "r")
local function set_language(state, lang)
  -- Update language_info metadata
  if not state.metadata then
    state.metadata = {}
  end
  if not state.metadata.language_info then
    state.metadata.language_info = { name = lang }
  else
    state.metadata.language_info.name = lang
  end

  -- Also update kernelspec.language if present
  if state.metadata.kernelspec then
    state.metadata.kernelspec.language = lang
  end

  -- Update treesitter injection
  local buf = state.facade_buf
  if buf and vim.api.nvim_buf_is_valid(buf) then
    vim.b[buf].ipynb_language = lang
    pcall(vim.treesitter.stop, buf)
    require('ipynb.facade').start_treesitter(buf)
  end

  -- Update shadow buffer filetype if language changed (triggers LSP reattach)
  if state.shadow_buf and vim.api.nvim_buf_is_valid(state.shadow_buf) then
    local old_lang = state.shadow_lang
    if old_lang ~= lang then
      -- Changing filetype detaches old LSP servers
      vim.bo[state.shadow_buf].filetype = lang
      state.shadow_lang = lang

      -- Trigger FileType to let new LSP attach
      vim.api.nvim_buf_call(state.shadow_buf, function()
        vim.api.nvim_exec_autocmds('FileType', {
          buffer = state.shadow_buf,
          modeline = false,
        })
      end)
    end
  end
end

---Language reported by a newly started/connected kernel
---@param state NotebookState
---@param language string|nil
local function adopt_kernel_language(state, language)
  if not language then
    return
  end
  local lang = language:lower() -- treesitter needs lowercase
  local current = state.metadata and state.metadata.language_info and state.metadata.language_info.name
  if current ~= lang then
    vim.schedule(function()
      set_language(state, lang)
      vim.notify('Language updated from kernel: ' .. lang, vim.log.levels.INFO)
    end)
  end
end

---Replace every output that shows `display_id` (IPython display handles)
---@param state NotebookState
---@param display_id string
---@param output table
local function update_display(state, display_id, output)
  for _, cell in ipairs(state.cells or {}) do
    for i, existing in ipairs(cell.outputs or {}) do
      if type(existing.transient) == "table" and existing.transient.display_id == display_id then
        local replacement = vim.deepcopy(output)
        replacement.output_type = existing.output_type
        replacement.execution_count = existing.execution_count
        replacement.transient = existing.transient
        cell.outputs[i] = replacement
        request_output_render(state, cell)
      end
    end
  end
end

---Handle a message from the Python bridge
---@param state NotebookState
---@param msg table Parsed JSON message
local function handle_message(state, msg)
  local msg_type = msg.type
  local kernel = state.kernel
  if not kernel then
    return
  end

  if msg_type == "ready" then
    vim.schedule(function()
      vim.notify("Kernel bridge ready", vim.log.levels.INFO)
    end)

  elseif msg_type == "kernel_started" or msg_type == "kernel_connected" then
    kernel.connected = true
    kernel.kernel_id = msg.kernel_id
    kernel.kernel_name = msg.kernel_name or kernel.kernel_name
    kernel.execution_state = "idle"
    adopt_kernel_language(state, msg.language)
    vim.schedule(function()
      vim.notify(msg_type == "kernel_started" and ("Kernel started: " .. tostring(msg.kernel_name))
        or "Connected to kernel", vim.log.levels.INFO)
    end)

  elseif msg_type == "status" then
    kernel.execution_state = msg.state or "idle"
    local _, cell = resolve_message_cell(state, msg)
    if cell and msg.state == "busy" and cell.execution_state == "queued" then
      cell.execution_state = "busy"
      request_render(state)
    end
    if msg.state == "idle" then
      vim.schedule(function()
        close_input_prompt(state)
      end)
    end

  elseif msg_type == "execute_input" then
    local _, cell = resolve_message_cell(state, msg)
    if cell then
      cell.execution_state = "busy"
      cell._exec_started = msg.date
      if msg.execution_count and msg.execution_count ~= vim.NIL then
        cell.execution_count = msg.execution_count
      end
      request_render(state)
    end

  elseif msg_type == "execute_reply" then
    local _, cell = resolve_message_cell(state, msg)
    if msg.cell_id then
      kernel.pending_cells[msg.cell_id] = nil
    end
    if cell then
      cell.execution_state = "idle"
      cell._clear_on_next_output = nil
      local started, finished = iso_seconds(cell._exec_started), iso_seconds(msg.date)
      cell.execution_time = (started and finished and finished >= started) and (finished - started) or nil
      if msg.status == "aborted" then
        cell.execution_time = nil
      end
      if require("ipynb.config").get().kernel.record_timing and cell._exec_started and msg.date then
        -- Same keys JupyterLab writes with "Record cell timing" enabled
        cell.metadata = cell.metadata or {}
        cell.metadata.execution = {
          ["iopub.execute_input"] = cell._exec_started,
          ["shell.execute_reply"] = msg.date,
        }
      end
      request_render(state)
    end

  elseif msg_type == "input_request" then
    if type(msg.request_id) ~= "string" or msg.request_id == "" then
      vim.schedule(function()
        vim.notify("Kernel input request missing request_id", vim.log.levels.ERROR)
      end)
      return
    end

    vim.schedule(function()
      local input_mod = require("ipynb.input")
      input_mod.request(
        state,
        msg,
        function(value)
          send_input_reply(state, msg.request_id, value or "")
        end,
        function()
          send_command(state, { action = "interrupt" })
        end
      )
    end)

  elseif msg_type == "output" then
    local _, cell = resolve_message_cell(state, msg)
    if cell and type(msg.output) == "table" then
      local output_mod = require("ipynb.output")
      if cell._clear_on_next_output then
        -- clear_output(wait=True): replace instead of append, avoiding flicker
        cell._clear_on_next_output = nil
        cell.outputs = {}
        cell._stream_state = nil
      end
      output_mod.append_output(cell, msg.output)
      request_output_render(state, cell)
    end

  elseif msg_type == "clear_output" then
    local idx, cell = resolve_message_cell(state, msg)
    if cell then
      if msg.wait then
        cell._clear_on_next_output = true
      else
        vim.schedule(function()
          if state.cells[idx] == cell then
            require("ipynb.output").clear_outputs(state, idx)
          end
        end)
      end
    end

  elseif msg_type == "update_display" then
    if type(msg.display_id) == "string" and type(msg.output) == "table" then
      update_display(state, msg.display_id, msg.output)
    end

  elseif msg_type == "interrupted" then
    kernel.execution_state = "idle"
    vim.schedule(function()
      close_input_prompt(state)
      vim.notify("Kernel interrupted", vim.log.levels.INFO)
    end)

  elseif msg_type == "restarted" or msg_type == "shutdown" then
    kernel.execution_state = "idle"
    kernel.pending_cells = {}
    if msg_type == "shutdown" then
      kernel.connected = false
    end
    for _, cell in ipairs(state.cells or {}) do
      if cell.execution_state and cell.execution_state ~= "idle" then
        cell.execution_state = "idle"
      end
    end
    request_render(state)
    local after_restart = msg_type == "restarted" and kernel.callbacks.restarted
    kernel.callbacks.restarted = nil
    vim.schedule(function()
      close_input_prompt(state)
      if msg_type == "restarted" then
        vim.notify("Kernel restarted", vim.log.levels.INFO)
      end
      if after_restart then
        after_restart()
      end
    end)

  elseif msg_type == "error" then
    vim.schedule(function()
      vim.notify("Kernel error: " .. (msg.error or "Unknown error"), vim.log.levels.ERROR)
    end)

  elseif msg_type == "is_alive" then
    if kernel.callbacks.is_alive then
      kernel.callbacks.is_alive(msg.alive)
      kernel.callbacks.is_alive = nil
    end

  elseif msg_type == "complete_reply" then
    if kernel.callbacks.complete then
      kernel.callbacks.complete(msg)
      kernel.callbacks.complete = nil
    end

  elseif msg_type == "inspect_reply" then
    local request_id = msg.request_id
    if request_id and kernel.callbacks.inspect[request_id] then
      kernel.callbacks.inspect[request_id](msg)
      kernel.callbacks.inspect[request_id] = nil
    end

  elseif msg_type == "server_kernels" then
    local cb = kernel.callbacks.server_kernels
    kernel.callbacks.server_kernels = nil
    if cb then
      vim.schedule(function()
        cb(msg.kernels or {})
      end)
    end

  elseif msg_type == "pong" then
    if kernel.callbacks.ping then
      kernel.callbacks.ping()
      kernel.callbacks.ping = nil
    end
  end
end
M._handle_message = handle_message

---Find a virtual environment python by walking up the directory tree
---@param start_path string Path to start searching from
---@return string|nil python_path
local function find_venv_python(start_path)
  local venv_names = { ".venv", "venv", ".virtualenv", "env" }
  local rel = vim.fn.has("win32") == 1 and "/Scripts/python.exe" or "/bin/python"
  for dir in vim.fs.parents(vim.fn.fnamemodify(start_path, ":p")) do
    for _, name in ipairs(venv_names) do
      local python = dir .. "/" .. name .. rel
      if vim.fn.executable(python) == 1 then
        return vim.fs.normalize(python)
      end
    end
  end
  return nil
end

---Discover Python executable to use
---@param notebook_path string|nil Path to notebook (for venv discovery)
---@param explicit_path string|nil Explicit python path (highest priority)
---@return string|nil python_path
---@return string source Description of where Python was found
local function discover_python(notebook_path, explicit_path)
  if explicit_path and explicit_path ~= "" then
    return explicit_path, "explicit"
  end

  local config = require("ipynb.config").get()
  if config.kernel and config.kernel.python_path then
    return config.kernel.python_path, "config"
  end

  if notebook_path then
    local venv = find_venv_python(notebook_path)
    if venv then
      return venv, "venv"
    end
  end

  -- On Windows "python" is the real interpreter; "python3" is usually only the
  -- Microsoft Store stub in WindowsApps, which opens the Store instead of running.
  local names = vim.fn.has("win32") == 1 and { "python", "python3", "py" } or { "python3", "python" }
  for _, name in ipairs(names) do
    local path = vim.fn.exepath(name)
    if path ~= "" and not path:lower():find("\\windowsapps\\", 1, true) then
      return path, "system"
    end
  end

  return nil, "not found"
end

---Get the Python that would be used for a notebook (for display purposes)
---@param notebook_path string Path to the notebook file
---@return string|nil python_path
---@return string source Description of where Python was found
function M.get_python_info(notebook_path)
  return discover_python(notebook_path, nil)
end

---Start the Python bridge process for a notebook
---@param state NotebookState
---@param python_path string|nil Explicit python path (highest priority)
---@return boolean success
function M.start_bridge(state, python_path)
  if state.kernel and state.kernel.job_id then
    return true -- Already running for this notebook
  end

  state.kernel = state.kernel or create_kernel_state()

  local bridge_path = get_bridge_path()
  if vim.fn.filereadable(bridge_path) ~= 1 then
    vim.notify("Kernel bridge script not found: " .. bridge_path, vim.log.levels.ERROR)
    return false
  end

  local python, source = discover_python(state.source_path, python_path)
  if not python then
    vim.notify("Python not found. Install Python or set kernel.python_path in config.", vim.log.levels.ERROR)
    return false
  end

  vim.notify("Using Python: " .. python .. " (" .. source .. ")", vim.log.levels.INFO)

  local cmd = { python, bridge_path }

  -- Unbuffered stdout arrives in chunks: data[1] continues the previous
  -- partial line, the last element starts the next one. Partial pieces are
  -- collected in a list so a large message costs O(n), not O(n^2), to rebuild.
  local partial = {}
  local job_id = vim.fn.jobstart(cmd, {
    on_stdout = function(_, data, _)
      for i, piece in ipairs(data) do
        if i == #data then
          if piece ~= "" then
            partial[#partial + 1] = piece
          end
        else
          partial[#partial + 1] = piece
          local line = table.concat(partial)
          partial = {}
          if line ~= "" then
            local ok, msg = pcall(vim.json.decode, line)
            if ok and type(msg) == "table" then
              handle_message(state, msg)
            end
          end
        end
      end
    end,
    on_stderr = function(_, data, _)
      for _, line in ipairs(data) do
        if line and line ~= "" then
          vim.schedule(function()
            vim.notify("Kernel bridge stderr: " .. line, vim.log.levels.WARN)
          end)
        end
      end
    end,
    on_exit = function(_, code, _)
      if state.kernel then
        state.kernel.job_id = nil
        state.kernel.connected = false
      end
      vim.schedule(function()
        close_input_prompt(state)
        if code ~= 0 then
          vim.notify("Kernel bridge exited with code " .. code, vim.log.levels.WARN)
        end
      end)
    end,
    stdout_buffered = false,
    stderr_buffered = false,
  })

  if job_id <= 0 then
    vim.notify("Failed to start kernel bridge", vim.log.levels.ERROR)
    return false
  end

  state.kernel.job_id = job_id
  return true
end

---Get the kernel name from notebook metadata
---@param state NotebookState
---@return string kernel_name
function M.get_kernel_name(state)
  if state.metadata and state.metadata.kernelspec and state.metadata.kernelspec.name then
    return state.metadata.kernelspec.name
  end
  return "python3"
end

---Map kernel name to language name for treesitter injection
---@param kernel_name string Kernel name (e.g., "python3", "julia-1.9")
---@return string language name for treesitter (e.g., "python", "julia")
local function kernel_to_language(kernel_name)
  local name = kernel_name:lower()
  if name:match('^python') then
    return 'python'
  elseif name:match('^julia') then
    return 'julia'
  elseif name == 'ir' or name == 'r' or name:match('^ir[%-_]') or name:match('^r[%-_]') then
    return 'r'
  end
  return name
end
M._kernel_to_language = kernel_to_language

---Set the kernel name in notebook metadata
---@param state NotebookState
---@param kernel_name string Kernel name (e.g., "python3", "conda-ml")
function M.set_kernel_name(state, kernel_name)
  local lang = kernel_to_language(kernel_name)

  -- Update kernelspec metadata
  if not state.metadata then
    state.metadata = require('ipynb.io').default_metadata(kernel_name)
  elseif not state.metadata.kernelspec then
    state.metadata.kernelspec = {
      display_name = kernel_name,
      language = lang,
      name = kernel_name,
    }
  else
    state.metadata.kernelspec.name = kernel_name
    if state.metadata.kernelspec.display_name == 'Python 3' or
       state.metadata.kernelspec.display_name:match('^python') then
      state.metadata.kernelspec.display_name = kernel_name
    end
  end

  -- Update language (metadata, treesitter, LSP)
  set_language(state, lang)

  -- Refresh visuals to update cell borders with new language
  require('ipynb.visuals').render_all(state)

  vim.notify('Kernel set to: ' .. kernel_name .. ' (language: ' .. lang .. ')', vim.log.levels.INFO)
end

---Connect to a Jupyter kernel
---@param state NotebookState
---@param opts table|nil Options: connection_file, python_path
---@return boolean success
function M.connect(state, opts)
  opts = opts or {}

  if state.kernel and state.kernel.connected then
    vim.notify('Kernel already running. Use :NotebookKernelRestart to restart.', vim.log.levels.WARN)
    return true
  end

  if not M.start_bridge(state, opts.python_path) then
    return false
  end

  local kernel_name = M.get_kernel_name(state)

  vim.defer_fn(function()
    if opts.server_url then
      -- Kernel on a Jupyter server: attach to a kernel id or start by name
      send_command(state, {
        action = "connect_server",
        url = opts.server_url,
        kernel = opts.kernel or kernel_name,
      })
    elseif opts.connection_file then
      send_command(state, {
        action = "connect",
        connection_file = opts.connection_file,
      })
    else
      send_command(state, {
        action = "start",
        kernel_name = kernel_name,
      })
    end
  end, 100)

  return true
end

---Kernels running on a Jupyter server
---@param state NotebookState
---@param url string Server URL, e.g. http://localhost:8888/?token=...
---@param callback fun(kernels: table[])
function M.list_server_kernels(state, url, callback)
  if not M.start_bridge(state, nil) then
    return
  end
  state.kernel.callbacks.server_kernels = callback
  send_command(state, { action = "list_server_kernels", url = url })
end

---Connect to a kernel on a Jupyter server, asking which one if not given
---@param state NotebookState
---@param url string
---@param kernel string|nil Running kernel id, or a kernelspec name to start
function M.connect_server(state, url, kernel)
  if kernel then
    M.connect(state, { server_url = url, kernel = kernel })
    return
  end
  M.list_server_kernels(state, url, function(kernels)
    local name = M.get_kernel_name(state)
    local choices = { { label = 'Start a new ' .. name .. ' kernel', kernel = name } }
    for _, k in ipairs(kernels) do
      table.insert(choices, {
        label = string.format('Attach to %s %s (%s, %s connection%s)', k.name or '?', (k.id or ''):sub(1, 8),
          k.execution_state or '?', tostring(k.connections or 0), k.connections == 1 and '' or 's'),
        kernel = k.id,
      })
    end
    vim.ui.select(choices, { prompt = 'Jupyter server kernel', format_item = function(c) return c.label end },
      function(choice)
        if choice then
          M.connect(state, { server_url = url, kernel = choice.kernel })
        end
      end)
  end)
end

---Disconnect from kernel
---@param state NotebookState
function M.disconnect(state)
  if state.kernel and state.kernel.job_id then
    send_command(state, { action = "shutdown" })
  end
end

---Execute a code cell
---@param state NotebookState
---@param cell_idx number
---@param code string|nil Code to run instead of the whole cell (e.g. a selection)
---@return boolean success
function M.execute(state, cell_idx, code)
  if not state.kernel or not state.kernel.connected then
    vim.notify("No kernel connected. Use :NotebookKernelStart", vim.log.levels.WARN)
    return false
  end

  local cell = state.cells[cell_idx]
  if not cell or cell.type ~= "code" then
    return false
  end

  -- Ensure the cell has a stable ID before execution routing.
  if not cell.id or cell.id == "" then
    local state_mod = require("ipynb.state")
    local id = state_mod.generate_cell_id(state.cell_ids)
    state.cell_ids[id] = true
    cell.id = id
    if state.kernel and state.kernel.cell_index_by_id then
      state.kernel.cell_index_by_id[id] = cell_idx
    end
  end

  require("ipynb.output").clear_outputs(state, cell_idx)

  -- Queued until the kernel actually starts it (execute_input)
  cell.execution_state = "queued"
  cell.execution_time = nil
  cell._exec_started = nil
  state.kernel.pending_cells[cell.id] = {
    cell_id = cell.id,
  }

  request_render(state)

  return send_command(state, {
    action = "execute",
    code = code or cell.source,
    cell_id = cell.id,
  })
end

---Execute all cells from current to end
---@param state NotebookState
---@param start_idx number|nil Start cell index (defaults to current cell)
function M.execute_all_below(state, start_idx)
  local cells_mod = require("ipynb.cells")

  if not start_idx then
    local cursor_line = vim.api.nvim_win_get_cursor(0)[1] - 1
    start_idx = cells_mod.get_cell_at_line(state, cursor_line) or 1
  end

  local to_execute = {}
  for i = start_idx, #state.cells do
    if state.cells[i].type == "code" then
      table.insert(to_execute, i)
    end
  end

  for _, idx in ipairs(to_execute) do
    M.execute(state, idx)
  end
end

---Execute the code cells in [from, to]
---@param state NotebookState
---@param from number
---@param to number
function M.execute_range(state, from, to)
  for i = math.max(from, 1), math.min(to, #state.cells) do
    if state.cells[i].type == "code" then
      M.execute(state, i)
    end
  end
end

---Execute all cells above `cell_idx` (Jupyter "Run All Above": not the cell itself)
---@param state NotebookState
---@param cell_idx number|nil Defaults to the cell at the cursor
function M.execute_all_above(state, cell_idx)
  if not cell_idx then
    cell_idx = require("ipynb.cells").get_cell_at_line(state, vim.api.nvim_win_get_cursor(0)[1] - 1) or 1
  end
  M.execute_range(state, 1, cell_idx - 1)
end

---Restart the kernel (clearing outputs), then run every cell once it is back
---@param state NotebookState
function M.restart_and_run_all(state)
  if not (state.kernel and state.kernel.connected) then
    vim.notify("No kernel connected. Use :NotebookKernelStart", vim.log.levels.WARN)
    return
  end
  state.kernel.callbacks.restarted = function()
    M.execute_range(state, 1, #state.cells)
  end
  M.restart(state, true)
end

---Interrupt kernel execution
---@param state NotebookState
function M.interrupt(state)
  close_input_prompt(state)
  if state.kernel and state.kernel.job_id then
    send_command(state, { action = "interrupt" })
  end
end

---Restart kernel
---@param state NotebookState
---@param clear_outputs boolean|nil Clear all outputs on restart
function M.restart(state, clear_outputs)
  close_input_prompt(state)
  if state.kernel and state.kernel.job_id then
    if clear_outputs then
      require("ipynb.output").clear_all_outputs(state)
      for _, cell in ipairs(state.cells) do
        cell.execution_count = nil
      end
      require("ipynb.visuals").render_all(state)
    end
    send_command(state, { action = "restart" })
  end
end

---Shutdown kernel
---@param state NotebookState
function M.shutdown(state)
  close_input_prompt(state)
  if state.kernel and state.kernel.job_id then
    send_command(state, { action = "shutdown" })
    vim.fn.jobstop(state.kernel.job_id)
    state.kernel.job_id = nil
  end
  if state.kernel then
    state.kernel.connected = false
  end
end

---Check if kernel is connected for a notebook
---@param state NotebookState
---@return boolean
function M.is_connected(state)
  return state.kernel and state.kernel.connected or false
end

---Check if kernel is busy for a notebook
---@param state NotebookState
---@return boolean
function M.is_busy(state)
  return state.kernel and state.kernel.execution_state == "busy" or false
end

---Get kernel state for a notebook
---@param state NotebookState
---@return KernelState|nil
function M.get_state(state)
  return state.kernel
end

---@class KernelInfo
---@field kernelspec string Kernel name from metadata
---@field python_path string|nil Python path for bridge
---@field python_source string Source of python discovery
---@field connected boolean Whether kernel is connected
---@field execution_state string Current state: "idle", "busy", "starting", "not started"
---@field running_kernel string|nil Name of running kernel

---Get kernel info for display (used by commands and keymaps)
---@param state NotebookState
---@return KernelInfo
function M.get_info(state)
  local kernel_state = state.kernel
  local python_path, python_source = discover_python(state.source_path, nil)

  return {
    kernelspec = M.get_kernel_name(state),
    python_path = python_path,
    python_source = python_source,
    connected = kernel_state and kernel_state.connected or false,
    execution_state = kernel_state and kernel_state.execution_state or 'not started',
    running_kernel = kernel_state and kernel_state.connected and kernel_state.kernel_name or nil,
  }
end

---Kernel info as display lines (used by :NotebookInfo and :NotebookKernelStatus)
---@param state NotebookState
---@return string[]
function M.format_info(state)
  local info = M.get_info(state)
  local lines = {
    'Kernelspec: ' .. info.kernelspec,
    'Python: ' .. (info.python_path or 'not found') .. ' (' .. info.python_source .. ')',
    'Connected: ' .. tostring(info.connected),
    'State: ' .. info.execution_state,
  }
  if info.running_kernel then
    table.insert(lines, 'Running kernel: ' .. info.running_kernel)
  end
  return lines
end

---Get statusline component for kernel status
---@param state NotebookState|nil
---@return string status Status string for statusline
---@return string hl_state State for highlight: "disconnected", "busy", "ready"
function M.statusline(state)
  local config = require('ipynb.config').get()
  if not config.kernel.show_status then
    return '', 'disconnected'
  end

  if not state then
    state = require('ipynb.state').get()
  end
  if not state then
    return '', 'disconnected'
  end

  local lang = state.shadow_lang or 'python' ---@diagnostic disable-line: undefined-field
  local icon = require('ipynb.visuals').get_language_icon(lang) or '󰌠'

  if state.kernel and state.kernel.connected then
    if state.kernel.execution_state == 'busy' then
      return icon .. ' BUSY', 'busy'
    else
      return icon .. ' IDLE', 'ready'
    end
  else
    return icon .. ' DISC', 'disconnected'
  end
end

---Get highlight group for statusline state (for lualine color option)
---@param hl_state string|nil State: "disconnected", "busy", "ready". If nil, auto-detects from current buffer.
---@return table color Lualine color table with fg from highlight group
function M.statusline_color(hl_state)
  if not hl_state then
    local _, state = M.statusline()
    hl_state = state
  end
  local hl_map = {
    disconnected = 'DiagnosticError',
    busy = 'DiagnosticWarn',
    ready = 'DiagnosticOk',
  }
  local hl_group = hl_map[hl_state] or 'Comment'

  local hl = vim.api.nvim_get_hl(0, { name = hl_group, link = false })
  if hl.fg then
    return { fg = string.format('#%06x', hl.fg) }
  end

  return {}
end

---Check if statusline component should be shown (for lualine cond)
---@return boolean
function M.statusline_visible()
  local config = require('ipynb.config').get()
  if not config.kernel.show_status then
    return false
  end
  return require('ipynb.state').get() ~= nil
end

---Request code completion from kernel
---@param state NotebookState
---@param code string Code to complete
---@param cursor_pos number Cursor position in code
---@param callback function Callback with completion results
function M.complete(state, code, cursor_pos, callback)
  if not state.kernel or not state.kernel.connected then
    callback(nil)
    return
  end

  state.kernel.callbacks.complete = callback
  send_command(state, {
    action = "complete",
    code = code,
    cursor_pos = cursor_pos,
  })
end

---Request variable/object inspection from kernel (language-agnostic)
---@param state NotebookState
---@param code string Code/identifier to inspect
---@param cursor_pos number|nil Cursor position (defaults to end of code)
---@param callback function Callback with inspect result
---@param request_id string|nil Optional request ID (auto-generated if not provided)
function M.inspect(state, code, cursor_pos, callback, request_id)
  if not state.kernel or not state.kernel.connected then
    callback({ found = false, data = {}, metadata = {} })
    return
  end

  cursor_pos = cursor_pos or #code
  request_id = request_id or (code .. "_" .. tostring(vim.loop.hrtime()))

  state.kernel.callbacks.inspect[request_id] = callback

  send_command(state, {
    action = "inspect",
    code = code,
    cursor_pos = cursor_pos,
    detail_level = 0,
    request_id = request_id,
  })
end

---Inspect multiple identifiers and collect results
---@param state NotebookState
---@param identifiers string[] List of identifiers to inspect
---@param callback function Callback with results
---@param timeout number|nil Timeout in ms (default 5000)
function M.inspect_batch(state, identifiers, callback, timeout)
  if not state.kernel or not state.kernel.connected then
    callback({})
    return
  end

  if #identifiers == 0 then
    callback({})
    return
  end

  timeout = timeout or 5000
  local results = {}
  local pending = #identifiers
  local completed = false

  local timer = vim.uv.new_timer()
  if timer then
    timer:start(timeout, 0, vim.schedule_wrap(function()
      if not completed then
        completed = true
        timer:stop()
        timer:close()
        callback(results)
      end
    end))
  end

  for _, ident in ipairs(identifiers) do
    local request_id = ident .. "_" .. vim.loop.hrtime()
    M.inspect(state, ident, #ident, function(reply)
      if completed then return end

      results[ident] = {
        found = reply.found,
        sections = reply.sections or {},
        data = reply.data or {},
        metadata = reply.metadata or {},
      }

      pending = pending - 1
      if pending == 0 then
        completed = true
        if timer then
          timer:stop()
          timer:close()
        end
        callback(results)
      end
    end, request_id)
  end
end

---Ping the kernel bridge to check responsiveness
---@param state NotebookState
---@param callback function Callback on pong
function M.ping(state, callback)
  if not state.kernel or not state.kernel.job_id then
    callback(false)
    return
  end

  state.kernel.callbacks.ping = function()
    callback(true)
  end

  vim.defer_fn(function()
    if state.kernel and state.kernel.callbacks.ping then
      state.kernel.callbacks.ping = nil
      callback(false)
    end
  end, 2000)

  send_command(state, { action = "ping" })
end

M.EXPORT_FORMATS = { 'html', 'pdf', 'webpdf', 'markdown', 'script', 'python', 'latex', 'rst', 'asciidoc', 'slides' }

---Export the saved notebook with `jupyter nbconvert` (same Python as the kernel)
---@param state NotebookState
---@param format string One of M.EXPORT_FORMATS ("python" is an alias for "script")
function M.export(state, format)
  if not vim.tbl_contains(M.EXPORT_FORMATS, format) then
    vim.notify('Unknown export format: ' .. tostring(format) .. ' (' .. table.concat(M.EXPORT_FORMATS, ', ') .. ')',
      vim.log.levels.ERROR)
    return
  end
  local python = discover_python(state.source_path, nil)
  if not python then
    vim.notify('Python not found for nbconvert', vim.log.levels.ERROR)
    return
  end
  if vim.bo[state.facade_buf].modified then
    require('ipynb.io').save_notebook(state.facade_buf)
  end
  local to = format == 'python' and 'script' or format
  vim.notify('Exporting to ' .. format .. '...', vim.log.levels.INFO)
  vim.system({ python, '-m', 'jupyter', 'nbconvert', '--to', to, state.source_path }, { text = true }, function(r)
    vim.schedule(function()
      if r.code ~= 0 then
        local msg = vim.trim(r.stderr or '')
        if msg:find('No module named') then
          msg = msg .. '\nInstall it with: ' .. python .. ' -m pip install nbconvert'
        end
        vim.notify('nbconvert failed:\n' .. msg, vim.log.levels.ERROR)
        return
      end
      local written = (r.stderr or ''):match('[Ww]riting %d+ bytes to ([^\r\n]+)')
      vim.notify('Exported: ' .. (written or state.source_path), vim.log.levels.INFO)
    end)
  end)
end

---List available Jupyter kernels
---@param notebook_path string|nil Path to notebook (for Python discovery)
---@param callback fun(kernels: table[]|nil, error: string|nil) Called with results
function M.list_kernels(notebook_path, callback)
  local python, source = discover_python(notebook_path, nil)
  if not python then
    callback(nil, 'Python not found in PATH or venv')
    return
  end

  local cmd = { python, '-m', 'jupyter', 'kernelspec', 'list', '--json' }

  vim.system(
    cmd,
    { text = true },
    function(result)
      vim.schedule(function()
        if result.code ~= 0 then
          local stderr = result.stderr or ''
          -- Trim and get first line of stderr for cleaner message
          stderr = stderr:gsub('^%s+', ''):gsub('%s+$', '')
          local first_line = stderr:match('^[^\n]*') or ''
          callback(nil, string.format(
            'jupyter command failed (python: %s [%s], exit: %d): %s',
            python, source, result.code, first_line
          ))
          return
        end

        local ok, data = pcall(vim.json.decode, result.stdout)
        if not ok or not data.kernelspecs then
          callback(nil, string.format(
            'Failed to parse kernel list (python: %s [%s])',
            python, source
          ))
          return
        end

        local kernels = {}
        for name, spec in pairs(data.kernelspecs) do
          table.insert(kernels, {
            name = name,
            display_name = spec.spec and spec.spec.display_name or name,
            language = spec.spec and spec.spec.language or nil,
          })
        end

        table.sort(kernels, function(a, b) return a.name < b.name end)
        callback(kernels, nil)
      end)
    end
  )
end

return M
