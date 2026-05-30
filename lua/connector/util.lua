local M = {}

local uv = vim.uv or vim.loop

function M.notify(message, level)
  vim.schedule(function()
    vim.notify(message, level or vim.log.levels.INFO, { title = "connector.nvim" })
  end)
end

function M.plugin_root()
  local source = debug.getinfo(1, "S").source:sub(2)
  local cargo = vim.fs.find("Cargo.toml", { path = source, upward = true, type = "file" })[1]
  return cargo and vim.fs.dirname(cargo) or vim.fn.getcwd()
end

function M.joinpath(...)
  return vim.fs.joinpath(...)
end

function M.state_path(...)
  return M.joinpath(vim.fn.stdpath("state"), ...)
end

function M.data_path(...)
  return M.joinpath(vim.fn.stdpath("data"), ...)
end

function M.ensure_dir(path)
  vim.fn.mkdir(path, "p")
  return path
end

function M.read_file(path)
  local fd = io.open(path, "r")
  if not fd then
    return nil
  end
  local content = fd:read("*a")
  fd:close()
  return content
end

function M.write_file(path, content)
  M.ensure_dir(vim.fs.dirname(path))
  local fd = assert(io.open(path, "w"))
  fd:write(content)
  fd:close()
end

function M.read_json(path, fallback)
  local content = M.read_file(path)
  if not content or content == "" then
    return fallback
  end
  local ok, decoded = pcall(vim.json.decode, content)
  if not ok then
    error(("failed to decode JSON file: %s"):format(path))
  end
  return decoded
end

function M.write_json(path, value)
  M.write_file(path, vim.json.encode(value))
end

-- Persistent project -> namespace mappings (to handle renames)
function M.project_mappings_file()
  return M.state_path("connector", "project_mappings.json")
end

function M.read_project_mappings()
  return M.read_json(M.project_mappings_file(), {})
end

function M.write_project_mappings(tbl)
  M.write_json(M.project_mappings_file(), tbl or {})
end

function M.set_project_mapping(root, namespace)
  if not root then return end
  local map = M.read_project_mappings()
  map[root] = namespace
  M.write_project_mappings(map)
end

function M.get_project_mapping(root)
  if not root then return nil end
  local map = M.read_project_mappings()
  return map[root]
end

function M.remove_project_mapping(root)
  local map = M.read_project_mappings()
  map[root] = nil
  M.write_project_mappings(map)
end

function M.random_id(prefix)
  prefix = prefix or "id"
  return ("%s-%x-%x"):format(prefix, uv.hrtime(), math.random(0, 0xffffff))
end

function M.slugify(value)
  local slug = value:lower():gsub("[^%w_%-]+", "-"):gsub("%-+", "-"):gsub("^%-", ""):gsub("%-$", "")
  if slug == "" then
    slug = "scratchpad"
  end
  return slug
end

function M.expand_connection(connection)
  local copy = vim.deepcopy(connection)
  copy.url = M.expand_template(copy.url or "")
  if copy.type == "sqlite" or copy.type == "sqlite3" then
    copy.url = vim.fn.expand(copy.url)
  end
  return copy
end

function M.expand_template(input)
  local output = input
  output = output:gsub("{{%s*env%s+([\"`])([^\"`]+)%1%s*}}", function(_, key)
    return vim.env[key] or ""
  end)
  output = output:gsub("{{%s*exec%s+([\"`])([^\"`]+)%1%s*}}", function(_, command)
    local result = vim.system({ "sh", "-lc", command }, { text = true }):wait()
    if result.code ~= 0 then
      error(result.stderr ~= "" and result.stderr or ("command failed: " .. command))
    end
    return vim.trim(result.stdout)
  end)
  return output
end

function M.normalize_range(from, to, length)
  from = from or 0
  to = to or length
  if from < 0 then
    from = length + 1 + from
  end
  if to < 0 then
    to = length + 1 + to
  end
  from = math.max(0, math.min(from, length))
  to = math.max(from, math.min(to, length))
  return from, to
end

function M.value_to_string(value)
  if value == nil or value == vim.NIL then
    return "NULL"
  end
  local kind = type(value)
  if kind == "string" then
    return value
  elseif kind == "number" or kind == "boolean" then
    return tostring(value)
  elseif kind == "table" then
    return vim.json.encode(value)
  end
  return tostring(value)
end

function M.display_width(text)
  text = text or ""
  if text == "" then
    return 0
  end
  return vim.fn.strdisplaywidth(text)
end

