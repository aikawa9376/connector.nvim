if vim.g.loaded_connector == 1 then
  return
end
vim.g.loaded_connector = 1

local COMMAND_NAME = "Connector"

local commands = {
  open = function()
    require("connector").open()
  end,
  close = function()
    require("connector").close()
  end,
  toggle = function()
    require("connector").toggle()
  end,
  install = function()
    require("connector").install()
  end,
  execute = function(args)
    require("connector").execute(table.concat(args, " "))
  end,
  store = function(args)
    if #args < 2 then
      error("store requires at least format and output")
    end
    require("connector").store(args[1], args[2], { extra_arg = args[3] })
  end,
  history = function()
    local connector = require("connector")
    local entries = connector.history()
    vim.ui.select(vim.tbl_map(function(entry)
      return entry.display
    end, entries), { prompt = "Select query history" }, function(_choice, idx)
      local entry = idx and entries[idx] or nil
      if entry then
        connector.api.core.connection_execute(entry.connection_id, entry.query, function(call)
          if call then
            connector.api.ui.result_set_call(call)
            connector.open()
          end
        end)
      end
    end)
  end,
  scratchpads = function()
    require("connector").pick_scratchpad()
  end,
  scratchgrep = function(args)
    local search = table.concat(args or {}, " ")
    require("connector").grep_scratchpads({ search = search ~= "" and search or nil })
  end,
  tables = function()
    require("connector").pick_table()
  end,
  reload = function()
    local api = require("connector").api.core
    for _, source in ipairs(api.get_sources()) do
      api.source_reload(source:name())
    end
    require("connector").api.ui.drawer_refresh()
  end,
}

local function split_args(text)
  local args = {}
  for word in string.gmatch(text, "([^%s]+)") do
    table.insert(args, word)
  end
  return args
end

vim.api.nvim_create_user_command(COMMAND_NAME, function(opts)
  local args = split_args(opts.args)
  if #args == 0 then
    require("connector").toggle()
    return
  end
  local subcommand = table.remove(args, 1)
  local fn = commands[subcommand]
  if not fn then
    error("unsupported subcommand: " .. subcommand)
  end
  fn(args)
end, {
  nargs = "*",
  range = true,
  bang = true,
  -- lazy.nvim creates a placeholder :Connector command when using `cmd = "Connector"`.
  -- Overwrite it when the plugin is actually loaded.
  force = true,
  complete = function(_, cmdline)
    local args = split_args(cmdline:gsub("^" .. COMMAND_NAME, ""))
    if #args <= 1 then
      return vim.tbl_keys(commands)
    end
    if args[1] == "store" then
      if #args == 2 then
        return { "csv", "json", "table" }
      elseif #args == 3 then
        return { "file", "yank", "buffer" }
      end
    end
    return {}
  end,
})
