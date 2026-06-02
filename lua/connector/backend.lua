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

local function push_tail(buf, line, max)
  if #buf >= max then
    table.remove(buf, 1)
  end
  table.insert(buf, line)
end

local function normalize_lines(data)
  if not data then
    return {}
  end
  local out = {}
  for _, line in ipairs(data) do
    if line and line ~= "" then
      table.insert(out, line)
    end
  end
  return out
end

function M.install(config, opts)
  config = config or {}
  opts = opts or {}

  local root = util.plugin_root()
  local cargo = (config.backend and config.backend.cargo_bin) or "cargo"
  if vim.fn.executable(cargo) ~= 1 then
    error("cargo executable was not found: " .. tostring(cargo))
  end

  local show_output = opts.show_output
  if show_output == nil then
    show_output = true
  end

  local timeout_ms = opts.timeout_ms or (10 * 60 * 1000)
  local last_out, last_err = {}, {}
  local max_tail = opts.max_output_lines or 200

  local done, exit_code = false, nil
  local cmd = { cargo, "build", "--release", "--manifest-path", util.joinpath(root, "Cargo.toml") }

  local function emit(lines, is_err)
    if #lines == 0 then
      return
    end

    for _, line in ipairs(lines) do
      push_tail(is_err and last_err or last_out, line, max_tail)
      if opts.on_output then
        pcall(opts.on_output, line, is_err)
      end
    end

    if show_output then
      vim.schedule(function()
        if is_err then
          for _, line in ipairs(lines) do
            vim.api.nvim_err_writeln(line)
          end
        else
          vim.api.nvim_out_write(table.concat(lines, "\n") .. "\n")
        end
      end)
    end
  end

  local jobid = vim.fn.jobstart(cmd, {
    cwd = root,
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = function(_, data)
      emit(normalize_lines(data), false)
    end,
    on_stderr = function(_, data)
      emit(normalize_lines(data), true)
    end,
    on_exit = function(_, code)
      exit_code = code
      done = true
    end,
  })

  if jobid <= 0 then
    error("failed to start cargo build")
  end

  local ok = vim.wait(timeout_ms, function()
    return done
  end, 50)

  if not ok then
    vim.fn.jobstop(jobid)
    error("cargo build timed out")
  end

  if exit_code ~= 0 then
    local tail = vim.trim(table.concat(#last_err > 0 and last_err or last_out, "\n"))
    error(tail ~= "" and tail or "cargo build failed")
  end

  local built = repo_binary_path("release")
  if not vim.uv.fs_stat(built) then
    error("cargo build finished but binary was not found: " .. built)
  end

  local installed = M.installed_binary_path()
  util.ensure_dir(vim.fs.dirname(installed))
  if vim.uv.fs_stat(installed) then
    vim.uv.fs_unlink(installed)
  end
  local ok_copy, err = pcall(vim.uv.fs_copyfile, built, installed)
  if not ok_copy then
    error("failed copying backend binary: " .. tostring(err))
  end
  return installed
end

return M
