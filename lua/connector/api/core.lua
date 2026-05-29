local state = require("connector.api.state")

local core = {}

function core.is_loaded()
  return state.is_core_loaded()
end

function core.register_event_listener(event, listener)
  state.handler():register_event_listener(event, listener)
end

function core.add_helpers(helpers)
  state.handler():add_helpers(helpers)
end

function core.add_source(source)
  state.handler():add_source(source)
end

function core.get_sources()
  return state.handler():get_sources()
end

function core.source_reload(id)
  state.handler():source_reload(id)
end

function core.source_add_connection(id, details)
  return state.handler():source_add_connection(id, details)
end

function core.source_remove_connection(id, conn_id)
  state.handler():source_remove_connection(id, conn_id)
end

function core.source_update_connection(id, conn_id, details)
  state.handler():source_update_connection(id, conn_id, details)
end

function core.source_get_connections(id)
  return state.handler():source_get_connections(id)
end

function core.get_current_connection()
  return state.handler():get_current_connection()
end

function core.set_current_connection(id)
  state.handler():set_current_connection(id)
end

function core.connection_execute(id, query, done)
  return state.handler():connection_execute(id, query, done)
end

function core.connection_get_structure(id)
  return state.handler():connection_get_structure(id)
end

function core.connection_get_columns(id, opts)
  return state.handler():connection_get_columns(id, opts)
end

function core.connection_get_params(id)
  return state.handler():connection_get_params(id)
end

function core.connection_get_helpers(id, opts)
  return state.handler():connection_get_helpers(id, opts)
end

function core.connection_list_databases(id)
  return state.handler():connection_list_databases(id)
end

function core.connection_select_database(id, database)
  state.handler():connection_select_database(id, database)
end

function core.connection_get_calls(id)
  return state.handler():connection_get_calls(id)
end

function core.call_cancel(id)
  state.handler():call_cancel(id)
end

function core.call_display_result(id, bufnr, from, to)
  return state.handler():call_display_result(id, bufnr, from, to)
end

function core.call_store_result(id, format_name, output, opts)
  state.handler():call_store_result(id, format_name, output, opts)
end

function core.call_update_cell(id, row_index, column_index, new_value_text)
  return state.handler():call_update_cell(id, row_index, column_index, new_value_text)
end

return core
