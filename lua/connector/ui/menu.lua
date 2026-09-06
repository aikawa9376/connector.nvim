local M = {}

-- Resolve APIs only after selection so opening a menu does not initialize
-- pickers, scan scratchpads or fetch database metadata.
function M.picker_items()
  local items = {}
  for _, spec in ipairs({
    { "Pick scratchpad", "editor_pick_scratchpad" },
    { "Grep scratchpads", "editor_grep_scratchpads" },
    { "Pick table", "drawer_pick_table" },
    { "Pick query history", "pick_history_calls" },
  }) do
    local method = spec[2]
    table.insert(items, {
      label = spec[1],
      action = method,
      run = function() require("connector.api.ui")[method]() end,
    })
  end
  return items
end

-- Let the selection UI finish closing before opening another picker. Use an
-- actual focus change: nvim_win_call would restore focus behind the new picker.
function M.dispatcher()
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(win)
  return function(run)
    vim.schedule(function()
      if not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= buf then return end
      vim.api.nvim_set_current_win(win)
      pcall(vim.api.nvim_win_set_cursor, win, cursor)
      run()
    end)
  end
end

function M.open(owner, title, items, run)
  local dispatch = M.dispatcher()
  for _, item in ipairs(items) do
    local keys, seen = {}, {}
    for _, mapping in ipairs(owner.config.mappings or {}) do
      if mapping.action == item.action and not seen[mapping.key] then
        seen[mapping.key] = true
        table.insert(keys, mapping.key)
      end
    end
    item.display = item.label .. (#keys > 0 and (' (' .. table.concat(keys, '/') .. ')') or '')
  end
  vim.ui.select(items, {
    prompt = title,
    format_item = function(item) return item.display end,
  }, function(item)
    if not item then return end
    dispatch(function()
      if item.run then item.run() elseif run then run(item.action) else owner:do_action(item.action) end
    end)
  end)
end

return M
