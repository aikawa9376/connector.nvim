local M = {}
local state = require("connector.api.state")

local function get_handler()
  return state.handler()
end

-- Simple omnifunc: when findstart==1 return byte index where completion starts
-- when findstart==0 return table of candidate strings
function M.omnifunc(findstart, base)
  local h = get_handler()
  if not h then return 0 end

  if findstart == 1 then
    local col = vim.fn.col('.') - 1
    local line = vim.fn.getline('.')
    local start = col
    while start > 0 do
      local ch = line:sub(start, start)
      if not ch:match('[%w_%.]') then
        break
      end
      start = start - 1
    end
    return start
  else
    base = base or ''
    local candidates = {}
    -- collect table names from indexed structure
    for conn_id in pairs(h.connections) do
      pcall(function() h:ensure_table_index(conn_id) end)
      local index = h.table_index[conn_id] or {}
      for key, entry in pairs(index) do
        if entry and entry.table then
          local name = entry.table
          if base == '' or name:sub(1, #base) == base then
            table.insert(candidates, name)
          end
        end
      end
    end
    table.sort(candidates)
    local out = {}
    local seen = {}
    for _, v in ipairs(candidates) do
      if not seen[v] then
        seen[v] = true
        table.insert(out, v)
      end
    end
    return out
  end
end

return M
