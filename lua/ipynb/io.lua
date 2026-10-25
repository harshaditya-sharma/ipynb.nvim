-- ipynb/io.lua - File I/O (ipynb ↔ facade conversion)
-- Files are written exactly the way Jupyter's nbformat writes them (sorted keys,
-- one-space indent, multi-line strings split into lists) so saving an untouched
-- notebook changes nothing and saved notebooks diff cleanly in git.

local M = {}

local state_mod = require('ipynb.state')

---Force an empty table to encode as a JSON object ({}) rather than an array ([])
---@param t table|nil
---@return table
local function ensure_dict(t)
  t = t or {}
  if next(t) == nil then
    return vim.empty_dict()
  end
  return t
end

---Convert JSON null to nil
---@param v any
---@return any
local function denull(v)
  if v == vim.NIL then
    return nil
  end
  return v
end

--------------------------------------------------------------------------------
-- Python-compatible line splitting and JSON encoding
--------------------------------------------------------------------------------

-- Single-byte line boundaries recognised by Python's str.splitlines()
local LINE_BREAK_BYTES = { [10] = true, [11] = true, [12] = true, [13] = true, [28] = true, [29] = true, [30] = true }

---Split a string like Python's str.splitlines(True) (line endings kept)
---@param s string
---@return string[]
function M.splitlines(s)
  local lines = {}
  local start, i, n = 1, 1, #s
  while i <= n do
    local b = s:byte(i)
    local stop
    if b == 13 and s:byte(i + 1) == 10 then
      stop = i + 1
    elseif LINE_BREAK_BYTES[b] then
      stop = i
    elseif b == 0xC2 and s:byte(i + 1) == 0x85 then -- U+0085 NEXT LINE
      stop = i + 1
    elseif b == 0xE2 and s:byte(i + 1) == 0x80 and (s:byte(i + 2) == 0xA8 or s:byte(i + 2) == 0xA9) then
      stop = i + 2 -- U+2028 LINE SEPARATOR, U+2029 PARAGRAPH SEPARATOR
    end
    if stop then
      lines[#lines + 1] = s:sub(start, stop)
      start = stop + 1
      i = stop + 1
    else
      i = i + 1
    end
  end
  if start <= n then
    lines[#lines + 1] = s:sub(start)
  end
  return lines
end

local JSON_ESCAPES = { ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }

---Encode a string like Python's json.dumps(ensure_ascii=False)
---@param s string
---@return string
local function encode_string(s)
  return '"' .. s:gsub('[%c"\\]', function(c)
    local b = c:byte()
    if JSON_ESCAPES[c] then
      return JSON_ESCAPES[c]
    elseif b < 32 then
      return string.format('\\u%04x', b)
    end
    return c -- DEL (127) is not escaped by Python
  end) .. '"'
end

---Encode a number like Python's json.dumps (shortest round-trip repr)
---@param n number
---@return string
local function encode_number(n)
  if n ~= n or n == math.huge or n == -math.huge then
    return n ~= n and 'NaN' or (n > 0 and 'Infinity' or '-Infinity')
  end
  if n == math.floor(n) and math.abs(n) < 2 ^ 53 then
    return string.format('%d', n)
  end
  for precision = 15, 17 do
    local s = string.format('%.' .. precision .. 'g', n)
    if tonumber(s) == n then
      return s
    end
  end
  return string.format('%.17g', n)
end

---Byte-wise string comparison (Python sorts keys by code point; UTF-8 byte
---order matches, while Lua's `<` uses the locale's collation)
---@param a string
---@param b string
---@return boolean
local function bytes_less(a, b)
  local n = math.min(#a, #b)
  for i = 1, n do
    local x, y = a:byte(i), b:byte(i)
    if x ~= y then
      return x < y
    end
  end
  return #a < #b
end

---Encode a Lua value as nbformat-style JSON (sort_keys=True, indent=1)
---@param value any
---@param indent string
---@param out string[]
local function encode_value(value, indent, out)
  local t = type(value)
  if value == nil or value == vim.NIL then
    out[#out + 1] = 'null'
  elseif t == 'boolean' then
    out[#out + 1] = tostring(value)
  elseif t == 'number' then
    out[#out + 1] = encode_number(value)
  elseif t == 'string' then
    out[#out + 1] = encode_string(value)
  elseif t == 'table' then
    local inner = indent .. ' '
    if next(value) == nil then
      out[#out + 1] = getmetatable(value) == getmetatable(vim.empty_dict()) and '{}' or '[]'
    elseif vim.islist(value) then
      out[#out + 1] = '[\n'
      for i, item in ipairs(value) do
        out[#out + 1] = inner
        encode_value(item, inner, out)
        out[#out + 1] = i < #value and ',\n' or '\n'
      end
      out[#out + 1] = indent .. ']'
    else
      local keys = {}
      for k in pairs(value) do
        keys[#keys + 1] = tostring(k)
      end
      table.sort(keys, bytes_less)
      out[#out + 1] = '{\n'
      for i, k in ipairs(keys) do
        local v = value[k]
        if v == nil then
          v = value[tonumber(k)]
        end
        out[#out + 1] = inner .. encode_string(k) .. ': '
        encode_value(v, inner, out)
        out[#out + 1] = i < #keys and ',\n' or '\n'
      end
      out[#out + 1] = indent .. '}'
    end
  else
    error('cannot encode ' .. t .. ' as JSON')
  end
end

---Encode a notebook table exactly like nbformat.writes()
---@param value table
---@return string
function M.encode_json(value)
  local out = {}
  encode_value(value, '', out)
  return table.concat(out)
end

---Split text mime values in a bundle into line lists (nbformat's _split_mimebundle)
---@param data table|nil
---@return table|nil
local function split_mimebundle(data)
  if type(data) ~= 'table' then
    return data
  end
  local result = vim.deepcopy(data)
  for key, value in pairs(result) do
    if type(value) == 'string' and (key:sub(1, 5) == 'text/' or key == 'application/javascript' or key == 'image/svg+xml') then
      result[key] = M.splitlines(value)
    end
  end
  return result
end

---Prepare outputs for writing (nbformat split_lines for outputs)
---@param outputs table[]|nil
---@return table[]
local function split_outputs(outputs)
  local result = {}
  for i, output in ipairs(outputs or {}) do
    local copy = vim.deepcopy(output)
    copy.transient = nil -- runtime-only (display ids); nbformat strips it too
    if copy.output_type == 'stream' and type(copy.text) == 'string' then
      copy.text = M.splitlines(copy.text)
    elseif copy.output_type == 'execute_result' or copy.output_type == 'display_data' then
      copy.data = split_mimebundle(copy.data)
      copy.metadata = ensure_dict(copy.metadata)
    end
    result[i] = copy
  end
  return result
end

--------------------------------------------------------------------------------
-- Notebook files
--------------------------------------------------------------------------------

---@class NotebookFileFormat
---@field crlf boolean Original file used CRLF line endings

---Create default metadata for a new notebook
---@param kernel_name string|nil Kernel name (default: "python3")
---@return table metadata
function M.default_metadata(kernel_name)
  kernel_name = kernel_name or 'python3'
  return {
    kernelspec = {
      display_name = 'Python 3',
      language = 'python',
      name = kernel_name,
    },
    language_info = {
      name = 'python',
    },
    nbformat = 4,
    nbformat_minor = 5,
  }
end

---Create a default empty notebook structure
---@param kernel_name string|nil Kernel name (default: "python3")
---@return Cell[], table metadata, table<string, boolean> cell_ids
function M.create_empty_notebook(kernel_name)
  local id = state_mod.generate_cell_id()
  local cell_ids = { [id] = true }
  local cells = {
    {
      id = id,
      type = 'code',
      source = '',
      metadata = {},
      outputs = {},
    },
  }
  return cells, M.default_metadata(kernel_name), cell_ids
end

---Parse a .ipynb JSON file into cells
---Auto-upgrades to nbformat 4.5 and ensures all loaded cells have unique, valid
---IDs (per JEP 62), repairing missing, duplicate or malformed IDs on read.
---@param path string Path to .ipynb file
---@return Cell[], table metadata, table<string, boolean> cell_ids, NotebookFileFormat format
function M.read_ipynb(path)
  local f, open_err = io.open(path, 'rb')
  if not f then
    error('Failed to read notebook: ' .. tostring(open_err))
  end
  local json_str = f:read('*a')
  f:close()

  local ok, notebook = pcall(vim.json.decode, json_str)
  if not ok or type(notebook) ~= 'table' then
    error('Failed to parse notebook JSON: ' .. tostring(notebook))
  end

  -- Assign IDs against a live "already used" set so malformed notebooks with
  -- duplicate IDs are repaired during load. The first valid occurrence wins.
  -- IDs must match the nbformat pattern: they are also used in cache file names.
  local existing_ids = {}
  local cells = {}
  for _, nb_cell in ipairs(notebook.cells or {}) do
    local source = denull(nb_cell.source) or ''
    if type(source) == 'table' then
      source = table.concat(source, '')
    end

    local id = nb_cell.id
    if not state_mod.is_valid_cell_id(id) or existing_ids[id] then
      id = state_mod.generate_cell_id(existing_ids)
    end
    existing_ids[id] = true

    table.insert(cells, {
      id = id,
      type = nb_cell.cell_type or 'code',
      source = source,
      metadata = denull(nb_cell.metadata) or {},
      outputs = denull(nb_cell.outputs),
      execution_count = denull(nb_cell.execution_count),
      attachments = denull(nb_cell.attachments),
    })
  end

  -- Keep ALL notebook metadata (Colab, Kaggle, Databricks, widgets, etc.)
  local metadata = vim.deepcopy(denull(notebook.metadata) or {})

  -- Auto-upgrade to nbformat 4.5 (cell IDs required per JEP 62)
  metadata.nbformat = notebook.nbformat or 4
  metadata.nbformat_minor = math.max(notebook.nbformat_minor or 0, 5)

  return cells, metadata, existing_ids, { crlf = json_str:find('\r\n', 1, true) ~= nil }
end

---Write cells back to .ipynb format
---@param path string Path to write to
---@param cells Cell[]
---@param metadata table|nil Notebook metadata
---@param format NotebookFileFormat|nil Original file format to preserve
function M.write_ipynb(path, cells, metadata, format)
  -- Collect existing IDs for collision avoidance (safety net for missing IDs)
  local existing_ids = {}
  for _, cell in ipairs(cells) do
    if cell.id then
      existing_ids[cell.id] = true
    end
  end

  local nb_cells = {}
  for _, cell in ipairs(cells) do
    local id = cell.id
    if not id then
      id = state_mod.generate_cell_id(existing_ids)
      existing_ids[id] = true
    end

    local nb_cell = {
      id = id,
      cell_type = cell.type,
      source = M.splitlines(cell.source or ''),
      metadata = ensure_dict(cell.metadata),
    }

    if cell.type == 'code' then
      nb_cell.outputs = split_outputs(cell.outputs)
      nb_cell.execution_count = cell.execution_count or vim.NIL
    elseif cell.attachments then
      local attachments = {}
      for name, bundle in pairs(cell.attachments) do
        attachments[name] = split_mimebundle(bundle)
      end
      nb_cell.attachments = ensure_dict(attachments)
    end

    table.insert(nb_cells, nb_cell)
  end

  -- Only nbformat/nbformat_minor are top-level; everything else goes in metadata
  local nb_metadata = {}
  for k, v in pairs(metadata or {}) do
    if k ~= 'nbformat' and k ~= 'nbformat_minor' then
      nb_metadata[k] = v
    end
  end

  local notebook = {
    cells = nb_cells,
    metadata = ensure_dict(nb_metadata),
    nbformat = metadata and metadata.nbformat or 4,
    nbformat_minor = metadata and metadata.nbformat_minor or 5,
  }

  local text = M.encode_json(notebook) .. '\n'
  if format and format.crlf then
    text = text:gsub('\n', '\r\n')
  end

  -- Write to a temp file first so a failed write never truncates the notebook
  local tmp = path .. '.ipynb-nvim-tmp'
  local f, err = io.open(tmp, 'wb')
  if not f then
    error('Failed to write notebook: ' .. tostring(err))
  end
  f:write(text)
  f:close()
  local renamed, rename_err = vim.uv.fs_rename(tmp, path)
  if not renamed then
    os.remove(tmp)
    error('Failed to write notebook: ' .. tostring(rename_err))
  end
end

--------------------------------------------------------------------------------
-- Facade format
--------------------------------------------------------------------------------

-- Source lines that look like a cell marker (optionally already escaped with
-- leading backslashes) get one extra backslash in the facade, so cell content
-- can never be mistaken for a cell boundary.
local MARKER_LIKE = '^\\*# <</?ipynb_nvim'

---Escape source lines for display in the facade buffer
---@param lines string[]
---@return string[]
function M.escape_lines(lines)
  local result = {}
  for i, line in ipairs(lines) do
    result[i] = line:find(MARKER_LIKE) and ('\\' .. line) or line
  end
  return result
end

---Reverse escape_lines (facade lines back to source lines)
---@param lines string[]
---@return string[]
function M.unescape_lines(lines)
  local result = {}
  for i, line in ipairs(lines) do
    result[i] = (line:sub(1, 1) == '\\' and line:find(MARKER_LIKE)) and line:sub(2) or line
  end
  return result
end

---Convert cells to facade format with explicit start/end delimiters
---Uses custom format: # <<ipynb_nvim:code>>, # <<ipynb_nvim:markdown>>, # <<ipynb_nvim:raw>>
---End marker: # <</ipynb_nvim>>
---@param cells Cell[]
---@return string[]
function M.cells_to_jupytext(cells)
  local lines = {}

  for i, cell in ipairs(cells) do
    -- Add blank line between cells (except before first)
    if i > 1 then
      table.insert(lines, '')
    end

    table.insert(lines, '# <<ipynb_nvim:' .. cell.type .. '>>')
    vim.list_extend(lines, M.escape_lines(vim.split(cell.source, '\n', { plain = true })))
    table.insert(lines, '# <</ipynb_nvim>>')
  end

  -- Add trailing blank line so last cell output can be scrolled into view
  table.insert(lines, '')

  return lines
end

---Parse facade format back into cells
---@param lines string[]
---@return Cell[]
function M.jupytext_to_cells(lines)
  local cells = {}
  local current_cell = nil
  local content_lines = {}

  local function save_current_cell()
    if current_cell then
      -- Join content lines - trailing newline represents a blank last line
      current_cell.source = table.concat(M.unescape_lines(content_lines), '\n')
      table.insert(cells, current_cell)
    end
  end

  for _, line in ipairs(lines) do
    local cell_type = line:match('^# <<ipynb_nvim:(%w+)>>$')

    if cell_type then
      save_current_cell()
      current_cell = {
        type = cell_type,
        source = '',
        metadata = {},
        outputs = cell_type == 'code' and {} or nil,
      }
      content_lines = {}
    elseif line == '# <</ipynb_nvim>>' then
      save_current_cell()
      current_cell = nil
      content_lines = {}
    elseif current_cell then
      table.insert(content_lines, line)
    end
  end

  -- Save last cell if not properly closed
  save_current_cell()

  return cells
end

--------------------------------------------------------------------------------
-- Buffer integration
--------------------------------------------------------------------------------

---Open a notebook file (or create new if doesn't exist)
---@param buf number Buffer to populate
---@param path string Path to .ipynb file
function M.open_notebook(buf, path)
  local cells, metadata, cell_ids, format

  if vim.fn.filereadable(path) == 1 then
    cells, metadata, cell_ids, format = M.read_ipynb(path)
  else
    cells, metadata, cell_ids = M.create_empty_notebook()
    vim.notify('New notebook: ' .. vim.fn.fnamemodify(path, ':t'), vim.log.levels.INFO)
  end

  local state = state_mod.create(path)
  state.cells = cells
  state.metadata = metadata
  state.cell_ids = cell_ids
  state.file_format = format

  require('ipynb.facade').create(state, buf)
  state_mod.register(state)

  require('ipynb.cells').place_markers(state)

  local visuals = require('ipynb.visuals')
  visuals.render_all(state)
  -- Setup active cell tracking (throttled, once per buffer)
  visuals.setup_active_tracking(state)

  -- Render existing outputs (including images)
  require('ipynb.output').render_all(state)

  require('ipynb.keymaps').setup_facade_keymaps(state)
  require('ipynb.commands').setup_buffer(state)
end

---Save a notebook file
---@param buf number Buffer number
---@param path string|nil Path to save to (defaults to source_path)
function M.save_notebook(buf, path)
  local state = state_mod.get(buf)
  if not state then
    vim.notify('No notebook state found for buffer', vim.log.levels.ERROR)
    return
  end

  path = path or state.source_path

  local cells_mod = require('ipynb.cells')
  cells_mod.sync_cells_from_facade(state)
  cells_mod.place_markers(state) -- Refresh extmarks after sync

  local ok, err = pcall(M.write_ipynb, path, state.cells, state.metadata, state.file_format)
  if not ok then
    vim.notify(tostring(err), vim.log.levels.ERROR)
    return
  end

  vim.bo[buf].modified = false
  vim.notify('Saved notebook: ' .. path, vim.log.levels.INFO)
end

return M
