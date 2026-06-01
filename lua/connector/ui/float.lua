local window = require("connector.ui.window")

local M = {}

function M.editor(file, opts)
  opts = vim.tbl_extend("force", {
    title = vim.fn.fnamemodify(file, ":t"),
    border = "rounded",
    on_save = nil,
  }, opts or {})

  local path = vim.fn.fnamemodify(file, ":p")
  local bufnr = vim.fn.bufadd(path)
  vim.fn.bufload(bufnr)
  vim.bo[bufnr].bufhidden = "delete"
  if path:match("%.json$") then
    vim.bo[bufnr].filetype = "json"
  end

  local winid = window.open_centered(bufnr, true, {
    border = opts.border,
    title = opts.title,
    title_pos = "center",
    zindex = 150,
  })

  local function close()
    if not vim.api.nvim_win_is_valid(winid) then
      return
    end
    if vim.bo[bufnr].modified then
      local choice = vim.fn.confirm(
        ("Save changes to %s?"):format(opts.title),
        "&Yes\n&No\n&Cancel",
        2
      )
      if choice == 1 then
        vim.api.nvim_buf_call(bufnr, function()
          vim.cmd("write")
        end)
      elseif choice == 3 then
        return
      end
    end
    pcall(vim.api.nvim_win_close, winid, true)
  end

  vim.keymap.set("n", "q", close, { buffer = bufnr, silent = true })
  vim.keymap.set("n", "<Esc>", close, { buffer = bufnr, silent = true })

  if opts.on_save then
    vim.api.nvim_create_autocmd("BufWritePost", {
      buffer = bufnr,
      callback = opts.on_save,
    })
  end
end

return M
