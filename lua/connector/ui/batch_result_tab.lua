local ResultUI = require("connector.ui.result")
local util = require("connector.util")

local M = {}

local function truncate_query(query, max_len)
  query = vim.trim((query or ""):gsub("%s+", " "))
  if #query <= max_len then
    return query
  end
  return query:sub(1, max_len - 3) .. "..."
end

local function close_tabpage(tabpage)
  if not tabpage or not vim.api.nvim_tabpage_is_valid(tabpage) then
    return
  end

  local current = vim.api.nvim_get_current_tabpage()
  if current ~= tabpage then
    pcall(vim.api.nvim_set_current_tabpage, tabpage)
  end
  pcall(vim.cmd, "tabclose")
end

local function render_placeholder(result_ui, query, index, total)
  util.buf_set_lines(result_ui.bufnr, {
    query,
    "",
    "Executing...",
  })

  if result_ui.window and vim.api.nvim_win_is_valid(result_ui.window) then
    vim.api.nvim_win_set_option(result_ui.window, "winbar",
      string.format("%d/%d  %s  pending", index, total, truncate_query(query, 56)))
  end
end

function M.open(handler, result_config, connection_id, queries)
  vim.cmd("tabnew")
  local tabpage = vim.api.nvim_get_current_tabpage()
  local windows = { vim.api.nvim_get_current_win() }

  for _ = 2, #queries do
    vim.cmd("belowright split")
    table.insert(windows, vim.api.nvim_get_current_win())
  end
  vim.cmd("wincmd =")

  local result_uis = {}

  for index, query in ipairs(queries) do
    local winid = windows[index]
    local result_ui = ResultUI:new(handler, result_config)
    vim.bo[result_ui.bufnr].bufhidden = "wipe"

    result_ui:show(winid)
    render_placeholder(result_ui, query, index, #queries)

    vim.keymap.set("n", "q", function()
      close_tabpage(tabpage)
    end, { buffer = result_ui.bufnr, silent = true })

    vim.api.nvim_create_autocmd("BufWipeout", {
      buffer = result_ui.bufnr,
      once = true,
      callback = function()
        result_ui:destroy()
      end,
    })

    result_uis[index] = result_ui
    handler:connection_execute(connection_id, query, function(call)
      if not tabpage or not vim.api.nvim_tabpage_is_valid(tabpage) then
        return
      end
      if result_ui.disposed or not result_ui.window or not vim.api.nvim_win_is_valid(result_ui.window) then
        return
      end

      if call then
        result_ui:set_call(call)
      else
        util.buf_set_lines(result_ui.bufnr, {
          query,
          "",
          "Query canceled.",
        })
      end
    end)
  end

  vim.api.nvim_set_current_win(windows[1])
  return {
    tabpage = tabpage,
    windows = windows,
    results = result_uis,
  }
end

return M
