local api_ui = require("connector.api.ui")

local layouts = {}

layouts.Default = {}

function layouts.Default:new(opts)
  opts = opts or {}
  local o = {
    tabpage = nil,
    windows = {},
    drawer_width = opts.drawer_width or 36,
    result_height = opts.result_height or 14,
    call_log_height = opts.call_log_height or 10,
  }
  setmetatable(o, self)
  self.__index = self
  return o
end

function layouts.Default:is_open()
  return self.tabpage and vim.api.nvim_tabpage_is_valid(self.tabpage) or false
end

function layouts.Default:open()
  local state_api = require("connector.api.state")
  local util = require("connector.util")
  -- Capture the project for the buffer where the user invoked open so Editor uses the expected project
  state_api.set_current_project(util.resolve_project())

  vim.cmd("tabnew")
  self.tabpage = vim.api.nvim_get_current_tabpage()

  self.windows.editor = vim.api.nvim_get_current_win()
  api_ui.editor_show(self.windows.editor)

  vim.cmd(("belowright %ssplit"):format(self.result_height))
  self.windows.result = vim.api.nvim_get_current_win()
  api_ui.result_show(self.windows.result)

  vim.api.nvim_set_current_win(self.windows.editor)
  vim.cmd(("topleft %svsplit"):format(self.drawer_width))
  self.windows.drawer = vim.api.nvim_get_current_win()
  api_ui.drawer_show(self.windows.drawer)

  vim.cmd(("belowright %ssplit"):format(self.call_log_height))
  self.windows.call_log = vim.api.nvim_get_current_win()
  api_ui.call_log_show(self.windows.call_log)

  vim.api.nvim_set_current_win(self.windows.editor)
end

function layouts.Default:reset()
  if self.windows.drawer and vim.api.nvim_win_is_valid(self.windows.drawer) then
    vim.api.nvim_win_set_width(self.windows.drawer, self.drawer_width)
  end
  if self.windows.result and vim.api.nvim_win_is_valid(self.windows.result) then
    vim.api.nvim_win_set_height(self.windows.result, self.result_height)
  end
  if self.windows.call_log and vim.api.nvim_win_is_valid(self.windows.call_log) then
    vim.api.nvim_win_set_height(self.windows.call_log, self.call_log_height)
  end
end

function layouts.Default:close()
  if not self:is_open() then
    return
  end
  vim.api.nvim_set_current_tabpage(self.tabpage)
  vim.cmd("tabclose")
  self.tabpage = nil
  self.windows = {}
end

return layouts

