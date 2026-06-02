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
