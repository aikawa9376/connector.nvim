local backend = require("connector.backend")
local completion = require("connector.completion")
local state = require("connector.api.state")
local util = require("connector.util")

local kinds = require("blink.cmp.types").CompletionItemKind

local source = {}

local DEFAULT_OPTS = {
  max_table_items = 250,
  max_column_items = 200,
}

local function empty_response()
  return {
    items = {},
    is_incomplete_backward = false,
    is_incomplete_forward = false,
  }
end

local function table_request_key(connection_id, schema, tbl)
  return connection_id .. "\0" .. util.table_index_key(schema, tbl)
end

function source.new(opts)
  local self = setmetatable({}, { __index = source })
  self.opts = vim.tbl_deep_extend("force", DEFAULT_OPTS, opts or {})
  self.table_requests = {}
  self.column_requests = {}
  self.column_cache = {}
  self.generation = 0
  self.unregister_connections_listener = nil
  return self
end

function source:enabled()
  return state.config() ~= nil and vim.bo.filetype == "sql"
end

function source:get_trigger_characters()
  return { "." }
end

function source:reload()
  self:clear_caches()
end

function source:clear_caches()
  self.generation = self.generation + 1
  self.table_requests = {}
  self.column_requests = {}
  self.column_cache = {}
end

function source:get_handler()
  local handler = completion.get_handler()
  if not handler then
    return nil
  end

  if not self.unregister_connections_listener then
    self.unregister_connections_listener = handler:register_event_listener("connections_changed", function()
      self:clear_caches()
    end)
  end

  return handler
end

function source:request_table_index(handler, connection_id, done)
  if handler.table_index_all_loaded[connection_id] then
    done()
    return
  end

  local pending = self.table_requests[connection_id]
  if pending then
    table.insert(pending.callbacks, done)
    return
  end

  local connection = handler.connections[connection_id]
  if not connection then
    done()
    return
  end

  local generation = self.generation
  local request_conn = vim.deepcopy(connection)
  request_conn.database = nil

  self.table_requests[connection_id] = {
    callbacks = { done },
    generation = generation,
  }

  backend.request_async(state.config(), "structure", {
    connection = util.expand_connection(request_conn),
  }, function(err, result)
    local request = self.table_requests[connection_id]
    if request and request.generation == generation then
      self.table_requests[connection_id] = nil
    end
    if generation ~= self.generation then
      return
    end

    if not err then
      result = result or {}
      handler.structure_cache[connection_id .. ":__all__"] = result
      handler:index_structure_items(connection_id, result)
      handler.table_index_all_loaded[connection_id] = true
    end

    for _, callback in ipairs(request and request.callbacks or {}) do
      callback()
    end
  end)
end

function source:ensure_table_indexes(handler, done)
  local connection_ids = completion.sorted_connection_ids(handler)
  if #connection_ids == 0 then
    done()
    return
  end

  local pending = 0
  local finished = false

  local function complete()
    if finished or pending > 0 then
      return
    end
    finished = true
    done()
  end

  for _, connection_id in ipairs(connection_ids) do
    if not handler.table_index_all_loaded[connection_id] then
      pending = pending + 1
      self:request_table_index(handler, connection_id, function()
        pending = pending - 1
        complete()
      end)
    end
  end

  complete()
end

function source:request_columns(handler, entry, done)
  local key = table_request_key(entry.connection_id, entry.schema, entry.table)
  local cached = self.column_cache[key]
  if cached ~= nil then
    done(cached)
    return
  end

  local pending = self.column_requests[key]
  if pending then
    table.insert(pending.callbacks, done)
    return
  end

  local connection = handler.connections[entry.connection_id]
  if not connection then
    self.column_cache[key] = {}
    done(self.column_cache[key])
    return
  end

  local generation = self.generation
  self.column_requests[key] = {
    callbacks = { done },
    generation = generation,
  }

  backend.request_async(state.config(), "columns", {
    connection = util.expand_connection(connection),
    table = entry.table,
    schema = entry.schema,
    materialization = entry.materialization,
  }, function(err, result)
    local request = self.column_requests[key]
    if request and request.generation == generation then
      self.column_requests[key] = nil
    end
    if generation ~= self.generation then
      return
    end

    self.column_cache[key] = err and {} or (result or {})

    for _, callback in ipairs(request and request.callbacks or {}) do
      callback(self.column_cache[key])
    end
  end)
end

function source:ensure_columns(handler, entries, done)
  if #entries == 0 then
    done()
    return
  end

  local pending = 0
  local finished = false

  local function complete()
    if finished or pending > 0 then
      return
    end
    finished = true
    done()
  end

  for _, entry in ipairs(entries) do
    local key = table_request_key(entry.connection_id, entry.schema, entry.table)
    if self.column_cache[key] == nil then
      pending = pending + 1
      self:request_columns(handler, entry, function()
        pending = pending - 1
        complete()
      end)
    end
  end

  complete()
