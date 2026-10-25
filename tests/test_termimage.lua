-- Sixel / iTerm2 inline images: geometry, encoding and placement
-- (what reaches the screen has to be checked by eye; see the README)
-- Run with: nvim --headless -u tests/minimal_init.lua -l tests/test_termimage.lua

local h = require('tests.helpers')
local termimage = require('ipynb.termimage')
local config = require('ipynb.config').get()

print('')
print(string.rep('=', 60))
print('Running terminal image tests')
print(string.rep('=', 60))
print('')

-- 1x1 PNG, 2x3 GIF header, minimal JPEG SOF0 for 300x200
local PNG = vim.base64.decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==')
local GIF = 'GIF89a' .. string.char(2, 0, 3, 0) .. string.rep('\0', 10)
local JPEG = '\255\216' .. '\255\224' .. string.char(0, 4) .. 'JF' .. '\255\192' .. string.char(0, 11, 8, 0, 200, 1, 44, 3) .. string.rep('\0', 8)

h.run_test('image_sizes_from_headers', function()
  local w, hh = termimage.image_size(PNG)
  h.assert_eq(w .. 'x' .. hh, '1x1', 'png')
  w, hh = termimage.image_size(GIF)
  h.assert_eq(w .. 'x' .. hh, '2x3', 'gif')
  w, hh = termimage.image_size(JPEG)
  h.assert_eq(w .. 'x' .. hh, '300x200', 'jpeg')
  h.assert_eq(termimage.image_size('not an image'), nil, 'unknown')
end)

h.run_test('fit_keeps_aspect_ratio_within_limits', function()
  local cols, rows = termimage.fit(640, 480, 10, 20, 80, 20)
  h.assert_eq(cols .. 'x' .. rows, '53x20', 'limited by rows, aspect kept (64x24 -> 53x20)')
  cols, rows = termimage.fit(1600, 200, 10, 20, 80, 20)
  h.assert_eq(cols .. 'x' .. rows, '80x5', 'limited by width')
  cols, rows = termimage.fit(30, 20, 10, 20, 80, 20)
  h.assert_eq(cols .. 'x' .. rows, '3x1', 'small images not enlarged')
end)

h.run_test('iterm2_sequence', function()
  local seq = termimage.iterm2_sequence(PNG, 4, 2)
  h.assert_true(seq:sub(1, 13) == '\27]1337;File=i', 'OSC 1337 prefix')
  h.assert_true(seq:find('width=4;height=2', 1, true) ~= nil, 'size in cells')
  h.assert_eq(seq:sub(-1), '\7', 'BEL terminated')
  h.assert_eq(vim.base64.decode(seq:match(':(.*)\7$')), PNG, 'payload is the image')
end)

h.run_test('backend_detection', function()
  local saved = { config.images.backend, vim.env.TERM_PROGRAM, vim.env.WT_SESSION }
  config.images.backend = 'sixel'
  h.assert_eq(termimage.backend(), 'sixel', 'explicit sixel')
  config.images.backend = 'none'
  h.assert_eq(termimage.backend(), nil, 'off')
  config.images.backend = 'auto'
  h.assert_eq(termimage.backend(), nil, 'auto without a UI: nothing to draw on')
  config.images.backend, vim.env.TERM_PROGRAM, vim.env.WT_SESSION = saved[1], saved[2], saved[3]
end)

h.run_test('reserved_rows_and_screen_position', function()
  config.images.backend = 'iterm2'
  local path = vim.fn.tempname() .. '.ipynb'
  vim.fn.writefile({ vim.json.encode({ nbformat = 4, nbformat_minor = 5, metadata = vim.empty_dict(), cells = {
    { id = 'img', cell_type = 'code', source = 'plot()', metadata = vim.empty_dict(), execution_count = 1, outputs = {
      { output_type = 'stream', name = 'stdout', text = 'before\n' },
      { output_type = 'display_data', metadata = vim.empty_dict(), data = { ['image/gif'] = vim.base64.encode(GIF) } },
    } },
  } }) }, path)
  local ok, err = pcall(function()
    local state = h.open_notebook_path(path)
    local ns = vim.api.nvim_create_namespace('notebook_outputs')
    local cell = state.cells[1]
    local mark = vim.api.nvim_buf_get_extmark_by_id(state.facade_buf, ns, cell.output_extmark, { details = true })
    local virt = mark[3].virt_lines
    -- separator, "before", then the reserved image rows
    h.assert_eq(virt[2][1][1], 'before', 'text output first')
    h.assert_eq(#virt, 2 + 1, 'one reserved row for a 2x3px gif')
    local _, end_line = require('ipynb.cells').get_cell_range(state, 1)
    local row, col = termimage.screen_position(vim.api.nvim_get_current_win(), end_line, { line_index = 3, rows = 1 })
    local marker_row = vim.fn.screenpos(0, end_line + 1, 1).row
    h.assert_eq(row, marker_row + 3, 'image row = end marker + its virt line index')
    h.assert_true(col >= 1, 'column inside the window')
    h.assert_eq(termimage.screen_position(0, end_line, { line_index = 3, rows = 500 }), nil, 'not drawn when it would not fit')
  end)
  config.images.backend = 'auto'
  vim.fn.delete(path)
  assert(ok, err)
end)

h.run_test('cell_size_report_parsing', function()
  local w, hh = termimage.parse_cell_size('\27[6;19;9t')
  h.assert_eq(w .. 'x' .. hh, '9x19', 'width x height from CSI 6;h;w t')
  h.assert_eq(termimage.parse_cell_size('\27[?62c'), nil, 'other replies ignored')
end)

h.run_test('sixel_encoding_with_imagemagick', function()
  local magick = vim.fn.exepath('magick')
  if magick == '' then
    print('  SKIP: ImageMagick not installed')
    return
  end
  local r = vim.system({ magick, '-', '-resize', '20x20', 'sixel:-' }, { stdin = PNG }):wait()
  h.assert_eq(r.code, 0, 'magick sixel ok: ' .. (r.stderr or ''))
  h.assert_true(r.stdout:sub(1, 2) == '\27P', 'DCS sixel start')
end)

local success = h.summary()
if success then
  vim.cmd('qa!')
else
  vim.cmd('cquit 1')
end