function M.pad_left(text, width)
  local gap = width - M.display_width(text)
  if gap <= 0 then
    return text
  end
  return string.rep(" ", gap) .. text
end

function M.pad_right(text, width)
  local gap = width - M.display_width(text)
  if gap <= 0 then
    return text
  end
  return text .. string.rep(" ", gap)
end

function M.csv_escape(value)
  local text = M.value_to_string(value)
  if text:find('[,"\n]') then
    return '"' .. text:gsub('"', '""') .. '"'
  end
  return text
end

function M.quote_identifier(connection_type, value)
  local quote = connection_type == "mysql" and "`" or '"'
  local escaped = value:gsub(quote, quote .. quote)
  return quote .. escaped .. quote
end

function M.qualify_table(connection_type, schema, tbl)
  if schema and schema ~= "" and connection_type ~= "sqlite" then
    return ("%s.%s"):format(M.quote_identifier(connection_type, schema), M.quote_identifier(connection_type, tbl))
  end
  return M.quote_identifier(connection_type, tbl)
end

function M.render_helper(template, vars)
  return (template:gsub("{{%s*%.([A-Za-z_]+)%s*}}", function(key)
    return vars[key] or ""
  end))
end

function M.strip_identifier_quotes(value)
  return (value:gsub('^"', ""):gsub('"$', ""):gsub("^`", ""):gsub("`$", ""))
end

function M.parse_editable_select(query)
  if not query or query == "" then
    return nil
  end

  local trimmed = vim.trim(query):gsub(";%s*$", "")
  local lowered = trimmed:lower()
  if not lowered:match("^select%s+") then
    return nil
  end

  for _, pattern in ipairs({
    "%f[%a]join%f[%A]",
    "%f[%a]union%f[%A]",
    "%f[%a]group%s+by%f[%A]",
    "%f[%a]having%f[%A]",
    "%f[%a]distinct%f[%A]",
    "%f[%a]intersect%f[%A]",
    "%f[%a]except%f[%A]",
    "%f[%a]returning%f[%A]",
    "^with%s+",
  }) do
    if lowered:find(pattern) then
      return nil
    end
  end

  local select_list, from_target = trimmed:match("^%s*[Ss][Ee][Ll][Ee][Cc][Tt]%s+(.-)%s+[Ff][Rr][Oo][Mm]%s+([^%s;]+)")
  if not select_list or vim.trim(select_list) ~= "*" then
    return nil
  end

  if from_target:find("%(") then
    return nil
  end

  local parts = {}
  for part in from_target:gmatch("[^%.]+") do
    table.insert(parts, M.strip_identifier_quotes(vim.trim(part)))
  end

  if #parts == 1 then
    return { table = parts[1], schema = nil }
  elseif #parts == 2 then
    return { table = parts[2], schema = parts[1] }
  end

  return nil
end

local SQL_KEYWORDS = {
  select = true,
  from = true,
  where = true,
  join = true,
  inner = true,
  left = true,
  right = true,
  outer = true,
  cross = true,
  on = true,
  as = true,
  ["and"] = true,
  ["or"] = true,
  ["not"] = true,
  null = true,
  limit = true,
  offset = true,
  order = true,
  by = true,
  group = true,
  having = true,
  union = true,
  into = true,
  update = true,
  set = true,
  values = true,
  insert = true,
  delete = true,
  dual = true,
}

function M.table_index_key(schema, tbl)
  if schema and schema ~= "" then
    return schema .. "\0" .. tbl
  end
  return tbl
end

