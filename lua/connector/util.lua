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

local function mapping_branch_key(branch)
  if branch and branch ~= "" then
    return branch
  end
  return "__default"
end

function M.set_project_mapping(project_or_root, namespace, branch)
  local root = type(project_or_root) == "table" and project_or_root.root or project_or_root
  branch = branch or (type(project_or_root) == "table" and project_or_root.branch or nil)
  if not root then return end

  local map = M.read_project_mappings()
  local current = map[root]
  if type(current) == "string" then
    local current_project = M.project_from_namespace(current)
    current = {
      [mapping_branch_key(current_project and current_project.branch or nil)] = current,
    }
  elseif type(current) ~= "table" then
    current = {}
  end

  current[mapping_branch_key(branch)] = namespace
  map[root] = current
  M.write_project_mappings(map)
end

function M.get_project_mapping(project_or_root, branch)
  local root = type(project_or_root) == "table" and project_or_root.root or project_or_root
  branch = branch or (type(project_or_root) == "table" and project_or_root.branch or nil)
  if not root then return nil end

  local map = M.read_project_mappings()
  local entry = map[root]
  if type(entry) == "string" then
    local mapped_project = M.project_from_namespace(entry)
    if branch and branch ~= "" then
      return mapped_project and mapped_project.branch == branch and entry or nil
    end
    return entry
  end
  if type(entry) ~= "table" then
    return nil
  end
  return entry[mapping_branch_key(branch)]
end

function M.remove_project_mapping(project_or_root, branch)
  local root = type(project_or_root) == "table" and project_or_root.root or project_or_root
  branch = branch or (type(project_or_root) == "table" and project_or_root.branch or nil)
  if not root then return end

  local map = M.read_project_mappings()
  local entry = map[root]
  if type(entry) == "table" and branch ~= nil then
    entry[mapping_branch_key(branch)] = nil
    if next(entry) == nil then
      map[root] = nil
    else
      map[root] = entry
    end
  else
    map[root] = nil
  end
  M.write_project_mappings(map)
end

function M.project_key(project)
  if not project then return nil end
  if project.root and project.root ~= "" then
    return "root:" .. project.root
  end
  if project.namespace and project.namespace ~= "" then
    return "namespace:" .. project.namespace
  end
  if project.name and project.name ~= "" then
    return "project:" .. project.name .. "/" .. (project.branch or "")
  end
  return nil
end

function M.project_db_ignores_file()
  return M.state_path("connector", "project_db_ignores.json")
end

function M.read_project_db_ignores()
  return M.read_json(M.project_db_ignores_file(), {})
end

function M.write_project_db_ignores(tbl)
  M.write_json(M.project_db_ignores_file(), tbl or {})
end

function M.is_project_database_ignored(project, connection_id, database)
  local project_key = M.project_key(project)
  if not project_key or not connection_id or not database or database == "" then
    return false
  end
  local ignores = M.read_project_db_ignores()
  return (ignores[project_key]
    and ignores[project_key][connection_id]
    and ignores[project_key][connection_id][database] == true) or false
end

function M.project_ignored_databases(project, connection_id)
  local project_key = M.project_key(project)
  if not project_key or not connection_id then
    return {}
  end
  local ignores = M.read_project_db_ignores()
  local databases = ignores[project_key] and ignores[project_key][connection_id] or {}
  -- Filter out any special markers (e.g. connection-level ignore markers)
  local items = {}
  for k, v in pairs(databases) do
    if k ~= "__connection__" and v == true then
      table.insert(items, k)
    end
  end
  table.sort(items)
  return items
end

function M.is_project_connection_ignored(project, connection_id)
  local project_key = M.project_key(project)
  if not project_key or not connection_id then
    return false
  end
  local ignores = M.read_project_db_ignores()
  return (ignores[project_key]
    and ignores[project_key][connection_id]
    and ignores[project_key][connection_id]["__connection__"] == true) or false
