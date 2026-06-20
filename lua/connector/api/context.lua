local state = require("connector.api.state")
local util = require("connector.util")

local M = {}

local function valid_bufnr(bufnr)
  bufnr = tonumber(bufnr) or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  return bufnr
end

local function valid_winid(winid)
  winid = tonumber(winid) or vim.api.nvim_get_current_win()
  if not vim.api.nvim_win_is_valid(winid) then
    return nil
  end
  return winid
end

local function compact_text(text, max_len)
  text = vim.trim(tostring(text or ""):gsub("%s+", " "))
  max_len = tonumber(max_len) or 240
  if #text <= max_len then
    return text
  end
  return text:sub(1, math.max(1, max_len - 3)) .. "..."
end

local function connection_label(conn)
  if not conn then
    return nil
  end
  local parts = {}
  if conn.name and conn.name ~= "" then
    parts[#parts + 1] = conn.name
  end
  if conn.id and conn.id ~= "" then
    parts[#parts + 1] = "id=" .. tostring(conn.id)
  end
  if conn.type and conn.type ~= "" then
    parts[#parts + 1] = "type=" .. tostring(conn.type)
  end
  if conn.database and conn.database ~= "" then
    parts[#parts + 1] = "database=" .. tostring(conn.database)
  end
  return table.concat(parts, ", ")
end

local function public_connection(conn)
  if not conn then
    return nil
  end
  return {
    id = conn.id,
    name = conn.name,
    type = conn.type,
    database = conn.database,
    source_id = conn.source_id,
  }
end

local function get_handler()
  local ok, handler = pcall(state.handler)
  if ok then
    return handler
  end
  return nil
end

local function safe_state_value(getter)
  local ok, value = pcall(getter)
  if ok then
    return value
  end
  return nil
end

local function note_for_buffer(editor, bufnr)
  if not editor or not bufnr then
    return nil
  end
  local note_id = editor.notes_by_buf and editor.notes_by_buf[bufnr] or nil
  if note_id and type(editor.search_note) == "function" then
    return editor:search_note(note_id)
  end
  local path = vim.api.nvim_buf_get_name(bufnr)
  if path ~= "" and type(editor.search_note_with_file) == "function" then
    return editor:search_note_with_file(path)
  end
  return nil
end

local function selected_sql(bufnr, max_chars)
  bufnr = valid_bufnr(bufnr)
  if not bufnr then
    return nil
  end
  local mode = vim.fn.mode()
  if mode ~= "v" and mode ~= "V" and mode ~= "\22" then
    return nil
  end
  local start_pos = vim.fn.getpos("v")
  local end_pos = vim.fn.getpos(".")
  local start_row = math.min(start_pos[2], end_pos[2])
  local end_row = math.max(start_pos[2], end_pos[2])
  if start_row < 1 or end_row < start_row then
    return nil
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, start_row - 1, end_row, false)
  local text = table.concat(lines, "\n")
  max_chars = tonumber(max_chars) or 2000
  if #text > max_chars then
    return text:sub(1, max_chars) .. "\n... (truncated)"
  end
  return text
end

local function current_statement(bufnr, max_chars, winid)
  bufnr = valid_bufnr(bufnr)
  if not bufnr then
    return nil
  end
  local cursor_winid = winid and valid_winid(winid) or nil
  local cursor = cursor_winid and vim.api.nvim_win_get_cursor(cursor_winid) or vim.api.nvim_win_get_cursor(0)

  local best = util.query_under_cursor and util.query_under_cursor(bufnr, cursor) or nil
  if not best then
    local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
    local statements = util.split_sql_statements(text, { blank_lines_are_separators = true })
    if #statements == 1 then
      best = statements[1]
    end
  end
  if not best or vim.trim(best) == "" then
    return nil
  end

  max_chars = tonumber(max_chars) or 2000
  if #best > max_chars then
    return best:sub(1, max_chars) .. "\n... (truncated)"
  end
  return best
end

local function add_line(lines, key, value)
  if value == nil or value == "" then
    return
  end
  lines[#lines + 1] = string.format("- %s: %s", key, tostring(value))
end

local function render_markdown(ctx)
  local lines = {
    "## Connector Context",
  }
  add_line(lines, "Provider", ctx.provider)
  add_line(lines, "Window", ctx.window_kind)
  add_line(lines, "Connection", connection_label(ctx.connection))
  if ctx.project then
    add_line(lines, "Project", ctx.project.name or ctx.project.namespace or ctx.project.root)
    add_line(lines, "Branch", ctx.project.branch)
  end
  if ctx.scratchpad then
    add_line(lines, "Scratchpad", ctx.scratchpad.name or ctx.scratchpad.file)
    add_line(lines, "Scratchpad namespace", ctx.scratchpad.namespace)
  end
  if ctx.query_context then
    local target = ctx.query_context.table
    if ctx.query_context.schema and ctx.query_context.schema ~= "" then
      target = ctx.query_context.schema .. "." .. tostring(target or "")
    end
    add_line(lines, "Query target", target)
  end
  if ctx.drawer_node then
    local node = ctx.drawer_node
    local target = node.name or node.table or node.database or node.connection_id or node.kind
    add_line(lines, "Drawer selection", tostring(node.kind or "node") .. (target and (": " .. tostring(target)) or ""))
  end
  if ctx.result then
    add_line(lines, "Result query", ctx.result.query)
    add_line(lines, "Result rows", ctx.result.row_count)
    add_line(lines, "Result columns", ctx.result.columns and table.concat(ctx.result.columns, ", ") or nil)
  end
  if ctx.current_sql and ctx.current_sql ~= "" then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Current SQL:"
    lines[#lines + 1] = "```sql"
    lines[#lines + 1] = ctx.current_sql
    lines[#lines + 1] = "```"
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Available CLI:"
  lines[#lines + 1] = "- Read-only SQL: `$LAZYAGENTBIN/nvim-cli-bridge connector query --format table '<SQL>'`"
  lines[#lines + 1] = "- Mutating SQL: `$LAZYAGENTBIN/nvim-cli-bridge connector execute --write --format table '<SQL>'`"
  lines[#lines + 1] = "- Connector context: `$LAZYAGENTBIN/nvim-cli-bridge connector context`"
  return table.concat(lines, "\n")
end

local function context_for_editor(bufnr, winid, handler)
  local editor = safe_state_value(state.editor)
  local note = note_for_buffer(editor, bufnr)
  local conn = handler and handler:get_current_connection() or nil
  local project = nil
  if note and note.file then
    project = util.resolve_project(note.file)
  end
  local current_query_context = editor and editor.current_query_context or nil
  return {
    provider = "connector.nvim",
    kind = "database",
    window_kind = "scratchpad",
    bufnr = bufnr,
    winid = winid,
    connection = public_connection(conn),
    project = project,
    scratchpad = note and {
      id = note.id,
      name = note.name,
      namespace = note.namespace,
      file = note.file,
    } or nil,
    query_context = current_query_context and vim.deepcopy(current_query_context) or nil,
    current_sql = selected_sql(bufnr) or current_statement(bufnr, nil, winid),
  }
end

local function context_for_result(bufnr, winid)
  local result_ui = safe_state_value(state.result)
  if not result_ui or result_ui.bufnr ~= bufnr then
    return nil
  end
  local call = result_ui:get_call()
  local conn = nil
  if call and call.connection_id and result_ui.handler then
    local ok, value = pcall(result_ui.handler.connection_get_params, result_ui.handler, call.connection_id)
    if ok then
      conn = value
    end
  end
  local columns = {}
  for _, col in ipairs((call and call.result and call.result.columns) or {}) do
    columns[#columns + 1] = col.name
  end
  return {
    provider = "connector.nvim",
    kind = "database",
    window_kind = "result",
    bufnr = bufnr,
    winid = winid,
    connection = public_connection(conn),
    result = call and {
      call_id = call.id,
      state = call.state,
      query = compact_text(call.query, 600),
      row_count = call.result and #(call.result.rows or {}) or nil,
      columns = columns,
      editable = call.result and call.result.editable ~= nil or false,
    } or nil,
  }
end

local function context_for_drawer(bufnr, winid, handler)
  local drawer = safe_state_value(state.drawer)
  if not drawer or drawer.bufnr ~= bufnr then
    return nil
  end
  local node = nil
  if winid and vim.api.nvim_win_is_valid(winid) then
    node = drawer.line_map[vim.api.nvim_win_get_cursor(winid)[1]]
  end
  local conn = handler and handler:get_current_connection() or nil
  return {
    provider = "connector.nvim",
    kind = "database",
    window_kind = "drawer",
    bufnr = bufnr,
    winid = winid,
    connection = public_connection(conn),
    drawer_node = node and vim.deepcopy(node) or nil,
  }
end

function M.context_for_buffer(bufnr, opts)
  opts = opts or {}
  bufnr = valid_bufnr(bufnr)
  if not bufnr then
    return nil
  end
  local winid = opts.winid and valid_winid(opts.winid) or nil
  local handler = get_handler()
  local ft = vim.bo[bufnr].filetype
  local name = vim.api.nvim_buf_get_name(bufnr)

  local ctx = nil
  if ft == "connector-result" then
    ctx = context_for_result(bufnr, winid)
  elseif ft == "connector-drawer" then
    ctx = context_for_drawer(bufnr, winid, handler)
  elseif (name ~= "" and util.is_scratchpad_path(name)) or ft == "sql" then
    ctx = context_for_editor(bufnr, winid, handler)
  end

  if ctx then
    ctx.text = render_markdown(ctx)
  end
  return ctx
end

function M.context_for_window(winid, opts)
  winid = valid_winid(winid)
  if not winid then
    return nil
  end
  opts = vim.tbl_extend("force", opts or {}, { winid = winid })
  return M.context_for_buffer(vim.api.nvim_win_get_buf(winid), opts)
end

function M.current_context(opts)
  return M.context_for_window(vim.api.nvim_get_current_win(), opts)
end

function M.render_markdown(ctx)
  return render_markdown(ctx or {})
end

return M
