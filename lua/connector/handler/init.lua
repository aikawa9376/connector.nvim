local backend = require("connector.backend")
local format = require("connector.format")
local util = require("connector.util")

local uv = vim.uv or vim.loop

local builtin_helpers = {
  sqlite = {
    ["Select all"] = "SELECT * FROM {{ .Table }} LIMIT 200;",
    ["Count rows"] = "SELECT COUNT(*) AS count FROM {{ .Table }};",
  },
  postgres = {
    ["Select all"] = "SELECT * FROM {{ .Table }} LIMIT 200;",
    ["Count rows"] = "SELECT COUNT(*) AS count FROM {{ .Table }};",
  },
  mysql = {
    ["Select all"] = "SELECT * FROM {{ .Table }} LIMIT 200;",
    ["Count rows"] = "SELECT COUNT(*) AS count FROM {{ .Table }};",
  },
}

local Handler = {}

function Handler:new(config)
  local o = {
    config = config,
    sources = {},
    source_conn_lookup = {},
    connections = {},
    current_connection_id = nil,
    calls = {},
    call_order = {},
    running_calls = {},
    structure_cache = {},
    database_cache = {},
    listeners = {},
  }
  setmetatable(o, self)
  self.__index = self

  for _, source in ipairs(config.sources or {}) do
    local ok, err = pcall(o.add_source, o, source)
    if not ok then
      util.notify(("Failed loading source %s: %s"):format(source:name(), err), vim.log.levels.ERROR)
    end
  end

  if config.default_connection then
    pcall(o.set_current_connection, o, config.default_connection)
  end

  if not o.current_connection_id then
    for _, conn_ids in pairs(o.source_conn_lookup) do
      if conn_ids[1] then
        o.current_connection_id = conn_ids[1]
        break
      end
    end
  end

  return o
end

function Handler:register_event_listener(event, listener)
  self.listeners[event] = self.listeners[event] or {}
  table.insert(self.listeners[event], listener)
end

function Handler:emit(event, payload)
  for _, listener in ipairs(self.listeners[event] or {}) do
    listener(payload)
  end
end

function Handler:add_source(source)
  local id = source:name()
  self.sources[id] = source
  self:source_reload(id)
end

function Handler:get_sources()
  local items = vim.tbl_values(self.sources)
  table.sort(items, function(left, right)
    return left:name() < right:name()
  end)
  return items
end

function Handler:add_helpers(helpers)
  for connection_type, entries in pairs(helpers or {}) do
    self.config.extra_helpers[connection_type] = vim.tbl_extend(
      "force",
      self.config.extra_helpers[connection_type] or {},
      entries or {}
    )
  end
end

function Handler:source_reload(id)
  local source = self.sources[id]
  if not source then
    error("source not found: " .. id)
  end

  for _, conn_id in ipairs(self.source_conn_lookup[id] or {}) do
    self.connections[conn_id] = nil
  end

  self.source_conn_lookup[id] = {}
  for _, spec in ipairs(source:load() or {}) do
    spec.id = spec.id or util.random_id("connection")
    spec.source_id = id
    table.insert(self.source_conn_lookup[id], spec.id)
    self.connections[spec.id] = spec
  end

  if self.current_connection_id and not self.connections[self.current_connection_id] then
    self.current_connection_id = nil
  end

  self.structure_cache = {}
  self.database_cache = {}
  self:emit("connections_changed", { source_id = id })
end

function Handler:source_add_connection(id, details)
  local source = assert(self.sources[id], "source not found: " .. id)
  if type(source.create) ~= "function" then
    error("source does not support create")
  end
  local conn_id = source:create(details)
  self:source_reload(id)
  return conn_id
end

function Handler:source_remove_connection(id, conn_id)
  local source = assert(self.sources[id], "source not found: " .. id)
  if type(source.delete) ~= "function" then
    error("source does not support delete")
  end
  source:delete(conn_id)
  self:source_reload(id)
end

function Handler:source_update_connection(id, conn_id, details)
  local source = assert(self.sources[id], "source not found: " .. id)
  if type(source.update) ~= "function" then
    error("source does not support update")
  end
  source:update(conn_id, details)
  self:source_reload(id)
end

