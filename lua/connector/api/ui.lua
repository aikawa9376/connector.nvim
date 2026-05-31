local state = require("connector.api.state")

local ui = {}

function ui.is_loaded()
  return state.is_ui_loaded()
end

function ui.editor_register_event_listener(event, listener)
  state.editor():register_event_listener(event, listener)
end

function ui.editor_search_note(id)
  return state.editor():search_note(id)
end

function ui.editor_search_note_with_buf(bufnr)
  return state.editor():search_note_with_buf(bufnr)
end

function ui.editor_search_note_with_file(file)
  return state.editor():search_note_with_file(file)
end

function ui.editor_namespace_create_note(id, name)
  return state.editor():namespace_create_note(id, name)
end

function ui.editor_namespace_get_notes(id)
  return state.editor():namespace_get_notes(id)
end

function ui.editor_namespace_remove_note(id, note_id)
  state.editor():namespace_remove_note(id, note_id)
end

function ui.editor_note_rename(id, name)
  state.editor():note_rename(id, name)
end

function ui.editor_get_current_note()
  return state.editor():get_current_note()
end

function ui.editor_set_current_note(id)
  state.editor():set_current_note(id)
end

function ui.editor_show(winid)
  state.editor():show(winid)
end

function ui.editor_do_action(action)
  state.editor():do_action(action)
end

function ui.call_log_refresh()
  state.call_log():refresh()
end

function ui.call_log_show(winid)
  state.call_log():show(winid)
end

function ui.call_log_do_action(action)
  state.call_log():do_action(action)
end

function ui.drawer_refresh()
  state.drawer():refresh()
end

function ui.drawer_show(winid)
  state.drawer():show(winid)
end

function ui.drawer_do_action(action)
  state.drawer():do_action(action)
end

function ui.result_set_call(call)
  state.result():set_call(call)
end

function ui.result_get_call()
  return state.result():get_call()
end

function ui.result_page_current()
  state.result():page_current()
end

function ui.result_page_next()
  state.result():page_next()
end

function ui.result_page_prev()
  state.result():page_prev()
end

function ui.result_page_last()
  state.result():page_last()
end

function ui.result_page_first()
  state.result():page_first()
end

function ui.result_show(winid)
  state.result():show(winid)
end

function ui.result_do_action(action)
  state.result():do_action(action)
end

-- Prompt to pick a table (connection · schema.table) and focus it in the drawer
function ui.drawer_pick_table()
  local util = require("connector.util")
  -- Ensure core/ui loaded and layout opened
  local cfg = state.config()
  if cfg and cfg.window_layout and not cfg.window_layout:is_open() then
    cfg.window_layout:open()
  end

  local handler = state.handler()
  local drawer = state.drawer()

  -- Collect table entries across connections (load full structure for each connection)
  local entries = {}
  for conn_id, _ in pairs(handler.connections or {}) do
    local ok, structure = pcall(handler.connection_get_structure, handler, conn_id, "", { all = true })
    if ok and structure and #structure > 0 then
      for _, item in ipairs(structure) do
        table.insert(entries, {
          connection_id = conn_id,
          schema = item.schema and item.schema ~= "" and item.schema or nil,
          table = item.name,
        })
      end
    end
  end

  if #entries == 0 then
    util.notify("No tables found", vim.log.levels.INFO)
    return
  end

  local labels = vim.tbl_map(function(entry) return handler:format_table_entry_label(entry) end, entries)

  vim.ui.select(labels, { prompt = "Jump to table" }, function(_choice, idx)
    if not idx then return end
    local entry = entries[idx]
    if not entry then return end

    -- Apply table context (sets current connection and database when needed)
    pcall(function()
      handler:apply_table_context(nil, entry, { notify = false })
    end)

    -- Expand the table node and refresh the drawer so the row exists
    local table_key = ("table:%s:%s:%s"):format(entry.connection_id, entry.schema or "", entry.table)
    drawer.expanded = drawer.expanded or {}
    drawer.expanded[table_key] = true
    drawer:refresh()

    -- Focus drawer window and move cursor to the table line
    if drawer.window and vim.api.nvim_win_is_valid(drawer.window) then
      vim.api.nvim_set_current_win(drawer.window)
      for i = 1, #drawer.line_map do
        local n = drawer.line_map[i]
        if n and n.kind == "table" and n.connection_id == entry.connection_id and n.table == entry.table then
          local same_schema = (not n.schema and not entry.schema) or (n.schema == entry.schema)
          if same_schema then
            pcall(vim.api.nvim_win_set_cursor, drawer.window, { i, 0 })
            return
          end
        end
      end
      -- fallback: move to top if not found
      pcall(vim.api.nvim_win_set_cursor, drawer.window, { 1, 0 })
    end
  end)
end

return ui
