local util = require("connector.util")

local M = {}

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

  local widths = {}
  for index, column in ipairs(columns) do
    widths[index] = #column.name
  end
  for _, row in ipairs(rows) do
    for index, value in ipairs(row) do
      widths[index] = math.max(widths[index] or 0, #util.value_to_string(value))
    end
  end

  local function render_row(values)
    local cells = {}
    local line = "| "
    for index, value in ipairs(values) do
      local text = util.value_to_string(value)
      local padded = text .. string.rep(" ", (widths[index] or #text) - #text)
      local start_col = #line + 1
      line = line .. padded
      local end_col = #line
      cells[index] = {
        start_col = start_col,
        end_col = end_col,
        width = widths[index] or #text,
      }
      line = line .. " | "
    end
    return line:sub(1, -2), cells
  end

  local header_values = {}
  local separator_values = {}
  for index, column in ipairs(columns) do
    header_values[index] = column.name
    separator_values[index] = string.rep("-", widths[index])
  end

  local header_line = render_row(header_values)
  local separator_line = render_row(separator_values)
  local lines = { header_line, separator_line }
  local line_map = {}
  local cell_map = {}
  for index, row in ipairs(rows) do
    local line, cells = render_row(row)
    table.insert(lines, line)
    line_map[#lines] = start_idx + index - 1
    cell_map[#lines] = cells
  end
  return lines, line_map, cell_map
end

function M.to_table(result, from, to)
  local lines = M.to_table_lines(result, from, to)
  return table.concat(lines, "\n")
end

return M
