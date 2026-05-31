local util = require("connector.util")

local M = {}

local function history_file()
  return util.state_path("connector", "query_history.json")
end

local function normalize_query(query)
  return vim.trim(query or "")
end

local function compact_query(query)
  return normalize_query(query):gsub("%s+", " ")
end

local function normalize_identifier(value)
  if not value or value == "" then
    return nil
  end
  return util.strip_identifier_quotes(tostring(value)):lower()
end

local function table_matches(entry, table_filter, schema_filter)
  if not table_filter or table_filter == "" then
    return true
  end
  local normalized_table = normalize_identifier(table_filter)
  local normalized_schema = normalize_identifier(schema_filter)
  for _, ref in ipairs(entry.tables or {}) do
    local ref_table = normalize_identifier(ref.table)
    local ref_schema = normalize_identifier(ref.schema)
    local same_table = ref.table == table_filter or ref_table == normalized_table
    local same_schema = not normalized_schema or ref.schema == schema_filter or ref_schema == normalized_schema
    if same_table and same_schema then
      return true
    end
  end
  return false
end

local function matches(entry, opts)
  opts = opts or {}
  if opts.connection_id and entry.connection_id ~= opts.connection_id then
    return false
  end
  if opts.project and entry.project ~= opts.project then
    return false
  end
  if opts.branch and entry.branch ~= opts.branch then
    return false
  end
  if not table_matches(entry, opts.table, opts.schema) then
    return false
  end
  return true
end

local History = {}

function History:new(config)
  local o = {
    config = config or {},
    path = (config and config.path) or history_file(),
    max_entries = (config and config.max_entries) or 1000,
  }
  setmetatable(o, self)
  self.__index = self
  return o
end

function History:read()
  local data = util.read_json(self.path, { entries = {} })
  if vim.islist(data) then
    return { entries = data }
  end
  data.entries = data.entries or {}
  return data
end

function History:write(data)
  util.write_json(self.path, data or { entries = {} })
end

function History:list(opts)
  local data = self:read()
  local entries = {}
  for _, entry in ipairs(data.entries or {}) do
    if matches(entry, opts) then
      local copy = vim.deepcopy(entry)
      copy.display = M.format_entry(copy)
      table.insert(entries, copy)
    end
  end
  return entries
end

function History:record(entry)
  local query = normalize_query(entry.query)
  if query == "" then
    return nil
  end

  local data = self:read()
  local dedupe_key = table.concat({
    entry.connection_id or "",
    entry.project or "",
    entry.branch or "",
    query,
  }, "\0")

  local entries = {}
  local existing = nil
  for _, item in ipairs(data.entries or {}) do
    local item_key = table.concat({
      item.connection_id or "",
      item.project or "",
      item.branch or "",
      normalize_query(item.query),
    }, "\0")
    if item_key == dedupe_key then
      existing = item
    else
      table.insert(entries, item)
    end
  end

  local merged = vim.tbl_deep_extend("force", existing or {}, entry, {
    id = existing and existing.id or util.random_id("history"),
    query = query,
    query_preview = compact_query(query),
    executed_at = entry.executed_at or os.date("!%Y-%m-%dT%H:%M:%SZ"),
    count = (existing and existing.count or 0) + 1,
  })

  table.insert(entries, 1, merged)
  while #entries > self.max_entries do
    table.remove(entries)
  end
  self:write({ entries = entries })
  return merged
end

function M.format_entry(entry)
  local parts = {}
  if entry.project and entry.project ~= "" then
    table.insert(parts, entry.branch and ("%s/%s"):format(entry.project, entry.branch) or entry.project)
  end
  if entry.connection_name and entry.connection_name ~= "" then
    table.insert(parts, entry.connection_name)
  end
  if entry.executed_at and entry.executed_at ~= "" then
    local executed_at = entry.executed_at:gsub("T", " "):gsub("Z$", "")
    table.insert(parts, executed_at)
  end
  local prefix = #parts > 0 and ("[" .. table.concat(parts, " · ") .. "] ") or ""
  return prefix .. (entry.query_preview or compact_query(entry.query))
end

function M.list(opts)
  return History:new({}):list(opts)
end

function M.new(config)
  return History:new(config)
end

return M
