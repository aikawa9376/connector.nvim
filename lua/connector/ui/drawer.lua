local buffer_line = require("connector.ui.buffer_line")
local candies_module = require("connector.ui.candies")
local float = require("connector.ui.float")
local util = require("connector.util")
local function dbg() end

local DrawerUI = {}
local GENERATE_ACTIONS = { "Select", "Update", "Delete", "Insert" }

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
  o:setup_enter_mappings()

  handler:register_event_listener("connections_changed", function()
    o:refresh()
  end)
  handler:register_event_listener("current_connection_changed", function()
    o:refresh()
  end)
  handler:register_event_listener("query_context_changed", function(payload)
    if payload and payload.table then
      o:reveal_table(payload)
      return
    end
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

function DrawerUI:capture_visual_range()
  local start_row = vim.fn.getpos("'<")[2]
  local end_row = vim.fn.getpos("'>")[2]

  if start_row and end_row and start_row ~= 0 and end_row ~= 0 then
    self._explicit_visual_range = {
      start_row = start_row,
      end_row = end_row,
    }
  else
    self._explicit_visual_range = nil
  end
end

function DrawerUI:run_primary_action(leave_visual_mode)
  if leave_visual_mode then
    local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
    vim.cmd("normal! " .. esc)
  end

  self:capture_visual_range()
  self:do_action("action_1")
  vim.schedule(function()
    self._explicit_visual_range = nil
  end)
end

function DrawerUI:setup_enter_mappings()
  local opts = { buffer = self.bufnr, nowait = true, silent = true }

  vim.keymap.set({ "v", "x" }, "<CR>", function()
    self:run_primary_action(true)
  end, opts)

  vim.keymap.set("n", "<CR>", function()
    self:run_primary_action(false)
  end, opts)
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
    if self:is_database_ignored(payload.connection_id, payload.database) then
      self.expanded["ignored_databases"] = true
      self.expanded["ignored_connection:" .. payload.connection_id] = true
    end
  end
end

function DrawerUI:table_line(entry)
  for line = 1, #self.line_map do
    local node = self.line_map[line]
    if node
      and node.kind == "table"
      and node.connection_id == entry.connection_id
      and node.table == entry.table
      and (node.schema or "") == (entry.schema or "") then
      return line
    end
  end
end

function DrawerUI:reveal_table(entry, opts)
  if not entry or not entry.connection_id or not entry.table then
    return
  end

  opts = vim.tbl_extend("force", {
    refresh = true,
    focus_window = false,
    center = true,
    fallback_top = false,
  }, opts or {})

  self:expand_query_context(entry)
  self.expanded[("table:%s:%s:%s"):format(entry.connection_id, entry.schema or "", entry.table)] = true

  if opts.refresh then
    self:refresh()
  end

  if not self.window or not vim.api.nvim_win_is_valid(self.window) then
    return
  end

  local current_win = vim.api.nvim_get_current_win()
  if opts.focus_window and current_win ~= self.window then
    vim.api.nvim_set_current_win(self.window)
  end

  local line = self:table_line(entry)
  if line then
    pcall(vim.api.nvim_win_set_cursor, self.window, { line, 0 })
    if opts.center then
      pcall(vim.api.nvim_win_call, self.window, function()
        pcall(vim.cmd, "normal! zz")
      end)
    end
  elseif opts.fallback_top then
    pcall(vim.api.nvim_win_set_cursor, self.window, { 1, 0 })
  end

  if not opts.focus_window and current_win ~= self.window and vim.api.nvim_win_is_valid(current_win) then
    pcall(vim.api.nvim_set_current_win, current_win)
  end
end

function DrawerUI:show(winid)
  self.window = winid
  vim.api.nvim_win_set_buf(winid, self.bufnr)
  vim.wo[winid].wrap = false
  vim.wo[winid].number = false
  vim.wo[winid].relativenumber = false

  -- Reapply buffer-local mappings when showing to ensure keys like 'i' are active
  util.apply_buffer_mappings(self.bufnr, self.config.mappings, function(action)
    self:do_action(action)
  end)
  self:setup_enter_mappings()

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
    if opts and opts.ignored then
      return candies_module.get(self.candies, "database_ignored", "database_switch")
    end
    return candies_module.get(self.candies, "database_switch")
  elseif kind == "ignored_databases_group" then
    return candies_module.get(self.candies, "ignore_group", "none_dir")
  elseif kind == "ignored_connection_group" then
    return candies_module.get(self.candies, "connection", "none_dir")
  elseif kind == "ignored_connection_marker" then
    return candies_module.get(self.candies, "remove", "none")
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
  -- mark whether this node is currently expanded (useful for folder icons)
  if node and node.key and opts.expanded == nil then
    opts.expanded = self:is_expanded(node.key)
  end

  local builder = buffer_line.new_builder()
  buffer_line.append(builder, string.rep("  ", depth))

  if self.config.disable_candies then
    local active = opts.active and "● " or ""
    buffer_line.append(builder, active .. label)
  else
    local candy = self:candy_for_kind(node.kind, opts.expandable, node.materialization, opts.active, opts)
    local c = vim.deepcopy(candy)

    -- current connection id (used to highlight connection children when the connection is active)
    local current_conn = self.handler and self.handler:get_current_connection()
    local current_conn_id = current_conn and current_conn.id or nil

    -- Hide the help icon for help items
    if node.kind == "help" then
      c.icon = ""
      c.icon_highlight = ""
      if depth == 0 then
        c.text_highlight = "Title"
      else
        c.text_highlight = nil
      end
    end

    -- Root headings: no icon but keep colored text
    if node.kind == "root" then
      c.icon = ""
      c.icon_highlight = ""
      c.text_highlight = "Title"
    end

    -- Determine whether this scratchpad dir contains the active namespace
    local contains_active = false
    if node and node.namespace and self._active_namespace and type(self._active_namespace) == "string" then
      if self._active_namespace:sub(1, #node.namespace) == node.namespace then
        contains_active = true
      end
    end

    -- Scratchpad directories: show open/closed icons; color only when active context
    if node.kind == "scratchpad_dir" then
      c.icon = opts.expanded and "" or ""
      if opts.is_active_project or contains_active then
        c.icon_highlight = "Identifier"
        c.text_highlight = opts.is_active_project and "Title" or "Identifier"
      else
        c.icon_highlight = "Comment"
        c.text_highlight = "Comment"
      end
    end

    -- Scratchpad files: active = green, active-context = blue icon / normal text, otherwise grey
    if node.kind == "scratchpad" then
      if opts.active then
        c.icon_highlight = "String"
        c.text_highlight = "String"
      else
        local in_active_context = opts.is_active_project or (opts.namespace and self._active_namespace and self._active_namespace:sub(1, #opts.namespace) == opts.namespace)
        if in_active_context then
          c.text_highlight = nil -- Normal text
          c.icon_highlight = nil -- Normal icon
        else
          c.icon_highlight = "Comment"
          c.text_highlight = "Comment"
        end
      end
    end

    -- Source headers: color when it contains the active connection
    if node.kind == "source" then
      if opts.active then
        c.text_highlight = "Title"
        c.icon_highlight = candy.icon_highlight
      else
        c.text_highlight = "Comment"
        c.icon_highlight = "Comment"
      end
    end

    -- Connection-related nodes: selected -> colored icon + normal text, otherwise normal text + candy icon (children not highlighted)
    if node.kind == "connection" or node.kind == "database" or node.kind == "table" or node.kind == "schema" or node.kind == "column" or node.kind == "ignored_connection_group" then
      local conn_active = node.connection_id and (node.connection_id == current_conn_id)

      -- Default: candy icon color, normal text (nil)
      c.icon_highlight = candy.icon_highlight
      c.text_highlight = nil

      if opts.active then
        -- Selected node: color icon and text per candy
        c.icon_highlight = candy.icon_highlight
        c.text_highlight = (candy.text_highlight and candy.text_highlight ~= "") and candy.text_highlight or candy.icon_highlight
      elseif not conn_active then
        -- Non-active connection and its children: show as comment (dim)
        c.text_highlight = "Comment"
        c.icon_highlight = "Comment"
      end
    end

    if c.icon and c.icon ~= "" then
      buffer_line.append(builder, c.icon .. " ", c.icon_highlight)
    elseif c.icon == " " then
      buffer_line.append(builder, " ")
    end

    local text_hl = c.text_highlight
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
  local current_conn = self.handler and self.handler:get_current_connection()
  local current_conn_id = current_conn and current_conn.id or nil
  for _, item in ipairs(items) do
    local schema = item.schema
    local table_key = ("table:%s:%s:%s"):format(conn.id, schema or "", item.name)
    local is_conn_active = current_conn_id == conn.id
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

function DrawerUI:current_project()
  return self.state_helpers.get_current_project and self.state_helpers.get_current_project() or nil
end

function DrawerUI:is_database_ignored(conn_id, database)
  return util.is_project_database_ignored(self:current_project(), conn_id, database)
end

function DrawerUI:add_database_line(lines, depth, conn, database, current_db, ignored)
  local db_key = ("database:%s:%s"):format(conn.id, database)
  self:add_line(lines, depth, database, {
    kind = "database",
    key = db_key,
    connection_id = conn.id,
    database = database,
    ignored = ignored == true,
  }, { expandable = true, active = database == current_db, ignored = ignored == true })
  if self:is_expanded(db_key) then
    local ok_structure, items = pcall(self.handler.connection_get_structure, self.handler, conn.id, database)
    if ok_structure then
      self:render_structure_items(lines, depth + 1, conn, items)
    else
      util.notify(("Failed to load tables for %s: %s"):format(database, items), vim.log.levels.ERROR)
    end
  end
end

function DrawerUI:execute_query(connection_id, query)
  if not query or query == "" then
    return
  end

  local ok, err = pcall(function()
    self.handler:connection_execute(connection_id, query, function(call)
      if call then
        self.result:set_call(call)
      end
    end)
  end)
  if not ok then
    util.notify(err, vim.log.levels.ERROR)
  end
end

function DrawerUI:query_action_items(node)
  local helpers = self.handler:connection_get_helpers(node.connection_id, {
    table = node.table,
    schema = node.schema,
    materialization = node.materialization,
  })

  local items = vim.deepcopy(GENERATE_ACTIONS)
  table.insert(items, "Query History")
  for _, helper_name in ipairs(util.table_keys_sorted(helpers)) do
    table.insert(items, helper_name)
  end

  return helpers, items
end

function DrawerUI:open_query_action_menu(node, opts)
  opts = opts or {}
  if opts.set_current_connection then
    self.handler:set_current_connection(node.connection_id)
  end

  local helpers, items = self:query_action_items(node)
  local visual_cols = self:get_selected_columns_from_visual(node)

  vim.ui.select(items, { prompt = "Select action" }, function(choice, idx)
    if not choice or not idx then
      return
    end

    if choice == "Query History" then
      self:table_history_action(node)
      return
    end

    if helpers[choice] then
      self:execute_query(node.connection_id, helpers[choice])
      return
    end

    local action = choice:lower()
    if action == "select" or action == "update" or action == "delete" or action == "insert" then
      self:generate_query_for_table(node, action, visual_cols)
    end
  end)
end

function DrawerUI:table_action(node)
  self:open_query_action_menu(node, { set_current_connection = true })
end

function DrawerUI:table_history_action(node)
  local entries = self.handler:query_history({
    connection_id = node.connection_id,
    table = node.table,
    schema = node.schema,
    ignore_project_branch = true,
  })
  if #entries == 0 then
    entries = self.handler:query_history({
      table = node.table,
      schema = node.schema,
      ignore_project_branch = true,
    })
  end
  if #entries == 0 and node.schema then
    entries = self.handler:query_history({
      table = node.table,
      ignore_project_branch = true,
    })
  end
  if #entries == 0 then
    util.notify(("No query history for %s."):format(node.table), vim.log.levels.INFO)
    return
  end

  local labels = vim.tbl_map(function(entry)
    return entry.display
  end, entries)
  vim.ui.select(labels, { prompt = "Select query history" }, function(_choice, idx)
    if not idx then
      return
    end
    local entry = entries[idx]
    if not entry or not entry.query or entry.query == "" then
      return
    end
    self:execute_query(entry.connection_id or node.connection_id, entry.query)
  end)
end

function DrawerUI:insert_query(text)
  -- Append query to the end of the current scratchpad with one blank line before it
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

  local bufnr = note_details.bufnr
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local line_count = vim.api.nvim_buf_line_count(bufnr)
  -- Insert a blank line then the query
  vim.api.nvim_buf_set_lines(bufnr, line_count, line_count, false, { "", text })

  -- Show the editor and move cursor to the inserted query
  if self.editor.window and vim.api.nvim_win_is_valid(self.editor.window) then
    vim.api.nvim_set_current_win(self.editor.window)
    local new_line = vim.api.nvim_buf_line_count(bufnr)
    pcall(vim.api.nvim_win_set_cursor, self.editor.window, { new_line, 0 })
  end
end

function DrawerUI:prompt_add_connection()
  local sources = self.handler:get_sources()
  local creatable = {}
  for _, source in ipairs(sources) do
    if type(source.create) == "function" then
      table.insert(creatable, source:name())
    end
  end

  if #creatable == 0 then
    util.notify("No sources support adding connections.", vim.log.levels.WARN)
    return
  end

  vim.ui.select(creatable, { prompt = "Select source to add connection:" }, function(choice)
    if not choice then
      return
    end

    self:connection_prompt({}, function(details)
      local ok, err = pcall(self.handler.source_add_connection, self.handler, choice, details)
      if not ok then
        util.notify(err, vim.log.levels.ERROR)
      end
      self:refresh()
    end)
  end)
end

-- Helpers for generating queries from table/column selection
function DrawerUI:get_visual_selection_range()
  -- Prefer an explicitly-captured range (set by the visual <CR> wrapper) so we don't
  -- depend on marks that may be cleared by UI prompts.
  if self._explicit_visual_range then
    local s = self._explicit_visual_range.start_row
    local e = self._explicit_visual_range.end_row
    dbg(("get_visual_selection_range: using explicit range: %s..%s"):format(tostring(s), tostring(e)))
    if s and e and s ~= 0 and e ~= 0 then
      if s > e then s, e = e, s end
      return s, e
    end
  end

  -- Try the regular visual marks first
  local start_row = vim.fn.getpos("'<")[2]
  local end_row = vim.fn.getpos("'>")[2]
  dbg(("get_visual_selection_range: fallback marks: start=%s end=%s mode=%s"):format(tostring(start_row), tostring(end_row), vim.fn.mode()))
  if start_row and end_row and start_row ~= 0 and end_row ~= 0 then
    if start_row > end_row then start_row, end_row = end_row, start_row end
    return start_row, end_row
  end

  -- If marks are not available but we're still in visual mode, try to compute the
  -- range from the visual-start ('v') mark and the current cursor row.
  local mode = vim.fn.mode()
  local mode_char = mode and mode:sub(1,1) or ''
  if mode_char == 'v' or mode_char == 'V' or mode_char == '\22' then
    local vpos = vim.fn.getpos('v')
    local vrow = vpos and vpos[2] or 0
    local currow = vim.api.nvim_win_get_cursor(0)[1]
    dbg(("get_visual_selection_range: visual mode fallback vrow=%s currow=%s"):format(tostring(vrow), tostring(currow)))
    if vrow and vrow ~= 0 then
      if vrow > currow then vrow, currow = currow, vrow end
      return vrow, currow
    end
  end

  dbg("get_visual_selection_range: no marks")
  return nil
end

function DrawerUI:get_selected_columns_from_visual(node)
  local s, e = self:get_visual_selection_range()
  if not s then
    dbg("no visual selection")
    return nil
  end
  dbg(("visual selection range: %s..%s"):format(s, e))
  local cols = {}
  for i = s, e do
    local n = self.line_map[i]
    if n and n.kind == "column" and n.table == node.table and n.connection_id == node.connection_id then
      if (not node.schema and not n.schema) or (node.schema and n.schema == node.schema) then
        table.insert(cols, n.column)
      end
    end
  end
  dbg(("selected columns from visual: %s"):format(vim.inspect(cols)))
  if #cols == 0 then return nil end
  return cols
end

function DrawerUI:get_all_columns_for_table(node)
  local ok, columns = pcall(self.handler.connection_get_columns, self.handler, node.connection_id, {
    table = node.table,
    schema = node.schema,
    materialization = node.materialization or "table",
  })
  if not ok or not columns or #columns == 0 then return nil end
  local names = {}
  for _, c in ipairs(columns) do table.insert(names, c.name) end
  return names, columns
end

function DrawerUI:generate_query_for_table(node, action, explicit_cols)
  -- action is one of: "select", "update", "delete", "insert"
  local sel_cols = explicit_cols or self:get_selected_columns_from_visual(node)
  dbg(("generate_query_for_table called: action=%s table=%s schema=%s explicit=%s sel_cols=%s"):format(tostring(action), tostring(node and node.table), tostring(node and node.schema), vim.inspect(explicit_cols), vim.inspect(sel_cols)))
  local all_cols, cols_meta = self:get_all_columns_for_table(node)
  dbg(("all_cols=%s cols_meta_count=%s"):format(vim.inspect(all_cols), tostring(cols_meta and #cols_meta or 0)))

  -- If no visual selection and this was invoked from a single column click, prefer that column
  if not sel_cols and node and node.kind == "column" and node.column then
    sel_cols = { node.column }
  end

  local cols = sel_cols or all_cols

  local conn = nil
  pcall(function() conn = self.handler:connection_get_params(node.connection_id) end)
  local conn_type = (conn and conn.type and conn.type:lower()) or "sqlite"
  local qual_table = util.qualify_table(conn_type, node.schema and node.schema ~= "" and node.schema or nil, node.table)

  local function quote(name)
    return util.quote_identifier(conn_type, name)
  end

  local text = ""
  if action == "select" then
    if not cols then
      text = ("SELECT * FROM %s;"):format(qual_table)
    else
      local quoted = {}
      for _, n in ipairs(cols) do table.insert(quoted, quote(n)) end
      text = ("SELECT %s FROM %s;"):format(table.concat(quoted, ", "), qual_table)
    end
  elseif action == "delete" then
    local pk_names = {}
    if cols_meta then
      for _, c in ipairs(cols_meta) do if c.primary_key then table.insert(pk_names, c.name) end end
    end
    local where_clause = nil
    if #pk_names > 0 then
      local parts = {}
      for _, pk in ipairs(pk_names) do table.insert(parts, ("%s = ?"):format(quote(pk))) end
      where_clause = table.concat(parts, " AND ")
    else
      local key_col = (cols and cols[1]) or (all_cols and all_cols[1])
      if key_col then
        where_clause = ("%s = "):format(quote(key_col))
      else
        where_clause = ""
      end
    end
    text = ("DELETE FROM %s WHERE %s;"):format(qual_table, where_clause)
  elseif action == "update" then
    local set_cols = {}
    if cols and #cols > 0 then
      for _, c in ipairs(cols) do table.insert(set_cols, ("%s = ?"):format(quote(c))) end
    elseif cols_meta then
      for _, c in ipairs(cols_meta) do if not c.primary_key then table.insert(set_cols, ("%s = ?"):format(quote(c.name))) end end
    end
    local set_clause = table.concat(set_cols, ", ")
    if set_clause == "" then
      set_clause = "-- TODO: set_column = ?"
    end

    local pk_names = {}
    if cols_meta then for _, c in ipairs(cols_meta) do if c.primary_key then table.insert(pk_names, c.name) end end end
    local where_clause = nil
    if #pk_names > 0 then
      local parts = {}
      for _, pk in ipairs(pk_names) do table.insert(parts, ("%s = ?"):format(quote(pk))) end
      where_clause = table.concat(parts, " AND ")
    else
      local key_col = (cols and cols[1]) or (all_cols and all_cols[1])
      if key_col then
        where_clause = ("%s = "):format(quote(key_col))
      else
        where_clause = ""
      end
    end
    text = ("UPDATE %s SET %s WHERE %s;"):format(qual_table, set_clause, where_clause)
  elseif action == "insert" then
    local ins_cols = cols or all_cols
    if not ins_cols or #ins_cols == 0 then
      text = ("INSERT INTO %s DEFAULT VALUES;"):format(qual_table)
    else
      local quoted = {}
      local placeholders = {}
      for _, c in ipairs(ins_cols) do table.insert(quoted, quote(c)); table.insert(placeholders, "?") end
      text = ("INSERT INTO %s (%s) VALUES (%s);"):format(qual_table, table.concat(quoted, ", "), table.concat(placeholders, ", "))
    end
  end

  if text and text ~= "" then
    dbg(("generated query:\n%s"):format(text))
    self:insert_query(text)
  end
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
        local src_key = "source:" .. active_conn.source_id
        if self.expanded[src_key] == nil then
          self.expanded[src_key] = true
        end
      end
      local conn_key = "connection:" .. active_conn.id
      if self.expanded[conn_key] == nil then
        self.expanded[conn_key] = true
      end
      local ok_db, current_db, databases = pcall(self.handler.connection_list_databases, self.handler, active_conn.id)
      if ok_db and current_db and current_db ~= "" then
        local db_key = ("database:%s:%s"):format(active_conn.id, current_db)
        if self.expanded[db_key] == nil then
          self.expanded[db_key] = true
        end
      end
    end

    local ignored_by_connection = {}
    local database_meta = {}
    local project_for_meta = self:current_project()
    local function get_database_meta(conn)
      if database_meta[conn.id] then
        return database_meta[conn.id]
      end

      local meta = {
        ok = false,
        current = nil,
        databases = {},
        visible = {},
        ignored = {},
        connection_ignored = false,
      }

      -- Connection-level ignore takes precedence
      local project = self:current_project()
      if util.is_project_connection_ignored(project, conn.id) then
        meta.connection_ignored = true
        database_meta[conn.id] = meta
        ignored_by_connection[conn.id] = {
          conn = conn,
          current_db = nil,
          databases = {},
          connection_ignored = true,
        }
        return meta
      end

      local ok_dbs, current_db, databases = pcall(self.handler.connection_list_databases, self.handler, conn.id)
      meta.ok = ok_dbs
      meta.current = current_db
      meta.databases = databases or {}

      if ok_dbs and #(databases or {}) > 0 then
        for _, database in ipairs(databases or {}) do
          if self:is_database_ignored(conn.id, database) then
            table.insert(meta.ignored, database)
          else
            table.insert(meta.visible, database)
          end
        end
      end

      local ignored = #meta.ignored > 0 and meta.ignored or util.project_ignored_databases(self:current_project(), conn.id)
      if #ignored > 0 then
        ignored_by_connection[conn.id] = {
          conn = conn,
          current_db = current_db,
          databases = ignored,
        }
      end
      database_meta[conn.id] = meta
      return meta
    end

    for _, source in ipairs(self.handler:get_sources()) do
      local source_key = "source:" .. source:name()
      local source_connections = self.handler:source_get_connections(source:name())
      for _, conn in ipairs(source_connections) do
        local ignored = util.project_ignored_databases(self:current_project(), conn.id)
        if #ignored > 0 then
          ignored_by_connection[conn.id] = {
            conn = conn,
            current_db = nil,
            databases = ignored,
          }
        end
      end

      -- Only show the source if it has connections or supports create/edit actions
      local show_source = (#source_connections > 0) or type(source.create) == "function" or type(source.file) == "function"
      if show_source then
        local source_active = active_conn and active_conn.source_id == source:name()
        self:add_line(lines, 1, source:name(), {
          kind = "source",
          key = source_key,
          source_id = source:name(),
        }, { expandable = true, active = source_active })
        if self:is_expanded(source_key) then
          for _, conn in ipairs(source_connections) do
            local active = self.handler:get_current_connection()
            local is_active = active and active.id == conn.id
            local db_meta = get_database_meta(conn)
            local has_databases = db_meta.ok and #db_meta.databases > 0
            local conn_key = "connection:" .. conn.id

            -- If the whole connection is ignored for the current project, don't show it in the main Connections list
            if not db_meta.connection_ignored then
              self:add_line(lines, 2, conn.name, {
                kind = "connection",
                key = conn_key,
                connection_id = conn.id,
                source_id = source:name(),
              }, { expandable = true, active = is_active })
              if self:is_expanded(conn_key) then
                if has_databases then
                  for _, database in ipairs(db_meta.visible) do
                    self:add_database_line(lines, 3, conn, database, db_meta.current, false)
                  end
                else
                  local ok_structure, structure = pcall(self.handler.connection_get_structure, self.handler, conn.id)
                  if ok_structure then
                    self:render_structure_items(lines, 3, conn, structure)
                  end
                end
              end
            end
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

    if next(ignored_by_connection) ~= nil then
      local ignore_key = "ignored_databases"
      self:add_line(lines, 1, "ignore", {
        kind = "ignored_databases_group",
        key = ignore_key,
      }, { expandable = true, ignored = true })
      if self:is_expanded(ignore_key) then
        local conn_ids = vim.tbl_keys(ignored_by_connection)
        table.sort(conn_ids, function(left, right)
          return ignored_by_connection[left].conn.name < ignored_by_connection[right].conn.name
        end)
        for _, conn_id in ipairs(conn_ids) do
          local entry = ignored_by_connection[conn_id]
          local conn_key = "ignored_connection:" .. conn_id
          self:add_line(lines, 2, entry.conn.name, {
            kind = "ignored_connection_group",
            key = conn_key,
            connection_id = conn_id,
          }, { expandable = true, ignored = true })
          if self:is_expanded(conn_key) then
            -- If connection-level ignore is set, show its databases under the ignore group
            if entry.connection_ignored then
              -- Try database listing first
              local ok_db, current_db, databases = pcall(self.handler.connection_list_databases, self.handler, entry.conn.id)
              if ok_db and databases and #databases > 0 then
                for _, database in ipairs(databases) do
                  self:add_database_line(lines, 3, entry.conn, database, current_db, true)
                end
              else
                -- If no databases returned, try rendering structure (tables) like the main connection view
                local ok_structure, structure = pcall(self.handler.connection_get_structure, self.handler, entry.conn.id)
                if ok_structure and structure and #structure > 0 then
                  self:render_structure_items(lines, 3, entry.conn, structure)
                else
                  -- Fallback marker only when nothing else can be displayed
                  self:add_line(lines, 3, "(entire connection ignored)", {
                    kind = "ignored_connection_marker",
                    key = "ignored_marker:" .. conn_id,
                    connection_id = conn.id,
                  }, { ignored = true })
                end
              end
            else
              for _, database in ipairs(entry.databases) do
                self:add_database_line(lines, 3, entry.conn, database, entry.current_db, true)
              end
            end
          end
        end
      end
    end
  end

  table.insert(lines, buffer_line.new_builder())
  self:add_line(lines, 0, "Scratchpads", {
    kind = "root",
    key = "root:scratchpads",
  }, { expandable = true })
  if self:is_expanded("root:scratchpads") then
    local all_namespaces = self.editor:get_namespaces()
    local current_note = self.editor:get_current_note()
    local active_namespace = nil
    local current_project = self:current_project()
    if current_project then
      active_namespace = self.editor:resolve_active_namespace(current_project)
    elseif current_note then
      active_namespace = current_note.namespace
    else
      active_namespace = self.last_active_namespace
    end
    local active_project_name = active_namespace and vim.split(active_namespace, "/")[1] or nil

    -- Auto-expand current project path (use full namespace if available)
    if active_namespace then
      local parts = vim.split(active_namespace, "/")
      for i=1,#parts do
        local ns_key = "scratchpad_ns:" .. table.concat(parts, "/", 1, i)
        if self.expanded[ns_key] == nil then
          self.expanded[ns_key] = true
        end
      end
    end

    -- Store active namespace so add_line can make contextual coloring decisions
    self._active_namespace = active_namespace

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
            }, { active = current_note and current_note.id == note.id, is_active_project = is_active, namespace = data.full_path })
          end
        end
      end
    end
    render_tree(tree, 1)

  end

  if not self.config.disable_help then
    table.insert(lines, buffer_line.new_builder())
    self:add_line(lines, 0, "Help", {
      kind = "help",
      key = "root:help",
    }, { expandable = true })
    if self:is_expanded("root:help") then
      self:add_line(lines, 1, "<CR>: open/select. On table/column opens SQL template menu; visual column selection supported", { kind = "help", key = "help:1" })
      self:add_line(lines, 1, "o: toggle node (expand/collapse)", { kind = "help", key = "help:2" })
      self:add_line(lines, 1, "cw: edit connection / rename scratchpad", { kind = "help", key = "help:3" })
      self:add_line(lines, 1, "dd: delete connection or scratchpad", { kind = "help", key = "help:4" })
      self:add_line(lines, 1, "i: ignore/unignore database or connection for current project", { kind = "help", key = "help:5" })
      self:add_line(lines, 1, "a: add connection (context-aware)", { kind = "help", key = "help:6" })
      self:add_line(lines, 1, "f: toggle project-only scratchpad filter", { kind = "help", key = "help:7" })
      self:add_line(lines, 1, "r: refresh", { kind = "help", key = "help:8" })
    end
  end

  buffer_line.render(self.bufnr, self.ns, lines)

  -- Move cursor to the active namespace so the drawer follows the current project/branch.
  if self.window and vim.api.nvim_win_is_valid(self.window) and active_namespace then
    for i = 1, #lines do
      local node = self.line_map[i]
      if node and node.kind == "scratchpad_dir" and node.namespace == active_namespace then
        pcall(vim.api.nvim_win_set_cursor, self.window, { i, 0 })

        if active_namespace ~= self.last_active_namespace then
          self.last_active_namespace = active_namespace
          if self.editor then
            local notes = self.editor:namespace_get_notes(active_namespace)
            if notes and #notes > 0 then
              local cur = self.editor:get_current_note()
              if not cur or cur.namespace ~= active_namespace then
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
    -- Prefer toggling the node itself when it's an expandable kind (table, database, connection, source, etc.)
    local expandable_kinds = {
      root = true,
      source = true,
      connection = true,
      database = true,
      table = true,
      scratchpad_dir = true,
      ignored_databases_group = true,
      ignored_connection_group = true,
      help = true,
    }

    if node.kind and expandable_kinds[node.kind] and node.key then
      self:toggle_node(node.key)
      self:refresh()
      return
    end

    -- If on a column, toggle its parent table so 'o' opens the table columns
    if node.kind == "column" and node.connection_id and node.table then
      local table_key = ("table:%s:%s:%s"):format(node.connection_id, node.schema or "", node.table)
      self:toggle_node(table_key)
      self:refresh()
      return
    end

    -- If on a scratchpad file, toggle its parent namespace/directory
    if node.kind == "scratchpad" and node.namespace then
      local ns_key = "scratchpad_ns:" .. node.namespace
      self:toggle_node(ns_key)
      self:refresh()
      return
    end

    -- As a last resort, toggle the connection group if present
    if node.connection_id then
      self:toggle_node("connection:" .. node.connection_id)
      self:refresh()
      return
    end

    return
  end

  if action == "action_toggle_filter" then
    self.config.project_filter_only_current = not self.config.project_filter_only_current
    self:refresh()
    return
  end

  if action == "action_add" then
    -- Detect whether the cursor is inside the Connections subtree.
    local key = node.key or ""
    local in_connections = key:match("^root:connections") or key:match("^source:") or key:match("^connection:") or key:match("^edit:") or key:match("^add:") or key:match("^ignored_") or node.kind == "ignored_databases_group" or node.kind == "ignored_connection_group"

    if in_connections then
      -- If on a connection or child under it, add to that connection's source
      if node.connection_id then
        local source_id = node.source_id
        if not source_id then
          local ok, conn = pcall(self.handler.connection_get_params, self.handler, node.connection_id)
          if ok and conn and conn.source_id then
            source_id = conn.source_id
          end
        end
        if source_id then
          self:connection_prompt({}, function(details)
            local ok, err = pcall(self.handler.source_add_connection, self.handler, source_id, details)
            if not ok then util.notify(err, vim.log.levels.ERROR) end
            self.expanded["source:" .. source_id] = true
            self:refresh()
          end)
        else
          util.notify("Cannot determine source for this connection.", vim.log.levels.WARN)
        end
        return
      end

      -- If node directly references a source (edit_source, source header), add to that source
      if node.source_id then
        self:connection_prompt({}, function(details)
          local ok, err = pcall(self.handler.source_add_connection, self.handler, node.source_id, details)
          if not ok then util.notify(err, vim.log.levels.ERROR) end
          self.expanded["source:" .. node.source_id] = true
          self:refresh()
        end)
        return
      end

      -- Otherwise (e.g. root:connections or ignored group), ask the user which source to add to
      self:prompt_add_connection()
      return
    end

    -- Not in Connections subtree: fallback to creating a new scratchpad
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
      self:open_query_action_menu(node)
    elseif node.kind == "database" then
      self.handler:set_current_connection(node.connection_id)
      self.handler:connection_select_database(node.connection_id, node.database)
      self:toggle_node(node.key)
      self:refresh()
    elseif node.kind == "ignored_databases_group" or node.kind == "ignored_connection_group" then
      self:toggle_node(node.key)
      self:refresh()
    elseif node.kind == "root" or node.kind == "source" or node.kind == "connection" then
      if node.kind == "connection" then
        self.handler:set_current_connection(node.connection_id)
      end
      self:toggle_node(node.key)
      self:refresh()
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

  if action == "action_ignore" then
    -- If invoked on a connection, present a list of databases for that connection
    if node.kind == "connection" then
      local project = self:current_project()
      if not project then
        util.notify("Open a project SQL scratchpad before ignoring connections.", vim.log.levels.WARN)
        return
      end

      local conn_id = node.connection_id
      local currently_ignored = util.is_project_connection_ignored(project, conn_id)
      local ok, err = pcall(util.set_project_connection_ignored, project, conn_id, not currently_ignored)
      if not ok then
        util.notify(err, vim.log.levels.ERROR)
        return
      end
      if not currently_ignored then
        util.notify(("Ignored connection for project: %s"):format(node.connection_id))
      else
        util.notify(("Restored connection for project: %s"):format(node.connection_id))
      end
      self:refresh()
      return
    end

    if node.kind == "ignored_connection_group" then
      local project = self:current_project()
      if not project then
        util.notify("Open a project SQL scratchpad before restoring ignored databases.", vim.log.levels.WARN)
        return
      end
      local conn_id = node.connection_id

      local restored = 0
      local last_err = nil

      -- Unignore connection-level marker if present
      if util.is_project_connection_ignored(project, conn_id) then
        local okc, errc = pcall(util.set_project_connection_ignored, project, conn_id, false)
        if not okc then last_err = errc else restored = restored + 1 end
      end

      -- Unignore per-database ignores as well
      local dbs = util.project_ignored_databases(project, conn_id)
      for _, db in ipairs(dbs) do
        local ok, err = pcall(util.set_project_database_ignored, project, conn_id, db, false)
        if not ok then last_err = err else restored = restored + 1 end
      end

      if last_err then util.notify(last_err, vim.log.levels.ERROR) end
      if restored == 0 then
        util.notify("No ignored databases or connections for this connection.", vim.log.levels.INFO)
      else
        util.notify(("Restored %d ignored items for connection: %s"):format(restored, conn_id))
      end
      self:refresh()
    elseif node.kind == "ignored_databases_group" then
      local project = self:current_project()
      if not project then
        util.notify("Open a project SQL scratchpad before restoring ignored databases.", vim.log.levels.WARN)
        return
      end
      local ignores = util.read_project_db_ignores()
      local proj_key = util.project_key(project)
      if not proj_key or not ignores[proj_key] then
        util.notify("No ignored databases for this project.", vim.log.levels.INFO)
        return
      end
      local count = 0
      local last_err = nil
      for conn_id, dbs in pairs(ignores[proj_key]) do
        for db, _ in pairs(dbs) do
          local ok, err = pcall(util.set_project_database_ignored, project, conn_id, db, false)
          if ok then count = count + 1 else last_err = err end
        end
      end
      if last_err then util.notify(last_err, vim.log.levels.ERROR) end
      util.notify(("Restored %d ignored databases for project"):format(count))
      self:refresh()
    elseif node.kind == "database" then
      local project = self:current_project()
      if not project then
        util.notify("Open a project SQL scratchpad before ignoring databases.", vim.log.levels.WARN)
        return
      end
      local ignored = not node.ignored
      local ok, err = pcall(util.set_project_database_ignored, project, node.connection_id, node.database, ignored)
      if not ok then
        util.notify(err, vim.log.levels.ERROR)
        return
      end
      if ignored then
        self.expanded["ignored_databases"] = true
        self.expanded["ignored_connection:" .. node.connection_id] = true
        util.notify(("Ignored database for project: %s"):format(node.database))
      else
        util.notify(("Restored database for project: %s"):format(node.database))
      end
      self:refresh()
    end
  end
end

return DrawerUI
