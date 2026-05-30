local CallLogUI = require("connector.ui.call_log")
local DrawerUI = require("connector.ui.drawer")
local EditorUI = require("connector.ui.editor")
local Handler = require("connector.handler")
local ResultUI = require("connector.ui.result")
local util = require("connector.util")

local M = {}
local m = {
  setup_called = false,
  core_loaded = false,
  ui_loaded = false,
  config = nil,
  current_project = nil,
}

local function setup_core()
  if m.core_loaded then
    return
  end
  if not m.setup_called then
    error("setup() has not been called yet")
  end
  m.handler = Handler:new(m.config)
  m.core_loaded = true
end

local function setup_ui()
  if m.ui_loaded then
    return
  end
  setup_core()

  -- Seed current project from current buffer immediately so initial UI render picks the right project
  m.current_project = m.current_project or util.resolve_project()

  m.result = ResultUI:new(m.handler, m.config.result)
  m.call_log = CallLogUI:new(m.handler, m.result, m.config.call_log)
  m.editor = EditorUI:new(m.handler, m.result, m.config.editor, {
    get_current_project = function() return m.current_project end
  })
  m.drawer = DrawerUI:new(m.handler, m.editor, m.result, m.config.drawer, {
    get_current_project = function() return m.current_project end
  })

  vim.api.nvim_create_autocmd("BufEnter", {
    group = vim.api.nvim_create_augroup("connector-project-refresh", { clear = true }),
    callback = function()
      local util = require("connector.util")
      local project = util.resolve_project()
      if project then
        -- If we are in a scratchpad of the same project, keep the one with root info
        if project.is_scratchpad and m.current_project and m.current_project.name == project.name then
          -- Keep existing m.current_project
        else
          m.current_project = project
        end
      end
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
  return m.current_project
end
function M.set_current_project(project)
  m.current_project = project
end

return M
