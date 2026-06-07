local util = require("connector.util")

local M = {}

---@class connector.sql.Dialect
---@field kind string
---@field quote_identifier fun(self: connector.sql.Dialect, name: string): string
---@field qualify_table fun(self: connector.sql.Dialect, schema: string|nil, tbl: string): string
---@field placeholder fun(self: connector.sql.Dialect, _index: integer|nil): string

local registry = {}

local function normalize_kind(kind)
  kind = (kind or ""):lower()
  if kind == "" then
    return "sqlite"
  end
  return kind
end

---Register/override a dialect.
---@param kind string
---@param spec table
function M.register(kind, spec)
  registry[normalize_kind(kind)] = spec or {}
end

local function default_dialect(kind)
  kind = normalize_kind(kind)
  return {
    kind = kind,
    quote_identifier = function(_, name)
      return util.quote_identifier(kind, name)
    end,
    qualify_table = function(_, schema, tbl)
      return util.qualify_table(kind, schema, tbl)
    end,
    -- NOTE: The execute() path runs raw SQL (no param binding). Placeholders are for user editing only.
    placeholder = function(_, _index)
      return "?"
    end,
  }
end

---Get a dialect implementation for a connection type.
---@param kind string|nil
---@return connector.sql.Dialect
function M.for_kind(kind)
  kind = normalize_kind(kind)
  local base = default_dialect(kind)
  local override = registry[kind]
  if type(override) ~= "table" then
    return base
  end
  return vim.tbl_extend("force", base, override)
end

-- Built-ins: intentionally minimal; util already encodes mysql/sqlite schema/quote behavior.
M.register("sqlite", {})
M.register("sqlite3", {})
M.register("postgres", {})
M.register("postgresql", {})
M.register("pg", {})
M.register("redshift", {})
M.register("mysql", {})
M.register("mariadb", {})
M.register("duck", {})
M.register("duckdb", {})
M.register("clickhouse", {})
M.register("sqlserver", {})
M.register("mssql", {})
M.register("redis", {})
M.register("mongo", {})
M.register("mongodb", {})
M.register("oracle", {})

return M
