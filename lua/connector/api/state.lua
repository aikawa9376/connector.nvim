local CallLogUI = require("connector.ui.call_log")
local DrawerUI = require("connector.ui.drawer")
local EditorUI = require("connector.ui.editor")
local Handler = require("connector.handler")
local ResultUI = require("connector.ui.result")

local M = {}
local m = {
  setup_called = false,
  core_loaded = false,
  ui_loaded = false,
  config = nil,
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
  m.result = ResultUI:new(m.handler, m.config.result)
  m.call_log = CallLogUI:new(m.handler, m.result, m.config.call_log)
  m.editor = EditorUI:new(m.handler, m.result, m.config.editor)
  m.drawer = DrawerUI:new(m.handler, m.editor, m.result, m.config.drawer)
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

return M
