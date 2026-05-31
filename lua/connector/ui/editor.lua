local util = require("connector.util")

local EditorUI = {}

function EditorUI:new(handler, result, config, state_helpers)
  local o = {
    handler = handler,
    result = result,
    config = config,
    listeners = {},
    namespaces = {},
    note_order = {},
    current_note_id = nil,
    window = nil,
    state_helpers = state_helpers or {},
  }
  setmetatable(o, self)
  self.__index = self
  util.ensure_dir(config.directory)
  o:load_notes()
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

function EditorUI:create_buf(file)
  local bufnr = vim.fn.bufadd(file)
  vim.fn.bufload(bufnr)
  vim.bo[bufnr].filetype = "sql"
  vim.bo[bufnr].bufhidden = "hide"
  util.apply_buffer_mappings(bufnr, self.config.mappings, function(action)
    self:do_action(action)
  end)

  -- Simple omnifunc for table-name completion
  vim.bo[bufnr].omnifunc = 'v:lua.require("connector.completion").omnifunc'

  return bufnr
end

function EditorUI:load_notes()
  local paths = vim.fn.globpath(self.config.directory, "**/*.sql", false, true)
  table.sort(paths)
  local root_len = #self.config.directory
  for _, file in ipairs(paths) do
    local rel_dir = vim.fs.dirname(file):sub(root_len + 2)
    local namespace = rel_dir ~= "" and rel_dir or "global"
    local ns = self:ensure_namespace(namespace)
    local id = util.random_id("note")
    local name = vim.fs.basename(file):gsub("%.sql$", "")
    local note = {
      id = id,
      name = name,
      file = file,
      bufnr = self:create_buf(file),
      namespace = namespace,
    }
    table.insert(ns.order, id)
    ns.notes[id] = note
    table.insert(self.note_order, id)
    self.current_note_id = self.current_note_id or id
  end
end

function EditorUI:search_note(id)
  for namespace, ns in pairs(self.namespaces) do
    if ns.notes[id] then
      return ns.notes[id], namespace
    end
  end
end

function EditorUI:search_note_with_buf(bufnr)
  for namespace, ns in pairs(self.namespaces) do
    for _, id in ipairs(ns.order) do
      local note = ns.notes[id]
      if note.bufnr == bufnr then
        return note, namespace
      end
    end
  end
end

function EditorUI:search_note_with_file(file)
  for namespace, ns in pairs(self.namespaces) do
    for _, id in ipairs(ns.order) do
      local note = ns.notes[id]
      if note.file == file then
        return note, namespace
      end
    end
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
  local note = {
    id = note_id,
    name = name,
    file = file,
    bufnr = self:create_buf(file),
    namespace = id,
  }
  table.insert(ns.order, note_id)
  table.insert(self.note_order, note_id)
  ns.notes[note_id] = note
  self.current_note_id = note_id
  self:emit("notes_changed", note)

  -- Register project -> namespace mapping for the project currently in context
  local proj = self.state_helpers and self.state_helpers.get_current_project and self.state_helpers.get_current_project()
  if not proj then
    proj = util.resolve_project()
  end
  if proj and proj.root then
    util.set_project_mapping(proj.root, id)
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
  note.file = new_file
  vim.api.nvim_buf_set_name(note.bufnr, new_file)
  self:emit("notes_changed", note)
end

function EditorUI:get_current_note()
  if not self.current_note_id then
    return nil
  end
  return self:search_note(self.current_note_id)
end

function EditorUI:set_current_note(id)
  local note = assert(self:search_note(id), "note not found: " .. id)
  self.current_note_id = id
  if self.window and vim.api.nvim_win_is_valid(self.window) then
    vim.api.nvim_win_set_buf(self.window, note.bufnr)
  end
  self:emit("current_note_changed", note)
end

function EditorUI:ensure_default_note()
  -- Prefer the saved state project (which may include root info) when available,
  -- otherwise fall back to resolving from the current buffer.
  local state_project = self.state_helpers and self.state_helpers.get_current_project and self.state_helpers.get_current_project()
  local resolved_project = util.resolve_project()
  local project = state_project or resolved_project

  local ns = "global"
  if project then
    local branch = util.get_git_branch(project.root) or "main"
    ns = project.name .. "/" .. branch

    -- If project has a root, prefer any persisted mapping for that root
    if project.root then
      local mapped = util.get_project_mapping(project.root)
      if mapped and self.namespaces[mapped] then
        ns = mapped
      else
        -- Look for existing namespaces that match the project name (e.g., after rename)
        local candidates = {}
        for _, name in ipairs(self:get_namespaces()) do
          if name:match("^" .. project.name .. "/") then
            table.insert(candidates, name)
          end
        end
        if #candidates > 0 then
          local preferred = nil
          for _, c in ipairs(candidates) do
            if c == project.name .. "/" .. branch then preferred = c; break end
          end
          preferred = preferred or candidates[1]
          ns = preferred
          util.set_project_mapping(project.root, preferred)
        end
      end
    end
  end

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
  if project then
    local current_project_name = vim.split(current.namespace, "/")[1]
    if current_project_name ~= project.name then
      self:set_current_note(notes[1].id)
      return
    end
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
end

