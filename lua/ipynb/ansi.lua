-- ipynb/ansi.lua - ANSI SGR colour codes in kernel output -> highlight chunks
-- Tracebacks and colored prints (rich, tqdm, pytest, R's crayon) use these.

local M = {}

local defined = {}

-- Fallback palette when the colorscheme sets no g:terminal_color_N
local PALETTE = {
  [0] = '#000000', '#cd3131', '#0dbc79', '#e5e510', '#2472c8', '#bc3fbc', '#11a8cd', '#e5e5e5',
  '#666666', '#f14c4c', '#23d18b', '#f5f543', '#3b8eea', '#d670d6', '#29b8db', '#ffffff',
}

local function color(n)
  return vim.g['terminal_color_' .. n] or PALETTE[n]
end

---Highlight group for an SGR state (created on first use)
---@param fg number|string|nil 0-15 or "#rrggbb"
---@param bg number|string|nil
---@param bold boolean
---@param base string Highlight group the text would otherwise use
---@return string
local function group(fg, bg, bold, base)
  if not fg and not bg and not bold then
    return base
  end
  local name = string.format('IpynbAnsi_%s_%s_%s', tostring(fg or 'x'):gsub('#', ''), tostring(bg or 'x'):gsub('#', ''), bold and 'b' or 'n')
  if not defined[name] then
    defined[name] = true
    vim.api.nvim_set_hl(0, name, {
      fg = type(fg) == 'number' and color(fg) or fg,
      bg = type(bg) == 'number' and color(bg) or bg,
      bold = bold or nil,
      default = true,
    })
  end
  return name
end

-- Recreate groups after a colorscheme change (terminal colors may differ)
vim.api.nvim_create_autocmd('ColorScheme', {
  group = vim.api.nvim_create_augroup('IpynbAnsi', { clear = true }),
  callback = function()
    defined = {}
  end,
})

local function cube(n)
  -- 256-colour palette entries 16-255 as hex
  if n < 16 then
    return n
  elseif n < 232 then
    n = n - 16
    local function c(v) return v == 0 and 0 or 55 + v * 40 end
    return string.format('#%02x%02x%02x', c(math.floor(n / 36)), c(math.floor(n / 6) % 6), c(n % 6))
  end
  local g = 8 + (n - 232) * 10
  return string.format('#%02x%02x%02x', g, g, g)
end

---Split one output line into virt_text chunks, applying SGR codes.
---Non-SGR escape sequences are dropped.
---@param line string
---@param base string Default highlight group
---@return table[] chunks { {text, hl}, ... }
function M.chunks(line, base)
  if not line:find('\27', 1, true) then
    return { { line, base } }
  end
  -- OSC sequences (e.g. hyperlinks from rich) carry no colour: drop them
  line = line:gsub('\27%][^\7\27]*\7', ''):gsub('\27%][^\7\27]*\27\\', '')
  local chunks = {}
  local fg, bg, bold = nil, nil, false
  local pos = 1
  while pos <= #line do
    local s, e, params, final = line:find('\27%[([%d;?]*)([%a])', pos)
    local text = line:sub(pos, (s or #line + 1) - 1)
    if text ~= '' then
      chunks[#chunks + 1] = { text, group(fg, bg, bold, base) }
    end
    if not s then
      break
    end
    if final == 'm' and not params:find('?', 1, true) then
      local codes = {}
      for code in (params == '' and '0' or params):gmatch('%d+') do
        codes[#codes + 1] = tonumber(code)
      end
      local i = 1
      while i <= #codes do
        local c = codes[i]
        if c == 0 then
          fg, bg, bold = nil, nil, false
        elseif c == 1 then
          bold = true
        elseif c == 22 then
          bold = false
        elseif c >= 30 and c <= 37 then
          fg = c - 30
        elseif c >= 90 and c <= 97 then
          fg = c - 90 + 8
        elseif c == 39 then
          fg = nil
        elseif c >= 40 and c <= 47 then
          bg = c - 40
        elseif c >= 100 and c <= 107 then
          bg = c - 100 + 8
        elseif c == 49 then
          bg = nil
        elseif (c == 38 or c == 48) and codes[i + 1] == 5 and codes[i + 2] then
          local v = cube(codes[i + 2])
          if c == 38 then fg = v else bg = v end
          i = i + 2
        elseif (c == 38 or c == 48) and codes[i + 1] == 2 and codes[i + 4] then
          local v = string.format('#%02x%02x%02x', codes[i + 2], codes[i + 3], codes[i + 4])
          if c == 38 then fg = v else bg = v end
          i = i + 4
        end
        i = i + 1
      end
    end
    pos = e + 1
  end
  if #chunks == 0 then
    chunks[1] = { '', base }
  end
  return chunks
end

---Remove all escape sequences (for copying output as plain text)
---@param line string
---@return string
function M.strip(line)
  return (line:gsub('\27%][^\7\27]*\7', ''):gsub('\27%][^\7\27]*\27\\', ''):gsub('\27%[[%d;?]*[%a]', ''))
end

return M
