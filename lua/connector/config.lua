local config = {}

function config.default()
  local sources = require("connector.sources")
  return {
    default_connection = nil,
    backend = {
      command = nil,
      cargo_bin = "cargo",
    },
    sources = {
      sources.EnvSource:new("CONNECTOR_CONNECTIONS"),
      sources.FileSource:new(vim.fs.joinpath(vim.fn.stdpath("state"), "connector", "connections.json")),
    },
    extra_helpers = {},
    drawer = {
      disable_help = false,
      disable_candies = false,
      candies = require("connector.ui.candies").drawer_defaults(),
      mappings = {
        { key = "r", mode = "n", action = "refresh" },
        { key = "<CR>", mode = "n", action = "action_1" },
        { key = "cw", mode = "n", action = "action_2" },
        { key = "dd", mode = "n", action = "action_3" },
        { key = "o", mode = "n", action = "toggle" },
      },
    },
    result = {
      page_size = 100,
      focus_result = false,
      mappings = {
        { key = "L", mode = "n", action = "page_next" },
        { key = "H", mode = "n", action = "page_prev" },
        { key = "E", mode = "n", action = "page_last" },
        { key = "F", mode = "n", action = "page_first" },
        { key = "yaj", mode = "n", action = "yank_current_json" },
        { key = "yaj", mode = "v", action = "yank_selection_json" },
        { key = "yaJ", mode = "n", action = "yank_all_json" },
        { key = "yac", mode = "n", action = "yank_current_csv" },
        { key = "yac", mode = "v", action = "yank_selection_csv" },
        { key = "yaC", mode = "n", action = "yank_all_csv" },
        { key = "<CR>", mode = "n", action = "edit_cell" },
        { key = "i", mode = "n", action = "edit_cell" },
        { key = "<C-c>", mode = "n", action = "cancel_call" },
      },
    },
    editor = {
      directory = vim.fs.joinpath(vim.fn.stdpath("state"), "connector", "scratchpads"),
      mappings = {
        { key = "BB", mode = "v", action = "run_selection" },
        { key = "BB", mode = "n", action = "run_file" },
        { key = "<CR>", mode = "n", action = "run_under_cursor" },
      },
    },
    call_log = {
      disable_candies = false,
      candies = require("connector.ui.candies").call_log_defaults(),
      mappings = {
        { key = "<CR>", mode = "n", action = "show_result" },
        { key = "<C-c>", mode = "n", action = "cancel_call" },
      },
    },
    window_layout = require("connector.layouts").Default:new(),
  }
end

function config.merge_with_default(changes)
  changes = changes or {}
  local merged = vim.tbl_deep_extend("force", config.default(), changes)
  if changes.sources and #changes.sources > 0 then
    merged.sources = changes.sources
  end
  if changes.window_layout then
    merged.window_layout = changes.window_layout
  end
  return merged
end

function config.validate(cfg)
  vim.validate({
    sources = { cfg.sources, "table" },
    extra_helpers = { cfg.extra_helpers, "table" },
    result = { cfg.result, "table" },
    editor = { cfg.editor, "table" },
    drawer = { cfg.drawer, "table" },
    call_log = { cfg.call_log, "table" },
    window_layout = { cfg.window_layout, "table" },
  })
  vim.validate({
    window_layout_open = { cfg.window_layout.open, "function" },
    window_layout_close = { cfg.window_layout.close, "function" },
    window_layout_is_open = { cfg.window_layout.is_open, "function" },
  })
end

return config
