local state = require("connector.api.state")
local util = require("connector.util")

local M = {}

local ALIAS_STOP_WORDS = {
  as = true,
  on = true,
  using = true,
  where = true,
  group = true,
  order = true,
  limit = true,
  offset = true,
  having = true,
  union = true,
  except = true,
  intersect = true,
  join = true,
  inner = true,
  left = true,
  right = true,
  full = true,
  cross = true,
  outer = true,
  set = true,
  values = true,
  returning = true,
}

local function sanitize_identifier(value)
  value = vim.trim(value or "")
  if value == "" then
    return ""
  end
  return util.strip_identifier_quotes(value:gsub("[,;]+$", ""))
end

local function parse_table_target(raw_target)
  raw_target = vim.trim(raw_target or "")
  if raw_target == "" or raw_target:find("%(") then
    return nil
  end

  local parts = {}
  for part in raw_target:gmatch("[^%.]+") do
    local identifier = sanitize_identifier(part)
    if identifier ~= "" then
      table.insert(parts, identifier)
    end
  end

  if #parts == 0 then
    return nil
  end
  if #parts == 1 then
    return { schema = nil, table = parts[1] }
  end
  return { schema = parts[#parts - 1], table = parts[#parts] }
end

local function connection_ids(handler)
  local ids = vim.tbl_keys(handler.connections or {})
  table.sort(ids)
  return ids
end

local function line_prefix(line, cursor_col)
  if not line or cursor_col <= 0 then
    return ""
  end
  return line:sub(1, cursor_col)
end

local function cursor_offset(lines, cursor)
  local offset = 1
  for index = 1, math.max(cursor[1] - 1, 0) do
    offset = offset + #(lines[index] or "") + 1
  end
  return offset + cursor[2]
end

local function extract_statement_text(lines, cursor)
  if #lines == 0 then
    lines = { "" }
  end

  local text = table.concat(lines, "\n")
  if text == "" then
    return "", 1
  end

  local offset = math.max(1, math.min(cursor_offset(lines, cursor), #text + 1))
  local start_pos = 1
  for pos = 1, math.max(offset - 1, 1) do
    if text:sub(pos, pos) == ";" then
      start_pos = pos + 1
    end
  end

  local end_pos = #text
  local next_pos = text:find(";", offset, true)
  if next_pos then
    end_pos = next_pos - 1
  end

  return text:sub(start_pos, end_pos), start_pos
end

local function build_aliases(statement)
  local aliases = {}
  local patterns = {
    "[Ff][Rr][Oo][Mm]%s+([^%s,;]+)%s+[Aa][Ss]%s+([`\"%w_]+)",
    "[Ff][Rr][Oo][Mm]%s+([^%s,;]+)%s+([`\"%w_]+)",
    "[Jj][Oo][Ii][Nn]%s+([^%s,;]+)%s+[Aa][Ss]%s+([`\"%w_]+)",
    "[Jj][Oo][Ii][Nn]%s+([^%s,;]+)%s+([`\"%w_]+)",
    "[Uu][Pp][Dd][Aa][Tt][Ee]%s+([^%s,;]+)%s+[Aa][Ss]%s+([`\"%w_]+)",
    "[Uu][Pp][Dd][Aa][Tt][Ee]%s+([^%s,;]+)%s+([`\"%w_]+)",
  }

  local function add(raw_target, raw_alias)
    local alias = sanitize_identifier(raw_alias)
    if alias == "" or ALIAS_STOP_WORDS[alias:lower()] then
      return
    end

    local target = parse_table_target(raw_target)
    if not target then
      return
    end
    aliases[alias] = target
  end

  for _, pattern in ipairs(patterns) do
    local init = 1
    while true do
      local start_pos, end_pos, raw_target, raw_alias = statement:find(pattern, init)
      if not start_pos then
        break
      end
      add(raw_target, raw_alias)
      init = end_pos + 1
    end
  end

  return aliases
end

local function parse_qualifier(prefix)
  local schema, tbl = prefix:match('([`"%w_]+)%.([`"%w_]+)%.([`"%w_]*)$')
  if schema and tbl then
    return {
      kind = "column",
      schema = sanitize_identifier(schema),
      table = sanitize_identifier(tbl),
    }
  end

  local name = prefix:match('([`"%w_]+)%.([`"%w_]*)$')
  if name then
    return {
      kind = "single",
      name = sanitize_identifier(name),
    }
  end

  return nil
end

local function connection_display_name(connection)
  return connection.name or connection.id
end

local function connection_database(connection)
  if not connection then
    return nil
  end

  local kind = (connection.type or ""):lower()
  if (kind == "sqlite" or kind == "sqlite3") and connection.url and connection.url ~= "" then
    return vim.fs.basename(connection.url)
  end
  if connection.database and connection.database ~= "" then
    return connection.database
  end
  return nil
end

local function markdown_bullets(lines)
  return {
    kind = "markdown",
    value = table.concat(lines, "\n"),
  }
end

function M.get_handler()
  if not state.config() then
    return nil
  end
  local ok, handler = pcall(state.handler)
  if not ok then
    return nil
  end
  return handler
end

function M.current_connection_id(handler)
  if handler.current_connection_id and handler.connections[handler.current_connection_id] then
    return handler.current_connection_id
  end
  return connection_ids(handler)[1]
end

function M.sorted_connection_ids(handler)
  return connection_ids(handler)
end

function M.statement_context(bufnr, cursor, line)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local statement, start_pos = extract_statement_text(lines, cursor)
  local buffer_text = table.concat(lines, "\n")
  local absolute_offset = math.max(1, math.min(cursor_offset(lines, cursor), #buffer_text + 1))
  local relative_offset = math.max(0, absolute_offset - start_pos)
  local prefix = line_prefix(line or "", cursor[2])

  return {
    text = statement,
    before_cursor = statement:sub(1, relative_offset),
    refs = util.parse_query_table_references(statement),
    aliases = build_aliases(statement),
    qualifier = parse_qualifier(prefix),
  }
end

function M.resolve_loaded_table_reference(handler, connection_id, schema, tbl)
  if not tbl or tbl == "" then
    return nil
  end

  if connection_id then
    local entry = handler:lookup_table_index(connection_id, schema, tbl)
    if entry then
      return entry
    end
  end

  for _, id in ipairs(connection_ids(handler)) do
    if id ~= connection_id then
      local entry = handler:lookup_table_index(id, schema, tbl)
      if entry then
        return entry
      end
    end
  end

  return nil
end

function M.collect_loaded_table_entries(handler)
  local entries = {}
  local current_id = M.current_connection_id(handler)
  local current_database = connection_database(handler.connections[current_id] or {})

  for _, connection_id in ipairs(connection_ids(handler)) do
    for _, entry in pairs(handler.table_index[connection_id] or {}) do
      table.insert(entries, entry)
    end
  end

  table.sort(entries, function(left, right)
    local left_conn = handler.connections[left.connection_id] or {}
    local right_conn = handler.connections[right.connection_id] or {}
    local left_db = connection_database(left_conn)
    local right_db = connection_database(right_conn)
    local left_priority = left.connection_id == current_id and 0 or 1
    local right_priority = right.connection_id == current_id and 0 or 1
    if left_priority ~= right_priority then
      return left_priority < right_priority
    end

    local left_db_priority = left_db == current_database and 0 or 1
    local right_db_priority = right_db == current_database and 0 or 1
    if left_db_priority ~= right_db_priority then
      return left_db_priority < right_db_priority
    end

    local left_key = util.table_index_key(left.schema, left.table) .. "\0" .. left.connection_id
    local right_key = util.table_index_key(right.schema, right.table) .. "\0" .. right.connection_id
    return left_key < right_key
  end)

  return entries
end

function M.schema_filter(statement)
  local qualifier = statement.qualifier
  if not qualifier or qualifier.kind ~= "single" then
    return nil
  end

  local alias_target = statement.aliases[qualifier.name]
  if alias_target then
    return nil
  end

  for _, ref in ipairs(statement.refs) do
    if ref.table == qualifier.name then
      return nil
    end
  end

  return qualifier.name
end

function M.infer_column_entries(handler, statement)
  local targets = {}
  local seen = {}
  local current_id = M.current_connection_id(handler)

  local function add_target(schema, tbl)
    local entry = M.resolve_loaded_table_reference(handler, current_id, schema, tbl)
    if not entry then
      return
    end

    local key = entry.connection_id .. "\0" .. util.table_index_key(entry.schema, entry.table)
    if seen[key] then
      return
    end
    seen[key] = true
    table.insert(targets, entry)
  end

  local qualifier = statement.qualifier
  if qualifier then
    if qualifier.kind == "column" then
      add_target(qualifier.schema, qualifier.table)
      return targets
    end

    local alias_target = statement.aliases[qualifier.name]
    if alias_target then
      add_target(alias_target.schema, alias_target.table)
      return targets
    end

    for _, ref in ipairs(statement.refs) do
      if ref.table == qualifier.name then
        add_target(ref.schema, ref.table)
        return targets
      end
    end
  end

  if #statement.refs == 1 then
    add_target(statement.refs[1].schema, statement.refs[1].table)
  end

  return targets
end

function M.replace_range(ctx)
  local line = ctx.cursor[1] - 1
  local start_character = math.max(0, (ctx.bounds.start_col or 1) - 1)
  local end_character = math.max(start_character, ctx.cursor[2] or 0)

  return {
    start = { line = line, character = start_character },
    ["end"] = { line = line, character = end_character },
  }
end

function M.connection_label(connection, entry)
  local bits = { connection_display_name(connection) }
  local database = connection_database(connection)
  if database and database ~= "" then
    table.insert(bits, database)
  end
  if entry.schema and entry.schema ~= "" and entry.schema ~= database then
    table.insert(bits, entry.schema)
  end
  return table.concat(bits, " · ")
end

function M.table_documentation(connection, entry)
  local lines = {
    ("# %s"):format(entry.table),
    "",
    ("- connection: `%s`"):format(connection_display_name(connection)),
  }

  local database = connection_database(connection)
  if database and database ~= "" then
    table.insert(lines, ("- database: `%s`"):format(database))
  end
  if entry.schema and entry.schema ~= "" and entry.schema ~= database then
    table.insert(lines, ("- schema: `%s`"):format(entry.schema))
  end
  if entry.materialization and entry.materialization ~= "" then
    table.insert(lines, ("- type: `%s`"):format(entry.materialization))
  end

  return markdown_bullets(lines)
end

function M.column_documentation(connection, entry, column)
  local lines = {
    ("# %s.%s"):format(entry.table, column.name),
    "",
    ("- connection: `%s`"):format(connection_display_name(connection)),
  }

  local database = connection_database(connection)
  if database and database ~= "" then
    table.insert(lines, ("- database: `%s`"):format(database))
  end
  if entry.schema and entry.schema ~= "" and entry.schema ~= database then
    table.insert(lines, ("- schema: `%s`"):format(entry.schema))
  end
  if column.data_type and column.data_type ~= "" then
    table.insert(lines, ("- type: `%s`"):format(column.data_type))
  end
  table.insert(lines, ("- nullable: `%s`"):format(column.nullable and "yes" or "no"))
  table.insert(lines, ("- primary key: `%s`"):format(column.primary_key and "yes" or "no"))
  if column.default_value ~= nil and column.default_value ~= "" then
    table.insert(lines, ("- default: `%s`"):format(tostring(column.default_value)))
  end
  if column.ordinal_position ~= nil then
    table.insert(lines, ("- position: `%s`"):format(tostring(column.ordinal_position)))
  end

  return markdown_bullets(lines)
end

return M
