local api_ui = require("connector.api.ui")

local layouts = {}

layouts.Default = {}

local function is_valid_window(winid)
  return winid and vim.api.nvim_win_is_valid(winid) or false
end

function layouts.Default:new(opts)
  opts = opts or {}
  local result_height = opts.result_height or 10
  local o = {
    tabpage = nil,
    windows = {},
    drawer_width = opts.drawer_width or 36,
    result_height = result_height,
    call_log_height = opts.call_log_height or result_height,
    augroup = nil,
    restore_scheduled = false,
  }
  setmetatable(o, self)
  self.__index = self
  return o
end

function layouts.Default:is_open()
  return self.tabpage and vim.api.nvim_tabpage_is_valid(self.tabpage) or false
end

function layouts.Default:is_layout_window(winid)
  for _, managed_win in pairs(self.windows) do
    if managed_win == winid and is_valid_window(managed_win) then
      return true
    end
  end
  return false
end

function layouts.Default:is_active_tab()
  return self:is_open() and vim.api.nvim_get_current_tabpage() == self.tabpage
end

function layouts.Default:clear_autocmds()
  if self.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, self.augroup)
    self.augroup = nil
  end
  self.restore_scheduled = false
end

function layouts.Default:apply_window_pinning()
  if is_valid_window(self.windows.drawer) then
    vim.api.nvim_set_option_value("winfixwidth", true, { win = self.windows.drawer })
  end
  if is_valid_window(self.windows.result) then
    vim.api.nvim_set_option_value("winfixheight", true, { win = self.windows.result })
  end
  if is_valid_window(self.windows.call_log) then
    vim.api.nvim_set_option_value("winfixheight", true, { win = self.windows.call_log })
  end
end

function layouts.Default:schedule_restore()
  if self.restore_scheduled then
    return
  end

  self.restore_scheduled = true
  vim.schedule(function()
    self.restore_scheduled = false
    if not self:is_open() then
      self.windows = {}
      self:clear_autocmds()
      return
    end
    self:reset()
  end)
end

function layouts.Default:setup_autocmds()
  self:clear_autocmds()
  self.augroup = vim.api.nvim_create_augroup(("connector-layout-%d"):format(self.tabpage), { clear = true })

  vim.api.nvim_create_autocmd("WinEnter", {
    group = self.augroup,
    callback = function()
      if self:is_active_tab() and self:is_layout_window(vim.api.nvim_get_current_win()) then
        self:schedule_restore()
      end
    end,
  })

  vim.api.nvim_create_autocmd({ "WinNew", "WinClosed" }, {
    group = self.augroup,
    callback = function()
      if self:is_active_tab() then
        self:schedule_restore()
      end
    end,
  })

  vim.api.nvim_create_autocmd("TabEnter", {
    group = self.augroup,
    callback = function()
      if self:is_active_tab() then
        self:schedule_restore()
      end
    end,
  })

  vim.api.nvim_create_autocmd("VimResized", {
    group = self.augroup,
    callback = function()
      if self:is_active_tab() then
        self:schedule_restore()
      end
    end,
  })

  vim.api.nvim_create_autocmd("TabClosed", {
    group = self.augroup,
    callback = function()
      if not self:is_open() then
        self.windows = {}
        self:clear_autocmds()
      end
    end,
  })
end

function layouts.Default:open()
  local state_api = require("connector.api.state")
  local util = require("connector.util")
  -- Capture the project for the buffer where the user invoked open so Editor uses the expected project
  local current_buf = vim.api.nvim_get_current_buf()
  local current_name = vim.api.nvim_buf_get_name(current_buf)
  local is_sql = current_name:match("%.sql$") or util.is_scratchpad_path(current_name) or vim.bo[current_buf].filetype == "sql"
  local project = is_sql and util.resolve_project(current_name) or nil
  if project then
    state_api.set_current_project(project, vim.api.nvim_get_current_buf())
  end

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
  self:apply_window_pinning()
  self:setup_autocmds()
end

function layouts.Default:reset()
  self:apply_window_pinning()
  if is_valid_window(self.windows.drawer) then
    vim.api.nvim_win_set_width(self.windows.drawer, self.drawer_width)
  end
  if is_valid_window(self.windows.result) then
    vim.api.nvim_win_set_height(self.windows.result, self.result_height)
  end
  if is_valid_window(self.windows.call_log) then
    vim.api.nvim_win_set_height(self.windows.call_log, self.call_log_height)
  end
end

function layouts.Default:close()
  if not self:is_open() then
    return
  end
  self:clear_autocmds()
  vim.api.nvim_set_current_tabpage(self.tabpage)
  vim.cmd("tabclose")
  self.tabpage = nil
  self.windows = {}
end

return layouts