end

function M.project_ignored_connections(project)
  local project_key = M.project_key(project)
  if not project_key then
    return {}
  end
  local ignores = M.read_project_db_ignores()
  local conn_map = ignores[project_key] or {}
  local keys = {}
  for conn_id, dbs in pairs(conn_map) do
    if dbs and dbs["__connection__"] == true then
      table.insert(keys, conn_id)
    end
  end
  table.sort(keys)
  return keys
end

function M.set_project_connection_ignored(project, connection_id, ignored)
  local project_key = M.project_key(project)
  if not project_key then
    error("current SQL project is required to ignore connections")
  end
  if not connection_id or connection_id == "" then
    error("connection_id is required")
  end

  local ignores = M.read_project_db_ignores()
  ignores[project_key] = ignores[project_key] or {}
  ignores[project_key][connection_id] = ignores[project_key][connection_id] or {}
  if ignored then
    ignores[project_key][connection_id]["__connection__"] = true
  else
    ignores[project_key][connection_id]["__connection__"] = nil
    if next(ignores[project_key][connection_id]) == nil then
      ignores[project_key][connection_id] = nil
    end
    if next(ignores[project_key]) == nil then
      ignores[project_key] = nil
    end
  end
  M.write_project_db_ignores(ignores)
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

local MUTATING_SQL_KEYWORDS = {
  insert = true,
  update = true,
  delete = true,
  alter = true,
  drop = true,
  create = true,
  truncate = true,
  replace = true,
  merge = true,
  grant = true,
  revoke = true,
  comment = true,
  rename = true,
  call = true,
  exec = true,
  execute = true,
  vacuum = true,
  analyze = true,
  reindex = true,
  refresh = true,
}

function M.table_index_key(schema, tbl)
  if schema and schema ~= "" then
    return schema .. "\0" .. tbl
  end
  return tbl
end

function M.query_has_side_effects(query)
  if not query or query == "" then
    return false
  end

  local normalized = query
    :gsub("/%*.-%*/", " ")
    :gsub("%-%-[^\n]*", " ")
    :gsub("#[^\n]*", " ")
    :lower()

  for keyword in pairs(MUTATING_SQL_KEYWORDS) do
    if normalized:find("%f[%a]" .. keyword .. "%f[%A]") then
      return true
    end
  end

  return false
end

local function push_sql_statement(statements, chunk)
  local trimmed = vim.trim(chunk or "")
  if trimmed ~= "" then
    table.insert(statements, trimmed)
  end
end

local function match_dollar_quote_tag(text, pos)
  local rest = text:sub(pos)
  return rest:match("^%$[%a_][%w_]*%$") or rest:match("^%$%$")
end

