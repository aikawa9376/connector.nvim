-- nvim --headless -u NONE -i NONE -l tests/ui_performance.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local temp = vim.fn.tempname()
vim.env.XDG_STATE_HOME = temp .. '/state'
vim.env.XDG_DATA_HOME = temp .. '/data'
local buffer_line = require('connector.ui.buffer_line')
local buf = vim.api.nvim_create_buf(false, true)
local ns = vim.api.nvim_create_namespace('render-test')
local function builders(rows)
  local out = {}
  for _, row in ipairs(rows) do
    local builder = buffer_line.new_builder()
    buffer_line.append(builder, row[1], row[2])
    out[#out + 1] = builder
  end
  return out
end
local function marks(row)
  return vim.api.nvim_buf_get_extmarks(buf, ns, { row, 0 }, { row, -1 }, { details = true })
end
local original = { { 'head', 'Title' }, { '日本語', 'Identifier' }, { 'tail', 'Comment' } }
local state = buffer_line.render(buf, ns, builders(original))
local tick = vim.api.nvim_buf_get_changedtick(buf)
local initial_marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
state = buffer_line.render(buf, ns, builders(original), state)
assert(vim.api.nvim_buf_get_changedtick(buf) == tick, 'unchanged render modified text')
assert(vim.deep_equal(initial_marks, vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })),
  'unchanged render replaced extmarks')

local head_id, tail_id = marks(0)[1][1], marks(2)[1][1]
state = buffer_line.render(buf, ns, builders({ original[1], { '日本語', 'String' }, original[3] }), state)
assert(vim.api.nvim_buf_get_changedtick(buf) == tick, 'highlight-only render modified text')
assert(marks(1)[1][4].hl_group == 'String')
assert(marks(1)[1][4].end_col == #'日本語', 'extmark columns must use bytes')
state = buffer_line.render(buf, ns, builders({ original[1], { 'changed', 'Constant' }, original[3] }), state)
assert(vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1] == 'changed')
assert(marks(0)[1][1] == head_id and marks(2)[1][1] == tail_id, 'unchanged rows lost their marks')
assert(marks(2)[1][3] == 0 and marks(2)[1][4].end_col == 4, 'replacement displaced the next row')
assert(not vim.bo[buf].modifiable)

-- External edits invalidate the saved state; row insertion/deletion rebuilds marks.
vim.bo[buf].modifiable = true
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'external' })
state = buffer_line.render(buf, ns, builders(original), state)
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { 'head', '日本語', 'tail' }))
assert(#vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}) == 3)
state = buffer_line.render(buf, ns, builders({ original[3], original[1] }), state)
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { 'tail', 'head' }))
assert(marks(0)[1][4].hl_group == 'Comment' and marks(1)[1][4].hl_group == 'Title')
state = buffer_line.render(buf, ns, {}, state)
assert(#vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}) == 0)
assert(vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1] == '')

