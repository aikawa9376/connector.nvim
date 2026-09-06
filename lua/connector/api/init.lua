local state = require("connector.api.state")

return setmetatable({
  setup = state.setup,
  current_config = state.config,
}, {
  __index = function(self, key)
    if key == "context" or key == "core" or key == "ui" then
      local module = require("connector.api." .. key)
      rawset(self, key, module)
      return module
    end
  end,
})
