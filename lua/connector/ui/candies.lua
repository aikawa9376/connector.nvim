local M = {}

function M.drawer_defaults()
  return {
    history = { icon = "", icon_highlight = "Constant", text_highlight = "" },
    note = { icon = "", icon_highlight = "Character", text_highlight = "" },
    connection = { icon = "󱘖", icon_highlight = "SpecialChar", text_highlight = "" },
    connection_active = { icon = "󰪩", icon_highlight = "Title", text_highlight = "Title" },
    database_switch = { icon = "", icon_highlight = "Character", text_highlight = "" },
    schema = { icon = "", icon_highlight = "Directory", text_highlight = "" },
    table = { icon = "", icon_highlight = "Conditional", text_highlight = "" },
    view = { icon = "", icon_highlight = "Debug", text_highlight = "" },
    column = { icon = "󰠵", icon_highlight = "WarningMsg", text_highlight = "" },
    add = { icon = "", icon_highlight = "String", text_highlight = "String" },
    edit = { icon = "󰏫", icon_highlight = "Directory", text_highlight = "Directory" },
    remove = { icon = "󰆴", icon_highlight = "Error", text_highlight = "Error" },
    help = { icon = "󰋖", icon_highlight = "Title", text_highlight = "Title" },
    source = { icon = "󰃖", icon_highlight = "MoreMsg", text_highlight = "MoreMsg" },
    none = { icon = " ", icon_highlight = "", text_highlight = "" },
    none_dir = { icon = "", icon_highlight = "Directory", text_highlight = "" },
  }
end

function M.call_log_defaults()
  return {
    executing = { icon = "󰑐", icon_highlight = "Constant", text_highlight = "Constant" },
    failed = { icon = "󰑐", icon_highlight = "Error", text_highlight = "" },
    archived = { icon = "", icon_highlight = "Title", text_highlight = "" },
    canceled = { icon = "", icon_highlight = "Error", text_highlight = "" },
    unknown = { icon = "", icon_highlight = "Identifier", text_highlight = "" },
  }
end

function M.get(candies, key, fallback_key)
  local candy = candies[key]
  if candy then
    return candy
  end
  if fallback_key then
    return candies[fallback_key] or {}
  end
  return {}
end

function M.state_initials(state)
  if not state or state == "" then
    return "  "
  end
  local initials = ""
  for word in state:gmatch("[^_]+") do
    initials = initials .. word:sub(1, 1)
  end
  if #initials < 2 then
    initials = initials .. string.rep(" ", 2 - #initials)
  end
  return initials
end

return M
