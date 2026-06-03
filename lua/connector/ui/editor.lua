local util = require("connector.util")
local window = require("connector.ui.window")
local batch_result_tab = require("connector.ui.batch_result_tab")

local EditorUI = {}
local WINBAR_ICONS = {
  project = "󰉋",
  database = "",
}

local function truncate_text(text, max_len)
  text = vim.trim((text or ""):gsub("%s+", " "))
  if text == "" or #text <= max_len then
    return text
  end
  return text:sub(1, max_len - 3) .. "..."
end

local function escape_winbar(text)
  return tostring(text or ""):gsub("%%", "%%%%")
end

local function connection_database_label(connection)
  if not connection then
    return nil
  end

  local kind = (connection.type or ""):lower()
  if kind == "sqlite" or kind == "sqlite3" then
    if connection.name and connection.name ~= "" then
      return connection.name
    end
    if connection.url and connection.url ~= "" then
      return vim.fs.basename(connection.url)
    end
  end
  if connection.database and connection.database ~= "" then
    return connection.database
  end
  return connection.name or connection.id
end

function EditorUI:new(handler, result, config, state_helpers, result_config)
  local o = {
    handler = handler,
    result = result,
    config = config,
    result_config = result_config,
    listeners = {},
    namespaces = {},
    note_order = {},
    notes_by_id = {},
    notes_by_buf = {},
    notes_by_file = {},
    current_note_id = nil,
    window = nil,
    state_helpers = state_helpers or {},
    explicit_visual_range = nil,
    current_query_context = nil,
  }
  setmetatable(o, self)
  self.__index = self
  util.ensure_dir(config.directory)
  o:load_notes()
  o:register_event_listener("notes_changed", function()
    o:update_winbar()
  end)
  handler:register_event_listener("current_connection_changed", function(connection)
    if o.current_query_context and connection and o.current_query_context.connection_id ~= connection.id then
      o.current_query_context = nil
    end
    o:update_winbar()
  end)
  handler:register_event_listener("connections_changed", function()
    o:update_winbar()
  end)
  handler:register_event_listener("query_context_changed", function(payload)
    o.current_query_context = payload
    o:update_winbar()
  end)
  return o
end

function EditorUI:register_event_listener(event, listener)
  self.listeners[event] = self.listeners[event] or {}
  table.insert(self.listeners[event], listener)
end

function EditorUI:emit(event, payload)
  for _, listener in ipairs(self.listeners[event] or {}) do
    listener(payload)
  end
end

function EditorUI:namespace_dir(id)
  return util.joinpath(self.config.directory, id)
end

function EditorUI:ensure_namespace(id)
  self.namespaces[id] = self.namespaces[id] or { order = {}, notes = {} }
  util.ensure_dir(self:namespace_dir(id))
  return self.namespaces[id]
end

function EditorUI:index_note(note)
  self.notes_by_id[note.id] = note
  self.notes_by_buf[note.bufnr] = note.id
  self.notes_by_file[note.file] = note.id
end

function EditorUI:unindex_note(note)
  if not note then
    return
  end

  self.notes_by_id[note.id] = nil
  if note.bufnr and self.notes_by_buf[note.bufnr] == note.id then
    self.notes_by_buf[note.bufnr] = nil
  end
  if note.file and self.notes_by_file[note.file] == note.id then
    self.notes_by_file[note.file] = nil
  end
end

function EditorUI:append_note(note)
  local ns = self:ensure_namespace(note.namespace)
  table.insert(ns.order, note.id)
  ns.notes[note.id] = note
  table.insert(self.note_order, note.id)
  self:index_note(note)
  self.current_note_id = self.current_note_id or note.id
  return note
end

function EditorUI:update_note_file(note, new_file)
  if note.file and self.notes_by_file[note.file] == note.id then
    self.notes_by_file[note.file] = nil
  end
  note.file = new_file
  self.notes_by_file[new_file] = note.id

  if vim.api.nvim_buf_is_valid(note.bufnr) then
    pcall(vim.api.nvim_buf_set_name, note.bufnr, new_file)
  end
