local buffer_line = require("connector.ui.buffer_line")
local candies_module = require("connector.ui.candies")
local float = require("connector.ui.float")
local util = require("connector.util")

local DrawerUI = {}

function DrawerUI:new(handler, editor, result, config, state_helpers)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].filetype = "connector-drawer"

  local o = {
    handler = handler,
    editor = editor,
    result = result,
    config = config,
    bufnr = bufnr,
    ns = vim.api.nvim_create_namespace("connector-drawer"),
    window = nil,
    line_map = {},
    expanded = {
      ["root:connections"] = true,
      ["root:scratchpads"] = true,
    },
    candies = config.disable_candies and {} or vim.tbl_deep_extend("force", candies_module.drawer_defaults(), config.candies or {}),
    state_helpers = state_helpers or {},
    -- remember last active namespace to avoid repeatedly reopening the same note
    last_active_namespace = nil,
  }
  setmetatable(o, self)
  self.__index = self

  util.apply_buffer_mappings(bufnr, config.mappings, function(action)
    o:do_action(action)
  end)

  handler:register_event_listener("connections_changed", function()
    o:refresh()
  end)
  handler:register_event_listener("current_connection_changed", function()
    o:refresh()
  end)
  handler:register_event_listener("query_context_changed", function(payload)
    o:expand_query_context(payload)
    o:refresh()
  end)
  editor:register_event_listener("notes_changed", function()
    o:refresh()
  end)
  editor:register_event_listener("current_note_changed", function()
    o:refresh()
  end)

  return o
end

function DrawerUI:expand_query_context(payload)
  self.expanded["root:connections"] = true
  if payload.source_id then
    self.expanded["source:" .. payload.source_id] = true
  end
  if payload.connection_id then
    self.expanded["connection:" .. payload.connection_id] = true
  end
  if payload.connection_id and payload.database and payload.database ~= "" then
    self.expanded[("database:%s:%s"):format(payload.connection_id, payload.database)] = true
  end
end

function DrawerUI:show(winid)
  self.window = winid
  vim.api.nvim_win_set_buf(winid, self.bufnr)
  vim.wo[winid].wrap = false
  vim.wo[winid].number = false
  vim.wo[winid].relativenumber = false
  self:refresh()
end

function DrawerUI:node_at_cursor()
  return self.line_map[vim.api.nvim_win_get_cursor(0)[1]]
end

function DrawerUI:candy_for_kind(kind, expandable, materialization, active, opts)
  if kind == "source" then
    return candies_module.get(self.candies, "source")
  elseif kind == "connection" then
    if active then
      return candies_module.get(self.candies, "connection_active", "connection")
    end
    return candies_module.get(self.candies, "connection")
  elseif kind == "database" then
    return candies_module.get(self.candies, "database_switch")
  elseif kind == "schema" or kind == "dbroot" then
    return candies_module.get(self.candies, "schema")
  elseif kind == "table" then
    if materialization == "view" then
      return candies_module.get(self.candies, "view")
    end
    return candies_module.get(self.candies, "table")
  elseif kind == "column" then
    return candies_module.get(self.candies, "column")
  elseif kind == "add_connection" or kind == "scratchpad_new" then
    return candies_module.get(self.candies, "add")
  elseif kind == "edit_source" then
    return candies_module.get(self.candies, "edit")
  elseif kind == "scratchpad" then
    return candies_module.get(self.candies, "note")
    elseif kind == "scratchpad_dir" then
    if opts and opts.is_active_project then
      local candy = vim.deepcopy(candies_module.get(self.candies, "connection_active", "source"))
      candy.icon = "" -- Open folder icon
      return candy
    end
    -- Normal folders and non-active project folders look the same (no color)
    return candies_module.get(self.candies, expandable and "none_dir" or "none")
  elseif kind == "help" then
    return candies_module.get(self.candies, "help")
  elseif kind == "root" then
    return candies_module.get(self.candies, expandable and "none_dir" or "none")
  end
  return candies_module.get(self.candies, expandable and "none_dir" or "none")