function Handler:source_get_connections(id)
  local items = {}
  for _, conn_id in ipairs(self.source_conn_lookup[id] or {}) do
    table.insert(items, vim.deepcopy(self.connections[conn_id]))
  end
  table.sort(items, function(left, right)
    return left.name < right.name
  end)
  return items
end

function Handler:get_current_connection()
  if not self.current_connection_id then
    return nil
  end
  return vim.deepcopy(self.connections[self.current_connection_id])
end

function Handler:set_current_connection(id)
  if not self.connections[id] then
    error("connection not found: " .. id)
  end
  self.current_connection_id = id
  self:emit("current_connection_changed", vim.deepcopy(self.connections[id]))
end

function Handler:connection_get_params(id)
  return vim.deepcopy(self.connections[id])
end

function Handler:connection_get_helpers(id, opts)
  local conn = assert(self.connections[id], "connection not found: " .. id)
  local connection_type = conn.type:lower()
  local helpers = vim.tbl_extend(
    "force",
    builtin_helpers[connection_type] or {},
    self.config.extra_helpers[connection_type] or {}
  )
  local vars = {
    Table = util.qualify_table(connection_type, opts.schema, opts.table),
    Schema = opts.schema or "",
    Materialization = opts.materialization or "table",
  }
  local rendered = {}
  for _, name in ipairs(util.table_keys_sorted(helpers)) do
    rendered[name] = util.render_helper(helpers[name], vars)
  end
  return rendered
end

function Handler:get_call(id)
  local call = self.calls[id]
  return call and vim.deepcopy(call) or nil
end

function Handler:attach_editable_result(conn, query, result)
  local target = util.parse_editable_select(query)
  if not target then
    return result
  end

  local ok, columns = pcall(self.connection_get_columns, self, conn.id, {
    table = target.table,
    schema = target.schema,
    materialization = "table",
  })
  if not ok or not columns or #columns == 0 then
    return result
  end

  if #columns ~= #(result.columns or {}) then
    return result
  end

  local primary_keys = {}
  for index, column in ipairs(columns) do
    local result_column = result.columns[index]
    if not result_column or result_column.name ~= column.name then
      return result
    end
    if column.primary_key then
      table.insert(primary_keys, column.name)
    end
  end

  if #primary_keys == 0 then
    return result
  end

  result.editable = {
    table = target.table,
    schema = target.schema,
    columns = columns,
    primary_keys = primary_keys,
  }
  return result
end

function Handler:connection_execute(id, query)
  local conn = assert(self.connections[id], "connection not found: " .. id)
  local call = {
    id = util.random_id("call"),
    connection_id = id,
    query = query,
    state = "executing",
    started_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    started_at_hr = uv.hrtime(),
    result = nil,
    error = nil,
  }
  self.calls[call.id] = call
  table.insert(self.call_order, 1, call.id)
  self:emit("call_state_changed", vim.deepcopy(call))

  local handle = backend.request_async(self.config, "execute", {
    connection = util.expand_connection(conn),
    query = query,
  }, function(err, result)
    self.running_calls[call.id] = nil
    if call.state == "canceled" then
      self:emit("call_state_changed", vim.deepcopy(call))
      return
    end

    if err then
      call.state = "failed"
      call.error = tostring(err)
    else
      call.state = "archived"
      call.result = self:attach_editable_result(conn, query, result)
      call.error = nil
    end
    if call.started_at_hr then
      call.time_taken_s = (uv.hrtime() - call.started_at_hr) / 1e9
    end
    call.completed_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
    self:emit("call_state_changed", vim.deepcopy(call))
  end)
  self.running_calls[call.id] = handle
  return vim.deepcopy(call)
end

function Handler:connection_get_structure(id)
  if self.structure_cache[id] then
    return vim.deepcopy(self.structure_cache[id])
  end
  local conn = assert(self.connections[id], "connection not found: " .. id)
  local result = backend.request_sync(self.config, "structure", { connection = util.expand_connection(conn) }) or {}
  self.structure_cache[id] = result
  return vim.deepcopy(result)
end

function Handler:connection_get_columns(id, opts)
  local conn = assert(self.connections[id], "connection not found: " .. id)
  return backend.request_sync(self.config, "columns", {
    connection = util.expand_connection(conn),
    table = opts.table,
    schema = opts.schema,
    materialization = opts.materialization,
  }) or {}
end

