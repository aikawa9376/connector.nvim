-- CONNECTOR_BENCH_ROOT may point to a checkout to compare. No real connections
-- or user state are loaded. Set CONNECTOR_BENCH_CUSTOM=1 for a custom directory.
vim.opt.rtp:prepend(vim.env.CONNECTOR_BENCH_ROOT or vim.fn.getcwd())
local temp = vim.fn.tempname()
vim.env.XDG_STATE_HOME = temp .. '/state'
vim.env.XDG_DATA_HOME = temp .. '/data'
vim.env.CONNECTOR_CONNECTIONS = '[]'
local cfg = { sources = {}, history = { path = temp .. '/history.json' } }
if vim.env.CONNECTOR_BENCH_CUSTOM == '1' then
  cfg.editor = { directory = temp .. '/custom-scratchpads' }
end
local start = vim.uv.hrtime()
local connector = require('connector')
connector.setup(cfg)
local setup_ms = (vim.uv.hrtime() - start) / 1e6
local system, git_count = vim.system, 0
vim.system = function(cmd, ...)
  if cmd[1] == 'git' then git_count = git_count + 1 end
  return system(cmd, ...)
end
start = vim.uv.hrtime()
connector.open()
local open_ms = (vim.uv.hrtime() - start) / 1e6
vim.wait(20, function() return false end)
print(vim.json.encode({ setup_ms = setup_ms, open_ms = open_ms, git_processes = git_count }))
connector.close()
vim.fn.delete(temp, 'rf')
vim.cmd('qa!')