end

function EditorUI:capture_visual_range()
  local mode = vim.fn.mode()
  local mode_char = mode and mode:sub(1, 1) or ""
  if mode_char ~= "v" and mode_char ~= "V" and mode_char ~= "\22" then
    self.explicit_visual_range = nil
    return
  end

  local start_row = vim.fn.getpos("v")[2]
  local end_row = vim.api.nvim_win_get_cursor(0)[1]
  if not start_row or not end_row or start_row == 0 or end_row == 0 then
    self.explicit_visual_range = nil
    return
  end

  if start_row > end_row then
    start_row, end_row = end_row, start_row
  end

  self.explicit_visual_range = {
    start_row = start_row,
    end_row = end_row,
  }
end

local function is_visual_mapping(mode)
  if type(mode) == "table" then
    for _, value in ipairs(mode) do
      if is_visual_mapping(value) then
        return true
      end
    end
    return false
  end

  return mode == "v" or mode == "x"
end

function EditorUI:apply_buffer_mappings(bufnr)
  for _, mapping in ipairs(self.config.mappings or {}) do
    vim.keymap.set(mapping.mode, mapping.key, function()
      if is_visual_mapping(mapping.mode) then
        self:capture_visual_range()
      end
      self:do_action(mapping.action)
    end, vim.tbl_extend("force", { buffer = bufnr, nowait = true, silent = true }, mapping.opts or {}))
  end
end