function Handler:connection_list_databases(id)
  if self.database_cache[id] then
    local cached = self.database_cache[id]
    return cached.current, vim.deepcopy(cached.available)
  end
  local conn = assert(self.connections[id], "connection not found: " .. id)
  local result = backend.request_sync(self.config, "list-databases", { connection = util.expand_connection(conn) }) or {}
  self.database_cache[id] = result
  return result.current or "", vim.deepcopy(result.available or {})
end

function Handler:connection_select_database(id, database)
  local conn = assert(self.connections[id], "connection not found: " .. id)
  conn.database = database
  self.structure_cache[id] = nil
  self.database_cache[id] = nil
  self:emit("connections_changed", { source_id = conn.source_id })
end

function Handler:connection_get_calls(id)
  local calls = {}
  for _, call_id in ipairs(self.call_order) do
    local call = self.calls[call_id]
    if call and call.connection_id == id then
      table.insert(calls, vim.deepcopy(call))
    end
  end
  return calls
end

function Handler:call_cancel(id)
  local call = assert(self.calls[id], "call not found: " .. id)
  local handle = self.running_calls[id]
  if handle and handle.kill then
    pcall(handle.kill, handle, 15)
  end
  self.running_calls[id] = nil
  call.state = "canceled"
  if call.started_at_hr then
    call.time_taken_s = (uv.hrtime() - call.started_at_hr) / 1e9
  end
  call.completed_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
  self:emit("call_state_changed", vim.deepcopy(call))
end

function Handler:call_display_result(id, bufnr, from, to)
  local call = assert(self.calls[id], "call not found: " .. id)
  local result = assert(call.result, "call has no result")
  local lines = format.to_table_lines(result, from, to)
  util.buf_set_lines(bufnr, lines)
  return #(result.rows or {})
end

function Handler:call_store_result(id, output_format, output, opts)
  local call = assert(self.calls[id], "call not found: " .. id)
  local result = assert(call.result, "call has no result")
  opts = opts or {}
  local from = opts.from or 0
  local to = opts.to or #(result.rows or {})

  local content
  if output_format == "json" then
    content = format.to_json(result, from, to)
  elseif output_format == "csv" then
    content = format.to_csv(result, from, to)
  elseif output_format == "table" then
    local lines = format.to_table_lines(result, from, to)
    content = table.concat(lines, "\n")
  else
    error("unsupported output format: " .. output_format)
  end

  if output == "yank" then
    vim.fn.setreg(opts.extra_arg or '"', content)
  elseif output == "file" then
    assert(opts.extra_arg, "file output requires path in extra_arg")
    util.write_file(opts.extra_arg, content)
  elseif output == "buffer" then
    local bufnr = tonumber(opts.extra_arg) or vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_option(bufnr, "modifiable", true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(content, "\n"))
    vim.api.nvim_buf_set_option(bufnr, "modifiable", false)
  else
    error("unsupported output: " .. output)
  end
end

function Handler:call_update_cell(id, row_index, column_index, new_value_text)
  local call = assert(self.calls[id], "call not found: " .. id)
  local result = assert(call.result, "call has no result")
  local editable = assert(result.editable, "result is not editable")
  local row = assert(result.rows[row_index + 1], "row out of range")
  local column = assert(editable.columns[column_index], "column out of range")
  if column.primary_key then
    error("primary key columns are read-only")
  end

  local keys = {}
  for index, meta in ipairs(editable.columns) do
    if meta.primary_key then
      table.insert(keys, {
        name = meta.name,
        data_type = meta.data_type,
        nullable = meta.nullable,
        value = row[index],
      })
    end
  end

  if #keys == 0 then
    error("editable result has no primary key metadata")
  end

  local conn = assert(self.connections[call.connection_id], "connection not found: " .. call.connection_id)
  local response = backend.request_sync(self.config, "update-row", {
    connection = util.expand_connection(conn),
    table = editable.table,
    schema = editable.schema,
    column = {
      name = column.name,
      data_type = column.data_type,
      nullable = column.nullable,
    },
    keys = keys,
    new_value_text = new_value_text,
  })
  if not response or response.affected_rows == 0 then
    error("update did not affect any rows")
  end

  row[column_index] = response.value
  self:emit("call_state_changed", vim.deepcopy(call))
  return response.value
end

return Handler
