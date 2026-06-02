local format = require("connector.format")
local window = require("connector.ui.window")
local util = require("connector.util")

local ResultUI = {}

local function truncate_query(query, max_len)
  query = vim.trim(query:gsub("%s+", " "))
  if #query <= max_len then
    return query
  end
  return query:sub(1, max_len - 3) .. "..."
end

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
    cell_map = {},
    editor = nil,
    disposed = false,
    dispose_call_state_listener = nil,
  }
  setmetatable(o, self)
  self.__index = self

  util.apply_buffer_mappings(bufnr, config.mappings, function(action)
    o:do_action(action)
  end)

  o.dispose_call_state_listener = handler:register_event_listener("call_state_changed", function(call)
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
  window.configure_result_window(winid)
  self:refresh()
end

function ResultUI:apply_highlight()
  window.apply_result_delimiter_highlight(self.window)
end

function ResultUI:update_winbar(call, total_rows)
  if not self.window or not vim.api.nvim_win_is_valid(self.window) then
    return
  end

  if not call then
    vim.api.nvim_win_set_option(self.window, "winbar", "Results")
    return
  end

  if call.state ~= "archived" or not call.result then
    local query = truncate_query(call.query or "", 72)
    local suffix = call.state == "executing" and "Executing..." or call.state
    vim.api.nvim_win_set_option(self.window, "winbar", ("%s  %s"):format(query, suffix))
    return
  end

  local total_pages = math.max(1, math.ceil(total_rows / math.max(1, self.config.page_size)))
  local query = truncate_query(call.query or "", 56)
  local seconds = call.time_taken_s or 0
  local right = string.format("Took %.3fs", seconds)
  if call.result.editable then
    right = "editable  " .. right
  end
  local winbar = string.format("%s  %d/%d (%d)%%=%s", query, self.page, total_pages, total_rows, right)
  vim.api.nvim_win_set_option(self.window, "winbar", winbar)
end

function ResultUI:render_waiting(call)
  self:close_editor()
  local lines = {}
  if call.error then
    table.insert(lines, call.error)
  else
    table.insert(lines, call.query)
  end
  util.buf_set_lines(self.bufnr, lines)
  self.line_map = {}
  self.cell_map = {}
  self:update_winbar(call, 0)
end

function ResultUI:refresh()
  self:close_editor()
  local call = self:get_call()
  if not call then
    util.buf_set_lines(self.bufnr, {
      "No result selected.",
      "",
      "Use the drawer or BB in the editor to run a query.",
    })
    self.line_map = {}
    self.cell_map = {}
    self:update_winbar(nil, 0)
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

  local body, line_map, cell_map = format.to_table_lines(call.result, from, to)
  self.line_map = line_map
  self.cell_map = cell_map
  util.buf_set_lines(self.bufnr, body)
  self:update_winbar(call, #rows)
  self:apply_highlight()
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

function ResultUI:history_neighbor(direction)
  local call = self:get_call()
  if not call then
    return
  end
  local next_call = self.handler:call_neighbor(call.id, direction)
  if not next_call then
    util.notify(("No %s query in this project/branch."):format(direction == "newer" and "newer" or "older"))
    return
  end
  self:set_call(next_call)
end

function ResultUI:result_neighbor(direction)
  local call = self:get_call()
  if not call then
    return
  end
  local next_call = self.handler:result_neighbor(call.id, direction)
  if not next_call then
    util.notify(("No %s result."):format(direction == "newer" and "newer" or "older"))
    return
  end
  self:set_call(next_call)
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

function ResultUI:selected_cell()
  local row_index = self.line_map[vim.api.nvim_win_get_cursor(0)[1]]
  if row_index == nil then
    return nil
  end

  local cursor_col = vim.api.nvim_win_get_cursor(0)[2] + 1
  local cells = self.cell_map[vim.api.nvim_win_get_cursor(0)[1]] or {}
  for index, cell in ipairs(cells) do
    if cursor_col >= cell.start_col and cursor_col <= cell.end_col + 2 then
      return row_index, index, cell
    end
  end

  if #cells > 0 then
    return row_index, 1, cells[1]
  end
end

function ResultUI:close_editor()
  if self.editor and self.editor.win and vim.api.nvim_win_is_valid(self.editor.win) then
    vim.api.nvim_win_close(self.editor.win, true)
  end
  self.editor = nil
end

function ResultUI:destroy()
  if self.disposed then
    return
  end

  self.disposed = true
  self:close_editor()
  if self.dispose_call_state_listener then
    self.dispose_call_state_listener()
    self.dispose_call_state_listener = nil
  end
  self.window = nil
end

function ResultUI:edit_cell()
  local call = self:get_call()
  if not call or not call.result or not call.result.editable then
    util.notify("Current result is read-only. Use a simple 'select * from table ...' result with a primary key.", vim.log.levels.WARN)
    return
  end

  local row_index, column_index, cell = self:selected_cell()
  if not row_index then
    util.notify("Place the cursor on a data cell to edit it.", vim.log.levels.WARN)
    return
  end

  local column = call.result.editable.columns[column_index]
  if not column then
    return
  end
  if column.primary_key then
    util.notify("Primary-key columns are read-only.", vim.log.levels.WARN)
    return
  end

  local row = call.result.rows[row_index + 1]
  local original = util.value_to_string(row[column_index])
  self:close_editor()

  local editor_buf = vim.api.nvim_create_buf(false, true)
  local width = math.max(cell.width + 2, util.display_width(original) + 1, 8)
  vim.api.nvim_buf_set_lines(editor_buf, 0, -1, false, { original })
  vim.bo[editor_buf].bufhidden = "wipe"

  local editor_win = vim.api.nvim_open_win(editor_buf, true, {
    relative = "win",
    win = self.window,
    row = vim.api.nvim_win_get_cursor(self.window)[1] - 1,
    col = cell.start_col - 1,
    width = width,
    height = 1,
    style = "minimal",
    border = "rounded",
    zindex = 80,
  })
  self.editor = {
    buf = editor_buf,
    win = editor_win,
    row_index = row_index,
    column_index = column_index,
  }

  local function finish(save)
    local state = self.editor
    if not state then
      return
    end
    local text = vim.api.nvim_buf_get_lines(state.buf, 0, 1, false)[1] or ""
    self:close_editor()
    if not save then
      if self.window and vim.api.nvim_win_is_valid(self.window) then
        vim.api.nvim_set_current_win(self.window)
      end
      return
    end

    local ok, err = pcall(self.handler.call_update_cell, self.handler, call.id, state.row_index, state.column_index, text)
    if not ok then
      util.notify(err, vim.log.levels.ERROR)
      return
    end
    util.notify("Cell updated.")
  end

  vim.keymap.set("n", "<CR>", function()
    finish(true)
  end, { buffer = editor_buf, silent = true })
  vim.keymap.set("i", "<CR>", function()
    finish(true)
  end, { buffer = editor_buf, silent = true })
  vim.keymap.set("n", "<Esc>", function()
    finish(false)
  end, { buffer = editor_buf, silent = true })
  vim.keymap.set("i", "<Esc>", function()
    finish(false)
  end, { buffer = editor_buf, silent = true })
  vim.cmd.startinsert()
  vim.api.nvim_win_set_cursor(editor_win, { 1, #original })
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
  elseif action == "result_newer" then
    self:result_neighbor("newer")
  elseif action == "result_older" then
    self:result_neighbor("older")
  elseif action == "history_newer" then
    self:history_neighbor("newer")
  elseif action == "history_older" then
    self:history_neighbor("older")
  elseif action == "yank_current_json" or action == "yank_selection_json" then
    self:yank("json", false)
  elseif action == "yank_all_json" then
    self:yank("json", true)
  elseif action == "yank_current_csv" or action == "yank_selection_csv" then
    self:yank("csv", false)
  elseif action == "yank_all_csv" then
    self:yank("csv", true)
  elseif action == "edit_cell" then
    self:edit_cell()
  elseif action == "cancel_call" then
    local call = self:get_call()
    if call then
      self.handler:call_cancel(call.id)
    end
  end
end

return ResultUI
