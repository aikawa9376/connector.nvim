local util = require("connector.util")

local sources = {}

sources.FileSource = {}

function sources.FileSource:new(path)
  assert(path, "path is required")
  local o = { path = path }
  setmetatable(o, self)
  self.__index = self
  return o
end

function sources.FileSource:name()
  return vim.fs.basename(self.path)
end

function sources.FileSource:load()
  local raw = util.read_file(self.path)
  if not raw or raw == "" then
    return {}
  end
  local filtered = {}
  for _, line in ipairs(vim.split(raw, "\n")) do
    if not vim.startswith(vim.trim(line), "//") then
      table.insert(filtered, line)
    end
  end
  local ok, data = pcall(vim.json.decode, table.concat(filtered, "\n"))
  if not ok then
    error(("failed to decode JSON file: %s"):format(self.path))
  end
  local items = {}
  for _, conn in ipairs(data or {}) do
    if type(conn) == "table" and conn.url and conn.type then
      conn.id = conn.id or util.random_id("file-source")
      table.insert(items, conn)
    end
  end
  return items
end

function sources.FileSource:create(details)
  local data = self:load()
  details.id = details.id or util.random_id("file-source")
  table.insert(data, details)
  util.write_json(self.path, data)
  return details.id
end

function sources.FileSource:update(id, details)
  local data = self:load()
  for index, conn in ipairs(data) do
    if conn.id == id then
      details.id = id
      data[index] = details
      util.write_json(self.path, data)
      return
    end
  end
  error("connection not found: " .. id)
end

function sources.FileSource:delete(id)
  local data = self:load()
  local new_items = {}
  for _, conn in ipairs(data) do
    if conn.id ~= id then
      table.insert(new_items, conn)
    end
  end
  util.write_json(self.path, new_items)
end

function sources.FileSource:file()
  return self.path
end

sources.EnvSource = {}

function sources.EnvSource:new(var)
  assert(var, "env variable name is required")
  local o = { var = var }
  setmetatable(o, self)
  self.__index = self
  return o
end

function sources.EnvSource:name()
  return self.var
end

function sources.EnvSource:load()
  local raw = vim.env[self.var]
  if not raw or raw == "" then
    return {}
  end
  local ok, data = pcall(vim.json.decode, raw)
  if not ok then
    error(("could not parse connections from env: %s"):format(self.var))
  end
  local items = {}
  for index, conn in ipairs(data) do
    if type(conn) == "table" and conn.url and conn.type then
      conn.id = conn.id or ("env-" .. self.var .. "-" .. index)
      table.insert(items, conn)
    end
  end
  return items
end

sources.MemorySource = {}

function sources.MemorySource:new(conns, name)
  local o = { conns = {}, display_name = name or "memory" }
  for index, conn in ipairs(conns or {}) do
    if type(conn) == "table" and conn.url and conn.type then
      conn.id = conn.id or ("memory-" .. (name or "memory") .. "-" .. index)
      table.insert(o.conns, conn)
    end
  end
  setmetatable(o, self)
  self.__index = self
  return o
end

function sources.MemorySource:name()
  return self.display_name
end

function sources.MemorySource:load()
  return vim.deepcopy(self.conns)
end

return sources
