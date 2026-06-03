local buffer_line = require("connector.ui.buffer_line")
local candies_module = require("connector.ui.candies")

local M = {}

function M.visible_calls(handler)
  local connection = handler:get_current_connection()
  local calls = connection and handler:connection_get_calls(connection.id) or {}
  if #calls == 0 then
    calls = handler:get_calls()
  end
  return calls
end

function M.build_call_line(call, opts)
  opts = opts or {}

  local builder = buffer_line.new_builder()
  local query = (call.query or ""):gsub("%s+", " ")
  local indent = opts.indent or ""
  local candies = opts.candies or candies_module.call_log_defaults()
  local width = opts.width or 40

  if indent ~= "" then
    buffer_line.append(builder, indent)
  end

  if opts.disable_candies then
    buffer_line.append(builder, ("[%s] %s"):format(call.state, query), opts.text_highlight)
    return builder
  end

  local candy = candies_module.get(candies, call.state, "unknown")
  local preview = candy.icon
  if not preview or preview == "" then
    preview = candies_module.state_initials(call.state)
  end

  buffer_line.append(builder, buffer_line.pad_display(preview, 3), candy.icon_highlight)
  buffer_line.append(builder, buffer_line.truncate_display(query, width), candy.text_highlight ~= "" and candy.text_highlight or nil)
  return builder
end

return M
