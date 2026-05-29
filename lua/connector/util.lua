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

return M
