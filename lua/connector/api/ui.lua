local ddl = require("connector.ddl")
local history_module = require("connector.history")
local state = require("connector.api.state")
local util = require("connector.util")

local ui = {}

local function ensure_layout_open()
  local cfg = state.config()
  if cfg and cfg.window_layout and not cfg.window_layout:is_open() then
    cfg.window_layout:open()
  end
end

local function scratchpad_only_current(opts)
  opts = opts or {}
  if opts.current_project_only ~= nil then
    return opts.current_project_only
  end
  local cfg = state.config()
  return cfg and cfg.drawer and cfg.drawer.project_filter_only_current or false
end

local function scratchpad_project_name()
  local editor = state.editor()
  local project = nil
  pcall(function()
    project = state.drawer():current_project()
  end)
  if not project then
    pcall(function()
      project = editor:current_project()
    end)
  end
  local ns = editor:resolve_active_namespace(project)
  return ns and ns:match("^([^/]+)") or nil
end

local function open_scratchpad_entry(entry)
  if not entry or not entry.id then
    return
  end

  ensure_layout_open()
  state.editor():set_current_note(entry.id)
end

local function build_scratchpad_entries(opts)
  opts = opts or {}
  local editor = state.editor()
  local root = editor.config.directory
  local only_current = scratchpad_only_current(opts)
  local active_project = only_current and scratchpad_project_name() or nil
  if only_current and not active_project then
    only_current = false
  end

  local entries = {}
  for _, ns in ipairs(editor:get_namespaces()) do
    local project_name = ns:match("^([^/]+)")
    if (not only_current) or project_name == "global" or (active_project and project_name == active_project) then
      for _, note in ipairs(editor:namespace_get_notes(ns)) do
        table.insert(entries, {
          id = note.id,
          name = note.name,
          namespace = note.namespace,
          file = note.file,
          path = vim.startswith(note.file, root .. "/") and note.file:sub(#root + 2) or note.file,
          display = vim.startswith(note.file, root .. "/") and note.file:sub(#root + 2) or note.file,
        })
      end
    end
  end

  table.sort(entries, function(a, b)
    return a.path < b.path
  end)

  return entries
end

local function scratchpad_picker_winopts()
  return {
    split = false,
    border = "single",
    height = 0.6,
    width = 0.8,
    row = 0.5,
    preview = {
      border = "single",
      hidden = false,
    },
  }
end

local function history_picker_winopts()
  return scratchpad_picker_winopts()
end

local function parse_history_call_picker_entry(item, calls_by_id)
  if not item or item == "" then
    return nil
  end

  local parts = vim.split(item, "\t", { plain = true })
  local id = parts[2]
  if not id or id == "" then
    return nil
  end

  return calls_by_id[id]
end

local function build_history_call_preview(call)
  if not call then
    return ""
  end

  local handler = state.handler()
  local conn = call.connection_id and handler.connections and handler.connections[call.connection_id] or nil
  local lines = {}

  table.insert(lines, ("-- state: %s"):format(call.state or "unknown"))
  if conn then
    table.insert(lines, ("-- connection: %s"):format(conn.name or conn.id))
  elseif call.connection_id then
    table.insert(lines, ("-- connection: %s"):format(call.connection_id))
  end
  if call.project and call.project ~= "" then
    local scope = call.branch and call.branch ~= "" and ("%s/%s"):format(call.project, call.branch) or call.project
    table.insert(lines, ("-- scope: %s"):format(scope))
  end
  if call.completed_at and call.completed_at ~= "" then
    table.insert(lines, ("-- completed: %s"):format(call.completed_at))
  elseif call.started_at and call.started_at ~= "" then
    table.insert(lines, ("-- started: %s"):format(call.started_at))
  end
  table.insert(lines, "")
  vim.list_extend(lines, vim.split(call.query or "", "\n", { plain = true }))

  return table.concat(lines, "\n")
end

local function history_call_picker_previewer_spec(calls_by_id)
  local builtin = require("fzf-lua.previewer.builtin")
  local Previewer = builtin.base:extend()

  function Previewer:new(o, resolved_opts)
    Previewer.super.new(self, o, resolved_opts)
  end

  function Previewer:gen_winopts()
    return vim.tbl_extend("keep", {
      wrap = false,
      cursorline = false,
      number = false,
    }, self.winopts)
  end

  function Previewer:populate_preview_buf(entry_str)
    if not self.win or not self.win:validate_preview() then
      return
    end

    local call = parse_history_call_picker_entry(entry_str, calls_by_id)
    local text = build_history_call_preview(call)
    local tmpbuf = self:get_tmp_buffer()
    vim.api.nvim_buf_set_lines(tmpbuf, 0, -1, false, vim.split(text, "\n", { plain = true }))
    vim.bo[tmpbuf].filetype = "sql"
    self:set_preview_buf(tmpbuf)
    if call then
      self.win:update_preview_title((" %s "):format(call.state or "history"))
    end
    self.win:update_preview_scrollbar()
  end

  return {
    _ctor = function()
      return Previewer
    end,
  }
end

local function open_history_call(call)
  if not call or not call.id then
    return
  end

  ensure_layout_open()
  local handler = state.handler()
  local fresh = handler:get_call(call.id) or call
  if fresh and fresh.state == "history" then
    handler:call_reexecute(fresh.id, function(new_call)
      if new_call then
        state.result():set_call(new_call)
      end
    end)
  elseif fresh and (fresh.state == "archived" or fresh.state == "executing") then
    state.result():set_call(fresh)
  end
end

local function format_history_call_label(call, handler)
  return history_module.format_entry({
    project = call.project,
    branch = call.branch,
    connection_name = (handler.connections[call.connection_id] or {}).name,
    executed_at = call.completed_at or call.started_at,
    query = call.query,
    query_preview = (call.query or ""):gsub("%s+", " "),
  })
end

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
  local call_log = state.call_log()
  if call_log then
    call_log:refresh()
  end
end

function ui.call_log_show(winid)
  local call_log = state.call_log()
  if call_log then
    call_log:show(winid)
  end
end

function ui.call_log_do_action(action)
  local call_log = state.call_log()
  if call_log then
    call_log:do_action(action)
  end
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

function ui.pick_history_calls(opts)
  opts = opts or {}

  local handler = state.handler()
  local calls = opts.calls or require("connector.ui.call_history").visible_calls(handler)
  if #calls == 0 then
    util.notify("No history entries found", vim.log.levels.INFO)
    return
  end

  local calls_by_id = {}
  for _, call in ipairs(calls) do
    calls_by_id[call.id] = call
  end

  local ok_fzf, fzf = pcall(require, "fzf-lua")
  if ok_fzf and fzf and type(fzf.fzf_exec) == "function" then
    local lines = vim.tbl_map(function(call)
      return table.concat({
        format_history_call_label(call, handler),
        call.id or "",
      }, "\t")
    end, calls)

    fzf.fzf_exec(lines, {
      prompt = "History> ",
      previewer = history_call_picker_previewer_spec(calls_by_id),
      winopts = history_picker_winopts(),
      fzf_opts = {
        ["--delimiter"] = "\t",
        ["--with-nth"] = "1",
        ["--nth"] = "1",
        ["--header"] = "enter: show result",
      },
      actions = {
        ["default"] = function(selected)
          local item = selected and selected[1] or nil
          local call = parse_history_call_picker_entry(item, calls_by_id)
          open_history_call(call)
        end,
      },
    })
    return
  end

  vim.ui.select(calls, {
    prompt = "Select history entry",
    format_item = function(call)
      return format_history_call_label(call, handler)
    end,
  }, function(choice, idx)
    open_history_call(choice or (idx and calls[idx] or nil))
  end)
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

local function table_picker_winopts()
  return scratchpad_picker_winopts()
end

local function parse_table_picker_entry(item)
  if not item or item == "" then
    return nil
  end

  local parts = vim.split(item, "\t", { plain = true })
  local conn_id = parts[3]
  local schema = parts[4] ~= "" and parts[4] or nil
  local tbl = parts[5]
  local materialization = parts[6] ~= "" and parts[6] or nil

  if not conn_id or conn_id == "" or not tbl or tbl == "" then
    return nil
  end

  return {
    connection_id = conn_id,
    schema = schema,
    table = tbl,
    materialization = materialization,
  }
end

local function build_table_preview(handler, preview_cache, item)
  local entry = parse_table_picker_entry(item)
  if not entry then
    return item or ""
  end

  local cache_key = table.concat({
    entry.connection_id,
    entry.schema or "",
    entry.table,
    entry.materialization or "",
  }, "\0")
  if preview_cache[cache_key] then
    return preview_cache[cache_key], entry
  end

  local ok_conn, conn = pcall(handler.connection_get_params, handler, entry.connection_id)
  if not ok_conn then
    local msg = "-- Failed to load connection params\n" .. tostring(conn)
    preview_cache[cache_key] = msg
    return msg, entry
  end

  local ok_cols, columns_or_err = pcall(handler.connection_get_columns, handler, entry.connection_id, {
    table = entry.table,
    schema = entry.schema,
    materialization = entry.materialization,
  })

  local text
  if ok_cols then
    text = ddl.render_table_definition(conn, entry, columns_or_err)
  else
    text = table.concat({
      ("-- %s"):format(ddl.format_schema_table(entry.schema, entry.table)),
      "",
      "-- Failed to load columns:",
      tostring(columns_or_err),
    }, "\n")
  end

  preview_cache[cache_key] = text
  return text, entry
end

local function table_picker_previewer_spec(handler, preview_cache)
  local builtin = require("fzf-lua.previewer.builtin")
  local Previewer = builtin.base:extend()

  function Previewer:new(o, resolved_opts)
    Previewer.super.new(self, o, resolved_opts)
  end

  function Previewer:gen_winopts()
    local winopts = {
      wrap = false,
      cursorline = false,
      number = false,
    }
    return vim.tbl_extend("keep", winopts, self.winopts)
  end

  function Previewer:populate_preview_buf(entry_str)
    if not self.win or not self.win:validate_preview() then
      return
    end

    local text, entry = build_table_preview(handler, preview_cache, entry_str)
    local tmpbuf = self:get_tmp_buffer()
    vim.api.nvim_buf_set_lines(tmpbuf, 0, -1, false, vim.split(text, "\n", { plain = true }))
    vim.bo[tmpbuf].filetype = "sql"
    self:set_preview_buf(tmpbuf)
    if entry then
      self.win:update_preview_title((" %s "):format(ddl.format_schema_table(entry.schema, entry.table)))
    end
    self.win:update_preview_scrollbar()
  end

  return {
    _ctor = function()
      return Previewer
    end,
  }
end

-- Prompt to pick a table (DB.table) and focus it in the drawer.
-- Uses fzf-lua with a table-definition preview when available.
function ui.drawer_pick_table(opts)
  opts = opts or {}

  -- Ensure core/ui loaded and layout opened
  ensure_layout_open()

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
          materialization = item.materialization,
        })
      end
    end
  end

  if #entries == 0 then
    util.notify("No tables found", vim.log.levels.INFO)
    return
  end

  local ok_fzf, fzf = pcall(require, "fzf-lua")
  if ok_fzf and fzf and type(fzf.fzf_exec) == "function" then
    local preview_cache = {}

    local lines = vim.tbl_map(function(entry)
      local conn = handler.connections and handler.connections[entry.connection_id] or nil
      local conn_name = (conn and conn.name) or entry.connection_id
      local schema_table = ddl.format_schema_table(entry.schema, entry.table)
      -- fields: display, conn_name, conn_id, schema, table, materialization
      return table.concat({
        schema_table,
        conn_name,
        entry.connection_id,
        entry.schema or "",
        entry.table or "",
        entry.materialization or "",
      }, "\t")
    end, entries)

    fzf.fzf_exec(lines, {
      prompt = "Tables> ",
      previewer = table_picker_previewer_spec(handler, preview_cache),
      winopts = table_picker_winopts(),
      fzf_opts = {
        ["--delimiter"] = "\t",
        ["--with-nth"] = "1",
        ["--nth"] = "1,2",
        ["--header"] = "enter: jump  ctrl-r: refresh",
      },
      actions = {
        ["default"] = function(selected)
          local item = selected and selected[1] or nil
          local entry = parse_table_picker_entry(item)
          if not entry then
            return
          end

          pcall(function()
            handler:apply_table_context(nil, entry, { notify = false })
          end)

          drawer:reveal_table(entry, {
            focus_window = true,
            fallback_top = true,
          })
        end,
        ["ctrl-r"] = function()
          ui.drawer_pick_table(opts)
        end,
      },
    })

    return
  end

  -- Fallback: built-in vim.ui.select
  local labels = vim.tbl_map(function(entry)
    return handler:format_table_entry_label(entry)
  end, entries)

  vim.ui.select(labels, { prompt = "Jump to table" }, function(_choice, idx)
    if not idx then return end
    local entry = entries[idx]
    if not entry then return end

    pcall(function()
      handler:apply_table_context(nil, entry, { notify = false })
    end)

    drawer:reveal_table(entry, {
      focus_window = true,
      fallback_top = true,
    })
  end)
