-- Run with: nvim --headless -u NONE -i NONE -l tests/startup.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local temp = vim.fn.tempname()
vim.fn.mkdir(temp, 'p')
vim.env.XDG_STATE_HOME = temp .. '/state'
vim.env.XDG_DATA_HOME = temp .. '/data'
local connector = require('connector')
local config = require('connector.config')
assert(#config.merge_with_default({ sources = {} }).sources == 0)
assert(#config.merge_with_default({}).sources == 2)
connector.setup({
  sources = {},
  history = { path = temp .. '/history.json', display = vim.env.CONNECTOR_TEST_DISPLAY or 'drawer' },
  editor = { directory = temp .. '/scratchpads' },
})
assert(not package.loaded['connector.ui.editor'], 'setup eagerly loaded editor')
assert(not package.loaded['connector.ui.drawer'], 'setup eagerly loaded drawer')
assert(not package.loaded['connector.handler'], 'setup eagerly loaded handler')
assert(connector.api.context == require('connector.api.context'))
assert(#connector.api.core.get_sources() == 0)
assert(not package.loaded['connector.ui.editor'], 'core API eagerly loaded UI')

local util = require('connector.util')
assert(util.is_scratchpad_path(temp .. '/scratchpads/project/topic/test.sql'))
assert(not util.is_scratchpad_path(temp .. '/scratchpads-other/test.sql'))
local project = util.resolve_project(temp .. '/scratchpads/project/topic/test.sql')
assert(project.name == 'project' and project.branch == 'topic')

-- Test real Git state, including checkout and detached HEAD across event-loop turns.
local repo = temp .. '/repo'
local function git(...)
  local cmd = { 'git', '-C', repo }
  vim.list_extend(cmd, { ... })
  local result = vim.system(cmd, { text = true }):wait()
  assert(result.code == 0, result.stderr)
end
vim.fn.mkdir(repo, 'p')
git('init', '-q', '-b', 'first')
git('-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', 'commit', '-q', '--allow-empty', '-m', 'test')
local system = vim.system
local lookups = 0
vim.system = function(cmd, ...)
  if cmd[1] == 'git' and cmd[4] == 'branch' then lookups = lookups + 1 end
  return system(cmd, ...)
end
assert(util.get_git_branch(repo) == 'first')
assert(util.get_git_branch(repo) == 'first')
assert(lookups == 1, 'branch lookup was not shared')
vim.wait(10, function() return false end)
git('checkout', '-q', '-b', 'second')
assert(util.get_git_branch(repo) == 'second', 'branch cache was stale after checkout')
vim.wait(10, function() return false end)
git('checkout', '-q', '--detach')
assert(util.get_git_branch(repo) == nil)
local detached_lookups = lookups
assert(util.get_git_branch(repo) == nil)
assert(lookups == detached_lookups, 'detached HEAD should also be cached')
vim.system = system

-- A SQL invocation captures context, opens the custom scratchpad and remains
-- usable after scheduled redraws and close/reopen.
vim.cmd('cd ' .. vim.fn.fnameescape(repo))
vim.api.nvim_buf_set_name(0, repo .. '/query.sql')
vim.bo.filetype = 'sql'
connector.open()
assert(connector.is_open())
local state = require('connector.api.state')
local drawer = state.drawer()
local redraws = 0
local refresh = drawer.refresh
drawer.refresh = function(self, ...)
  redraws = redraws + 1
  return refresh(self, ...)
end
for _ = 1, 5 do drawer:schedule_refresh() end
vim.wait(30, function() return false end)
assert(redraws == 1, 'redraws were not coalesced: ' .. redraws)
local note = state.editor():get_current_note()
assert(vim.startswith(note.file, temp .. '/scratchpads/'))
assert(vim.api.nvim_buf_is_loaded(note.bufnr))
assert(#vim.api.nvim_buf_get_lines(drawer.bufnr, 0, -1, false) > 0)
connector.close()
assert(not connector.is_open())
connector.open()
assert(connector.is_open())
drawer:schedule_refresh()
connector.close()
vim.wait(30, function() return false end)
vim.cmd('cd /tmp')
vim.fn.delete(temp, 'rf')
print('startup regression tests passed')
vim.cmd('qa!')
