-- ipynb/cellmeta.lua - Cell metadata shared with other notebook frontends
--
-- JupyterLab: metadata.jupyter.source_hidden / outputs_hidden, metadata.tags
-- Classic Notebook: metadata.collapsed (outputs collapsed)
-- Google Colab: metadata.cellView = "form" and a "#@title ..." first line
-- Databricks: metadata["application/vnd.databricks.v1+cell"].title

local M = {}

local DATABRICKS = 'application/vnd.databricks.v1+cell'

---@param cell Cell
---@return table
local function jupyter_meta(cell)
  cell.metadata = cell.metadata or {}
  if type(cell.metadata.jupyter) ~= 'table' then
    cell.metadata.jupyter = {}
  end
  return cell.metadata.jupyter
end

---Drop a now-empty metadata.jupyter table so files stay byte-identical
---@param cell Cell
local function tidy(cell)
  local j = cell.metadata and cell.metadata.jupyter
  if type(j) == 'table' and next(j) == nil then
    cell.metadata.jupyter = nil
  end
end

---@param cell Cell
---@return boolean
function M.is_source_hidden(cell)
  local meta = cell.metadata or {}
  return (type(meta.jupyter) == 'table' and meta.jupyter.source_hidden == true) or meta.cellView == 'form'
end

---@param cell Cell
---@param hidden boolean
function M.set_source_hidden(cell, hidden)
  if hidden then
    jupyter_meta(cell).source_hidden = true
  else
    if cell.metadata and type(cell.metadata.jupyter) == 'table' then
      cell.metadata.jupyter.source_hidden = nil
    end
    if cell.metadata and cell.metadata.cellView == 'form' then
      cell.metadata.cellView = nil
    end
    tidy(cell)
  end
end

---@param cell Cell
---@return boolean
function M.is_outputs_hidden(cell)
  local meta = cell.metadata or {}
  return (type(meta.jupyter) == 'table' and meta.jupyter.outputs_hidden == true) or meta.collapsed == true
end

---Set like JupyterLab does: jupyter.outputs_hidden plus the legacy collapsed flag
---@param cell Cell
---@param hidden boolean
function M.set_outputs_hidden(cell, hidden)
  cell.metadata = cell.metadata or {}
  if hidden then
    jupyter_meta(cell).outputs_hidden = true
    cell.metadata.collapsed = true
  else
    if type(cell.metadata.jupyter) == 'table' then
      cell.metadata.jupyter.outputs_hidden = nil
    end
    cell.metadata.collapsed = nil
    tidy(cell)
  end
end

---@param cell Cell
---@return string[]
function M.tags(cell)
  local tags = cell.metadata and cell.metadata.tags
  if type(tags) ~= 'table' then
    return {}
  end
  local result = {}
  for _, tag in ipairs(tags) do
    if type(tag) == 'string' then
      result[#result + 1] = tag
    end
  end
  return result
end

---Set tags (an empty list removes the key, like JupyterLab)
---@param cell Cell
---@param tags string[]
function M.set_tags(cell, tags)
  cell.metadata = cell.metadata or {}
  local seen, clean = {}, {}
  for _, tag in ipairs(tags) do
    tag = vim.trim(tag)
    if tag ~= '' and not tag:find('[%s,]') and not seen[tag] then
      seen[tag] = true
      clean[#clean + 1] = tag
    end
  end
  cell.metadata.tags = #clean > 0 and clean or nil
end

---Display title from Databricks metadata or a Colab "#@title" line
---@param cell Cell
---@return string|nil
function M.title(cell)
  local meta = cell.metadata or {}
  local databricks = meta[DATABRICKS]
  if type(databricks) == 'table' and type(databricks.title) == 'string' and databricks.title ~= '' then
    return databricks.title
  end
  local first = (cell.source or ''):match('^[^\n]*')
  local colab = first and first:match('^%s*#%s*@title%s+(.-)%s*$')
  if colab then
    -- strip Colab form options: #@title Load data { display-mode: "form" }
    colab = vim.trim(colab:gsub('%s*{.*}%s*$', ''))
    return colab ~= '' and colab or nil
  end
  return nil
end

return M
