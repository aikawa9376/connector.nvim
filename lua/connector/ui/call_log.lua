local buffer_line = require("connector.ui.buffer_line")
local candies_module = require("connector.ui.candies")
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
    ns = vim.api.nvim_create_namespace("connector-call-log"),
    window = nil,
    line_map = {},
    candies = config.disable_candies and {} or vim.tbl_deep_extend("force", candies_module.call_log_defaults(), config.candies or {}),
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

function CallLogUI:state_preview(state)
  local candy = candies_module.get(self.candies, state, "unknown")
  local preview = candy.icon
  if not preview or preview == "" then
    preview = candies_module.state_initials(state)
  end
  return buffer_line.pad_display(preview, 3), candy
end

function CallLogUI:build_call_line(call)
  local builder = buffer_line.new_builder()
  local query = call.query:gsub("%s+", " ")

  if self.config.disable_candies then
    buffer_line.append(builder, ("[%s] %s"):format(call.state, query))
    return builder
  end

  local preview, candy = self:state_preview(call.state)
  buffer_line.append(builder, preview, candy.icon_highlight)
  buffer_line.append(builder, " ┃ ", "Delimiter")
  buffer_line.append(builder, buffer_line.truncate_display(query, 40), candy.text_highlight ~= "" and candy.text_highlight or nil)
  return builder
end

function CallLogUI:refresh()
  local connection = self.handler:get_current_connection()
  local calls = connection and self.handler:connection_get_calls(connection.id) or {}
  if #calls == 0 then
    calls = self.handler:get_calls()
  end
  local lines = {}
  self.line_map = {}

  if #calls == 0 then
    local builder = buffer_line.new_builder()
    buffer_line.append(builder, "Call log will be displayed here!", "MoreMsg")
    table.insert(lines, builder)
    buffer_line.render(self.bufnr, self.ns, lines)
    return
  end

  for _, call in ipairs(calls) do
    table.insert(lines, self:build_call_line(call))
    self.line_map[#lines] = call.id
  end

  buffer_line.render(self.bufnr, self.ns, lines)
end

function CallLogUI:show(winid)
  self.window = winid
  vim.api.nvim_win_set_buf(winid, self.bufnr)
  vim.wo[winid].wrap = false
  vim.wo[winid].number = false
  vim.wo[winid].relativenumber = false
  self:refresh()
end

function CallLogUI:do_action(action)
  local call_id = self.line_map[vim.api.nvim_win_get_cursor(0)[1]]
  if not call_id then
    return
  end
  if action == "show_result" then
    local call = self.handler:get_call(call_id)
    if call and (call.state == "archived" or call.state == "executing" or call.state == "history") then
      self.result:set_call(call)
    end
  elseif action == "cancel_call" then
    local call = self.handler:get_call(call_id)
    if call and call.state == "executing" then
      self.handler:call_cancel(call_id)
    end
  end
end

return CallLogUI