end

function DrawerUI:add_line(lines, depth, label, node, opts)
  opts = opts or {}
  local builder = buffer_line.new_builder()
  buffer_line.append(builder, string.rep("  ", depth))

  if self.config.disable_candies then
    local active = opts.active and "● " or ""
    buffer_line.append(builder, active .. label)
  else
    local candy = self:candy_for_kind(node.kind, opts.expandable, node.materialization, opts.active, opts)
    if candy.icon and candy.icon ~= "" then
      buffer_line.append(builder, candy.icon .. " ", candy.icon_highlight)
    elseif candy.icon == " " then
      buffer_line.append(builder, " ")
    end

    local text_hl = candy.text_highlight
    if opts.active and candy.icon_highlight ~= "" then
      text_hl = candy.icon_highlight
    end
    buffer_line.append(builder, label, text_hl ~= "" and text_hl or nil)
  end

  table.insert(lines, builder)
  self.line_map[#lines] = node
end

function DrawerUI:is_expanded(key)
  return self.expanded[key] == true
end

function DrawerUI:toggle_node(key)
  self.expanded[key] = not self.expanded[key]
end

function DrawerUI:connection_prompt(initial, done)
  local values = vim.deepcopy(initial or {})
  local fields = {
    { key = "name", prompt = "Connection name: " },
    { key = "type", prompt = "Connection type (sqlite/postgres/mysql): " },
    { key = "url", prompt = "Connection URL/path: " },
  }

  local function step(index)
    if index > #fields then
      done(values)
      return
    end
    local field = fields[index]
    vim.ui.input({ prompt = field.prompt, default = values[field.key] or "" }, function(value)
      if value == nil then
        return
      end
      values[field.key] = value
      step(index + 1)
    end)
  end

  step(1)
end

function DrawerUI:render_structure_items(lines, depth, conn, items)
  table.sort(items, function(left, right)
    return left.name < right.name
  end)
  for _, item in ipairs(items) do
    local schema = item.schema
    local table_key = ("table:%s:%s:%s"):format(conn.id, schema or "", item.name)
    self:add_line(lines, depth, item.name, {
      kind = "table",
      key = table_key,
      connection_id = conn.id,
      schema = schema ~= "" and schema or nil,
      table = item.name,
      materialization = item.materialization,
    }, { expandable = true })

    if self:is_expanded(table_key) then
      local ok_cols, columns = pcall(self.handler.connection_get_columns, self.handler, conn.id, {
        table = item.name,
        schema = schema ~= "" and schema or nil,
        materialization = item.materialization,
      })
      if ok_cols then
        for _, col in ipairs(columns) do
          local col_label = col.name
          if col.primary_key then
            col_label = col_label .. " [PK]"
          end
          if col.data_type and col.data_type ~= "" then
            col_label = col_label .. " (" .. col.data_type .. ")"
          end
          self:add_line(lines, depth + 1, col_label, {
            kind = "column",
            key = ("column:%s:%s:%s:%s"):format(conn.id, schema or "", item.name, col.name),
            connection_id = conn.id,
            schema = schema ~= "" and schema or nil,
            table = item.name,
            column = col.name,
          })
        end
      else
        util.notify(("Failed to load columns for %s: %s"):format(item.name, columns), vim.log.levels.ERROR)
      end
    end
  end
end

function DrawerUI:table_action(node)
  self.handler:set_current_connection(node.connection_id)
  local helpers = self.handler:connection_get_helpers(node.connection_id, {
    table = node.table,
    schema = node.schema,
    materialization = node.materialization,
  })
  local items = util.table_keys_sorted(helpers)
  vim.ui.select(items, { prompt = "Select a query" }, function(choice)
    if not choice then
      return
    end
    local query = helpers[choice]
    if not query or query == "" then
      return
    end
    local ok, err = pcall(function()
      self.handler:connection_execute(node.connection_id, query, function(call)
        if call then
          self.result:set_call(call)
        end
      end)
    end)
    if not ok then
      util.notify(err, vim.log.levels.ERROR)
    end
  end)
end

function DrawerUI:insert_query(text)
  local note = self.editor:get_current_note()
  if not note then
    self.editor:namespace_create_note("global", "scratchpad")
    note = self.editor:get_current_note()
  end
  local note_details = note
  if type(note) == "table" and note.id then
    note_details = note
  elseif type(note) == "table" and note[1] then
    note_details = note[1]
  end
  if self.editor.window and vim.api.nvim_win_is_valid(self.editor.window) then
    vim.api.nvim_set_current_win(self.editor.window)
  end
  local line = vim.api.nvim_win_get_cursor(0)[1]
  vim.api.nvim_buf_set_lines(note_details.bufnr, line, line, false, { text, "" })
end

function DrawerUI:refresh()
  self.line_map = {}
  local lines = {}
  local current_note = self.editor:get_current_note()

  self:add_line(lines, 0, "Connections", {
    kind = "root",
    key = "root:connections",
  }, { expandable = true })
  if self:is_expanded("root:connections") then
    -- Auto-expand current active connection and its current database so initial view shows DB list
    local active_conn = self.handler:get_current_connection()
    if active_conn and active_conn.id then
      if active_conn.source_id then
        self.expanded["source:" .. active_conn.source_id] = true
      end
      self.expanded["connection:" .. active_conn.id] = true
      local ok_db, current_db, databases = pcall(self.handler.connection_list_databases, self.handler, active_conn.id)
      if ok_db and current_db and current_db ~= "" then
        self.expanded[("database:%s:%s"):format(active_conn.id, current_db)] = true
      end
    end

    for _, source in ipairs(self.handler:get_sources()) do
      local source_key = "source:" .. source:name()
      self:add_line(lines, 1, source:name(), {
        kind = "source",
        key = source_key,
        source_id = source:name(),
      }, { expandable = true })
      if self:is_expanded(source_key) then
        for _, conn in ipairs(self.handler:source_get_connections(source:name())) do
          local active = self.handler:get_current_connection()
          local is_active = active and active.id == conn.id
          local conn_key = "connection:" .. conn.id
          self:add_line(lines, 2, conn.name, {
            kind = "connection",
            key = conn_key,
            connection_id = conn.id,
            source_id = source:name(),
          }, { expandable = true, active = is_active })
          if self:is_expanded(conn_key) then
            local ok_dbs, current_db, databases = pcall(self.handler.connection_list_databases, self.handler, conn.id)
            local has_databases = ok_dbs and #(databases or {}) > 0

            if has_databases then
              for _, database in ipairs(databases or {}) do
                local db_key = ("database:%s:%s"):format(conn.id, database)
                self:add_line(lines, 3, database, {
                  kind = "database",
                  key = db_key,
                  connection_id = conn.id,
                  database = database,
                }, { expandable = true, active = database == current_db })
                if self:is_expanded(db_key) then
                  local ok_structure, items = pcall(self.handler.connection_get_structure, self.handler, conn.id, database)
                  if ok_structure then
                    self:render_structure_items(lines, 4, conn, items)
                  else
                    util.notify(("Failed to load tables for %s: %s"):format(database, items), vim.log.levels.ERROR)
                  end
                end
              end
            else
              local ok_structure, structure = pcall(self.handler.connection_get_structure, self.handler, conn.id)
              if ok_structure then
                self:render_structure_items(lines, 3, conn, structure)
              end
            end
          end
        end

        if type(source.create) == "function" then
          self:add_line(lines, 2, "add connection", {
            kind = "add_connection",
            key = "add:" .. source:name(),
            source_id = source:name(),
          })
        end
        if type(source.file) == "function" then
          self:add_line(lines, 2, "edit source file", {
            kind = "edit_source",
            key = "edit:" .. source:name(),
            source_id = source:name(),
            file = source:file(),
          })
        end
      end
    end
  end

        self:add_line(lines, 0, "Scratchpads", {
    kind = "root",
    key = "root:scratchpads",
  }, { expandable = true })
  if self:is_expanded("root:scratchpads") then
                    local all_namespaces = self.editor:get_namespaces()
    local current_note = self.editor:get_current_note()

    -- Resolve project immediately from the current buffer so the drawer doesn't rely solely on external state updates.
    local buffer_project = util.resolve_project()
    local state_project = self.state_helpers.get_current_project and self.state_helpers.get_current_project() or nil

    local current_project = nil
    if buffer_project then
      -- If the buffer is a scratchpad, prefer the richer state_project (with root info) when names match.
      if buffer_project.is_scratchpad and state_project and state_project.name == buffer_project.name then
        current_project = state_project
      else
        current_project = buffer_project
      end
    else
      current_project = state_project
    end

    -- Determine the full namespace to expand (prefer persisted mapping when available)
    local active_namespace = nil
    local active_project_name = nil
    if current_project then
      -- Try persisted mapping first
      if current_project.root and util.get_project_mapping then
        local mapped_ns = util.get_project_mapping(current_project.root)
        if mapped_ns and vim.tbl_contains(self.editor:get_namespaces(), mapped_ns) then
          active_namespace = mapped_ns
        end
      end

      if not active_namespace then
        -- Prefer exact branch match when possible, otherwise try to find any namespace matching the project name
        local branch = nil
        if current_project.root then
          branch = util.get_git_branch(current_project.root) or "main"
        end
        local ns_list = self.editor:get_namespaces()
        if branch then
          local desired = current_project.name .. "/" .. branch
          for _, n in ipairs(ns_list) do
            if n == desired then
              active_namespace = n
              break
            end
          end
        end

        -- If still not found, search for any namespace that starts with the project name
        if not active_namespace then
          local prefix = current_project.name .. "/"
          local candidate = nil
          for _, n in ipairs(ns_list) do
            if n:sub(1, #prefix) == prefix then
              candidate = candidate or n
            end
          end
          if candidate then
            active_namespace = candidate
            -- persist mapping for next time
            if current_project.root then
              util.set_project_mapping(current_project.root, candidate)
            end
          else
            -- fallback to constructed namespace
            if current_project.root then
              active_namespace = current_project.name .. "/" .. (branch or "main")
            else
              active_namespace = current_project.name
            end
          end
        end
      end

      active_project_name = vim.split(active_namespace, "/")[1]
    end

    -- If a scratchpad note is focused (and it's the focused buffer), use its namespace as an explicit override.
    local current_buf = vim.api.nvim_get_current_buf()
    if current_note and current_note.namespace ~= "global" and current_note.bufnr and current_note.bufnr == current_buf then
      active_namespace = current_note.namespace
      active_project_name = vim.split(active_namespace, "/")[1]
    end

    -- Auto-expand current project path (use full namespace if available)
    if active_namespace then
      local parts = vim.split(active_namespace, "/")
      for i=1,#parts do
        self.expanded["scratchpad_ns:" .. table.concat(parts, "/", 1, i)] = true
      end
    end

    local tree = {}
    for _, ns_id in ipairs(all_namespaces) do
      local parts = vim.split(ns_id, "/")
      local project_name = parts[1]
      
      if not self.config.project_filter_only_current or project_name == active_project_name or project_name == "global" then
        local curr = tree
        for i, part in ipairs(parts) do
          curr[part] = curr[part] or { nodes = {}, full_path = table.concat(parts, "/", 1, i), is_project = (i == 1 and part ~= "global") }
          curr = curr[part].nodes
        end
      end
    end

    local function render_tree(nodes, depth)
      local sorted_keys = vim.tbl_keys(nodes)
      table.sort(sorted_keys, function(a, b)
        if a == "global" then return true end
        if b == "global" then return false end
        return a < b
      end)
      for _, key in ipairs(sorted_keys) do
        local data = nodes[key]
        local ns_key = "scratchpad_ns:" .. data.full_path
        local is_active = data.is_project and (key == active_project_name)

        self:add_line(lines, depth, key, {
          kind = "scratchpad_dir",
          key = ns_key,
          namespace = data.full_path,
        }, { 
          expandable = true, 
          is_project = data.is_project,
          is_active_project = is_active
        })

        if self:is_expanded(ns_key) then
          render_tree(data.nodes, depth + 1)
          for _, note in ipairs(self.editor:namespace_get_notes(data.full_path)) do
            self:add_line(lines, depth + 1, note.name, {
              kind = "scratchpad",
              key = "scratchpad:" .. note.id,
              note_id = note.id,
              namespace = data.full_path,
            }, { active = current_note and current_note.id == note.id })
          end
        end
      end
    end
    render_tree(tree, 1)

  end

  if not self.config.disable_help then
    self:add_line(lines, 0, "Help", {
      kind = "help",
      key = "root:help",
    }, { expandable = true })
    if self:is_expanded("root:help") then
      self:add_line(lines, 1, "<CR>: open/select", { kind = "help", key = "help:1" })
      self:add_line(lines, 1, "o: toggle node", { kind = "help", key = "help:2" })
      self:add_line(lines, 1, "cw: rename/edit", { kind = "help", key = "help:3" })
      self:add_line(lines, 1, "dd: delete", { kind = "help", key = "help:4" })
      self:add_line(lines, 1, "r: refresh", { kind = "help", key = "help:5" })
    end
  end

  buffer_line.render(self.bufnr, self.ns, lines)

  -- Move cursor to active project directory so the drawer's visual selection follows the project
  if self.window and vim.api.nvim_win_is_valid(self.window) and active_project_name then
    for i = 1, #lines do
      local node = self.line_map[i]
      if node and node.kind == "scratchpad_dir" then
        local proj = vim.split(node.namespace, "/")[1]
        if proj == active_project_name then
          -- move cursor
          pcall(vim.api.nvim_win_set_cursor, self.window, { i, 0 })

          -- If we've switched active project namespace, open the project's first scratchpad note in the editor
          local ns = node.namespace
          if ns and ns ~= self.last_active_namespace then
            self.last_active_namespace = ns
            if self.editor then
              local notes = self.editor:namespace_get_notes(ns)
              if notes and #notes > 0 then
                local cur = self.editor:get_current_note()
                if not cur or cur.namespace ~= ns then
                  pcall(function()
                    self.editor:set_current_note(notes[1].id)
                  end)
                end
              end
            end
          end

          break
        end
      end
    end
  end
end

function DrawerUI:do_action(action)
  local node = self:node_at_cursor()
  if not node then
    return
  end

  if action == "refresh" then
    self:refresh()
    return
  end

  if action == "toggle" then
    if node.key then
      self:toggle_node(node.key)
      self:refresh()
    end
    return
  end

    if action == "action_toggle_filter" then
    self.config.project_filter_only_current = not self.config.project_filter_only_current
    self:refresh()
    return
  end

  if action == "action_add" then
    local ns = "global"
    if node.kind == "scratchpad_dir" or node.kind == "scratchpad" then
      ns = node.namespace
    end
    vim.ui.input({ prompt = "New scratchpad name: " }, function(name)
      if not name or name == "" then return end
      local ok, note_id = pcall(self.editor.namespace_create_note, self.editor, ns, name)
      if ok then
        self.editor:set_current_note(note_id)
        self:refresh()
      end
    end)
    return
  end

  if action == "action_1" then
    if node.kind == "table" then
      self:table_action(node)
    elseif node.kind == "column" then
      self:insert_query(node.column)
    elseif node.kind == "database" then
      self.handler:set_current_connection(node.connection_id)
      self.handler:connection_select_database(node.connection_id, node.database)
      self:toggle_node(node.key)
      self:refresh()
    elseif node.kind == "root" or node.kind == "source" or node.kind == "connection" then
      if node.kind == "connection" then
        self.handler:set_current_connection(node.connection_id)
      end
      self:toggle_node(node.key)
      self:refresh()
    elseif node.kind == "add_connection" then
      self:connection_prompt({}, function(details)
        local ok, err = pcall(self.handler.source_add_connection, self.handler, node.source_id, details)
        if not ok then
          util.notify(err, vim.log.levels.ERROR)
        end
      end)
    elseif node.kind == "edit_source" then
      float.editor(node.file, {
        title = vim.fn.fnamemodify(node.file, ":t"),
        on_save = function()
          pcall(self.handler.source_reload, self.handler, node.source_id)
        end,
      })
    elseif node.kind == "scratchpad" then
      self.editor:set_current_note(node.note_id)
    end
    return
  end

  if action == "action_2" then
    if node.kind == "connection" then
      local conn = self.handler:connection_get_params(node.connection_id)
      self:connection_prompt(conn, function(details)
        details.id = conn.id
        local ok, err = pcall(self.handler.source_update_connection, self.handler, node.source_id, node.connection_id, details)
        if not ok then
          util.notify(err, vim.log.levels.ERROR)
        end
      end)
    elseif node.kind == "scratchpad" then
      -- Prefill with the current note name
      local note = self.editor:search_note(node.note_id)
      local default_name = note and note.name or ""
      vim.ui.input({ prompt = "Rename scratchpad: ", default = default_name }, function(name)
        if not name or name == "" then return end
        local ok, err = pcall(self.editor.note_rename, self.editor, node.note_id, name)
        if not ok then util.notify(err, vim.log.levels.ERROR) end
        self:refresh()
      end)
    elseif node.kind == "scratchpad_dir" then
      -- Prefill with only the last path segment (directory name)
      local parts = vim.split(node.namespace, "/")
      local last = parts[#parts]
      vim.ui.input({ prompt = "Rename directory: ", default = last }, function(new_basename)
        if not new_basename or new_basename == "" then return end
        -- reconstruct full namespace using the parent path
        local parent = #parts > 1 and table.concat(parts, "/", 1, #parts - 1) or nil
        local new_ns = parent and (parent .. "/" .. new_basename) or new_basename
        if new_ns == node.namespace then return end
        local ok, err = pcall(function()
          -- Perform namespace rename in editor (preserves buffers)
          self.editor:namespace_rename(node.namespace, new_ns)

          -- Collapse other scratchpad namespaces and expand only the renamed path
          for k, _ in pairs(self.expanded) do
            if k:sub(1, string.len("scratchpad_ns:")) == "scratchpad_ns:" then
              self.expanded[k] = nil
            end
          end
          local new_parts = vim.split(new_ns, "/")
          for i=1,#new_parts do
            self.expanded["scratchpad_ns:" .. table.concat(new_parts, "/", 1, i)] = true
          end

          -- Remember last active namespace and instruct editor to show its first note
          self.last_active_namespace = new_ns
          local notes = self.editor:namespace_get_notes(new_ns)
          if notes and #notes > 0 then
            pcall(function()
              self.editor:set_current_note(notes[1].id)
            end)
          end
        end)
        if not ok then util.notify(err, vim.log.levels.ERROR) end
        self:refresh()
      end)
    end
    return
  end

  if action == "action_3" then
    if node.kind == "connection" then
      local ok, err = pcall(self.handler.source_remove_connection, self.handler, node.source_id, node.connection_id)
      if not ok then
        util.notify(err, vim.log.levels.ERROR)
      end
    elseif node.kind == "scratchpad" then
      local note, namespace = self.editor:search_note(node.note_id)
      if note then
        self.editor:namespace_remove_note(namespace, node.note_id)
      end
    end
  end
end

return DrawerUI
