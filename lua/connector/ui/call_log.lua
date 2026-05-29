local util = require("connector.util")

local CallLogUI = {}

function CallLogUI:new(handler, result, config)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].filetype = "connector-call-log"

  local o = {
    handler = handler,
    result = result,
    config = config,
    bufnr = bufnr,
    window = nil,
    line_map = {},
  }
  setmetatable(o, self)
  self.__index = self

  util.apply_buffer_mappings(bufnr, config.mappings, function(action)
    o:do_action(action)
  end)

  handler:register_event_listener("call_state_changed", function()
    o:refresh()
  end)
  handler:register_event_listener("current_connection_changed", function()
    o:refresh()
  end)

  return o
end

function CallLogUI:refresh()
  local connection = self.handler:get_current_connection()
  local calls = connection and self.handler:connection_get_calls(connection.id) or {}
  local lines = {
    connection and ("Call log: " .. connection.name) or "Call log",
    "",
  }
  self.line_map = {}
  for _, call in ipairs(calls) do
    local line = ("[%s] %s"):format(call.state, call.query:gsub("%s+", " "))
    table.insert(lines, line)
    self.line_map[#lines] = call.id
  end
  if #calls == 0 then
    table.insert(lines, "No calls yet.")
  end
  util.buf_set_lines(self.bufnr, lines)
end

function CallLogUI:show(winid)
  self.window = winid
  vim.api.nvim_win_set_buf(winid, self.bufnr)
  self:refresh()
end

function CallLogUI:do_action(action)
  local call_id = self.line_map[vim.api.nvim_win_get_cursor(0)[1]]
  if not call_id then
    return
  end
  if action == "show_result" then
    local call = self.handler:get_call(call_id)
    if call then
      self.result:set_call(call)
    end
  elseif action == "cancel_call" then
    self.handler:call_cancel(call_id)
  end
end

return CallLogUI

