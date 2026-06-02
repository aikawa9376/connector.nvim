local util = require("connector.util")

local M = {}

function M.format_schema_table(schema, tbl)
  schema = schema and schema ~= "" and schema or nil
  if schema then
    return ("%s.%s"):format(schema, tbl)
  end
  return tbl
end

local function normalize_default_value(value)
  if value == nil or value == vim.NIL then
    return nil
  end
  local text = tostring(value)
  return text ~= "" and text or nil
end

function M.render_table_definition(conn, entry, columns)
  local kind = ((conn and conn.type) or ""):lower()
  local quote_kind = kind ~= "" and kind or "postgres"
  local conn_name = (conn and conn.name) or entry.connection_id or "(unknown)"
  local object = M.format_schema_table(entry.schema, entry.table)
  local materialization = entry.materialization or "table"
  local mat_kind = materialization:lower()
  local qualified = util.qualify_table(kind, entry.schema, entry.table)

  local lines = {
    ("-- connection: %s (%s)"):format(conn_name, kind ~= "" and kind or "?"),
    ("-- object: %s (%s)"):format(object, materialization),
    "-- preview: columns / primary key only",
    "",
  }

  if not columns or #columns == 0 then
    table.insert(lines, "-- No columns (or failed to load)")
    return table.concat(lines, "\n")
  end

  if mat_kind ~= "table" then
    local label = mat_kind == "materialized_view" and "MATERIALIZED VIEW" or "VIEW"
    table.insert(lines, ("-- %s %s"):format(label, qualified))
    table.insert(lines, "")
    for _, col in ipairs(columns) do
      local name = util.quote_identifier(quote_kind, col.name)
      local dtype = col.data_type and col.data_type ~= "" and col.data_type or ""
      local suffix = dtype ~= "" and (" " .. dtype) or ""
      table.insert(lines, ("- %s%s"):format(name, suffix))
    end
    return table.concat(lines, "\n")
  end

  local pk_cols = {}
  for _, col in ipairs(columns) do
    if col.primary_key then
      table.insert(pk_cols, col.name)
    end
  end

  local body = {}
  for _, col in ipairs(columns) do
    local name = util.quote_identifier(quote_kind, col.name)
    local dtype = col.data_type and col.data_type ~= "" and col.data_type or ""
    local parts = { name }
    if dtype ~= "" then
      table.insert(parts, dtype)
    end
    if col.nullable == false then
      table.insert(parts, "NOT NULL")
    end
    local def = normalize_default_value(col.default_value)
    if def then
      table.insert(parts, "DEFAULT " .. def)
    end
    table.insert(body, "  " .. table.concat(parts, " "))
  end

  table.insert(lines, ("CREATE TABLE %s ("):format(qualified))

  local tail = {}
  if #pk_cols >= 1 then
    local pk = vim.tbl_map(function(name)
      return util.quote_identifier(quote_kind, name)
    end, pk_cols)
    table.insert(tail, "  PRIMARY KEY (" .. table.concat(pk, ", ") .. ")")
  end

  local all = vim.list_extend(vim.deepcopy(body), tail)
  for i, line in ipairs(all) do
    if i < #all then
      all[i] = line .. ","
    end
  end

  vim.list_extend(lines, all)
  table.insert(lines, ");")
  return table.concat(lines, "\n")
end

return M
