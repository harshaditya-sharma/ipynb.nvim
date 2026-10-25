-- ipynb/magics.lua - Hide IPython syntax from Python language servers
--
-- `%time x()`, `!pip install`, `files = !ls`, `obj?` and `%%bash` cells are valid
-- in a Jupyter kernel but are syntax errors to pyright/ruff. In the shadow
-- buffer each such line becomes plain Python tagged with its line number, so
-- diagnostics stay quiet and a formatter's output can be mapped back to the
-- original line (see restore).

local M = {}

local TAG = '# ipynb-magic:'

-- Cell magics whose body is still Python: only the %% line is hidden
local PYTHON_BODY_CELL_MAGICS = {
  time = true, timeit = true, capture = true, prun = true, debug = true,
}

---@param lang string|nil
---@return boolean
function M.applies_to(lang)
  return lang == nil or lang == 'python' or lang == 'ipython'
end

---Replacement for one IPython-only line, or nil if the line is plain Python
---@param line string
---@param n number Line number within the cell (1-based)
---@return string|nil
local function mask_line(line, n)
  local indent, rest = line:match('^(%s*)(.*)$')
  local tag = '  ' .. TAG .. n
  -- %magic, !shell, ?help / help? / help??
  if rest:match('^[%%!]') or rest:match('^%?') or rest:match('^[%w_.]+%?%??%s*$') then
    return indent .. 'pass' .. tag
  end
  -- x = !cmd / x = %magic
  local lhs = rest:match('^([%w_.,%s%[%]()]-%s*=)%s*[%%!]')
  if lhs and not lhs:match('[=!<>]=$') then
    return indent .. lhs .. ' None' .. tag
  end
  return nil
end

---Mask IPython-only syntax in a code cell's lines
---@param lines string[]
---@return string[] masked (same length as lines)
function M.mask(lines)
  local first = 1
  while lines[first] and lines[first]:match('^%s*$') do
    first = first + 1
  end
  local cell_magic = lines[first] and lines[first]:match('^%%%%(%w+)')

  local result = {}
  for i, line in ipairs(lines) do
    if cell_magic and i == first then
      result[i] = 'pass' .. '  ' .. TAG .. i
    elseif cell_magic and not PYTHON_BODY_CELL_MAGICS[cell_magic] and i > first then
      result[i] = '' -- %%bash, %%html, %%sql... : the body is not Python
    else
      result[i] = mask_line(line, i) or line
    end
  end
  return result
end

---Put original lines back where a formatter kept a masked placeholder
---@param lines string[] Formatted lines (may still contain placeholders)
---@param original string[] The cell's lines before formatting
---@return string[]
function M.restore(lines, original)
  local result = {}
  for i, line in ipairs(lines) do
    local n = tonumber(line:match(TAG:gsub('%-', '%%-') .. '(%d+)%s*$'))
    result[i] = (n and original[n]) or line
  end
  return result
end

return M
