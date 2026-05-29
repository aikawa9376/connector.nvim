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
    window = nil,
    line_map = {},
    expanded = {
      ["root:connections"] = true,
      ["root:scratchpads"] = true,
      ["root:help"] = true,
    },
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
  editor:register_event_listener("notes_changed", function()
    o:refresh()
  end)

  return o
end

function DrawerUI:show(winid)
  self.window = winid
  vim.api.nvim_win_set_buf(winid, self.bufnr)
  self:refresh()
end

function DrawerUI:node_at_cursor()
  return self.line_map[vim.api.nvim_win_get_cursor(0)[1]]
end

function DrawerUI:add_line(lines, depth, label, node)
  table.insert(lines, string.rep("  ", depth) .. label)
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

  self:add_line(lines, 0, (self:is_expanded("root:connections") and "▾ " or "▸ ") .. "Connections", {
    kind = "root",
    key = "root:connections",
  })
  if self:is_expanded("root:connections") then
    for _, source in ipairs(self.handler:get_sources()) do
      local source_key = "source:" .. source:name()
      self:add_line(lines, 1, (self:is_expanded(source_key) and "▾ " or "▸ ") .. source:name(), {
        kind = "source",
        key = source_key,
        source_id = source:name(),
      })
      if self:is_expanded(source_key) then
        for _, conn in ipairs(self.handler:source_get_connections(source:name())) do
          local active = self.handler:get_current_connection()
          local is_active = active and active.id == conn.id
          local conn_key = "connection:" .. conn.id
          self:add_line(lines, 2, (self:is_expanded(conn_key) and "▾ " or "▸ ") .. (is_active and "* " or "") .. conn.name, {
            kind = "connection",
            key = conn_key,
            connection_id = conn.id,
            source_id = source:name(),
          })
          if self:is_expanded(conn_key) then
            local ok_dbs, current_db, databases = pcall(self.handler.connection_list_databases, self.handler, conn.id)
            if ok_dbs and (current_db ~= "" or #(databases or {}) > 0) then
              local db_root_key = "dbroot:" .. conn.id
              self:add_line(lines, 3, (self:is_expanded(db_root_key) and "▾ " or "▸ ") .. "Databases", {
                kind = "dbroot",
                key = db_root_key,
              })
              if self:is_expanded(db_root_key) then
                for _, database in ipairs(databases or {}) do
                  self:add_line(lines, 4, (database == current_db and "* " or "") .. database, {
                    kind = "database",
                    key = ("database:%s:%s"):format(conn.id, database),
                    connection_id = conn.id,
                    database = database,
                  })
                end
              end
            end

            local ok_structure, structure = pcall(self.handler.connection_get_structure, self.handler, conn.id)
            if ok_structure then
              local grouped = {}
              for _, item in ipairs(structure) do
                local schema = item.schema or ""
                grouped[schema] = grouped[schema] or {}
                table.insert(grouped[schema], item)
              end
              for _, schema in ipairs(util.table_keys_sorted(grouped)) do
                local schema_key = ("schema:%s:%s"):format(conn.id, schema)
                self:add_line(lines, 3, (self:is_expanded(schema_key) and "▾ " or "▸ ") .. (schema ~= "" and schema or "(default)"), {
                  kind = "schema",
                  key = schema_key,
                })
                if self:is_expanded(schema_key) then
                  table.sort(grouped[schema], function(left, right)
                    return left.name < right.name
                  end)
                  for _, item in ipairs(grouped[schema]) do
                    local table_key = ("table:%s:%s:%s"):format(conn.id, schema, item.name)
                    self:add_line(lines, 4, (self:is_expanded(table_key) and "▾ " or "▸ ") .. item.name .. " [" .. item.materialization .. "]", {
                      kind = "table",
                      key = table_key,
                      connection_id = conn.id,
                      schema = schema ~= "" and schema or nil,
                      table = item.name,
                      materialization = item.materialization,
                    })
                    if self:is_expanded(table_key) then
                      local helpers = self.handler:connection_get_helpers(conn.id, {
                        table = item.name,
                        schema = schema ~= "" and schema or nil,
                        materialization = item.materialization,
                      })
                      for _, helper_name in ipairs(util.table_keys_sorted(helpers)) do
                        self:add_line(lines, 5, helper_name, {
                          kind = "helper",
                          key = ("helper:%s:%s:%s"):format(conn.id, item.name, helper_name),
                          query = helpers[helper_name],
                        })
                      end

                      local ok_columns, cols = pcall(self.handler.connection_get_columns, self.handler, conn.id, {
                        table = item.name,
                        schema = schema ~= "" and schema or nil,
                        materialization = item.materialization,
                      })
                      if ok_columns then
                        for _, column in ipairs(cols) do
                          self:add_line(lines, 5, ("%s :: %s"):format(column.name, column.data_type), {
                            kind = "column",
                            key = ("column:%s:%s"):format(item.name, column.name),
                          })
                        end
                      end
                    end
                  end
                end
              end
            end
          end
        end

        if type(source.create) == "function" then
          self:add_line(lines, 2, "+ add connection", {
            kind = "add_connection",
            key = "add:" .. source:name(),
            source_id = source:name(),
          })
        end
        if type(source.file) == "function" then
          self:add_line(lines, 2, "~ edit source file", {
            kind = "edit_source",
            key = "edit:" .. source:name(),
            file = source:file(),
          })
        end
      end
    end
  end

  self:add_line(lines, 0, (self:is_expanded("root:scratchpads") and "▾ " or "▸ ") .. "Scratchpads", {
    kind = "root",
    key = "root:scratchpads",
  })
  if self:is_expanded("root:scratchpads") then
    self:add_line(lines, 1, "+ new", {
      kind = "scratchpad_new",
      key = "scratchpad:new",
    })
    for _, note in ipairs(self.editor:namespace_get_notes("global")) do
      self:add_line(lines, 1, note.name, {
        kind = "scratchpad",
        key = "scratchpad:" .. note.id,
        note_id = note.id,
      })
    end
  end

  if not self.config.disable_help then
    self:add_line(lines, 0, (self:is_expanded("root:help") and "▾ " or "▸ ") .. "Help", {
      kind = "root",
      key = "root:help",
    })
    if self:is_expanded("root:help") then
      self:add_line(lines, 1, "<CR>: open/select/insert", { kind = "help", key = "help:1" })
      self:add_line(lines, 1, "o: toggle node", { kind = "help", key = "help:2" })
      self:add_line(lines, 1, "cw: rename/edit", { kind = "help", key = "help:3" })
      self:add_line(lines, 1, "dd: delete", { kind = "help", key = "help:4" })
      self:add_line(lines, 1, "r: refresh", { kind = "help", key = "help:5" })
    end
  end

  util.buf_set_lines(self.bufnr, lines)
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
    if node.kind == "root" or node.kind == "source" or node.kind == "connection" or node.kind == "schema" or node.kind == "table" or node.kind == "dbroot" then
      if node.kind == "connection" then
        self.handler:set_current_connection(node.connection_id)
      elseif node.kind == "table" then
        local conn = self.handler:connection_get_params(node.connection_id)
        self:insert_query(("SELECT * FROM %s LIMIT 200;"):format(util.qualify_table(conn.type, node.schema, node.table)))
      end
      self:toggle_node(node.key)
      self:refresh()
    elseif node.kind == "helper" then
      self:insert_query(node.query)
    elseif node.kind == "database" then
      self.handler:connection_select_database(node.connection_id, node.database)
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

