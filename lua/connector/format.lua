local util = require("connector.util")

local M = {}

local COL_SEP = "│"
local ROW_SEP = "─"
local COL_CROSS = "┼"

local function row_objects(result, rows)
  local objects = {}
  for _, row in ipairs(rows) do
    local object = {}
    for index, column in ipairs(result.columns or {}) do
      object[column.name] = row[index]
    end
    table.insert(objects, object)
  end
  return objects
end

local function render_separator(widths)
  local line = ""
  for index, width in ipairs(widths) do
    if index > 1 then
      line = line .. ROW_SEP .. COL_CROSS .. ROW_SEP
    end
    line = line .. string.rep(ROW_SEP, width)
  end
  return line
end

local function render_row(values, widths, track_cells)
  local line = ""
  local cells = {}
  for index, value in ipairs(values) do
    if index > 1 then
      line = line .. " " .. COL_SEP .. " "
    end
    local text = util.value_to_string(value)
    local padded = index == 1 and util.pad_left(text, widths[index]) or util.pad_right(text, widths[index])
    local start_col = #line + 1
    line = line .. padded
    local end_col = #line
    if track_cells and index > 1 then
      cells[index - 1] = {
        start_col = start_col,
        end_col = end_col,
        width = widths[index],
      }
    end
  end
  return line:gsub("%s+$", ""), cells
end

local function measure_width(text)
  return util.display_width(text)
end

function M.slice_rows(result, from, to)
  local rows = result.rows or {}
  local start_idx, end_idx = util.normalize_range(from, to, #rows)
  local sliced = {}
  for index = start_idx + 1, end_idx do
    table.insert(sliced, rows[index])
  end
  return sliced, start_idx, end_idx
end

function M.to_json(result, from, to)
  local rows = M.slice_rows(result, from, to)
  return vim.json.encode(row_objects(result, rows))
end

function M.to_csv(result, from, to)
  local rows = M.slice_rows(result, from, to)
  local lines = {}
  local headers = {}
  for _, column in ipairs(result.columns or {}) do
    table.insert(headers, util.csv_escape(column.name))
  end
  if #headers > 0 then
    table.insert(lines, table.concat(headers, ","))
  end
  for _, row in ipairs(rows) do
    local values = {}
    for _, value in ipairs(row) do
      table.insert(values, util.csv_escape(value))
    end
    table.insert(lines, table.concat(values, ","))
  end
  return table.concat(lines, "\n")
end

function M.to_table_lines(result, from, to)
  local rows, start_idx = M.slice_rows(result, from, to)
  local columns = result.columns or {}

  if #columns == 0 then
    return { result.message or "No result" }, {}, {}
  end

  local widths = { 1 }
  for _, column in ipairs(columns) do
    table.insert(widths, measure_width(column.name))
  end

  for index, column in ipairs(columns) do
    widths[index + 1] = math.max(widths[index + 1], measure_width(column.name))
  end
  for row_offset, row in ipairs(rows) do
    widths[1] = math.max(widths[1], measure_width(tostring(start_idx + row_offset)))
    for index, value in ipairs(row) do
      widths[index + 1] = math.max(widths[index + 1], measure_width(util.value_to_string(value)))
    end
  end

  local header_values = { "" }
  for _, column in ipairs(columns) do
    table.insert(header_values, column.name)
  end

  local header_line = render_row(header_values, widths, false)
  local separator_line = render_separator(widths)
  local lines = { header_line, separator_line }
  local line_map = {}
  local cell_map = {}

  for index, row in ipairs(rows) do
    local row_values = { tostring(start_idx + index) }
    for _, value in ipairs(row) do
      table.insert(row_values, value)
    end
    local line, cells = render_row(row_values, widths, true)
    table.insert(lines, line)
    line_map[#lines] = start_idx + index - 1
    cell_map[#lines] = cells
  end

  table.insert(lines, render_separator(widths))
  return lines, line_map, cell_map
end

function M.to_table(result, from, to)
  local lines = M.to_table_lines(result, from, to)
  return table.concat(lines, "\n")
end

return M