function EditorUI:setup_note_autocmds(bufnr)
  local group = vim.api.nvim_create_augroup("connector-editor-winbar-" .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd({ "BufEnter", "TextChanged", "TextChangedI" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      local note = self:search_note_with_buf(bufnr)
      if note and note.id == self.current_note_id then
        self:update_winbar()
      end
    end,
  })
end

function EditorUI:create_buf(file)
  local bufnr = vim.fn.bufadd(file)
  vim.fn.bufload(bufnr)
  vim.bo[bufnr].filetype = "sql"
  vim.bo[bufnr].bufhidden = "hide"
  self:apply_buffer_mappings(bufnr)
  self:setup_note_autocmds(bufnr)

  return bufnr
end

function EditorUI:load_notes()
  local paths = vim.fn.globpath(self.config.directory, "**/*.sql", false, true)
  table.sort(paths)
  local root_len = #self.config.directory
  for _, file in ipairs(paths) do
    local rel_dir = vim.fs.dirname(file):sub(root_len + 2)
    local namespace = rel_dir ~= "" and rel_dir or "global"
    local id = util.random_id("note")
    local name = vim.fs.basename(file):gsub("%.sql$", "")
    self:append_note({
      id = id,
      name = name,
      file = file,
      bufnr = self:create_buf(file),
      namespace = namespace,
    })
  end
end

function EditorUI:search_note(id)
  local note = self.notes_by_id[id]
  if note then
    return note, note.namespace
  end
end

function EditorUI:search_note_with_buf(bufnr)
  local note_id = self.notes_by_buf[bufnr]
  if note_id then
    return self:search_note(note_id)
  end
end

function EditorUI:search_note_with_file(file)
  local note_id = self.notes_by_file[file]
  if note_id then
    return self:search_note(note_id)
  end
end

function EditorUI:namespace_create_note(id, name)
  local ns = self:ensure_namespace(id)
  for _, note_id in ipairs(ns.order) do
    if ns.notes[note_id].name == name then
      error("note already exists: " .. name)
    end
  end
  local slug = util.slugify(name)
  local file = util.joinpath(self:namespace_dir(id), slug .. ".sql")
  util.write_file(file, "")
  local note_id = util.random_id("note")
  local note = self:append_note({
    id = note_id,
    name = name,
    file = file,
    bufnr = self:create_buf(file),
    namespace = id,
  })
  self.current_note_id = note_id
  self:emit("notes_changed", note)

  -- Register project -> namespace mapping for the project currently in context
  local proj = self.state_helpers and self.state_helpers.get_current_project and self.state_helpers.get_current_project()
  if not proj then
    proj = util.resolve_project()
  end
  if proj and proj.root then
    util.set_project_mapping(proj, id)
  end

  return note_id
end

function EditorUI:get_namespaces()
  local ids = vim.tbl_keys(self.namespaces)
  table.sort(ids)
  return ids
end

function EditorUI:namespace_get_notes(id)
  local ns = self:ensure_namespace(id)
  local items = {}
  for _, note_id in ipairs(ns.order) do
    table.insert(items, vim.deepcopy(ns.notes[note_id]))
  end
  table.sort(items, function(left, right)
    return left.name < right.name
  end)
  return items
end

function EditorUI:namespace_remove_note(id, note_id)
  local ns = self:ensure_namespace(id)
  local note = ns.notes[note_id]
  if not note then
    error("note not found: " .. note_id)
  end
  os.remove(note.file)
  ns.notes[note_id] = nil
  ns.order = vim.tbl_filter(function(value)
    return value ~= note_id
  end, ns.order)
  self.note_order = vim.tbl_filter(function(value)
    return value ~= note_id
  end, self.note_order)
  self:unindex_note(note)
  if self.current_note_id == note_id then
    self.current_note_id = self.note_order[1]
  end
  self:emit("notes_changed", note)
end

function EditorUI:note_rename(id, name)
  local note, namespace = self:search_note(id)
  if not note then
    error("note not found: " .. id)
  end
  local new_file = util.joinpath(self:namespace_dir(namespace), util.slugify(name) .. ".sql")
  os.rename(note.file, new_file)
  note.name = name
  self:update_note_file(note, new_file)
  self:emit("notes_changed", note)
  if self.current_note_id == id then
    self:update_winbar()
  end
end

function EditorUI:current_project()
  local state_project = self.state_helpers and self.state_helpers.get_current_project and self.state_helpers.get_current_project()
  return state_project or util.resolve_project()
end

function EditorUI:resolve_active_namespace(project)
  if not project or not project.name or project.name == "" then
    return "global"
  end

  local branch = project.branch or (project.root and util.get_git_branch(project.root)) or "main"
  local default_namespace = project.name .. "/" .. branch
  if not project.root then
    return default_namespace
  end

  if self.namespaces[default_namespace] then
    util.set_project_mapping(project, default_namespace)
    return default_namespace
  end

  local mapped = util.get_project_mapping(project)
  if mapped and self.namespaces[mapped] then
    return mapped
  end

  return default_namespace
end

function EditorUI:get_current_note()
  if not self.current_note_id then
    return nil
  end
  return self:search_note(self.current_note_id)
end

function EditorUI:current_note_query_count(note)
  note = note or self:get_current_note()
  if not note or not note.bufnr or not vim.api.nvim_buf_is_valid(note.bufnr) then
    return 0
  end
  local text = table.concat(vim.api.nvim_buf_get_lines(note.bufnr, 0, -1, false), "\n")
  return #util.split_sql_statements(text)
end

function EditorUI:current_target_parts()
  local conn = self.handler:get_current_connection()
  if not conn then
    return "no-db", nil
  end

  local db = connection_database_label(conn)
  local ctx = self.current_query_context
  if not ctx or ctx.connection_id ~= conn.id or not ctx.table or ctx.table == "" then
    return db or conn.name or conn.id or "no-db", nil
  end

  local kind = (conn.type or ""):lower()
  local schema = ctx.schema
  if (kind == "mysql" or kind == "mariadb") and db and schema == db then
    schema = nil
  elseif kind == "sqlite" and (schema == "main" or schema == "temp") then
    schema = nil
  end

  local table_name = schema and schema ~= "" and (schema .. "." .. ctx.table) or ctx.table
  return db or conn.name or conn.id or "no-db", table_name
end

function EditorUI:update_winbar()
  if not self.window or not vim.api.nvim_win_is_valid(self.window) then
    return
  end

  local note = self:get_current_note()
  if not note then
    pcall(vim.api.nvim_win_set_option, self.window, "winbar", "Scratchpad")
    return
  end

  local project = util.resolve_project(note.file) or self:current_project() or {}
  local project_name = project.name or "global"
  local branch = project.branch
  local file_name = note.name or vim.fs.basename(note.file):gsub("%.sql$", "")

  local left_parts = {
    WINBAR_ICONS.project .. " " .. project_name,
  }
  if branch and branch ~= "" then
    table.insert(left_parts, branch)
  end
  table.insert(left_parts, file_name)

  local database_name, table_name = self:current_target_parts()
  if database_name and database_name ~= "" then
    table.insert(left_parts, WINBAR_ICONS.database .. " " .. database_name)
  end
  if table_name and table_name ~= "" then
    table.insert(left_parts, table_name)
  end
  local sep = (self.config and self.config.winbar_separator) or "/"
  local summary = table.concat(left_parts, sep)

  local query_count = self:current_note_query_count(note)
  local right = ("%d %s"):format(query_count, query_count == 1 and "query" or "queries")
  local winbar = ("%s%%=%s"):format(escape_winbar(truncate_text(summary, 120)), escape_winbar(right))
  pcall(vim.api.nvim_win_set_option, self.window, "winbar", winbar)
end

function EditorUI:set_current_note(id)
  local note = assert(self:search_note(id), "note not found: " .. id)
  self.current_note_id = id
  if self.state_helpers and self.state_helpers.set_current_project then
    self.state_helpers.set_current_project(util.resolve_project(note.file), note.bufnr)
  end
  if self.window and vim.api.nvim_win_is_valid(self.window) then
    vim.api.nvim_win_set_buf(self.window, note.bufnr)
  end
  self:emit("current_note_changed", note)
  self:update_winbar()
end

function EditorUI:ensure_default_note()
  local project = self:current_project()
  local ns = self:resolve_active_namespace(project)

  local notes = self:namespace_get_notes(ns)
  if #notes == 0 then
    local note_id = self:namespace_create_note(ns, "default")
    self:set_current_note(note_id)
    return
  end

  local current = self:get_current_note()
  -- If there's no current note or it's global, pick the project note
  if not current or current.namespace == "global" then
    self:set_current_note(notes[1].id)
    return
  end

  -- If the current note belongs to a different project than the resolved project,
  -- prefer the resolved project note when available.
  if current and current.namespace ~= ns then
    self:set_current_note(notes[1].id)
    return
  end

  -- Fallback to selecting a note if none selected
  if not self.current_note_id then
    self:set_current_note(notes[1].id)
  end
end

function EditorUI:show(winid)
  self.window = winid
  self:ensure_default_note()
  local note = assert(self:search_note(self.current_note_id))
  vim.api.nvim_win_set_buf(winid, note.bufnr)
  self:update_winbar()
end

local function get_visual_lines(editor, bufnr)
  local explicit = editor and editor.explicit_visual_range or nil
  local start_row = explicit and explicit.start_row or vim.fn.getpos("'<")[2]
  local end_row = explicit and explicit.end_row or vim.fn.getpos("'>")[2]
  if editor then
    editor.explicit_visual_range = nil
  end
  if start_row == 0 or end_row == 0 then
    return nil
  end
  if start_row > end_row then
    start_row, end_row = end_row, start_row
  end
  return vim.api.nvim_buf_get_lines(bufnr, start_row - 1, end_row, false)
end

function EditorUI:run_query(query)
  local connection = self.handler:get_current_connection()
  if not connection then
    error("no active connection selected")
  end
  self.handler:connection_execute(connection.id, query, function(call)
    if call then
      self.result:set_call(call)
    end
  end)
end

function EditorUI:run_queries(queries)
  local statements = queries or {}
  if #statements == 0 then
    return
  end

  if #statements == 1 then
    self:run_query(statements[1])
    return
  end

  local connection = self.handler:get_current_connection()
  if not connection then
    error("no active connection selected")
  end

  batch_result_tab.open(self.handler, self.result_config, connection.id, statements)
end

function EditorUI:jump_to_table_under_cursor()
  local state_api = require("connector.api.state")
  local api_ui = require("connector.api.ui")

  local schema, tbl
  local token = vim.fn.expand("<cWORD>") or ""
  token = token:gsub("^%s+", ""):gsub("%s+$", "")

  if token ~= "" then
    if token:find("%.") then
      local parts = {}
      for part in token:gmatch("[^%.]+") do
        table.insert(parts, util.strip_identifier_quotes(part))
      end
      if #parts >= 2 then
        schema = parts[#parts-1]
        tbl = parts[#parts]
      else
        tbl = parts[#parts]
      end
    else
      tbl = util.strip_identifier_quotes(token)
    end
  else
    local line = vim.api.nvim_get_current_line()
    local refs = util.parse_query_table_references(line)
    if #refs >= 1 then
      schema = refs[1].schema
      tbl = refs[1].table
    end
  end

  if not tbl or tbl == "" then
    util.notify("No table found under cursor", vim.log.levels.INFO)
    return
  end

  -- Pick a connection seed
  local conn_id = self.handler.current_connection_id
  if not conn_id then
    for id in pairs(self.handler.connections) do conn_id = id; break end
  end
  if not conn_id then
    util.notify("No connections configured", vim.log.levels.ERROR)
    return
  end

  -- Resolve table entry
  local entry = nil
  pcall(function() self.handler:ensure_table_index(conn_id) end)
  entry = self.handler:resolve_table_reference(conn_id, schema, tbl)
  if not entry then
    local entries = self.handler:find_table_entries(conn_id, tbl)
    if entries and #entries > 0 then entry = entries[1] end
  end

  if not entry then
    util.notify(("Table not found: %s"):format(tbl), vim.log.levels.INFO)
    return
  end

  -- Apply context (switch connection/database if needed)
  pcall(function() self.handler:apply_table_context(conn_id, entry, { notify = true }) end)

  -- Ensure drawer is visible
  local drawer = state_api.drawer()
  local curwin = vim.api.nvim_get_current_win()
  if not drawer.window or not vim.api.nvim_win_is_valid(drawer.window) then
    local width = 36
    vim.cmd(("topleft %svsplit"):format(width))
    local win = vim.api.nvim_get_current_win()
    api_ui.drawer_show(win)
    pcall(vim.api.nvim_set_current_win, curwin)
  end

  drawer:reveal_table(entry)
end

function EditorUI:do_action(action)
  self:ensure_default_note()
  local note = assert(self:search_note(self.current_note_id))
  local bufnr = note.bufnr

  if action == "jump_to_table" then
    self:jump_to_table_under_cursor()
    return
  end

  if action == "run_file" then
    self:run_query(table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n"))
  elseif action == "run_selection" then
    local lines = get_visual_lines(self, bufnr)
    if not lines then
      return
    end
    local statements = util.split_sql_statements(table.concat(lines, "\n"))
    if #statements == 0 then
      return
    end
    self:run_queries(statements)
  elseif action == "run_under_cursor" then
    local line = vim.api.nvim_get_current_line()
    self:run_query(line)
  elseif action == "run_in_float" then
    local lines = get_visual_lines(self, bufnr)
    local query = nil
    if lines then
      query = table.concat(lines, "\n")
    else
      query = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
    end

    local conn = self.handler:get_current_connection()
    if not conn then
      util.notify("no active connection selected", vim.log.levels.ERROR)
      return
    end

    local res_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[res_buf].bufhidden = "wipe"
    vim.bo[res_buf].filetype = "connector-result"
    vim.bo[res_buf].buflisted = false
    vim.api.nvim_buf_set_option(res_buf, "modifiable", true)
    vim.api.nvim_buf_set_lines(res_buf, 0, -1, false, { "Running query..." })
    vim.api.nvim_buf_set_option(res_buf, "modifiable", false)

    local winid = window.open_centered(res_buf, true, {
      border = "rounded",
      zindex = 150,
    })
    window.configure_result_window(winid)

    local dispose_listener = nil
    local active_call_id = nil
    local finalized = false

    local function cleanup_listener()
      if dispose_listener then
        dispose_listener()
        dispose_listener = nil
      end
    end

    local function render_status(message)
      util.buf_set_lines(res_buf, { message })
    end

    local function render_result(call_id)
      if finalized then
        return
      end

      finalized = true
      cleanup_listener()
      pcall(function()
        self.handler:call_store_result(call_id, "table", "buffer", { extra_arg = res_buf })
      end)
      window.apply_result_delimiter_highlight(winid)
    end

    local function close()
      cleanup_listener()
      pcall(vim.api.nvim_win_close, winid, true)
    end

    vim.keymap.set("n", "q", close, { buffer = res_buf, silent = true })
    vim.api.nvim_create_autocmd("BufWipeout", {
      buffer = res_buf,
      once = true,
      callback = cleanup_listener,
    })

    local function on_call_state(payload)
      if not active_call_id or not payload or payload.id ~= active_call_id then
        return
      end

      if payload.state == "archived" then
        render_result(payload.id)
      elseif payload.state == "failed" then
        cleanup_listener()
        render_status(payload.error or "Query failed.")
      elseif payload.state == "canceled" then
        cleanup_listener()
        render_status("Query canceled.")
      end
    end

    dispose_listener = self.handler:register_event_listener("call_state_changed", on_call_state)

    self.handler:connection_execute(conn.id, query, function(call)
      if not call then
        cleanup_listener()
        render_status("Query canceled.")
        return
      end

      active_call_id = call.id
      if call.state == "archived" then
        render_result(call.id)
      elseif call.state == "failed" then
        cleanup_listener()
        render_status(call.error or "Query failed.")
      end
    end)
  end
end




function EditorUI:namespace_rename(id, new_id)
  local old_dir = self:namespace_dir(id)
  local new_dir = self:namespace_dir(new_id)
  if vim.fn.isdirectory(old_dir) == 0 then error("directory not found: " .. id) end

  -- Snapshot existing notes under the old namespace so buffers can be preserved
  local old_ns = self.namespaces[id]
  if not old_ns then error("namespace not found: " .. id) end
  local snapshot = {}
  for _, note_id in ipairs(old_ns.order) do
    local note = old_ns.notes[note_id]
    table.insert(snapshot, { id = note_id, name = note.name, bufnr = note.bufnr, basename = vim.fs.basename(note.file) })
  end

  -- Ensure parent directory for the new namespace exists, then perform filesystem rename
  local parent_dir = vim.fs.dirname(new_dir)
  util.ensure_dir(parent_dir)
  local ok, err = pcall(os.rename, old_dir, new_dir)
  if not ok then error("failed to rename namespace directory: " .. tostring(err)) end

  -- Update project mappings: any root mapping that pointed to the old namespace should now point to the new one
  local mappings = util.read_project_mappings()
  local changed = false
  for root, entry in pairs(mappings) do
    if type(entry) == "table" then
      for branch, ns in pairs(entry) do
        if ns == id then
          entry[branch] = new_id
          changed = true
        end
      end
      mappings[root] = entry
    elseif entry == id then
      mappings[root] = new_id
      changed = true
    end
  end
  if changed then
    util.write_project_mappings(mappings)
  end

  -- Ensure target namespace exists and merge notes while preserving buffers
  local target_ns = self:ensure_namespace(new_id)
  for _, info in ipairs(snapshot) do
    local note = old_ns.notes[info.id]
    if note then
      local new_file = util.joinpath(new_dir, info.basename)
      note.namespace = new_id
      self:update_note_file(note, new_file)
      table.insert(target_ns.order, info.id)
      target_ns.notes[info.id] = note
    end
  end

  -- Remove old namespace entry
  self.namespaces[id] = nil

  -- Notify listeners that notes changed
  self:emit("notes_changed")
end

return EditorUI
