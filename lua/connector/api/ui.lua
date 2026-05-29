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

return ui
