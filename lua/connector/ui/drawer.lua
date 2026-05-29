local buffer_line = require("connector.ui.buffer_line")
local candies_module = require("connector.ui.candies")
local util = require("connector.util")

local DrawerUI = {}

function DrawerUI:new(handler, editor, result, config)
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

function DrawerUI:candy_for_kind(kind, expandable, materialization, active)
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
    local candy = self:candy_for_kind(node.kind, opts.expandable, node.materialization, opts.active)
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
    })
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
    self:add_line(lines, 1, "new", {
      kind = "scratchpad_new",
      key = "scratchpad:new",
    })
    for _, note in ipairs(self.editor:namespace_get_notes("global")) do
      self:add_line(lines, 1, note.name, {
        kind = "scratchpad",
        key = "scratchpad:" .. note.id,
        note_id = note.id,
      }, { active = current_note and current_note.id == note.id })
    end
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

  if action == "action_1" then
    if node.kind == "table" then
      self:table_action(node)
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
      vim.cmd("edit " .. vim.fn.fnameescape(node.file))
    elseif node.kind == "scratchpad_new" then
      vim.ui.input({ prompt = "Scratchpad name: " }, function(name)
        if not name or name == "" then
          return
        end
        local ok, note_id = pcall(self.editor.namespace_create_note, self.editor, "global", name)
        if ok then
          self.editor:set_current_note(note_id)
          self:refresh()
        end
      end)
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
      vim.ui.input({ prompt = "Rename scratchpad: " }, function(name)
        if not name or name == "" then
          return
        end
        local ok, err = pcall(self.editor.note_rename, self.editor, node.note_id, name)
        if not ok then
          util.notify(err, vim.log.levels.ERROR)
        end
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