local function get_visual_lines(bufnr)
  local start_row = vim.fn.getpos("'<")[2]
  local end_row = vim.fn.getpos("'>")[2]
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

  -- Expand path to table
  drawer.expanded["root:connections"] = true
  local conn = self.handler.connections[entry.connection_id]
  if conn and conn.source_id then drawer.expanded["source:" .. conn.source_id] = true end
  drawer.expanded["connection:" .. entry.connection_id] = true
  if entry.schema and entry.schema ~= "" then
    drawer.expanded[("database:%s:%s"):format(entry.connection_id, entry.schema)] = true
  end
  drawer.expanded[("table:%s:%s:%s"):format(entry.connection_id, entry.schema or "", entry.table)] = true

  drawer:refresh()

  -- Move cursor to the table line
  if drawer.window and vim.api.nvim_win_is_valid(drawer.window) then
    for i = 1, #drawer.line_map do
      local node = drawer.line_map[i]
      if node and node.kind == "table" and node.connection_id == entry.connection_id and (node.table == entry.table) and ((node.schema or "") == (entry.schema or "")) then
        pcall(vim.api.nvim_win_set_cursor, drawer.window, { i, 0 })
        pcall(vim.api.nvim_win_call, drawer.window, function()
          pcall(vim.cmd, 'normal! zz')
        end)
        break
      end
    end
  end
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
    local lines = get_visual_lines(bufnr)
    if not lines then
      return
    end
    self:run_query(table.concat(lines, "\n"))
  elseif action == "run_under_cursor" then
    local line = vim.api.nvim_get_current_line()
    self:run_query(line)
  elseif action == "run_in_float" then
    local lines = get_visual_lines(bufnr)
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

    -- Create ephemeral buffer and float window (styled like ResultUI)
    local ui = vim.api.nvim_list_uis()[1]
    local width = math.max(40, math.min(ui.width - 8, math.floor(ui.width * 0.85)))
    local height = math.max(10, math.min(ui.height - 4, math.floor(ui.height * 0.85)))
    local col = math.floor((ui.width - width) / 2)
    local row = math.floor((ui.height - height) / 2)

    local res_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[res_buf].bufhidden = "wipe"
    vim.bo[res_buf].filetype = "connector-result"
    vim.bo[res_buf].buflisted = false
    vim.api.nvim_buf_set_option(res_buf, "modifiable", true)
    vim.api.nvim_buf_set_lines(res_buf, 0, -1, false, { "Running query..." })
    vim.api.nvim_buf_set_option(res_buf, "modifiable", false)

    local winid = vim.api.nvim_open_win(res_buf, true, {
      relative = "editor",
      width = width,
      height = height,
      col = col,
      row = row,
      border = "rounded",
      style = "minimal",
      zindex = 150,
    })

    -- Make sure float doesn't wrap and looks like the result window
    pcall(vim.api.nvim_win_set_option, winid, "wrap", false)
    pcall(vim.api.nvim_win_set_option, winid, "sidescroll", 1)
    pcall(vim.api.nvim_win_set_option, winid, "sidescrolloff", 5)
    pcall(vim.api.nvim_win_set_option, winid, "number", false)
    pcall(vim.api.nvim_win_set_option, winid, "relativenumber", false)

    -- Apply same delimiter match as ResultUI (window-local)
    local curwin = vim.api.nvim_get_current_win()
    pcall(vim.api.nvim_set_current_win, winid)
    pcall(vim.cmd, [[match Delimiter /^\s*\d\\+|─|│|┼/]])
    if vim.api.nvim_win_is_valid(curwin) then
      pcall(vim.api.nvim_set_current_win, curwin)
    end

    vim.keymap.set("n", "q", function() pcall(vim.api.nvim_win_close, winid, true) end, { buffer = res_buf, silent = true })

    -- Register listener to write results when call is completed (also reapply match)
    local function on_call_state(payload)
      if not payload or not payload.id then return end
      if payload.state == "archived" then
        pcall(function()
          self.handler:call_store_result(payload.id, "table", "buffer", { extra_arg = res_buf })
          if vim.api.nvim_win_is_valid(winid) then
            local cur = vim.api.nvim_get_current_win()
            pcall(vim.api.nvim_set_current_win, winid)
            pcall(vim.cmd, [[match Delimiter /^\s*\d\\+|─|│|┼/]])
            pcall(vim.api.nvim_set_current_win, cur)
          end
        end)
      end
    end
    self.handler:register_event_listener("call_state_changed", on_call_state)

    self.handler:connection_execute(conn.id, query, function(call)
      if call and call.state == "archived" then
        pcall(function()
          self.handler:call_store_result(call.id, "table", "buffer", { extra_arg = res_buf })
          if vim.api.nvim_win_is_valid(winid) then
            local cur = vim.api.nvim_get_current_win()
            pcall(vim.api.nvim_set_current_win, winid)
            pcall(vim.cmd, [[match Delimiter /^\s*\d\\+|─|│|┼/]])
            pcall(vim.api.nvim_set_current_win, cur)
          end
        end)
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
  for root, ns in pairs(mappings) do
    if ns == id then
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
      note.file = new_file
      if vim.api.nvim_buf_is_valid(note.bufnr) then
        pcall(vim.api.nvim_buf_set_name, note.bufnr, new_file)
      end
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
