-- ipynb/repl.lua - Run cells in an iron.nvim REPL
--
-- For languages without a Jupyter kernel (or when you'd rather use a plain
-- REPL), cells and selections can be sent to iron.nvim's REPL for the
-- notebook language. Output appears in the REPL window, not under the cell:
-- a plain REPL has no message protocol to capture it from.

local M = {}

---@return table|nil iron.core
local function iron()
  local ok, core = pcall(require, 'iron.core')
  return ok and core or nil
end

---@return boolean
function M.available()
  return iron() ~= nil
end

---Notebook language as a Neovim filetype (what iron's repl_definition uses)
---@param state NotebookState
---@return string
function M.filetype(state)
  local lang = state.shadow_lang
    or (state.metadata and state.metadata.language_info and state.metadata.language_info.name)
    or 'python'
  local aliases = { ['c++'] = 'cpp', ['c#'] = 'cs', bash = 'sh', ['javascript (node.js)'] = 'javascript' }
  lang = lang:lower()
  return aliases[lang] or lang
end

---Send lines to the REPL for the notebook language (starts it if needed)
---@param state NotebookState
---@param lines string[]
---@return boolean sent
function M.send(state, lines)
  local core = iron()
  if not core then
    vim.notify('iron.nvim is not installed (needed to run cells without a Jupyter kernel)', vim.log.levels.WARN)
    return false
  end
  local ft = M.filetype(state)
  local ok, err = pcall(function()
    local ll_ok, ll = pcall(require, 'iron.lowlevel')
    local st_ok, iron_state = pcall(require, 'iron.state')
    if not (ll_ok and st_ok and core.repl_for) then
      core.send(ft, lines) -- unknown iron version: public API
      return
    end
    -- Same as core.send, minus its Windows workaround, which sends the final
    -- <CR> to the REPL of the *current buffer's* filetype ("ipynb" here, so
    -- it errors and the code never runs).
    local meta = iron_state.get_repl(ft)
    if not ll.repl_exists(meta) then
      meta = core.repl_for(ft)
    end
    if not meta then
      error('no REPL could be started')
    end
    ll.send_to_repl(meta, lines)
    if vim.fn.has('win32') == 1 then
      vim.defer_fn(function()
        if ll.repl_exists(meta) then
          vim.fn.chansend(meta.job, '\r')
        end
      end, 150)
    end
  end)
  if not ok then
    vim.notify('iron.nvim could not send to a ' .. ft .. ' REPL: ' .. tostring(err), vim.log.levels.ERROR)
    return false
  end
  return true
end

---Send a code cell to the REPL
---@param state NotebookState
---@param cell_idx number
---@return boolean sent
function M.send_cell(state, cell_idx)
  local cell = state.cells[cell_idx]
  if not cell or cell.type ~= 'code' then
    return false
  end
  local lines = vim.split(cell.source, '\n', { plain = true })
  -- A trailing blank line ends indented blocks in Python-style REPLs
  if lines[#lines] ~= '' then
    table.insert(lines, '')
  end
  return M.send(state, lines)
end

return M
