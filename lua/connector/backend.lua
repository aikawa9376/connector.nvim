local util = require("connector.util")

local M = {}

local function exe_name()
  return vim.fn.has("win32") == 1 and "connector-backend.exe" or "connector-backend"
end

function M.installed_binary_path()
  return util.joinpath(util.ensure_dir(util.data_path("connector", "bin")), exe_name())
end

local function repo_binary_path(mode)
  return util.joinpath(util.plugin_root(), "target", mode, exe_name())
end

function M.resolve_command(config)
  local backend = config.backend or {}
  if backend.command and backend.command ~= "" then
    return backend.command
  end

  local installed = M.installed_binary_path()
  if vim.uv.fs_stat(installed) then
    return installed
  end

  for _, mode in ipairs({ "release", "debug" }) do
    local candidate = repo_binary_path(mode)
    if vim.uv.fs_stat(candidate) then
      return candidate
    end
  end

  if vim.fn.executable(exe_name()) == 1 then
    return exe_name()
  end

  error("connector backend binary was not found. Run require('connector').install() first.")
end

local function parse_result(result)
  local output = vim.trim(result.stdout or "")
  if result.code ~= 0 then
    if output ~= "" then
      local ok, decoded = pcall(vim.json.decode, output)
      if ok and decoded.error then
        error(decoded.error)
      end
    end
    error(vim.trim(result.stderr or "") ~= "" and vim.trim(result.stderr) or "connector backend request failed")
  end
  if output == "" then
    return nil
  end
  local ok, decoded = pcall(vim.json.decode, output)
  if not ok then
    error("failed to decode backend response: " .. output)
  end
  return decoded
end

function M.request_sync(config, subcommand, payload)
  local result = vim.system({ M.resolve_command(config), subcommand }, {
    text = true,
    stdin = vim.json.encode(payload),
  }):wait()
  return parse_result(result)
end

function M.request_async(config, subcommand, payload, callback)
  return vim.system({ M.resolve_command(config), subcommand }, {
    text = true,
    stdin = vim.json.encode(payload),
  }, function(result)
    local ok, decoded = pcall(parse_result, result)
    vim.schedule(function()
      if ok then
        callback(nil, decoded)
      else
        callback(decoded)
      end
    end)
  end)
end

function M.install(config)
  config = config or {}
  local root = util.plugin_root()
  local cargo = (config.backend and config.backend.cargo_bin) or "cargo"
  local result = vim.system({ cargo, "build", "--release", "--manifest-path", util.joinpath(root, "Cargo.toml") }, {
    cwd = root,
    text = true,
  }):wait()
  if result.code ~= 0 then
    error(vim.trim(result.stderr) ~= "" and vim.trim(result.stderr) or "cargo build failed")
  end

  local built = repo_binary_path("release")
  local installed = M.installed_binary_path()
  util.ensure_dir(vim.fs.dirname(installed))
  if vim.uv.fs_stat(installed) then
    vim.uv.fs_unlink(installed)
  end
  local ok, err = pcall(vim.uv.fs_copyfile, built, installed)
  if not ok then
    error("failed copying backend binary: " .. tostring(err))
  end
  return installed
end

return M
