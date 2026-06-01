local CallLogUI = require("connector.ui.call_log")
local DrawerUI = require("connector.ui.drawer")
local EditorUI = require("connector.ui.editor")
local Handler = require("connector.handler")
local ResultUI = require("connector.ui.result")
local window = require("connector.ui.window")
local util = require("connector.util")

local M = {}
local m = {
  setup_called = false,
  core_loaded = false,
  ui_loaded = false,
  config = nil,
  current_project = nil,
  current_sql_bufnr = nil,
}

local function is_sql_context_buffer(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name ~= "" and util.is_scratchpad_path(name) then
    return true
  end
  if name:match("%.sql$") then
    return true
  end
  return vim.bo[bufnr].filetype == "sql"
end

local function set_project_from_buf(bufnr)
  if not is_sql_context_buffer(bufnr) then
    return nil
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  local project = util.resolve_project(name)
  if project then
    m.current_project = project
    m.current_sql_bufnr = bufnr
  end
  return project
end

local function setup_core()
  if m.core_loaded then
    return
  end
  if not m.setup_called then
    error("setup() has not been called yet")
  end
  m.handler = Handler:new(m.config)
  m.handler:set_project_provider(function()
    return m.current_project or set_project_from_buf(vim.api.nvim_get_current_buf())
  end)
  m.core_loaded = true
end

local function setup_ui()
  if m.ui_loaded then
    return
  end
  setup_core()

  -- Seed from the SQL buffer that opened connector. Non-SQL connector buffers must not change project context.
  m.current_project = m.current_project or set_project_from_buf(vim.api.nvim_get_current_buf())

  m.result = ResultUI:new(m.handler, m.config.result)

  -- Ensure connector-result windows use horizontal scrolling and same highlights
  vim.api.nvim_create_autocmd("FileType", {
    pattern = "connector-result",
    callback = function()
      window.configure_result_window(vim.api.nvim_get_current_win())
    end,
  })

  m.call_log = CallLogUI:new(m.handler, m.result, m.config.call_log)
  m.editor = EditorUI:new(m.handler, m.result, m.config.editor, {
    get_current_project = function() return m.current_project end,
    set_current_project = function(project, bufnr)
      if project then
        m.current_project = project
        m.current_sql_bufnr = bufnr
      end
    end,
  })
  m.drawer = DrawerUI:new(m.handler, m.editor, m.result, m.config.drawer, {
    get_current_project = function() return m.current_project end
  })

  m.editor:register_event_listener("current_note_changed", function(note)
    if note and note.bufnr then
      set_project_from_buf(note.bufnr)
    end
  end)

  vim.api.nvim_create_autocmd("BufEnter", {
    group = vim.api.nvim_create_augroup("connector-project-refresh", { clear = true }),
    callback = function()
      set_project_from_buf(vim.api.nvim_get_current_buf())
      if m.drawer and m.drawer.window and vim.api.nvim_win_is_valid(m.drawer.window) then
        m.drawer:refresh()
      end
    end,
  })

  m.ui_loaded = true
end

function M.setup(config)
  if m.setup_called then
    error("setup() can only be called once")
  end
  m.config = config
  m.setup_called = true
end

function M.config()
  return m.config
end

function M.is_core_loaded()
  return m.core_loaded
end

function M.is_ui_loaded()
  return m.ui_loaded
end

function M.handler()
  setup_core()
  return m.handler
end

function M.result()
  setup_ui()
  return m.result
end

function M.call_log()
  setup_ui()
  return m.call_log
end

function M.editor()
  setup_ui()
  return m.editor
end

function M.drawer()
  setup_ui()
  return m.drawer
end


function M.current_project()
  return m.current_project or set_project_from_buf(vim.api.nvim_get_current_buf())
end
function M.set_current_project(project, bufnr)
  m.current_project = project
  m.current_sql_bufnr = bufnr
end

return M