function M.split_sql_statements(text)
  if not text or text == "" then
    return {}
  end

  local statements = {}
  local start_pos = 1
  local pos = 1
  local len = #text
  local state = "normal"
  local dollar_tag = nil

  while pos <= len do
    local ch = text:sub(pos, pos)
    local next_ch = pos < len and text:sub(pos + 1, pos + 1) or ""
    local prev_ch = pos > 1 and text:sub(pos - 1, pos - 1) or ""

    if state == "line_comment" then
      if ch == "\n" then
        state = "normal"
      end
      pos = pos + 1
    elseif state == "block_comment" then
      if ch == "*" and next_ch == "/" then
        state = "normal"
        pos = pos + 2
      else
        pos = pos + 1
      end
    elseif state == "single_quote" then
      if ch == "'" then
        if next_ch == "'" then
          pos = pos + 2
        elseif prev_ch == "\\" then
          pos = pos + 1
        else
          state = "normal"
          pos = pos + 1
        end
      else
        pos = pos + 1
      end
    elseif state == "double_quote" then
      if ch == '"' then
        if next_ch == '"' then
          pos = pos + 2
        else
          state = "normal"
          pos = pos + 1
        end
      else
        pos = pos + 1
      end
    elseif state == "backtick_quote" then
      if ch == "`" then
        if next_ch == "`" then
          pos = pos + 2
        else
          state = "normal"
          pos = pos + 1
        end
      else
        pos = pos + 1
      end
    elseif state == "dollar_quote" then
      if dollar_tag and text:sub(pos, pos + #dollar_tag - 1) == dollar_tag then
        state = "normal"
        pos = pos + #dollar_tag
        dollar_tag = nil
      else
        pos = pos + 1
      end
    else
      if ch == "-" and next_ch == "-" then
        state = "line_comment"
        pos = pos + 2
      elseif ch == "#" then
        state = "line_comment"
        pos = pos + 1
      elseif ch == "/" and next_ch == "*" then
        state = "block_comment"
        pos = pos + 2
      elseif ch == "'" then
        state = "single_quote"
        pos = pos + 1
      elseif ch == '"' then
        state = "double_quote"
        pos = pos + 1
      elseif ch == "`" then
        state = "backtick_quote"
        pos = pos + 1
      else
        local tag = match_dollar_quote_tag(text, pos)
        if tag then
          state = "dollar_quote"
          dollar_tag = tag
          pos = pos + #tag
        elseif ch == ";" then
          push_sql_statement(statements, text:sub(start_pos, pos - 1))
          start_pos = pos + 1
          pos = pos + 1
        else
          pos = pos + 1
        end
      end
    end
  end

  push_sql_statement(statements, text:sub(start_pos))
  return statements
end

function M.parse_query_table_references(query)
  if not query or query == "" then
    return {}
  end

  local matches = {}
  local seen = {}

  local function add(pos, schema, tbl)
    schema = schema ~= "" and schema or nil
    local key = M.table_index_key(schema, tbl)
    if seen[key] then
      return
    end
    seen[key] = true
    table.insert(matches, {
      pos = pos,
      schema = schema,
      table = tbl,
    })
  end

  local function add_unqualified(pos, tbl)
    if SQL_KEYWORDS[tbl:lower()] or tbl:find("%.") then
      return
    end
    add(pos, nil, tbl)
  end

  local function scan(pattern, callback)
    local init = 1
    while true do
      local start_pos, end_pos, a, b = query:find(pattern, init)
      if not start_pos then
        break
      end
      callback(start_pos, a, b)
      init = end_pos + 1
    end
  end

  scan("`([^`]+)`%.`([^`]+)`", function(pos, schema, tbl)
    add(pos, schema, tbl)
  end)
  scan('"([^"]+)"%."([^"]+)"', function(pos, schema, tbl)
    add(pos, schema, tbl)
  end)
  scan("[Ff][Rr][Oo][Mm]%s+([%w_]+)%.([%w_]+)", function(pos, schema, tbl)
    add(pos, schema, tbl)
  end)
  scan("[Jj][Oo][Ii][Nn]%s+([%w_]+)%.([%w_]+)", function(pos, schema, tbl)
    add(pos, schema, tbl)
  end)
  scan("[Ii][Nn][Tt][Oo]%s+([%w_]+)%.([%w_]+)", function(pos, schema, tbl)
    add(pos, schema, tbl)
  end)
  scan("[Uu][Pp][Dd][Aa][Tt][Ee]%s+([%w_]+)%.([%w_]+)", function(pos, schema, tbl)
    add(pos, schema, tbl)
  end)
  scan("[Ff][Rr][Oo][Mm]%s+`([^`]+)`", function(pos, tbl)
    add_unqualified(pos, tbl)
  end)
  scan('[Ff][Rr][Oo][Mm]%s+"([^"]+)"', function(pos, tbl)
    add_unqualified(pos, tbl)
  end)
  scan("[Ff][Rr][Oo][Mm]%s+([%w_%.]+)", function(pos, tbl)
    add_unqualified(pos, tbl)
  end)
  scan("[Jj][Oo][Ii][Nn]%s+`([^`]+)`", function(pos, tbl)
    add_unqualified(pos, tbl)
  end)
  scan('[Jj][Oo][Ii][Nn]%s+"([^"]+)"', function(pos, tbl)
    add_unqualified(pos, tbl)
  end)
  scan("[Jj][Oo][Ii][Nn]%s+([%w_%.]+)", function(pos, tbl)
    add_unqualified(pos, tbl)
  end)
  scan("[Ii][Nn][Tt][Oo]%s+`([^`]+)`", function(pos, tbl)
    add_unqualified(pos, tbl)
  end)
  scan("[Ii][Nn][Tt][Oo]%s+([%w_%.]+)", function(pos, tbl)
    add_unqualified(pos, tbl)
  end)
  scan("[Uu][Pp][Dd][Aa][Tt][Ee]%s+`([^`]+)`", function(pos, tbl)
    add_unqualified(pos, tbl)
  end)
  scan("[Uu][Pp][Dd][Aa][Tt][Ee]%s+([%w_%.]+)", function(pos, tbl)
    add_unqualified(pos, tbl)
  end)

  table.sort(matches, function(left, right)
    if left.pos == right.pos then
      return M.table_index_key(left.schema, left.table) < M.table_index_key(right.schema, right.table)
    end
    return left.pos < right.pos
  end)

  local refs = {}
  for _, match in ipairs(matches) do
    table.insert(refs, {
      schema = match.schema,
      table = match.table,
    })
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
  local was_modifiable = vim.bo[bufnr].modifiable
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = was_modifiable
end

function M.buf_append_text(bufnr, text, opts)
  opts = opts or {}
  local lines = vim.split(text or "", "\n", { plain = true })
  if #lines == 0 then
    lines = { "" }
  end

  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local current_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local buffer_empty = line_count == 1 and current_lines[1] == ""
  local last_line = current_lines[#current_lines] or ""

  if opts.leading_blank_line and not buffer_empty and last_line ~= "" then
    table.insert(lines, 1, "")
  end

  local start_line = buffer_empty and 0 or line_count
  local was_modifiable = vim.bo[bufnr].modifiable
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, start_line, line_count, false, lines)
  vim.bo[bufnr].modifiable = was_modifiable
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

function M.project_from_namespace(namespace)
  if not namespace or namespace == "" or namespace == "global" then
    return nil
  end

  local parts = vim.split(namespace, "/")
  local name = parts[1]
  local branch = #parts > 1 and table.concat(parts, "/", 2) or nil
  if not name or name == "" or name == "global" then
    return nil
  end

  local root = nil
  for mapped_root, mapped_entry in pairs(M.read_project_mappings()) do
    local namespaces = type(mapped_entry) == "table" and vim.tbl_values(mapped_entry) or { mapped_entry }
    for _, mapped_namespace in ipairs(namespaces) do
      if type(mapped_namespace) == "string"
        and (mapped_namespace == namespace or mapped_namespace:match("^" .. vim.pesc(name) .. "/")) then
        root = mapped_root
        break
      end
    end
    if root then
      break
    end
  end

  return {
    name = name,
    root = root,
    branch = branch,
    namespace = namespace,
    is_scratchpad = true,
  }
end

function M.resolve_project(path)
  path = path or vim.api.nvim_buf_get_name(0)
  if M.is_scratchpad_path(path) then
    local scratch_root = M.state_path("connector", "scratchpads")
    local relative = path:sub(#scratch_root + 2)
    local namespace = vim.fs.dirname(relative)
    if namespace == "." then namespace = relative:match("^([^/]+)") end
    return M.project_from_namespace(namespace)
  end

  local root = M.find_project_root(path)
  if not root then return nil end
  return {
    name = vim.fs.basename(root),
    root = root,
    branch = M.get_git_branch(root),
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
