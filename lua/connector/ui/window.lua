local M = {}

local RESULT_DELIMITER_MATCH = [[match Delimiter /^\s*\d\+\|─\|│\|┼/]]

local function centered_size(total, ratio, minimum, margin)
  local maximum = math.max(minimum, total - margin)
  return math.max(minimum, math.min(maximum, math.floor(total * ratio)))
end

function M.centered_layout(opts)
  opts = vim.tbl_extend("force", {
    width_ratio = 0.85,
    height_ratio = 0.85,
    min_width = 40,
    min_height = 10,
    horizontal_margin = 8,
    vertical_margin = 4,
  }, opts or {})

  local ui = vim.api.nvim_list_uis()[1]
  local width = centered_size(ui.width, opts.width_ratio, opts.min_width, opts.horizontal_margin)
  local height = centered_size(ui.height, opts.height_ratio, opts.min_height, opts.vertical_margin)

  return {
    width = width,
    height = height,
    col = math.floor((ui.width - width) / 2),
    row = math.floor((ui.height - height) / 2),
  }
end

function M.open_centered(bufnr, enter, opts)
  opts = opts or {}
  local layout = M.centered_layout(opts)

  return vim.api.nvim_open_win(bufnr, enter ~= false, {
    relative = "editor",
    width = layout.width,
    height = layout.height,
    col = layout.col,
    row = layout.row,
    border = opts.border or "rounded",
    style = opts.style or "minimal",
    title = opts.title,
    title_pos = opts.title_pos,
    zindex = opts.zindex or 150,
  })
end

function M.apply_result_delimiter_highlight(winid)
  if not winid or not vim.api.nvim_win_is_valid(winid) then
    return
  end

  pcall(vim.api.nvim_win_call, winid, function()
    vim.cmd(RESULT_DELIMITER_MATCH)
  end)
end

function M.configure_result_window(winid)
  if not winid or not vim.api.nvim_win_is_valid(winid) then
    return
  end

  local options = {
    wrap = false,
    sidescroll = 1,
    sidescrolloff = 5,
    number = false,
    relativenumber = false,
  }

  for name, value in pairs(options) do
    pcall(vim.api.nvim_win_set_option, winid, name, value)
  end

  M.apply_result_delimiter_highlight(winid)
end

return M
