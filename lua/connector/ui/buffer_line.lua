local util = require("connector.util")

local M = {}

function M.new_builder()
  return {
    text = "",
    marks = {},
  }
end

function M.append(builder, text, hl_group)
  text = text or ""
  if text == "" then
    return builder
  end
  if hl_group and hl_group ~= "" then
    table.insert(builder.marks, {
      start = #builder.text,
      finish = #builder.text + #text,
      hl_group = hl_group,
    })
  end
  builder.text = builder.text .. text
  return builder
end

function M.pad_display(text, width)
  local gap = width - util.display_width(text)
  if gap <= 0 then
    return text
  end
  return text .. string.rep(" ", gap)
end

function M.truncate_display(text, width)
  if util.display_width(text) <= width then
    return text
  end
  local result = ""
  local used = 0
  local limit = math.max(1, width - 1)
  for i = 0, vim.fn.strlen(text) - 1 do
    local ch = vim.fn.strcharpart(text, i, 1)
    local ch_width = vim.fn.strdisplaywidth(ch)
    if used + ch_width > limit then
      break
    end
    result = result .. ch
    used = used + ch_width
  end
  return result .. "…"
end

function M.render(bufnr, namespace, builders)
  local lines = {}
  for _, builder in ipairs(builders) do
    table.insert(lines, builder.text)
  end

  vim.api.nvim_buf_set_option(bufnr, "modifiable", true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)

  for line_nr, builder in ipairs(builders) do
    for _, mark in ipairs(builder.marks) do
      vim.api.nvim_buf_set_extmark(bufnr, namespace, line_nr - 1, mark.start, {
        end_row = line_nr - 1,
        end_col = mark.finish,
        hl_group = mark.hl_group,
        strict = false,
      })
    end
  end

  vim.api.nvim_buf_set_option(bufnr, "modifiable", false)
end

return M
