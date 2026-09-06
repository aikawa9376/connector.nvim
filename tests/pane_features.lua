-- nvim --headless -u NONE -i NONE -l tests/pane_features.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local temp = vim.fn.tempname()
vim.env.XDG_STATE_HOME = temp .. '/state'
vim.env.XDG_DATA_HOME = temp .. '/data'
local connector = require('connector')
local config = require('connector.config')
assert(config.default().drawer.recent_scratchpads_limit == 10)
for _, value in ipairs({ -1, 1.5, math.huge, '10' }) do
  assert(not pcall(config.validate, config.merge_with_default({ drawer = { recent_scratchpads_limit = value } })))
end
connector.setup({ sources = {}, history = { display = 'panel' }, drawer = { recent_scratchpads_limit = 2 } })
connector.open()
local state = require('connector.api.state')
local editor, drawer, result, history = state.editor(), state.drawer(), state.result(), state.call_log()
local ids = {}
for i = 1, 3 do
  ids[i] = editor:namespace_create_note('test/main', 'note' .. i)
  editor:set_current_note(ids[i])
end
editor:set_current_note(ids[1])
editor:set_current_note(ids[1])
local recent = editor:recent_notes(2)
assert(#recent == 2 and recent[1].id == ids[1] and recent[2].id == ids[3])
editor:note_rename(ids[1], 'renamed')
editor:save_recent_notes()
local Editor = require('connector.ui.editor')
local restored = Editor:new(state.handler(), result, state.config().editor, {}, state.config().result)
assert(restored:recent_notes(2)[1].name == 'renamed', 'MRU did not survive reload/rename')
editor:namespace_remove_note('test/main', ids[3])
assert(editor:recent_notes(2)[2].id == ids[2], 'deleted note remained in MRU')
vim.wait(30, function() return false end)
drawer:refresh()
local rows = {}
for row, node in pairs(drawer.line_map) do
  if node.key and node.key:match('^recent_scratchpad:') then rows[#rows + 1] = row end
end
table.sort(rows)
assert(#rows == 2)
assert(drawer.line_map[rows[1]].note_id == ids[1])
assert(drawer.line_map[rows[2]].note_id == ids[2])
vim.api.nvim_set_current_win(drawer.window)
vim.api.nvim_win_set_cursor(0, { rows[2], 0 })
drawer:do_action('action_1')
assert(editor:get_current_note().id == ids[2], 'recent entry did not open the selected note')
vim.wait(30, function() return false end)

local selected
vim.ui.select = function(items, opts, callback) selected = { items = items, opts = opts, callback = callback } end
local function menu_for(owner, win, buf)
  vim.api.nvim_set_current_win(win)
  local mapping
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
    if m.lhs == 'g?' then mapping = m end
  end
  assert(mapping and mapping.callback, 'missing g? mapping')
  selected = nil
  mapping.callback()
  assert(selected and #selected.items > 0, 'menu did not open')
  return selected
end
local menu = menu_for(editor, editor.window, editor:get_current_note().bufnr)
assert(menu.opts.prompt == 'Scratchpad menu')
local ran
local original_action = editor.do_action
editor.do_action = function(_, action) ran = action end
vim.api.nvim_set_current_win(drawer.window)
menu.callback(menu.items[1])
vim.wait(10, function() return false end)
assert(ran == 'run_under_cursor', 'picker failed to dispatch from another window')
editor.do_action = original_action
vim.api.nvim_set_current_win(editor.window)
vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'select 1;', 'select 2;' })
vim.cmd('normal! ggVj')
editor:open_menu()
local visual_menu = selected
assert(visual_menu.items[1].action == 'run_selection')
visual_menu.callback(nil)
assert(editor.explicit_visual_range == nil, "canceled menu retained a stale selection")
vim.cmd('normal! ' .. vim.api.nvim_replace_termcodes('<Esc>', true, false, true))
menu = menu_for(result, result.window, result.bufnr)
assert(menu.opts.prompt == 'Result menu')
menu = menu_for(history, history.window, history.bufnr)
assert(menu.opts.prompt == 'History menu')
vim.api.nvim_set_current_win(drawer.window)
for row, node in pairs(drawer.line_map) do
  if node.key == 'recent_scratchpad:' .. ids[2] then vim.api.nvim_win_set_cursor(0, {row, 0}) end
end
menu = menu_for(drawer, drawer.window, drawer.bufnr)
assert(menu.opts.prompt == 'Drawer menu')
local actions = {}
for _, item in ipairs(menu.items) do actions[item.action] = true end
assert(actions.action_1 and actions.action_2 and actions.action_3)
-- A redraw can move the selected entry while a picker remains open.
editor:set_current_note(ids[1])
drawer:refresh()
menu.callback(menu.items[1])
vim.wait(10, function() return false end)
assert(editor:get_current_note().id == ids[2], 'drawer menu acted on the wrong row after redraw')
-- Picker actions are available from every pane, independently of the selected
-- node/result. Opening/canceling a menu must not invoke expensive picker APIs.
local ui = require('connector.api.ui')
local originals, calls = {}, {}
local picker_methods = {
  'editor_pick_scratchpad', 'editor_grep_scratchpads',
  'drawer_pick_table', 'pick_history_calls',
}
for _, method in ipairs(picker_methods) do
  originals[method] = ui[method]
  ui[method] = function() calls[#calls + 1] = method end
end
for _, pane in ipairs({ editor, drawer, result, history }) do
  local buf = pane == editor and editor:get_current_note().bufnr or pane.bufnr
  local picker_menu = menu_for(pane, pane.window, buf)
  local before = #calls
  picker_menu.callback(nil)
  assert(#calls == before, 'menu opening/cancellation invoked a picker')
  -- Simulate a drawer refresh removing the previously selected node.
  local old_map = drawer.line_map
  if pane == drawer then drawer.line_map = {} end
  for _, method in ipairs(picker_methods) do
    local found
    for _, item in ipairs(picker_menu.items) do
      if item.action == method then found = item end
    end
    assert(found, 'missing picker: ' .. method)
    picker_menu.callback(found)
    vim.wait(10, function() return false end)
    assert(calls[#calls] == method, 'wrong picker dispatched: ' .. method)
  end
  drawer.line_map = old_map
end
-- The populated result menu uses a different selection callback from the empty
-- pane: exercise it as well, without executing a database query.
local get_call = result.get_call
result.get_call = function() return { id = 'test', state = 'archived', query = 'select 1' } end
local populated = menu_for(result, result.window, result.bufnr)
for _, label in ipairs({ 'Pick scratchpad', 'Grep scratchpads', 'Pick table', 'Pick query history' }) do
  local found
  for index, item in ipairs(populated.items) do
    if item == label then found = index end
  end
  assert(found, 'missing populated-result picker: ' .. label)
  populated.callback(label, found)
  vim.wait(10, function() return false end)
end
for i, method in ipairs(picker_methods) do
  assert(calls[#calls - #picker_methods + i] == method)
  ui[method] = originals[method]
end
result.get_call = get_call
-- Model an fzf picker opening a focused floating window, followed by the
-- previous selection UI restoring its background window before returning.
local saved_fzf = package.loaded['fzf-lua']
local grep_window, grep_options, scratchpad_options
package.loaded['fzf-lua'] = {
  grep = function(opts)
    grep_options = opts
    grep_window = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), true, {
      relative = 'editor', row = 1, col = 1, width = 30, height = 5, style = 'minimal',
    })
  end,
  live_grep = function() error('ordinary grep must not use live_grep') end,
  fzf_exec = function(_, opts) scratchpad_options = opts end,
}
local grep_menu = menu_for(editor, editor.window, editor:get_current_note().bufnr)
for _, item in ipairs(grep_menu.items) do
  if item.action == 'editor_grep_scratchpads' then grep_menu.callback(item) end
end
assert(grep_window == nil, 'picker opened before the menu finished closing')
vim.api.nvim_set_current_win(drawer.window)
vim.wait(10, function() return false end)
assert(vim.api.nvim_get_current_win() == grep_window, 'focus restored behind the new picker')
assert(grep_options.search == '', 'missing search triggers an input prompt in fzf-lua')
assert(grep_options.cwd == editor.config.directory)
assert(grep_options.rg_opts:find('--glob=*.sql', 1, true))
vim.api.nvim_win_close(grep_window, true)
grep_window = nil
ui.editor_pick_scratchpad()
scratchpad_options.actions['ctrl-g']()
assert(grep_window == nil, 'scratchpad-to-grep transition was not deferred')
vim.wait(10, function() return false end)
assert(vim.api.nvim_get_current_win() == grep_window)
vim.api.nvim_win_close(grep_window, true)
ui.editor_grep_scratchpads({ search = 'select' })
assert(grep_options.search == 'select', 'explicit search was discarded')
vim.api.nvim_win_close(grep_window, true)
package.loaded['fzf-lua'] = saved_fzf

-- A queued menu action must not execute if its originating pane has closed.
local scratch_win = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), true, {
  relative = 'editor', row = 1, col = 1, width = 30, height = 5, style = 'minimal',
})
local dispatch = require('connector.ui.menu').dispatcher()
local stale_action_ran = false
dispatch(function() stale_action_ran = true end)
vim.api.nvim_win_close(scratch_win, true)
vim.wait(10, function() return false end)
assert(not stale_action_ran)
drawer.config.recent_scratchpads_limit = 0
drawer:refresh()
for _, node in pairs(drawer.line_map) do assert(node.key ~= 'root:recent_scratchpads') end
-- Missing files are omitted without loading their buffers.
os.remove(editor:search_note(ids[1]).file)
for _, note in ipairs(editor:recent_notes(10)) do assert(note.id ~= ids[1]) end
connector.close()
vim.wait(30, function() return false end)
editor:save_recent_notes()
vim.fn.delete(temp, 'rf')
print('pane feature tests passed')
vim.cmd('qa!')
