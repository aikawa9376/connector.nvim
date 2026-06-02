local api = require("connector.api")
local backend = require("connector.backend")
local config = require("connector.config")

local connector = {
  api = {
    core = api.core,
    ui = api.ui,
  },
}

local blink_provider_keys = {
  async = true,
  enabled = true,
  fallbacks = true,
  get_completions = true,
  kind = true,
  max_items = true,
  min_keyword_length = true,
  module = true,
  name = true,
  opts = true,
  resolve = true,
  score_offset = true,
  should_show_items = true,
  timeout_ms = true,
  transform_items = true,
  trigger_characters = true,
}

local function has_top_level_blink_provider_overrides(opts)
  for key in pairs(opts) do
    if key ~= "provider" and key ~= "source" and blink_provider_keys[key] then
      return true
    end
  end

  return false
end

local function top_level_blink_provider_overrides(opts)
  local overrides = {}

  for key, value in pairs(opts) do
    if key ~= "provider" and key ~= "source" and blink_provider_keys[key] then
      overrides[key] = value
    end
  end

  return overrides
end

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

function connector.install(opts)
  return backend.install(api.current_config() or config.default(), opts)
end

function connector.scratchpads(opts)
  return connector.api.ui.editor_scratchpads(opts or {})
end

function connector.scratchpads_fzf_source(opts)
  local entries = connector.scratchpads(opts or {})
  return vim.tbl_map(function(entry)
    return entry.display
  end, entries)
end

function connector.pick_scratchpad(opts)
  return connector.api.ui.editor_pick_scratchpad(opts or {})
end

function connector.grep_scratchpads(opts)
  if type(opts) == "string" then
    opts = { search = opts }
  end
  return connector.api.ui.editor_grep_scratchpads(opts or {})
end

function connector.blink_source(opts)
  opts = opts or {}
  local uses_provider_overrides = opts.source ~= nil or opts.provider ~= nil or has_top_level_blink_provider_overrides(opts)
  local provider_opts = opts.provider or {}
  local source_opts = uses_provider_overrides and (opts.source or {}) or opts
  local provider_overrides = top_level_blink_provider_overrides(opts)

  return vim.tbl_deep_extend("force", {
    name = "Connector",
    module = "connector.blink",
    async = true,
    min_keyword_length = 0,
    opts = source_opts,
  }, provider_overrides, provider_opts)
end

return connector
