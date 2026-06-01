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
  api.core.connection_execute(connection.id, query, function(call)
    if call then
      api.ui.result_set_call(call)
      connector.open()
    end
  end)
end

function connector.store(format_name, output, opts)
  local call = api.ui.result_get_call()
  if not call then
    error("no current result to store")
  end
  api.core.call_store_result(call.id, format_name, output, opts or {})
end

function connector.history(opts)
  return api.core.query_history(opts or {})
end

function connector.history_fzf_source(opts)
  local entries = connector.history(opts or {})
  return vim.tbl_map(function(entry)
    return entry.display
  end, entries)
end

function connector.install()
  return backend.install(api.current_config() or config.default())
end

function connector.blink_source(opts)
  opts = opts or {}
  local source_opts = opts.source or opts
  local provider_opts = opts.provider or {}

  return vim.tbl_deep_extend("force", {
    name = "Connector",
    module = "connector.blink",
    async = true,
    min_keyword_length = 0,
    opts = source_opts,
  }, provider_opts)
end

return connector
