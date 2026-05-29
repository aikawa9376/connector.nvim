local util = require("connector.util")

local EditorUI = {}

function EditorUI:new(handler, result, config)
  local o = {
    handler = handler,
    result = result,
    config = config,
    listeners = {},
    namespaces = {},
    note_order = {},
    current_note_id = nil,
    window = nil,
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
  return bufnr
end

function EditorUI:load_notes()
  local paths = vim.fn.globpath(self.config.directory, "**/*.sql", false, true)
  table.sort(paths)
  for _, file in ipairs(paths) do
    local namespace = vim.fs.basename(vim.fs.dirname(file))
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
  return note_id
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
  if self.current_note_id then
    return
  end
  self:namespace_create_note("global", "scratchpad")
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

function EditorUI:do_action(action)
  self:ensure_default_note()
  local note = assert(self:search_note(self.current_note_id))
  local bufnr = note.bufnr

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
  end
end

return EditorUI