local config = require('connector.config').merge_with_default({
  sources = {}, history = { path = temp .. '/history.json' },
  drawer = { recent_scratchpads_limit = 0, disable_help = true },
})
local handler = require('connector.handler'):new(config)
handler:add_source({
  name = function() return 'fixture' end,
  load = function() return {
    { id = 'mysql', name = 'MySQL', type = 'mysql', database = 'active' },
    { id = 'sqlite', name = 'SQLite', type = 'sqlite' },
  } end,
})
handler.current_connection_id = 'mysql'
handler.database_cache.mysql = { current = 'active', available = { 'active', 'other' } }
handler.database_cache.sqlite = { current = '', available = {} }
handler.structure_cache['mysql:active'] = {
  { name = 'z_table', schema = 'active', materialization = 'table' },
  { name = 'a_view', schema = 'active', materialization = 'view' },
}
handler.structure_cache['mysql:other'] = {{ name = 'other_table', schema = 'other', materialization = 'table' }}
handler.structure_cache.sqlite = {{ name = 'local_table', materialization = 'table' }}
handler.column_cache[table.concat({ 'mysql', 'active', 'z_table', 'table' }, '\0')] = {{ name = 'id' }}
local drawer = require('connector.ui.drawer'):new(handler, {
  get_current_note = function() end, register_event_listener = function() end,
}, {}, config.drawer, {})
drawer.expanded['root:scratchpads'] = false
drawer.expanded['connection:sqlite'] = true
drawer.expanded['database:mysql:other'] = true
drawer.expanded['table:mysql:active:z_table'] = true
drawer:refresh()
local function label_highlight(key)
  for row, node in pairs(drawer.line_map) do
    if node.key == key then
      local row_marks = vim.api.nvim_buf_get_extmarks(drawer.bufnr, drawer.ns,
        { row - 1, 0 }, { row - 1, -1 }, { details = true })
      return row_marks[#row_marks][4].hl_group, row
    end
  end
  error('missing node: ' .. key)
end
assert(label_highlight('table:mysql:active:z_table') == 'Identifier')
assert(label_highlight('table:mysql:active:a_view') == 'Identifier')
assert(label_highlight('table:mysql:other:other_table') == 'Comment')
assert(label_highlight('table:sqlite::local_table') == 'Comment')
local _, view_row = label_highlight('table:mysql:active:a_view')
local _, table_row = label_highlight('table:mysql:active:z_table')
assert(view_row < table_row, 'table/view ordering changed')
-- Public metadata caches must retain their original order/content.
assert(handler.structure_cache['mysql:active'][1].name == 'z_table')
local drawer_tick = vim.api.nvim_buf_get_changedtick(drawer.bufnr)
handler.database_cache.mysql.current = 'other'
handler.connections.mysql.database = 'other'
drawer:refresh()
assert(label_highlight('table:mysql:active:z_table') == 'Comment')
assert(label_highlight('table:mysql:other:other_table') == 'Identifier')
assert(vim.api.nvim_buf_get_changedtick(drawer.bufnr) == drawer_tick, 'DB highlight switch rewrote unchanged text')
handler.current_connection_id = 'sqlite'
drawer:refresh()
assert(label_highlight('table:mysql:active:z_table') == 'Comment')
assert(label_highlight('table:sqlite::local_table') == 'Identifier')
-- Highlight changes must also be visible when icons are disabled.
drawer.config.disable_candies = true
drawer:refresh()
assert(label_highlight('table:sqlite::local_table') == 'Identifier')
assert(label_highlight('table:mysql:other:other_table') == 'Comment')

-- Summaries preserve filtering/order/fallback without traversing result rows.
handler:set_project_provider(function() return { name = 'fixture', branch = 'main' } end)
handler.call_order = { 'other-project', 'other-branch', 'second', 'first', 'deleted' }
handler.calls = {
  ['other-project'] = { id = 'other-project', connection_id = 'mysql', project = 'elsewhere', branch = 'main' },
  ['other-branch'] = { id = 'other-branch', connection_id = 'mysql', project = 'fixture', branch = 'topic' },
  first = { id = 'first', state = 'archived', query = 'select 1', connection_id = 'mysql', project = 'fixture', branch = 'main', result = { rows = {{1}} } },
  second = { id = 'second', state = 'executing', query = 'select 2', connection_id = 'sqlite', project = 'fixture', branch = 'main' },
}
local history = require('connector.ui.call_history')
local summaries = history.visible_calls(handler, { summary = true })
assert(#summaries == 1 and summaries[1].id == 'second')
handler.current_connection_id = 'missing'
summaries = history.visible_calls(handler, { summary = true })
assert(#summaries == 2 and summaries[1].id == 'second' and summaries[2].id == 'first')
assert(summaries[2].result == nil)
summaries[2].query = 'changed'
assert(handler.calls.first.query == 'select 1', 'summary mutation affected stored call')
local full = history.visible_calls(handler)
assert(full[2].result.rows[1][1] == 1, 'full history lost query results')
full[2].result.rows[1][1] = 2
assert(handler.calls.first.result.rows[1][1] == 1, 'public call API lost copy isolation')
vim.fn.delete(temp, 'rf')
print('UI performance regression tests passed')
vim.cmd('qa!')
