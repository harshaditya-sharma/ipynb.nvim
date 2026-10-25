-- ipynb/termimage.lua - Inline images with Sixel / iTerm2 graphics
--
-- snacks.nvim draws images through kitty placeholders (kitty, Ghostty,
-- WezTerm). Windows Terminal (Sixel) and iTerm2/WezTerm (OSC 1337) have no
-- placeholders: images are drawn at screen positions. So outputs reserve
-- blank virtual lines, and after Neovim redraws, each visible image is written
-- over its reserved rows through nvim_ui_send (the TUI is a separate process
-- in Neovim 0.10+, so plain stdout would not reach the terminal).

local M = {}

-- placements[buf] = list of { cell_id, line_index, rows, cols, key, mime, bytes }
local placements = {}
-- encoded[key] = escape sequence ready to send (Sixel data is produced async)
local encoded = {}
local pending = {}
-- last drawn screen position per placement, to avoid resending unchanged images
local drawn = {}

---@return table
local function config()
  return require('ipynb.config').get().images or {}
end

---Terminal graphics protocol to use for non-placeholder images
---@return "sixel"|"iterm2"|nil
function M.backend()
  local cfg = config()
  if cfg.enabled == false then
    return nil
  end
  local backend = cfg.backend or 'auto'
  if backend == 'sixel' or backend == 'iterm2' then
    return backend
  elseif backend ~= 'auto' then
    return nil -- 'kitty' (snacks) or 'none'
  end
  if not vim.api.nvim_ui_send or #vim.api.nvim_list_uis() == 0 then
    return nil
  end
  local term_program = vim.env.TERM_PROGRAM or ''
  if term_program == 'iTerm.app' or term_program == 'WezTerm' then
    return 'iterm2'
  end
  if vim.env.WT_SESSION then
    return 'sixel' -- Windows Terminal 1.22+
  end
  local term = vim.env.TERM or ''
  if term:find('foot') or term:find('mlterm') or term:find('contour') then
    return 'sixel'
  end
  return nil
end

--------------------------------------------------------------------------------
-- Image geometry
--------------------------------------------------------------------------------

local function u32be(s, i)
  local a, b, c, d = s:byte(i, i + 3)
  return ((a * 256 + b) * 256 + c) * 256 + d
end

local function u16be(s, i)
  local a, b = s:byte(i, i + 1)
  return a * 256 + b
end

---Pixel size of PNG / JPEG / GIF data
---@param bytes string
---@return number|nil width
---@return number|nil height
function M.image_size(bytes)
  if bytes:sub(1, 8) == '\137PNG\r\n\26\n' and #bytes >= 24 then
    return u32be(bytes, 17), u32be(bytes, 21)
  end
  if bytes:sub(1, 3) == 'GIF' and #bytes >= 10 then
    local w = bytes:byte(7) + bytes:byte(8) * 256
    local h = bytes:byte(9) + bytes:byte(10) * 256
    return w, h
  end
  if bytes:sub(1, 2) == '\255\216' then
    local i = 3
    while i + 8 <= #bytes do
      if bytes:byte(i) ~= 0xFF then
        return nil
      end
      local marker = bytes:byte(i + 1)
      local len = u16be(bytes, i + 2)
      -- SOF0..SOF15 except DHT (C4), JPG (C8), DAC (CC)
      if marker >= 0xC0 and marker <= 0xCF and marker ~= 0xC4 and marker ~= 0xC8 and marker ~= 0xCC then
        return u16be(bytes, i + 7), u16be(bytes, i + 5)
      end
      i = i + 2 + len
    end
  end
  return nil
end

---Fit an image into terminal cells, keeping its aspect ratio
---@param width_px number
---@param height_px number
---@param cell_w number Cell width in pixels
---@param cell_h number Cell height in pixels
---@param max_cols number
---@param max_rows number
---@return number cols
---@return number rows
function M.fit(width_px, height_px, cell_w, cell_h, max_cols, max_rows)
  local cols = width_px / cell_w
  local rows = height_px / cell_h
  local scale = math.min(1, max_cols / cols, max_rows / rows)
  return math.max(1, math.floor(cols * scale + 0.5)), math.max(1, math.floor(rows * scale + 0.5))