function M.parse_query_table_references(query)
  if not query or query == "" then
    return {}
  end

  local refs = {}
  local seen = {}

  local function add(schema, tbl)
    schema = schema ~= "" and schema or nil
    local key = M.table_index_key(schema, tbl)
    if seen[key] then
      return
    end
    seen[key] = true
    table.insert(refs, { schema = schema, table = tbl })
  end

  local function add_unqualified(tbl)
    if SQL_KEYWORDS[tbl:lower()] or tbl:find("%.") then
      return
    end
    add(nil, tbl)
  end

  for schema, tbl in query:gmatch("`([^`]+)`%.`([^`]+)`") do
    add(schema, tbl)
  end

  for schema, tbl in query:gmatch('"([^"]+)"%."([^"]+)"') do
    add(schema, tbl)
  end

  for schema, tbl in query:gmatch("[Ff][Rr][Oo][Mm]%s+([%w_]+)%.([%w_]+)") do
    add(schema, tbl)
  end

  for schema, tbl in query:gmatch("[Jj][Oo][Ii][Nn]%s+([%w_]+)%.([%w_]+)") do
    add(schema, tbl)
  end

  for schema, tbl in query:gmatch("[Ii][Nn][Tt][Oo]%s+([%w_]+)%.([%w_]+)") do
    add(schema, tbl)
  end

  for schema, tbl in query:gmatch("[Uu][Pp][Dd][Aa][Tt][Ee]%s+([%w_]+)%.([%w_]+)") do
    add(schema, tbl)
  end

  for tbl in query:gmatch("[Ff][Rr][Oo][Mm]%s+`([^`]+)`") do
    add_unqualified(tbl)
  end

  for tbl in query:gmatch('[Ff][Rr][Oo][Mm]%s+"([^"]+)"') do
    add_unqualified(tbl)
  end

  for tbl in query:gmatch("[Ff][Rr][Oo][Mm]%s+([%w_]+)") do
    add_unqualified(tbl)
  end

  for tbl in query:gmatch("[Jj][Oo][Ii][Nn]%s+`([^`]+)`") do
    add_unqualified(tbl)
  end

  for tbl in query:gmatch('[Jj][Oo][Ii][Nn]%s+"([^"]+)"') do
    add_unqualified(tbl)
  end

  for tbl in query:gmatch("[Jj][Oo][Ii][Nn]%s+([%w_]+)") do
    add_unqualified(tbl)
  end

  for tbl in query:gmatch("[Ii][Nn][Tt][Oo]%s+`([^`]+)`") do
    add_unqualified(tbl)
  end

  for tbl in query:gmatch("[Ii][Nn][Tt][Oo]%s+([%w_]+)") do
    add_unqualified(tbl)
  end

  for tbl in query:gmatch("[Uu][Pp][Dd][Aa][Tt][Ee]%s+`([^`]+)`") do
    add_unqualified(tbl)
  end

  for tbl in query:gmatch("[Uu][Pp][Dd][Aa][Tt][Ee]%s+([%w_]+)") do
    add_unqualified(tbl)
  end

  return refs
end

function M.apply_buffer_mappings(bufnr, mappings, callback)
  for _, mapping in ipairs(mappings or {}) do
    vim.keymap.set(mapping.mode, mapping.key, function()
      callback(mapping.action)
    end, vim.tbl_extend("force", { buffer = bufnr, nowait = true, silent = true }, mapping.opts or {}))
  end
end

function M.table_keys_sorted(input)
  local keys = vim.tbl_keys(input or {})
  table.sort(keys)
  return keys
end

function M.sorted_copy(items, sorter)
  local copy = vim.deepcopy(items or {})
  table.sort(copy, sorter)
  return copy
end

function M.buf_set_lines(bufnr, lines)
  vim.api.nvim_buf_set_option(bufnr, "modifiable", true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(bufnr, "modifiable", false)
end


function M.find_project_root(path)
  path = path or vim.api.nvim_buf_get_name(0)
  if path == "" then path = vim.fn.getcwd() end
  local markers = { ".git", "package.json", "Cargo.toml", "go.mod", "Makefile" }
  local found = vim.fs.find(markers, { path = path, upward = true })[1]
  if found then return vim.fs.dirname(found) end
  return nil
end

function M.is_scratchpad_path(path)
  local scratch_root = M.state_path("connector", "scratchpads")
  return vim.startswith(path, scratch_root)
end

function M.resolve_project(path)
  path = path or vim.api.nvim_buf_get_name(0)
  if M.is_scratchpad_path(path) then
    local scratch_root = M.state_path("connector", "scratchpads")
    local relative = path:sub(#scratch_root + 2)
    local namespace = relative:match("^([^/]+)")
    if namespace and namespace ~= "global" then
      return {
        name = namespace,
        root = nil,
        is_scratchpad = true,
      }
    end
    return nil
  end

  local root = M.find_project_root(path)
  if not root then return nil end
  return {
    name = vim.fs.basename(root),
    root = root,
  }
end

function M.get_git_branch(path)
  path = path or vim.api.nvim_buf_get_name(0)
  if path == "" then path = vim.fn.getcwd() end
  local root = M.find_project_root(path)
  if not root then return nil end
  local result = vim.system({ "git", "-C", root, "branch", "--show-current" }, { text = true }):wait()
  if result.code == 0 then
    local branch = vim.trim(result.stdout)
    return branch ~= "" and branch or nil
  end
  return nil
end

return M