end

function ui.editor_scratchpads(opts)
  return build_scratchpad_entries(opts)
end

function ui.editor_pick_scratchpad(opts)
  opts = opts or {}

  local entries = build_scratchpad_entries(opts)
  if #entries == 0 then
    util.notify("No scratchpads found", vim.log.levels.INFO)
    return
  end

  local ok_fzf, fzf = pcall(require, "fzf-lua")
  if ok_fzf and fzf and type(fzf.fzf_exec) == "function" then
    local editor = state.editor()
    fzf.fzf_exec(vim.tbl_map(function(entry)
      return entry.path
    end, entries), {
      prompt = "Scratchpads> ",
      cwd = editor.config.directory,
      previewer = "builtin",
      winopts = scratchpad_picker_winopts(),
      fzf_opts = {
        ["--header"] = "ctrl-g: grep scratchpads",
      },
      actions = {
        ["default"] = function(selected, picker_opts)
          local item = selected and selected[1] or nil
          if not item then
            return
          end

          local ok_path, parsed = pcall(require("fzf-lua.path").entry_to_file, item, picker_opts)
          local path = ok_path and parsed and parsed.path or item
          if path and path ~= "" and not vim.startswith(path, "/") then
            path = vim.fs.joinpath((picker_opts and picker_opts.cwd) or editor.config.directory, path)
          end

          local entry = path and state.editor():search_note_with_file(path) or nil
          if entry then
            open_scratchpad_entry(entry)
          end
        end,
        ["ctrl-g"] = function()
          ui.editor_grep_scratchpads(opts)
        end,
      },
    })
    return
  end

  vim.ui.select(entries, {
    prompt = "Select scratchpad",
    format_item = function(entry)
      return entry.display
    end,
  }, function(choice, idx)
    open_scratchpad_entry(choice or (idx and entries[idx] or nil))
  end)