end

--------------------------------------------------------------------------------
-- Encoding
--------------------------------------------------------------------------------

---OSC 1337 inline image (iTerm2, WezTerm); the terminal does the scaling
---@param bytes string PNG/JPEG/GIF data
---@param cols number
---@param rows number
---@return string
function M.iterm2_sequence(bytes, cols, rows)
  return string.format('\27]1337;File=inline=1;size=%d;width=%d;height=%d;preserveAspectRatio=1:%s\7',
    #bytes, cols, rows, vim.base64.encode(bytes))
end

---Cache key for an encoded image at a size
local function key_for(bytes, cols, rows, backend)
  return table.concat({ backend, vim.fn.sha256(bytes):sub(1, 16), cols, rows }, ':')
end

---Produce the Sixel sequence with ImageMagick (async); redraw when ready
---@param key string
---@param bytes string
---@param cols number
---@param rows number
local function encode_sixel(key, bytes, cols, rows)
  if pending[key] or encoded[key] then
    return
  end
  local magick = vim.fn.executable('magick') == 1 and 'magick' or (vim.fn.executable('convert') == 1 and 'convert')
  if not magick then
    encoded[key] = false
    vim.schedule(function()
      vim.notify('Inline images in this terminal need ImageMagick (magick) for Sixel', vim.log.levels.WARN)
    end)
    return
  end
  local cell = config().cell_size or { 10, 20 }
  pending[key] = true
  vim.system({ magick, '-', '-resize', string.format('%dx%d', cols * cell[1], rows * cell[2]), 'sixel:-' },
    { stdin = bytes }, function(r)
      vim.schedule(function()
        pending[key] = nil
        encoded[key] = (r.code == 0 and r.stdout ~= '') and r.stdout or false
        if encoded[key] then
          M.redraw({ force = true })
        end
      end)
    end)
end

--------------------------------------------------------------------------------
-- Placement
--------------------------------------------------------------------------------

---Reserve rows for an image in a cell's output virt_lines
---@param state NotebookState
---@param cell Cell
---@param bytes string Decoded PNG/JPEG/GIF (SVG etc. are converted for Sixel only)
---@param line_index number 1-based index in the cell's virt_lines where the image starts
---@param max_cols number Available width in cells
---@return table[]|nil virt_lines Blank rows to insert, or nil if the image can't be shown
function M.reserve(state, cell, bytes, line_index, max_cols)
  local backend = M.backend()
  if not backend then
    return nil
  end
  local w, h = M.image_size(bytes)
  if not w then
    if backend == 'iterm2' then
      return nil -- only PNG/JPEG/GIF are sent as-is
    end
    w, h = 640, 480 -- let ImageMagick decide; assume a typical plot size
  end
  local cell_size = config().cell_size or { 10, 20 }
  local cols, rows = M.fit(w, h, cell_size[1], cell_size[2], math.max(10, max_cols), config().max_rows or 20)
  local key = key_for(bytes, cols, rows, backend)
  if backend == 'iterm2' then
    encoded[key] = encoded[key] or M.iterm2_sequence(bytes, cols, rows)
  else
    encode_sixel(key, bytes, cols, rows)
  end

  placements[state.facade_buf] = placements[state.facade_buf] or {}
  table.insert(placements[state.facade_buf], {
    cell_id = cell.id, line_index = line_index, rows = rows, cols = cols, key = key,
  })

  local lines = {}
  for i = 1, rows do
    lines[i] = { { string.rep(' ', cols), 'Normal' } }
  end
  return lines
end

---Forget placements of a cell (its outputs are being re-rendered or cleared)
---@param buf number
---@param cell_id string
function M.clear(buf, cell_id)
  local list = placements[buf]
  if not list then
    return
  end
  for i = #list, 1, -1 do
    if list[i].cell_id == cell_id then
      table.remove(list, i)
    end
  end
end

---Forget everything for a notebook buffer
---@param buf number
function M.clear_buffer(buf)
  placements[buf] = nil
end

---Screen position for a placement in a window, if the whole image is visible
---@param win number
---@param end_line number 0-based line the output extmark is attached to
---@param placement table
---@return number|nil row 1-based screen row
---@return number|nil col 1-based screen column
function M.screen_position(win, end_line, placement)
  if vim.fn.foldclosed(end_line + 1) ~= -1 then
    return nil
  end
  local pos = vim.fn.screenpos(win, end_line + 1, 1)
  if not pos or pos.row == 0 then
    return nil
  end
  local win_row, win_col = unpack(vim.api.nvim_win_get_position(win))
  local info = vim.fn.getwininfo(win)[1] or {}
  -- virt_lines start on the row after the (single-row, concealed) end marker
  local row = pos.row + placement.line_index
  local last_row = win_row + vim.api.nvim_win_get_height(win) -- 1-based screen row of the window's last line
  if row + placement.rows - 1 > last_row then
    return nil
  end
  return row, win_col + 1 + (info.textoff or 0)
end

---Draw visible images (debounced). force = resend even if nothing moved.
---@param opts { force: boolean }|nil
function M.redraw(opts)
  if opts and opts.force then
    drawn = {}
  end
  if M._timer then
    M._timer:stop()
  else
    M._timer = vim.uv.new_timer()
  end
  M._timer:start(40, 0, vim.schedule_wrap(function()
    M._draw_now()
  end))
end

function M._draw_now()
  if not vim.api.nvim_ui_send then
    return
  end
  local state_mod = require('ipynb.state')
  local cells_mod = require('ipynb.cells')
  local out = {}
  local seen = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    local list = placements[buf]
    local state = list and state_mod.get_by_facade(buf)
    if state then
      local index = {}
      for i, c in ipairs(state.cells) do
        index[c.id] = i
      end
      for _, p in ipairs(list) do
        local idx = index[p.cell_id]
        local seq = encoded[p.key]
        if idx and seq then
          local _, end_line = cells_mod.get_cell_range(state, idx)
          local row, col = end_line and M.screen_position(win, end_line, p)
          if row then
            local id = table.concat({ win, p.cell_id, p.line_index }, ':')
            local where = row .. ',' .. col
            seen[id] = where
            if drawn[id] ~= where then
              out[#out + 1] = string.format('\27[%d;%dH', row, col) .. seq
            end
          end
        end
      end
    end
  end
  drawn = seen
  if #out > 0 then
    -- Save cursor, draw, restore: Neovim's TUI keeps its own cursor state
    vim.api.nvim_ui_send('\0277' .. table.concat(out) .. '\0278')
  end
end

---Parse a cell-size report (reply to CSI 16 t): ESC [ 6 ; height ; width t
---@param sequence string
---@return number|nil width
---@return number|nil height
function M.parse_cell_size(sequence)
  local hh, w = sequence:match('\27%[6;(%d+);(%d+)t')
  if hh then
    return tonumber(w), tonumber(hh)
  end
end

---Redraw images whenever Neovim may have moved or overwritten them
function M.setup_autocmds()
  if M._autocmds then
    return
  end
  M._autocmds = true
  local group = vim.api.nvim_create_augroup('IpynbTermImage', { clear = true })

  -- Ask the terminal for its real cell size in pixels (unless configured);
  -- terminals that don't answer keep the default.
  if config().cell_size_auto ~= false and vim.api.nvim_ui_send then
    vim.api.nvim_create_autocmd('TermResponse', {
      group = group,
      callback = function(args)
        local seq = type(args.data) == 'table' and args.data.sequence or vim.v.termresponse
        local w, hh = M.parse_cell_size(seq or '')
        if w and hh and w > 0 and hh > 0 then
          config().cell_size = { w, hh }
          encoded, drawn = {}, {}
          for buf in pairs(placements) do
            local state = require('ipynb.state').get_by_facade(buf)
            if state then
              require('ipynb.output').render_all(state)
            end
          end
          return true -- one answer is enough
        end
      end,
    })
    vim.api.nvim_ui_send('\27[16t')
  end

  vim.api.nvim_create_autocmd({ 'WinScrolled', 'WinResized', 'VimResized', 'BufWinEnter', 'WinClosed', 'TabEnter', 'FocusGained' }, {
    group = group,
    callback = function()
      if next(placements) then
        M.redraw({ force = true })
      end
    end,
  })
end

return M
