-- ipynb/output.lua - Cell output rendering
-- Renders output as virtual lines (virt_lines extmarks)

local M = {}

local output_ns = vim.api.nvim_create_namespace('notebook_outputs')
local ansi = require('ipynb.ansi')
local termimage = require('ipynb.termimage')

---Convert Jupyter text to string (handles both string and array formats)
---@param text string|table|nil
---@return string
local function to_string(text)
  if type(text) == 'table' then
    return table.concat(text, '')
  end
  return type(text) == 'string' and text or ''
end

---Apply terminal-style stream controls to text.
---Only the last line can still change (\r and \b never cross a newline), so
---just that tail is processed; earlier output is never re-scanned. The cursor
---is a codepoint offset into the tail so progress bars made of block
---characters overwrite one character at a time instead of one UTF-8 byte.
---@param text string Existing normalized text
---@param cursor number Cursor offset within the last line (0-based)
---@param new_text string Incoming stream text
---@return string text Normalized text
---@return number cursor Updated cursor offset within the last line
local function process_stream_text(text, cursor, new_text)
  local head, tail = text:match('^(.*\n)(.*)$')
  if not head then
    head, tail = '', text
  end
  local done = { head }
  local chars = vim.fn.str2list(tail, true)
  cursor = math.max(0, math.min(cursor, #chars))

  for _, char in ipairs(vim.fn.str2list(new_text, true)) do
    if char == 8 then -- \b: move back over the previous character
      if cursor > 0 then
        table.remove(chars, cursor)
        cursor = cursor - 1
      end
    elseif char == 13 then -- \r: return to the beginning of the current line
      cursor = 0
    elseif char == 10 then -- \n: finish the current logical line
      done[#done + 1] = vim.fn.list2str(chars, true) .. '\n'
      chars = {}
      cursor = 0
    else
      cursor = cursor + 1
      chars[cursor] = char
    end
  end

  done[#done + 1] = vim.fn.list2str(chars, true)
  return table.concat(done), cursor
end

---Append an output to a cell, coalescing adjacent streams of the same kind.
---Carriage returns update the current logical line, matching Jupyter frontend
---behavior for progress bars and other terminal-style stream output.
---@param cell Cell
---@param output Output
function M.append_output(cell, output)
  cell.outputs = cell.outputs or {}

  if output.output_type ~= 'stream' then
    table.insert(cell.outputs, output)
    cell._stream_state = nil
    return
  end

  local previous = cell.outputs[#cell.outputs]
  local can_coalesce = previous
    and previous.output_type == 'stream'
    and previous.name == output.name

  if can_coalesce then
    local stream_state = cell._stream_state
    local cursor
    if stream_state and stream_state.output_index == #cell.outputs then
      cursor = stream_state.cursor
    else
      -- Recover sensibly for pre-existing output or transient state loss.
      local normalized
      normalized, cursor = process_stream_text('', 0, to_string(previous.text))
      previous.text = normalized
    end

    previous.text, cursor = process_stream_text(
      to_string(previous.text),
      cursor,
      to_string(output.text)
    )
    cell._stream_state = { output_index = #cell.outputs, cursor = cursor }
    return
  end

  local cursor
  output.text, cursor = process_stream_text('', 0, to_string(output.text))
  table.insert(cell.outputs, output)
  cell._stream_state = { output_index = #cell.outputs, cursor = cursor }
end

--------------------------------------------------------------------------------
-- Rich output as text
--------------------------------------------------------------------------------

local ENTITIES = { amp = '&', lt = '<', gt = '>', quot = '"', apos = "'", nbsp = ' ', ['#39'] = "'" }

---@param s string
---@return string
local function decode_entities(s)
  return (s:gsub('&(#?%w+);', function(name)
    if ENTITIES[name] then
      return ENTITIES[name]
    end
    local code = name:match('^#x(%x+)$') and tonumber(name:sub(3), 16) or (name:match('^#(%d+)$') and tonumber(name:sub(2)))
    if code and code < 0x110000 then
      return vim.fn.nr2char(code, true)
    end
  end))
end

---@param cell_html string
---@return string
local function html_inline_text(cell_html)
  return vim.trim(decode_entities((cell_html:gsub('<[^>]*>', ''):gsub('%s+', ' '))))
end

---Render <table> markup as an aligned text table
---@param table_html string
---@return string[]
local function html_table(table_html)
  local rows, widths = {}, {}
  for row in table_html:gmatch('<tr[^>]*>(.-)</tr>') do
    local cols = {}
    for _, cell in row:gmatch('<t([hd])[^>]*>(.-)</t[hd]>') do
      cols[#cols + 1] = html_inline_text(cell)
    end
    if #cols > 0 then
      rows[#rows + 1] = cols
      for i, c in ipairs(cols) do
        widths[i] = math.max(widths[i] or 0, vim.fn.strdisplaywidth(c))
      end
    end
  end
  local lines = {}
  for _, cols in ipairs(rows) do
    local parts = {}
    for i, c in ipairs(cols) do
      parts[i] = c .. string.rep(' ', widths[i] - vim.fn.strdisplaywidth(c))
    end
    lines[#lines + 1] = vim.trim(table.concat(parts, '  '))
  end
  return lines
end

---Very small HTML -> text conversion for display (tables become aligned text)
---@param html string
---@return string
function M.html_to_text(html)
  html = html:gsub('<!%-%-.-%-%->', ''):gsub('<script.-</script>', ''):gsub('<style.-</style>', '')
  local out = {}
  local pos = 1
  while true do
    local s, e = html:find('<table.-</table>', pos)
    local before = html:sub(pos, (s or #html + 1) - 1)
    before = before:gsub('<br%s*/?>', '\n'):gsub('</p>', '\n'):gsub('</div>', '\n'):gsub('</h%d>', '\n'):gsub('<li[^>]*>', '\n• ')
    before = decode_entities((before:gsub('<[^>]*>', '')))
    for line in (before .. '\n'):gmatch('([^\n]*)\n') do
      line = vim.trim((line:gsub('%s+', ' ')))
      if line ~= '' then
        out[#out + 1] = line
      end
    end
    if not s then
      break
    end
    vim.list_extend(out, html_table(html:sub(s, e)))
    pos = e + 1
  end
  return table.concat(out, '\n')
end

-- Placeholder reprs IPython uses when the real content is in another mime type
local function is_placeholder(text)
  return text:match('^<IPython%.core%.display%.[%w_]+ object>$') ~= nil
    or text:match('^<IPython%.lib%.display%.[%w_]+ object>$') ~= nil
end

---Best plain-text form of a mime bundle, like a text-only Jupyter frontend
---@param data table|nil
---@return string|nil text
---@return string|nil mime The mime type the text came from
function M.bundle_text(data)
  if type(data) ~= 'table' then
    return nil
  end
  local plain = data['text/plain'] and to_string(data['text/plain'])
  if plain and not is_placeholder(plain) then
    return plain, 'text/plain'
  end
  for _, mime in ipairs({ 'text/markdown', 'text/latex' }) do
    if data[mime] then
      return to_string(data[mime]), mime
    end
  end
  if data['text/html'] then
    return M.html_to_text(to_string(data['text/html'])), 'text/html'
  end
  if data['application/json'] ~= nil then
    return vim.inspect(data['application/json']), 'application/json'
  end
  if plain then
    return plain, 'text/plain'
  end
  local mimes = vim.tbl_keys(data)
  table.sort(mimes)
  return nil, mimes[1]
end

---Text lines of one output (without the trailing newline Jupyter adds)
---@param output table
---@return string[] lines
---@return string hl Highlight group
local function output_lines(output)
  local kind = output.output_type
  local text, hl = '', 'IpynbOutput'
  if kind == 'stream' then
    text = to_string(output.text)
    if output.name == 'stderr' then
      hl = 'IpynbOutputStderr'
    end
  elseif kind == 'error' then
    hl = 'IpynbOutputError'
    local tb = {}
    for _, line in ipairs(output.traceback or {}) do
      tb[#tb + 1] = line
    end
    text = #tb > 0 and table.concat(tb, '\n') or ((output.ename or 'Error') .. ': ' .. (output.evalue or ''))
  elseif kind == 'execute_result' or kind == 'display_data' then
    local mime
    text, mime = M.bundle_text(output.data)
    if not text then
      text = '[' .. (mime or 'empty') .. ' output]'
    end
  end
  if text:sub(-1) == '\n' then
    text = text:sub(1, -2)
  end
  return vim.split(text, '\n', { plain = true }), hl
end

---Render a single output item as virtual line specs
---@param output table Output object
---@return table[] Virtual line specs
function M.render_output(output)
  local virt = {}
  local has_image, mime = require('ipynb.images').get_image_data(output)
  if not has_image or M.bundle_text(output.data) then
    local lines, hl = output_lines(output)
    for i, line in ipairs(lines) do
      local chunks = ansi.chunks(line, hl)
      if i == 1 and output.output_type == 'execute_result' then
        table.insert(chunks, 1, { 'Out: ', 'IpynbExecCount' })
      end
      virt[i] = chunks
    end
  end
  if has_image then
    -- No inline image here: say what it is and how to view it
    table.insert(virt, { { '[' .. (mime or 'image') .. ': ' .. M.open_hint() .. ']', 'Comment' } })
  end
  return virt
end

---Key hint for opening rich output outside Neovim
---@return string
function M.open_hint()
  local key = require('ipynb.config').get().keymaps.open_output_external
  return key and ('open with ' .. key) or 'open with :NotebookOpenOutput'
end

---Build plain text lines from cell outputs (for float buffer)
---@param cell table Cell with outputs
---@return string[] lines Plain text lines
function M.build_output_text(cell)
  local lines = {}
  for _, output in ipairs(cell.outputs or {}) do
    local out_lines = output_lines(output)
    for i, line in ipairs(out_lines) do
      line = ansi.strip(line)
      if i == 1 and output.output_type == 'execute_result' then
        line = 'Out: ' .. line
      end
      lines[#lines + 1] = line
    end
  end
  return lines
end

---Render outputs for a cell as virtual lines with true text/image interleaving
---All outputs (text and images) are combined into a single extmark's virt_lines
---This guarantees correct ordering: text1 → img1 → text2 → img2 → etc.
---@param state NotebookState
---@param cell_idx number
function M.render_outputs(state, cell_idx)
  local cell = state.cells[cell_idx]
  if not cell then
    return
  end

  local cells_mod = require('ipynb.cells')
  local images_mod = require('ipynb.images')
  local config = require('ipynb.config').get().output or {}
  local _, end_line = cells_mod.get_cell_range(state, cell_idx)

  -- Clear old extmark for this cell
  if cell.output_extmark then
    pcall(vim.api.nvim_buf_del_extmark, state.facade_buf, output_ns, cell.output_extmark)
    cell.output_extmark = nil
  end
  if cell.id then
    images_mod.clear_images(state, cell.id)
    termimage.clear(state.facade_buf, cell.id)
  end
  if not end_line or not cell.outputs or #cell.outputs == 0 then
    return
  end

  -- Output separator
  local virt_lines = { { { '┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄', 'IpynbBorder' } } }

  if require('ipynb.cellmeta').is_outputs_hidden(cell) then
    local n = #cell.outputs
    table.insert(virt_lines, { { string.format('⋯ %d output%s hidden', n, n == 1 and '' or 's'), 'Comment' } })
  else
    local max_lines = config.max_lines or 0
    local text_lines, dropped = 0, 0
    local image_index = 0
    for _, output in ipairs(cell.outputs) do
      local has_image, mime, image_data, is_text = images_mod.get_image_data(output)
      local term_lines
      if has_image and not images_mod.supports_placeholders() and termimage.backend() and mime ~= 'application/pdf' then
        -- Sixel / iTerm2: reserve rows now, draw over them after Neovim redraws
        local bytes = is_text and image_data or images_mod._base64_decode(image_data)
        term_lines = bytes and termimage.reserve(state, cell, bytes, #virt_lines + 1, M.text_width(state))
      end
      if term_lines then
        vim.list_extend(virt_lines, term_lines)
      elseif has_image and images_mod.supports_placeholders() then
        image_index = image_index + 1
        local img_lines = images_mod.get_image_virt_lines(state, cell, output, image_index)
        if img_lines then
          vim.list_extend(virt_lines, img_lines)
        else
          table.insert(virt_lines, { { '[image failed to load: ' .. M.open_hint() .. ']', 'Comment' } })
        end
      else
        for _, line in ipairs(M.render_output(output)) do
          if max_lines > 0 and text_lines >= max_lines then
            dropped = dropped + 1
          else
            text_lines = text_lines + 1
            table.insert(virt_lines, line)
          end
        end
      end
    end
    if dropped > 0 then
      local key = require('ipynb.config').get().keymaps.open_output
      table.insert(virt_lines, { {
        string.format('⋯ %d more line%s (%s)', dropped, dropped == 1 and '' or 's',
          key and ('see all with ' .. key) or ':NotebookOutput'),
        'Comment',
      } })
    end
  end

  -- Create single extmark with all virt_lines (text + images interleaved)
  cell.output_extmark = vim.api.nvim_buf_set_extmark(state.facade_buf, output_ns, end_line, 0, {
    virt_lines = virt_lines,
    undo_restore = false,
    strict = false,
  })
  if termimage.backend() then
    termimage.setup_autocmds()
    termimage.redraw({ force = true })
  end
end

---Usable text width of the window showing the notebook (for image sizing)
---@param state NotebookState
---@return number
function M.text_width(state)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == state.facade_buf then
      local info = vim.fn.getwininfo(win)[1] or {}
      return vim.api.nvim_win_get_width(win) - (info.textoff or 0) - 2
    end
  end
  return 78
end

local EXTERNAL_MIMES = {
  { 'image/png', 'png', true }, { 'image/jpeg', 'jpg', true }, { 'image/gif', 'gif', true },
  { 'image/webp', 'webp', true }, { 'application/pdf', 'pdf', true },
  { 'image/svg+xml', 'svg', false }, { 'text/html', 'html', false },
  { 'application/vnd.plotly.v1+json', 'html', false },
}

---Make a standalone HTML page for rich output that needs a browser
---@param mime string
---@param value any
---@return string
local function html_page(mime, value)
  local body
  if mime == 'application/vnd.plotly.v1+json' then
    local spec = type(value) == 'table' and value or {}
    body = '<div id="plot" style="width:100%;height:95vh"></div>'
      .. '<script src="https://cdn.plot.ly/plotly-2.35.2.min.js"></script>'
      .. '<script>var s=' .. vim.json.encode(spec) .. ';Plotly.newPlot("plot",s.data||[],s.layout||{},s.config||{});</script>'
  else
    body = to_string(value)
  end
  return '<!doctype html><html><head><meta charset="utf-8"><title>Notebook output</title></head><body>'
    .. body .. '</body></html>'
end

---Open an image/HTML/PDF/plot output of the cell at cursor in the system
---viewer or browser (for terminals that can't show it inline)
---@param state NotebookState
---@param cell_idx number|nil
function M.open_external(state, cell_idx)
  if not cell_idx then
    cell_idx = require('ipynb.cells').get_cell_at_line(state, vim.api.nvim_win_get_cursor(0)[1] - 1)
  end
  local cell = cell_idx and state.cells[cell_idx]
  if not cell then
    return
  end

  local choices = {}
  for out_idx, output in ipairs(cell.outputs or {}) do
    if type(output.data) == 'table' then
      for _, spec in ipairs(EXTERNAL_MIMES) do
        local mime, ext, base64 = spec[1], spec[2], spec[3]
        if output.data[mime] ~= nil then
          table.insert(choices, { mime = mime, ext = ext, base64 = base64, value = output.data[mime], n = out_idx })
          break -- one viewer per output: the richest format
        end
      end
    end
  end
  if #choices == 0 then
    vim.notify('No image, HTML or plot output in this cell', vim.log.levels.INFO)
    return
  end

  local function open(choice)
    local dir = require('ipynb.config').get().images.cache_dir or (vim.fn.stdpath('cache') .. '/ipynb.nvim')
    vim.fn.mkdir(dir, 'p')
    local content
    if choice.base64 then
      content = require('ipynb.images')._base64_decode(to_string(choice.value))
    elseif choice.ext == 'html' then
      content = html_page(choice.mime, choice.value)
    else
      content = to_string(choice.value)
    end
    if not content then
      vim.notify('Could not decode ' .. choice.mime .. ' output', vim.log.levels.ERROR)
      return
    end
    local safe_id = (cell.id or 'cell'):gsub('[^%w_-]', '_')
    local path = string.format('%s/%s-out%d.%s', dir, safe_id, choice.n, choice.ext)
    local f = io.open(path, 'wb')
    if not f then
      vim.notify('Could not write ' .. path, vim.log.levels.ERROR)
      return
    end
    f:write(content)
    f:close()
    local _, err = vim.ui.open(path)
    if err then
      vim.notify('Could not open ' .. path .. ': ' .. err, vim.log.levels.ERROR)
    end
  end

  if #choices == 1 then
    open(choices[1])
  else
    vim.ui.select(choices, {
      prompt = 'Open output',
      format_item = function(c) return string.format('output %d: %s', c.n, c.mime) end,
    }, function(choice)
      if choice then
        open(choice)
      end
    end)
  end
end

---Toggle "hide outputs" for the cell at cursor; saved like JupyterLab does
---@param state NotebookState
function M.toggle_outputs_hidden(state)
  local cellmeta = require('ipynb.cellmeta')
  local idx, cell = require('ipynb.cells').get_cell_at_line(state, vim.api.nvim_win_get_cursor(0)[1] - 1)
  if not cell or cell.type ~= 'code' then
    return
  end
  cellmeta.set_outputs_hidden(cell, not cellmeta.is_outputs_hidden(cell))
  M.render_outputs(state, idx)
  vim.bo[state.facade_buf].modified = true
end

---Clear outputs for a cell
---@param state NotebookState
---@param cell_idx number
function M.clear_outputs(state, cell_idx)
  local cell = state.cells[cell_idx]
  if not cell then
    return
  end

  local images_mod = require('ipynb.images')

  -- Clear images first (using cell.id)
  if cell.id then
    images_mod.clear_images(state, cell.id)
    termimage.clear(state.facade_buf, cell.id)
  end

  -- Clear output extmark
  if cell.output_extmark then
    pcall(vim.api.nvim_buf_del_extmark, state.facade_buf, output_ns, cell.output_extmark)
    cell.output_extmark = nil
  end

  cell.outputs = {}
  cell._stream_state = nil
end

---Clear all outputs
---@param state NotebookState
function M.clear_all_outputs(state)
  local images_mod = require('ipynb.images')

  -- Clear all images first
  images_mod.clear_all_images(state)

  for i, _ in ipairs(state.cells) do
    M.clear_outputs(state, i)
  end
end

---Render all cell outputs
---@param state NotebookState
function M.render_all(state)
  -- Render each cell's outputs fully (including images) before moving to next cell
  -- This maintains correct text/image interleaving within each cell
  for i, cell in ipairs(state.cells) do
    if cell.type == 'code' and cell.outputs and #cell.outputs > 0 then
      M.render_outputs(state, i, false)  -- render images synchronously
    end
  end
end

---Open cell output in a floating buffer for copying/inspection
---@param state NotebookState
---@param cell_idx number|nil Cell index (nil = current cell)
function M.open_output_float(state, cell_idx)
  local cells_mod = require('ipynb.cells')

  -- Get current cell if not specified
  if not cell_idx then
    local cursor_line = vim.api.nvim_win_get_cursor(0)[1] - 1
    cell_idx = cells_mod.get_cell_at_line(state, cursor_line)
  end

  if not cell_idx then
    vim.notify('No cell at cursor', vim.log.levels.WARN)
    return
  end

  local cell = state.cells[cell_idx]
  if not cell then
    vim.notify('Cell not found', vim.log.levels.WARN)
    return
  end

  if not cell.outputs or #cell.outputs == 0 then
    vim.notify('No output for this cell', vim.log.levels.INFO)
    return
  end

  -- Build plain text output
  local lines = M.build_output_text(cell)
  if #lines == 0 then
    vim.notify('No text output for this cell', vim.log.levels.INFO)
    return
  end

  -- Create buffer for output
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  -- Buffer settings
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = 'notebook_output'

  -- Calculate float dimensions
  local width = math.min(100, math.floor(vim.o.columns * 0.8))
  local height = math.min(#lines + 2, math.floor(vim.o.lines * 0.7))

  -- Find max line width for better sizing
  local max_line_width = 0
  for _, line in ipairs(lines) do
    max_line_width = math.max(max_line_width, vim.fn.strdisplaywidth(line))
  end
  width = math.min(math.max(width, max_line_width + 4), vim.o.columns - 4)

  -- Center the float
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  -- Open float window
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    row = row,
    col = col,
    width = width,
    height = height,
    style = 'minimal',
    border = 'rounded',
    title = ' Cell Output [' .. cell_idx .. '] ',
    title_pos = 'center',
  })

  -- Window settings
  vim.wo[win].wrap = true
  vim.wo[win].cursorline = true
  vim.wo[win].number = true

  -- Keymaps for the output float
  local close = function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  local opts = { buffer = buf, silent = true, nowait = true }
  vim.keymap.set('n', 'q', close, opts)
  vim.keymap.set('n', '<Esc>', close, opts)
  vim.keymap.set('n', '<C-c>', close, opts)

  -- Yank all output
  vim.keymap.set('n', 'Y', function()
    local all_text = table.concat(lines, '\n')
    vim.fn.setreg('+', all_text)
    vim.fn.setreg('"', all_text)
    vim.notify('Output copied to clipboard', vim.log.levels.INFO)
  end, vim.tbl_extend('force', opts, { desc = 'Yank all output' }))
end

return M
