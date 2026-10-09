-- nvim --headless -u NONE -i NONE -l tests/drawer_benchmark.lua
-- CONNECTOR_BENCH_ROOT selects another checkout with the same fixture.
vim.opt.rtp:prepend(vim.env.CONNECTOR_BENCH_ROOT or vim.fn.getcwd())
local temp = vim.fn.tempname()
vim.env.XDG_STATE_HOME = temp .. '/state'
vim.env.XDG_DATA_HOME = temp .. '/data'
local config = require('connector.config').merge_with_default({
  sources = {}, history = { path = temp .. '/history.json' },
  drawer = { recent_scratchpads_limit = 0 },
})
local handler = require('connector.handler'):new(config)
handler:add_source({
  name = function() return 'fixture' end,
  load = function()
    return {{ id = 'fixture', name = 'Fixture', type = 'mysql', url = '', database = 'active' }}
  end,
})
handler.current_connection_id = 'fixture'
handler:set_project_provider(function() return { name = 'bench', branch = 'main' } end)
handler.database_cache.fixture = { current = 'active', available = { 'active', 'other' } }
for _, database in ipairs({ 'active', 'other' }) do
  local items = {}
  for i = 2000, 1, -1 do
    items[#items + 1] = { name = ('table_%04d'):format(i), schema = database, materialization = 'table' }
  end
  handler.structure_cache['fixture:' .. database] = items
end
local drawer = require('connector.ui.drawer'):new(handler, {
  get_current_note = function() end,
  register_event_listener = function() end,
}, {}, config.drawer, {})
drawer.expanded['root:scratchpads'] = false
drawer.expanded['database:fixture:other'] = true
local lookups, writes, marks = 0, 0, 0
local getter, set_lines, set_mark = handler.get_current_connection, vim.api.nvim_buf_set_lines, vim.api.nvim_buf_set_extmark
handler.get_current_connection = function(self)
  lookups = lookups + 1
  return getter(self)
end
vim.api.nvim_buf_set_lines = function(...)
  writes = writes + 1
  return set_lines(...)
end
vim.api.nvim_buf_set_extmark = function(...)
  marks = marks + 1
  return set_mark(...)
end
drawer:refresh()
lookups, writes, marks = 0, 0, 0
local samples = {}
for _ = 1, 20 do
  local start = vim.uv.hrtime()
  drawer:refresh()
  samples[#samples + 1] = (vim.uv.hrtime() - start) / 1e6
end
table.sort(samples)
local lookup_count, write_count, mark_count = lookups, writes, marks
-- History rendering only needs id/state/query, even when calls have large results.
for i = 1, 10 do
  local rows = {}
  for row = 1, 3000 do rows[row] = { row, 'value', 'value', 'value', 'value' } end
  local id = 'call' .. i
  handler.call_order[i] = id
  handler.calls[id] = {
    id = id, connection_id = 'fixture', state = 'archived', query = 'select * from example',
    project = 'bench', branch = 'main',
    result = { rows = rows },
  }
end
local history_samples = {}
for _ = 1, 10 do
  local start = vim.uv.hrtime()
  require('connector.ui.call_history').visible_calls(handler, { summary = true })
  history_samples[#history_samples + 1] = (vim.uv.hrtime() - start) / 1e6
end
table.sort(history_samples)
print(vim.json.encode({
  rows = vim.api.nvim_buf_line_count(drawer.bufnr),
  refresh_median_ms = (samples[10] + samples[11]) / 2,
  connection_lookups_per_refresh = lookup_count / 20,
  buffer_writes_per_refresh = write_count / 20,
  extmark_writes_per_refresh = mark_count / 20,
  history_median_ms = (history_samples[5] + history_samples[6]) / 2,
}))
vim.fn.delete(temp, 'rf')
vim.cmd('qa!')
