local backend = require("connector.backend")
local format = require("connector.format")
local history_module = require("connector.history")
local util = require("connector.util")

local uv = vim.uv or vim.loop

local postgres_constraint_query = [[
SELECT tc.constraint_name, tc.table_name, kcu.column_name, ccu.table_name AS foreign_table_name, ccu.column_name AS foreign_column_name, rc.update_rule, rc.delete_rule
FROM information_schema.table_constraints AS tc
JOIN information_schema.key_column_usage AS kcu ON tc.constraint_name = kcu.constraint_name
JOIN information_schema.referential_constraints AS rc ON tc.constraint_name = rc.constraint_name
JOIN information_schema.constraint_column_usage AS ccu ON ccu.constraint_name = tc.constraint_name
]]

local builtin_helpers = {
  sqlite = {
    List = "SELECT * FROM {{ .Table }} LIMIT 500;",
    Columns = "PRAGMA table_info('{{ .TableName }}');",
    Indexes = "SELECT * FROM pragma_index_list('{{ .TableName }}');",
    ["Foreign Keys"] = "SELECT * FROM pragma_foreign_key_list('{{ .TableName }}');",
    ["Primary Keys"] = "SELECT * FROM pragma_index_list('{{ .TableName }}') WHERE origin = 'pk';",
  },
  postgres = {
    List = "SELECT * FROM {{ .Table }} LIMIT 500;",
    Columns = "SELECT * FROM information_schema.columns WHERE table_name = '{{ .TableName }}' AND table_schema = '{{ .Schema }}';",
    Indexes = "SELECT * FROM pg_indexes WHERE tablename = '{{ .TableName }}' AND schemaname = '{{ .Schema }}';",
    ["Foreign Keys"] = postgres_constraint_query
      .. " WHERE tc.constraint_type = 'FOREIGN KEY' AND tc.table_name = '{{ .TableName }}' AND tc.table_schema = '{{ .Schema }}';",
    ["Primary Keys"] = postgres_constraint_query
      .. " WHERE tc.constraint_type = 'PRIMARY KEY' AND tc.table_name = '{{ .TableName }}' AND tc.table_schema = '{{ .Schema }}';",
  },
  mysql = {
    List = "SELECT * FROM {{ .Table }} LIMIT 500;",
    Columns = "DESCRIBE {{ .Table }};",
    Indexes = "SHOW INDEXES FROM {{ .Table }};",
    ["Foreign Keys"] = "SELECT * FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS WHERE TABLE_SCHEMA = '{{ .Schema }}' AND TABLE_NAME = '{{ .TableName }}' AND CONSTRAINT_TYPE = 'FOREIGN KEY';",
    ["Primary Keys"] = "SELECT * FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS WHERE TABLE_SCHEMA = '{{ .Schema }}' AND TABLE_NAME = '{{ .TableName }}' AND CONSTRAINT_TYPE = 'PRIMARY KEY';",
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
    table_index = {},
    table_index_all_loaded = {},
    listeners = {},
    history = history_module.new(config.history),
    project_provider = nil,
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

  o:load_history_calls()

  return o
end

function Handler:set_project_provider(provider)
  self.project_provider = provider
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
  self.table_index = {}
  self.table_index_all_loaded = {}
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
  local schema = opts.schema or ""
  if schema == "" and connection_type == "postgres" then
    schema = "public"
  end
  local vars = {
    Table = util.qualify_table(connection_type, schema ~= "" and schema or nil, opts.table),
    Schema = schema,
    TableName = opts.table or "",
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

function Handler:current_project()
  if self.project_provider then
    local ok, project = pcall(self.project_provider)
    if ok and project then
      return project
    end
  end
  return util.resolve_project()
end

function Handler:query_history_context()
  local project = self:current_project()
  local branch = project and project.branch or nil
  if project and project.root then
    branch = branch or util.get_git_branch(project.root)
  end
  return {
    project = project and project.name or nil,
    project_root = project and project.root or nil,
    branch = branch,
  }
end

function Handler:history_entry_for_call(call)
  local conn = self.connections[call.connection_id]
  if not conn then
    return nil
  end
  local context = self:query_history_context()
  return vim.tbl_extend("force", context, {
    connection_id = call.connection_id,
    connection_name = conn.name,
    connection_type = conn.type,
    database = conn.database,
    source_id = conn.source_id,
    query = call.query,
    state = call.state,
    tables = util.parse_query_table_references(call.query),
    executed_at = call.completed_at or call.started_at or os.date("!%Y-%m-%dT%H:%M:%SZ"),
  })
end

function Handler:load_history_calls()
  for _, entry in ipairs(self.history:list()) do
    if entry.connection_id and self.connections[entry.connection_id] then
      local call = {
        id = entry.id,
        history_id = entry.id,
        connection_id = entry.connection_id,
        query = entry.query,
        state = "history",
        started_at = entry.executed_at,
        completed_at = entry.executed_at,
        result = nil,
        error = nil,
        project = entry.project,
        branch = entry.branch,
      }
      self.calls[call.id] = call
      table.insert(self.call_order, call.id)
    end
  end
end

function Handler:record_call_history(call)
  local entry = self:history_entry_for_call(call)
  if not entry then
    return nil
  end
  local ok, saved = pcall(self.history.record, self.history, entry)
  if not ok then
    util.notify(("Failed to save query history: %s"):format(saved), vim.log.levels.ERROR)
    return nil
  end
  call.history_id = saved.id
  call.project = saved.project
  call.branch = saved.branch
  return saved
end

function Handler:query_history(opts)
  opts = opts or {}
  -- Default to current project/branch when not explicitly provided so history shown
  -- in UI (left-bottom, table history, etc.) is scoped to project context.
  local ctx = self:query_history_context()
  if opts.project == nil then opts.project = ctx.project end
  if opts.branch == nil then opts.branch = ctx.branch end

  local entries = self.history:list(opts)
  if opts.include_missing_connections then
    return entries
  end
  return vim.tbl_filter(function(entry)
    return entry.connection_id and self.connections[entry.connection_id] ~= nil
  end, entries)
end

function Handler:call_neighbor(id, direction)
  local current = self.calls[id]
  if not current then
    return nil
  end

  local context = self:query_history_context()
  local project = current.project or context.project
  local branch = current.branch or context.branch
  local current_index = nil
  for index, call_id in ipairs(self.call_order) do
    if call_id == id then
      current_index = index
      break
    end
  end
  if not current_index then
    return nil
  end

  local step = direction == "newer" and -1 or 1
  local index = current_index + step
  while index >= 1 and index <= #self.call_order do
    local candidate = self.calls[self.call_order[index]]
    local same_connection = candidate and candidate.connection_id == current.connection_id
    local same_project = not project or candidate.project == project
    local same_branch = not branch or candidate.branch == branch
    if same_connection and same_project and same_branch then
      return vim.deepcopy(candidate)
    end
    index = index + step
  end
  return nil
end

function Handler:result_neighbor(id, direction)
  local current = self.calls[id]
  if not current then
    return nil
  end

  local current_index = nil
  for index, call_id in ipairs(self.call_order) do
    if call_id == id then
      current_index = index
      break
    end
  end
  if not current_index then
    return nil
  end

  local step = direction == "newer" and -1 or 1
  local index = current_index + step
  while index >= 1 and index <= #self.call_order do
    local candidate = self.calls[self.call_order[index]]
    if candidate and candidate.state == "archived" and candidate.result then
      return vim.deepcopy(candidate)
    end
    index = index + step
  end
  return nil
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

function Handler:connection_execute(id, query, done)
  local resolved_id, entries = self:prepare_query_context(id, query)
  if entries then
    self:pick_table_context(id, entries, { notify = true }, function(chosen_id)
      if not chosen_id then
        if done then
          done(nil)
        end
        return
      end
      local call = self:begin_connection_execute(chosen_id, query)
      if done then
        done(call)
      end
    end)
    return nil
  end

  local call = self:begin_connection_execute(resolved_id or id, query)
  if done then
    done(call)
  end
  return call
end

function Handler:begin_connection_execute(id, query)
  local ctx = self:query_history_context()
  local call = {
    id = util.random_id("call"),
    connection_id = id,
    query = query,
    state = "executing",
    started_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    started_at_hr = uv.hrtime(),
    result = nil,
    error = nil,
    context_retried = false,
    project = ctx.project,
    branch = ctx.branch,
  }
  self.calls[call.id] = call
  table.insert(self.call_order, 1, call.id)
  self:emit("call_state_changed", vim.deepcopy(call))
  self:run_call(call)
  return vim.deepcopy(call)
end

function Handler:run_call(call)
  assert(self.connections[call.connection_id], "connection not found: " .. call.connection_id)
  local handle = backend.request_async(self.config, "execute", {
    connection = util.expand_connection(self.connections[call.connection_id]),
    query = call.query,
  }, function(err, result)
    self.running_calls[call.id] = nil
    if call.state == "canceled" then
      self:emit("call_state_changed", vim.deepcopy(call))
      return
    end

    if err and not call.context_retried then
      local entries = self:failed_retry_candidates(call.query, call.connection_id)
      if #entries == 1 then
        call.context_retried = true
        call.connection_id = self:apply_table_context(call.connection_id, entries[1], { notify = true })
        call.state = "executing"
        call.error = nil
        self:emit("call_state_changed", vim.deepcopy(call))
        self:run_call(call)
        return
      elseif #entries > 1 then
        call.context_retried = true
        self:pick_table_context(call.connection_id, entries, { notify = true }, function(chosen_id)
          if chosen_id then
            call.connection_id = chosen_id
            call.state = "executing"
            call.error = nil
            self:emit("call_state_changed", vim.deepcopy(call))
            self:run_call(call)
          else
            call.state = "failed"
            call.error = tostring(err)
            if call.started_at_hr then
              call.time_taken_s = (uv.hrtime() - call.started_at_hr) / 1e9
            end
            call.completed_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
            self:emit("call_state_changed", vim.deepcopy(call))
          end
        end)
        return
      end
    end

    if err then
      call.state = "failed"
      call.error = tostring(err)
    else
      call.state = "archived"
      local current_conn = self.connections[call.connection_id]
      call.result = self:attach_editable_result(current_conn, call.query, result)
      call.error = nil
    end
    if call.started_at_hr then
      call.time_taken_s = (uv.hrtime() - call.started_at_hr) / 1e9
    end
    call.completed_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
    self:record_call_history(call)
    self:emit("call_state_changed", vim.deepcopy(call))
  end)
  self.running_calls[call.id] = handle
end

function Handler:clear_table_index(id)
  self.table_index[id] = nil
  self.table_index_all_loaded[id] = nil
end

function Handler:format_table_entry_label(entry)
  local conn = self.connections[entry.connection_id]
  local conn_name = conn and conn.name or entry.connection_id
  if entry.schema and entry.schema ~= "" then
    return ("%s · %s.%s"):format(conn_name, entry.schema, entry.table)
  end
  return ("%s · %s"):format(conn_name, entry.table)
end

function Handler:pick_table_context(connection_id, entries, opts, on_done)
  local labels = vim.tbl_map(function(entry)
    return self:format_table_entry_label(entry)
  end, entries)

  vim.ui.select(labels, { prompt = "Select table location" }, function(_choice, idx)
    if not idx then
      on_done(nil)
      return
    end
    local entry = entries[idx]
    if not entry then
      on_done(nil)
      return
    end
    on_done(self:apply_table_context(connection_id, entry, opts or {}))
  end)
end

function Handler:candidates_for_ref(connection_id, ref)
  if ref.schema then
    local entry = self:resolve_table_reference(connection_id, ref.schema, ref.table)
    return entry and { entry } or {}
  end
  return self:find_table_entries(connection_id, ref.table)
end

function Handler:prepare_query_context(connection_id, query)
  local refs = util.parse_query_table_references(query)
  if #refs == 0 then
    return connection_id, nil
  end

  self:ensure_table_index(connection_id)
  local entries = self:candidates_for_ref(connection_id, refs[1])
  if #entries == 0 then
    return connection_id, nil
  end
  if #entries == 1 then
    return self:apply_table_context(connection_id, entries[1], { notify = true }), nil
  end
  return nil, entries
end

function Handler:failed_retry_candidates(query, connection_id)
  local refs = util.parse_query_table_references(query)
  if #refs == 0 then
    return {}
  end

  local conn = self.connections[connection_id]
  local current_db = conn and conn.database or ""
  local ref = refs[1]

  if ref.schema then
    self:ensure_table_index(connection_id)
    local entry = self:resolve_table_reference(connection_id, ref.schema, ref.table)
    if not entry then
      return {}
    end
    local entry_db = entry.schema or ""
    if entry.connection_id ~= connection_id or entry_db ~= current_db then
      return { entry }
    end
    return {}
  end

  self:ensure_table_index(connection_id)
  local entries = {}
  for _, entry in ipairs(self:find_table_entries(connection_id, ref.table)) do
    local entry_db = entry.schema or ""
    if entry.connection_id ~= connection_id or entry_db ~= current_db then
      table.insert(entries, entry)
    end
  end
  return entries
end

function Handler:index_structure_items(connection_id, items)
  if not items or #items == 0 then
    return
  end

  self.table_index[connection_id] = self.table_index[connection_id] or {}
  local index = self.table_index[connection_id]
  for _, item in ipairs(items) do
    local schema = item.schema or ""
    local key = util.table_index_key(schema ~= "" and schema or nil, item.name)
    index[key] = {
      connection_id = connection_id,
      schema = schema ~= "" and schema or nil,
      table = item.name,
      materialization = item.materialization,
    }
  end
end

function Handler:ensure_table_index(connection_id)
  if self.table_index_all_loaded[connection_id] then
    return
  end

  local ok = pcall(self.connection_get_structure, self, connection_id, "", { all = true })
  if ok then
    self.table_index_all_loaded[connection_id] = true
  end
end

function Handler:lookup_table_index(connection_id, schema, tbl)
  local index = self.table_index[connection_id]
  if not index then
    return nil
  end

  if schema and schema ~= "" then
    return index[util.table_index_key(schema, tbl)]
  end

  local conn = self.connections[connection_id]
  local current_schema = conn and conn.database or ""
  if current_schema ~= "" then
    local entry = index[util.table_index_key(current_schema, tbl)]
    if entry then
      return entry
    end
  end

  local entry = index[tbl]
  if entry then
    return entry
  end

  local suffix = "\0" .. tbl
  for key, candidate in pairs(index) do
    if vim.endswith(key, suffix) then
      return candidate
    end
  end

  return nil
end

function Handler:find_table_entries(connection_id, tbl)
  local entries = {}
  local seen = {}

  local function collect(id)
    self:ensure_table_index(id)
    local index = self.table_index[id]
    if not index then
      return
    end
    local suffix = "\0" .. tbl
    for key, entry in pairs(index) do
      if key == tbl or vim.endswith(key, suffix) then
        local dedupe = util.table_index_key(entry.schema, entry.table) .. "\0" .. entry.connection_id
        if not seen[dedupe] then
          seen[dedupe] = true
          table.insert(entries, entry)
        end
      end
    end
  end

  collect(connection_id)
  for id in pairs(self.connections) do
    if id ~= connection_id then
      collect(id)
    end
  end

  table.sort(entries, function(left, right)
    local left_key = left.connection_id .. "\0" .. util.table_index_key(left.schema, left.table)
    local right_key = right.connection_id .. "\0" .. util.table_index_key(right.schema, right.table)
    return left_key < right_key
  end)

  return entries
end

function Handler:resolve_table_reference(connection_id, schema, tbl)
  self:ensure_table_index(connection_id)
  local entry = self:lookup_table_index(connection_id, schema, tbl)
  if entry then
    return entry
  end

  for id in pairs(self.connections) do
    if id ~= connection_id then
      self:ensure_table_index(id)
      entry = self:lookup_table_index(id, schema, tbl)
      if entry then
        return entry
      end
    end
  end

  return nil
end

function Handler:apply_table_context(connection_id, entry, opts)
  opts = opts or {}
  local changed = false
  local database = entry.schema

  if entry.connection_id ~= connection_id then
    connection_id = entry.connection_id
    self:set_current_connection(connection_id)
    changed = true
  end

  local conn = self.connections[connection_id]
  local kind = (conn.type or ""):lower()
  if (kind == "mysql" or kind == "mariadb") and database and database ~= "" then
    local current_db = self:connection_list_databases(connection_id)
    if current_db ~= database then
      self:connection_select_database(connection_id, database)
      changed = true
      if opts.notify then
        util.notify(("Switched to database %s"):format(database), vim.log.levels.INFO)
      end
    end
  end

  if changed then
    self:emit("query_context_changed", {
      connection_id = connection_id,
      database = database,
      source_id = conn.source_id,
    })
  end

  return connection_id
end

function Handler:apply_query_context(connection_id, query)
  local resolved_id, entries = self:prepare_query_context(connection_id, query)
  if entries then
    return connection_id
  end
  return resolved_id or connection_id
end

function Handler:clear_structure_cache(id)
  for key in pairs(self.structure_cache) do
    if key == id or vim.startswith(key, id .. ":") then
      self.structure_cache[key] = nil
    end
  end
  self:clear_table_index(id)
end

function Handler:connection_get_structure(id, database, opts)
  if type(database) == "table" then
    opts = database
    database = ""
  end
  opts = opts or {}
  database = database or ""

  local conn = assert(self.connections[id], "connection not found: " .. id)
  local cache_key
  if opts.all then
    cache_key = id .. ":__all__"
  elseif database ~= "" then
    cache_key = id .. ":" .. database
  else
    cache_key = id
  end

  if self.structure_cache[cache_key] then
    return vim.deepcopy(self.structure_cache[cache_key])
  end

  local request_conn = vim.deepcopy(conn)
  if opts.all then
    request_conn.database = nil
  elseif database ~= "" then
    request_conn.database = database
  end
  local result = backend.request_sync(self.config, "structure", {
    connection = util.expand_connection(request_conn),
  }) or {}
  self.structure_cache[cache_key] = result
  self:index_structure_items(id, result)
  if opts.all then
    self.table_index_all_loaded[id] = true
  end
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
  self:clear_structure_cache(id)
  self.database_cache[id] = nil
  self:emit("connections_changed", { source_id = conn.source_id })
end

function Handler:connection_get_calls(id)
  local ctx = self:query_history_context()
  local project = ctx.project
  local branch = ctx.branch
  local calls = {}
  for _, call_id in ipairs(self.call_order) do
    local call = self.calls[call_id]
    if call and call.connection_id == id then
      if project and call.project ~= project then
        -- skip entries from other projects
      elseif branch and call.branch ~= branch then
        -- skip entries from other branches
      else
        table.insert(calls, vim.deepcopy(call))
      end
    end
  end
  return calls
end

function Handler:get_calls()
  local ctx = self:query_history_context()
  local project = ctx.project
  local branch = ctx.branch
  local calls = {}
  for _, call_id in ipairs(self.call_order) do
    local call = self.calls[call_id]
    if call then
      if project and call.project ~= project then
        -- skip entries from other projects
      elseif branch and call.branch ~= branch then
        -- skip entries from other branches
      else
        table.insert(calls, vim.deepcopy(call))
      end
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
