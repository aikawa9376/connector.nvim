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

local function same_marks(left, right)
  if #left ~= #right then return false end
  for i, mark in ipairs(left) do
    local other = right[i]
    if mark.start ~= other.start or mark.finish ~= other.finish or mark.hl_group ~= other.hl_group then
      return false
    end
  end
  return true
end

-- Owners may retain the returned state while treating builders as immutable.
-- External buffer edits or a changed row count require a complete rebuild.
function M.render(bufnr, namespace, builders, previous)
  local changedtick = vim.api.nvim_buf_get_changedtick(bufnr)
  local reuse = previous and previous.bufnr == bufnr and previous.namespace == namespace
    and previous.changedtick == changedtick and #previous.builders == #builders
  local first, last, text_changed
  if reuse then
    for row, builder in ipairs(builders) do
      local old = previous.builders[row]
      local changed = builder.text ~= old.text
      if changed or not same_marks(builder.marks, old.marks) then
        first = first or row
        last = row
        text_changed = text_changed or changed
      end
    end
    if not first then return previous end
  else
    first, last, text_changed = 1, #builders, true
  end

  local lines = {}
  if text_changed then
    for row = first, last do
      lines[#lines + 1] = builders[row].text
    end
  end

  local end_row = reuse and last or -1
  vim.api.nvim_buf_clear_namespace(bufnr, namespace, first - 1, end_row)
  if text_changed then
    vim.api.nvim_buf_set_option(bufnr, "modifiable", true)
    vim.api.nvim_buf_set_lines(bufnr, first - 1, end_row, false, lines)
    vim.api.nvim_buf_set_option(bufnr, "modifiable", false)
  end

  for line_nr = first, last do
    local builder = builders[line_nr]
    for _, mark in ipairs(builder.marks) do
      vim.api.nvim_buf_set_extmark(bufnr, namespace, line_nr - 1, mark.start, {
        end_row = line_nr - 1,
        end_col = mark.finish,
        hl_group = mark.hl_group,
        strict = false,
      })
    end
  end

  return { bufnr = bufnr, namespace = namespace, changedtick = vim.api.nvim_buf_get_changedtick(bufnr), builders = builders }
end

return M
