local format = require("connector.format")
local util = require("connector.util")

local ResultUI = {}

function ResultUI:new(handler, config)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].filetype = "connector-result"

  local o = {
    handler = handler,
    config = config,
    bufnr = bufnr,
    window = nil,
    current_call_id = nil,
    page = 1,
    line_map = {},
  }
  setmetatable(o, self)
  self.__index = self

  util.apply_buffer_mappings(bufnr, config.mappings, function(action)
    o:do_action(action)
  end)

  handler:register_event_listener("call_state_changed", function(call)
    if o.current_call_id == call.id then
      o:refresh()
      if call.state == "archived" and o.config.focus_result and o.window and vim.api.nvim_win_is_valid(o.window) then
        vim.api.nvim_set_current_win(o.window)
      end
    end
  end)

  return o
end

function ResultUI:set_call(call)
  self.current_call_id = call.id
  self.page = 1
  self:refresh()
end

function ResultUI:get_call()
  return self.current_call_id and self.handler:get_call(self.current_call_id) or nil
end

function ResultUI:show(winid)
  self.window = winid
  vim.api.nvim_win_set_buf(winid, self.bufnr)
  self:refresh()
end

function ResultUI:render_waiting(call)
  local lines = {
    ("Call: %s"):format(call.id),
    ("State: %s"):format(call.state),
  }
  if call.error then
    table.insert(lines, "Error: " .. call.error)
  else
    table.insert(lines, "")
    table.insert(lines, call.query)
  end
  util.buf_set_lines(self.bufnr, lines)
  self.line_map = {}
end

function ResultUI:refresh()
  local call = self:get_call()
  if not call then
    util.buf_set_lines(self.bufnr, {
      "No result selected.",
      "",
      "Use the drawer or BB in the editor to run a query.",
    })
    self.line_map = {}
    return
  end

  if call.state ~= "archived" or not call.result then
    self:render_waiting(call)
    return
  end

  local rows = call.result.rows or {}
  local page_size = self.config.page_size
  local total_pages = math.max(1, math.ceil(#rows / math.max(1, page_size)))
  self.page = math.min(math.max(self.page, 1), total_pages)
  local from = (self.page - 1) * page_size
  local to = math.min(from + page_size, #rows)

  local body, line_map = format.to_table_lines(call.result, from, to)
  local lines = {
    ("Connection: %s"):format(call.connection_id),
    ("Page %d/%d | Rows %d-%d of %d"):format(self.page, total_pages, math.min(from + 1, #rows), to, #rows),
    "",
  }
  vim.list_extend(lines, body)
  self.line_map = {}
  for line, row_index in pairs(line_map) do
    self.line_map[line + 3] = row_index
  end
  util.buf_set_lines(self.bufnr, lines)
end

function ResultUI:page_current()
  self:refresh()
end

function ResultUI:page_next()
  self.page = self.page + 1
  self:refresh()
end

function ResultUI:page_prev()
  self.page = math.max(1, self.page - 1)
  self:refresh()
end

function ResultUI:page_last()
  local call = self:get_call()
  if not call or not call.result then
    return
  end
  self.page = math.max(1, math.ceil(#(call.result.rows or {}) / math.max(1, self.config.page_size)))
  self:refresh()
end

function ResultUI:page_first()
  self.page = 1
  self:refresh()
end

function ResultUI:selected_range()
  local call = self:get_call()
  if not call or not call.result then
    return nil
  end

  local mode = vim.fn.mode()
  if mode == "v" or mode == "V" then
    local line1 = vim.fn.line("v")
    local line2 = vim.fn.line(".")
    if line1 > line2 then
      line1, line2 = line2, line1
    end
    local start_idx, end_idx
    for line = line1, line2 do
      local row_index = self.line_map[line]
      if row_index then
        start_idx = start_idx or row_index
        end_idx = row_index + 1
      end
    end
    return start_idx, end_idx
  end

  local row_index = self.line_map[vim.api.nvim_win_get_cursor(0)[1]]
  if row_index then
    return row_index, row_index + 1
  end
end

function ResultUI:yank(kind, all_rows)
  local call = self:get_call()
  if not call or not call.result then
    return
  end
  local from, to
  if all_rows then
    from, to = 0, #(call.result.rows or {})
  else
    from, to = self:selected_range()
    if not from then
      return
    end
  end
  self.handler:call_store_result(call.id, kind, "yank", { from = from, to = to })
  util.notify(("Yanked %s result"):format(kind))
end

function ResultUI:do_action(action)
  if action == "page_next" then
    self:page_next()
  elseif action == "page_prev" then
    self:page_prev()
  elseif action == "page_last" then
    self:page_last()
  elseif action == "page_first" then
    self:page_first()
  elseif action == "yank_current_json" or action == "yank_selection_json" then
    self:yank("json", false)
  elseif action == "yank_all_json" then
    self:yank("json", true)
  elseif action == "yank_current_csv" or action == "yank_selection_csv" then
    self:yank("csv", false)
  elseif action == "yank_all_csv" then
    self:yank("csv", true)
  elseif action == "cancel_call" then
    local call = self:get_call()
    if call then
      self.handler:call_cancel(call.id)
    end
  end
end

return ResultUI