end

function source:table_item(ctx, handler, entry)
  local connection = handler.connections[entry.connection_id]
  if not connection then
    return nil
  end

  local description = completion.connection_label(connection, entry)
  local detail = entry.materialization and entry.materialization ~= ""
      and ("%s · %s"):format(entry.materialization, description)
    or description

  return {
    label = entry.table,
    filterText = table.concat(vim.tbl_filter(function(value)
      return value and value ~= ""
    end, {
      entry.table,
      entry.schema,
      connection.id,
      connection.name,
      connection.database,
      entry.materialization,
    }), " "),
    sortText = table.concat({
      entry.connection_id == completion.current_connection_id(handler) and "0" or "1",
      entry.schema or "",
      entry.table,
      entry.connection_id,
    }, ":"),
    kind = kinds.Struct,
    detail = detail,
    labelDetails = { description = description },
    documentation = completion.table_documentation(connection, entry),
    insertTextFormat = vim.lsp.protocol.InsertTextFormat.PlainText,
    textEdit = {
      newText = entry.table,
      range = completion.replace_range(ctx),
    },
  }
end

function source:column_item(ctx, handler, entry, column)
  local connection = handler.connections[entry.connection_id]
  if not connection then
    return nil
  end

  local tags = {}
  if column.data_type and column.data_type ~= "" then
    table.insert(tags, column.data_type)
  end
  if column.primary_key then
    table.insert(tags, "PK")
  end
  if column.nullable == false then
    table.insert(tags, "NOT NULL")
  end

  local table_label = entry.schema and entry.schema ~= ""
      and ("%s.%s"):format(entry.schema, entry.table)
    or entry.table

  return {
    label = column.name,
    filterText = table.concat(vim.tbl_filter(function(value)
      return value and value ~= ""
    end, {
      column.name,
      entry.table,
      entry.schema,
      connection.id,
      connection.name,
      column.data_type,
    }), " "),
    sortText = ("%08d:%s:%s"):format(column.ordinal_position or 0, entry.table, column.name),
    kind = column.primary_key and kinds.Property or kinds.Field,
    detail = ("%s · %s"):format(table_label, completion.connection_label(connection, entry)),
    labelDetails = #tags > 0 and { description = table.concat(tags, " · ") } or nil,
    documentation = completion.column_documentation(connection, entry, column),
    insertTextFormat = vim.lsp.protocol.InsertTextFormat.PlainText,
    textEdit = {
      newText = column.name,
      range = completion.replace_range(ctx),
    },
  }
end

function source:build_table_items(ctx, handler, statement)
  local items = {}
  local schema_filter = completion.schema_filter(statement)
  if schema_filter then
    schema_filter = schema_filter:lower()
  end

  for _, entry in ipairs(completion.collect_loaded_table_entries(handler)) do
    if not schema_filter or (entry.schema and entry.schema:lower() == schema_filter) then
      local item = self:table_item(ctx, handler, entry)
      if item then
        table.insert(items, item)
      end
      if #items >= self.opts.max_table_items then
        break
      end
    end
  end

  return items
end

function source:build_column_items(ctx, handler, entries)
  local items = {}
  for _, entry in ipairs(entries) do
    local key = table_request_key(entry.connection_id, entry.schema, entry.table)
    for _, column in ipairs(self.column_cache[key] or {}) do
      local item = self:column_item(ctx, handler, entry, column)
      if item then
        table.insert(items, item)
      end
      if #items >= self.opts.max_column_items then
        return items
      end
    end
  end
  return items
end

function source:get_completions(ctx, callback)
  local handler = self:get_handler()
  if not handler then
    callback(empty_response())
    return function() end
  end

  local request_generation = self.generation
  local canceled = false
  local statement = completion.statement_context(ctx.bufnr, ctx.cursor, ctx.line)

  local function finish()
    if canceled or request_generation ~= self.generation then
      return
    end

    local column_entries = completion.infer_column_entries(handler, statement)
    local items = {}
    local prefer_columns = statement.qualifier ~= nil and #column_entries > 0

    vim.list_extend(items, self:build_column_items(ctx, handler, column_entries))
    if not prefer_columns then
      vim.list_extend(items, self:build_table_items(ctx, handler, statement))
    end

    callback({
      items = items,
      is_incomplete_backward = false,
      is_incomplete_forward = false,
    })
  end

  self:ensure_table_indexes(handler, function()
    if canceled or request_generation ~= self.generation then
      return
    end

    local column_entries = completion.infer_column_entries(handler, statement)
    self:ensure_columns(handler, column_entries, finish)
  end)

  return function()
    canceled = true
  end
end

return source
