local ddl = require("connector.ddl")
local dialect_mod = require("connector.sql.dialect")

local M = {}

local function normalize_schema(schema)
  if schema == nil or schema == "" then
    return nil
  end
  return schema
end

local function quote_list(dialect, cols)
  local out = {}
  for _, name in ipairs(cols or {}) do
    table.insert(out, dialect:quote_identifier(name))
  end
  return out
end

local function primary_keys(cols_meta)
  local pks = {}
  for _, c in ipairs(cols_meta or {}) do
    if c.primary_key then
      table.insert(pks, c.name)
    end
  end
  return pks
end

local function where_clause(dialect, pk_names, fallback_col)
  if pk_names and #pk_names > 0 then
    local parts = {}
    for _, pk in ipairs(pk_names) do
      table.insert(parts, ("%s = %s"):format(dialect:quote_identifier(pk), dialect:placeholder(nil)))
    end
    return table.concat(parts, " AND ")
  end

  if fallback_col and fallback_col ~= "" then
    return ("%s = "):format(dialect:quote_identifier(fallback_col))
  end

  return ""
end

---@class connector.sql.GenerateTableQueryOpts
---@field connection table|nil
---@field connection_id string|nil
---@field action 'select'|'update'|'delete'|'insert'|'ddl'|'truncate'
---@field schema string|nil
---@field table string
---@field materialization string|nil
---@field selected_columns string[]|nil
---@field all_columns string[]|nil
---@field columns_meta table[]|nil

---@param opts connector.sql.GenerateTableQueryOpts
---@return string
function M.generate_table_query(opts)
  opts = opts or {}
  local action = opts.action
  local conn = opts.connection

  local kind = ((conn and conn.type) or "sqlite"):lower()
  local dialect = dialect_mod.for_kind(kind)

  local schema = normalize_schema(opts.schema)
  local table_name = assert(opts.table, "table is required")
  local qualified = dialect:qualify_table(schema, table_name)

  local cols = opts.selected_columns or opts.all_columns

  if action == "select" then
    if not cols then
      return ("SELECT * FROM %s;"):format(qualified)
    end
    local quoted = quote_list(dialect, cols)
    return ("SELECT %s FROM %s;"):format(table.concat(quoted, ", "), qualified)
  end

  if action == "delete" then
    local pk_names = primary_keys(opts.columns_meta)
    local fallback = (cols and cols[1]) or (opts.all_columns and opts.all_columns[1])
    local wc = where_clause(dialect, pk_names, fallback)
    return ("DELETE FROM %s WHERE %s;"):format(qualified, wc)
  end

  if action == "truncate" then
    if kind == "sqlite" or kind == "sqlite3" then
      return ("DELETE FROM %s;"):format(qualified)
    end
    return ("TRUNCATE TABLE %s;"):format(qualified)
  end

  if action == "update" then
    local set_cols = {}

    if opts.selected_columns and #opts.selected_columns > 0 then
      for _, c in ipairs(opts.selected_columns) do
        table.insert(set_cols, ("%s = %s"):format(dialect:quote_identifier(c), dialect:placeholder(nil)))
      end
    elseif opts.columns_meta then
      for _, c in ipairs(opts.columns_meta) do
        if not c.primary_key then
          table.insert(set_cols, ("%s = %s"):format(dialect:quote_identifier(c.name), dialect:placeholder(nil)))
        end
      end
    elseif cols and #cols > 0 then
      for _, c in ipairs(cols) do
        table.insert(set_cols, ("%s = %s"):format(dialect:quote_identifier(c), dialect:placeholder(nil)))
      end
    end

    local set_clause = table.concat(set_cols, ", ")
    if set_clause == "" then
      set_clause = "-- TODO: set_column = ?"
    end

    local pk_names = primary_keys(opts.columns_meta)
    local fallback = (cols and cols[1]) or (opts.all_columns and opts.all_columns[1])
    local wc = where_clause(dialect, pk_names, fallback)

    return ("UPDATE %s SET %s WHERE %s;"):format(qualified, set_clause, wc)
  end

  if action == "insert" then
    local ins_cols = cols or opts.all_columns
    if not ins_cols or #ins_cols == 0 then
      return ("INSERT INTO %s DEFAULT VALUES;"):format(qualified)
    end

    local quoted = quote_list(dialect, ins_cols)
    local placeholders = {}
    for _ = 1, #ins_cols do
      table.insert(placeholders, dialect:placeholder(nil))
    end

    return ("INSERT INTO %s (%s) VALUES (%s);"):format(
      qualified,
      table.concat(quoted, ", "),
      table.concat(placeholders, ", ")
    )
  end

  if action == "ddl" then
    return ddl.render_table_definition(conn, {
      connection_id = opts.connection_id,
      schema = schema,
      table = table_name,
      materialization = opts.materialization,
    }, opts.columns_meta)
  end

  return ""
end

return M