end

function ui.editor_grep_scratchpads(opts)
  opts = opts or {}

  local ok_fzf, fzf = pcall(require, "fzf-lua")
  if not ok_fzf or not fzf or type(fzf.grep) ~= "function" then
    util.notify("scratchgrep requires fzf-lua", vim.log.levels.ERROR)
    return
  end

  local cfg = state.config() or {}
  local root = (cfg.editor and cfg.editor.directory) or vim.fs.joinpath(vim.fn.stdpath("state"), "connector", "scratchpads")

  local only_current = scratchpad_only_current(opts)
  local project_name = only_current and scratchpad_project_name() or nil

  local rg_opts = "--column --line-number --no-heading --color=always --smart-case --hidden --glob=*.sql"
  if only_current and project_name and project_name ~= "" then
    rg_opts = rg_opts .. " --glob=global/**"
    if project_name ~= "global" then
      rg_opts = rg_opts .. (" --glob=%s/**"):format(project_name)
    end
  end

  local grep_opts = {
    cwd = root,
    prompt = "Scratchpad Grep> ",
    previewer = "builtin",
    rg_opts = rg_opts,
    winopts = scratchpad_picker_winopts(),
    fzf_opts = {
      ["--delimiter"] = ":",
      ["--nth"] = "-1,1..-2",
    },
  }
  if opts.search and opts.search ~= "" then
    grep_opts.search = opts.search
  end

  fzf.grep(grep_opts)
end

return ui
