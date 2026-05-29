local api = require("connector.api")
local backend = require("connector.backend")
local config = require("connector.config")

local connector = {
  api = {
    core = api.core,
    ui = api.ui,
  },
}

function connector.setup(cfg)
  local merged = config.merge_with_default(cfg)
  config.validate(merged)
  api.setup(merged)
end

function connector.open()
  if api.current_config().window_layout:is_open() then
    return api.current_config().window_layout:reset()
  end
  api.current_config().window_layout:open()
end

function connector.close()
  if api.current_config().window_layout:is_open() then
    api.current_config().window_layout:close()
  end
end

function connector.toggle()
  if api.current_config().window_layout:is_open() then
    connector.close()
  else
    connector.open()
  end
end

function connector.is_open()
  return api.current_config().window_layout:is_open()
end

function connector.execute(query)
  local connection = api.core.get_current_connection()
  if not connection then
    error("no active connection selected")
  end
  local call = api.core.connection_execute(connection.id, query)
  api.ui.result_set_call(call)
  connector.open()
end

function connector.store(format_name, output, opts)
  local call = api.ui.result_get_call()
  if not call then
    error("no current result to store")
  end
  api.core.call_store_result(call.id, format_name, output, opts or {})
end

function connector.install()
  return backend.install(api.current_config() or config.default())
end

return connector

