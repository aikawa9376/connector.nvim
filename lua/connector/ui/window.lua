local M = {}

local COL_SEP = "│"
local ROW_SEP = "─"
local COL_CROSS = "┼"

local NS_RESULT_TABLE = vim.api.nvim_create_namespace("connector-result-table")

local function centered_size(total, ratio, minimum, margin)
  local maximum = math.max(minimum, total - margin)
  return math.max(minimum, math.min(maximum, math.floor(total * ratio)))
end

local function ensure_result_highlights()
  -- Use `default = true` to keep user overrides.
  vim.api.nvim_set_hl(0, "ConnectorResultTableBorder", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "ConnectorResultTableHeader", { link = "Title", default = true })
  vim.api.nvim_set_hl(0, "ConnectorResultTableIndex", { link = "LineNr", default = true })
  vim.api.nvim_set_hl(0, "ConnectorResultTableNull", { link = "Comment", default = true })
end

local function add_hl(bufnr, row, start_col, end_col, group)
  if end_col <= start_col then
    return
  end
  vim.api.nvim_buf_set_extmark(bufnr, NS_RESULT_TABLE, row, start_col, {
    end_row = row,
    end_col = end_col,
    hl_group = group,
    strict = false,
  })
end

local function highlight_char(bufnr, row, line, ch, group)
  local pos = 1
  while true do
    local s, e = line:find(ch, pos, true)
    if not s then
      break
    end
    -- extmark columns are 0-based byte indices; end_col is exclusive.
    add_hl(bufnr, row, s - 1, e, group)
    pos = e + 1
  end
end

local function highlight_header_segments(bufnr, row, line)
  local segment_start = 1
  local segment_index = 0

  while true do
    local sep_s, sep_e = line:find(COL_SEP, segment_start, true)
    local segment_end = (sep_s and (sep_s - 1)) or #line

    -- Segment 0 is the row-number header (blank). Highlight remaining segments.
    if segment_index >= 1 then
      local segment = line:sub(segment_start, segment_end)
      local first = segment:find("%S")
      if first then
        local last = segment:match(".*()%S")
        local abs_start = segment_start + first - 1
        local abs_end = segment_start + last - 1
        add_hl(bufnr, row, abs_start - 1, abs_end, "ConnectorResultTableHeader")
      end
    end

    if not sep_s then
      break
    end

    segment_index = segment_index + 1
    segment_start = sep_e + 1
  end
end

local function highlight_nulls(bufnr, row, line)
  local pos = 1
  while true do
    local s, e = line:find("NULL", pos, true)
    if not s then
      break
    end

    -- Boundaries: avoid highlighting within words like "NULLABLE".
    local before = s > 1 and line:sub(s - 1, s - 1) or ""
    local after = e < #line and line:sub(e + 1, e + 1) or ""
    local before_ok = before == "" or not before:match("[%w_]")
    local after_ok = after == "" or not after:match("[%w_]")

    if before_ok and after_ok then
      add_hl(bufnr, row, s - 1, e, "ConnectorResultTableNull")
    end

    pos = e + 1
  end
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

  -- Clear the legacy `:match` highlight (used in older versions).
  pcall(vim.api.nvim_win_call, winid, function()
    vim.cmd("match none")
  end)

  ensure_result_highlights()

  local bufnr = vim.api.nvim_win_get_buf(winid)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  vim.api.nvim_buf_clear_namespace(bufnr, NS_RESULT_TABLE, 0, -1)

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for i, line in ipairs(lines) do
    local row = i - 1

    -- Separator lines: keep it subtle by tinting the whole line.
    if (line:find(ROW_SEP, 1, true) or line:find(COL_CROSS, 1, true)) and not line:find(COL_SEP, 1, true) then
      add_hl(bufnr, row, 0, #line, "ConnectorResultTableBorder")
    else
      highlight_char(bufnr, row, line, COL_SEP, "ConnectorResultTableBorder")

      if i == 1 then
        highlight_header_segments(bufnr, row, line)
      else
        -- Row number (left-most column)
        local ws_end = select(2, line:find("^%s*")) or 0
        local ds, de = line:find("%d+", ws_end + 1)
        if ds and de and ds <= ws_end + 1 then
          add_hl(bufnr, row, ds - 1, de, "ConnectorResultTableIndex")
        end

        highlight_nulls(bufnr, row, line)
      end
    end
  end
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
    cursorline = true,
  }

  for name, value in pairs(options) do
    pcall(vim.api.nvim_win_set_option, winid, name, value)
  end

  M.apply_result_delimiter_highlight(winid)
end

return M
