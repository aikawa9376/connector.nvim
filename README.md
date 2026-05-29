# connector.nvim

Neovim database client inspired by `nvim-dbee`, with a **Rust backend** and **Lua frontend**.

## Current scope

- 4-pane workflow: drawer, editor, result, call log
- connection sources: memory, env, file
- query execution from editor, current line, or selection
- result paging and CSV/JSON/table export
- structure browsing for SQLite, PostgreSQL, and MySQL
- connection CRUD for writable sources
- database switching for PostgreSQL and MySQL
- secret expansion with `{{ env "VAR" }}` and `{{ exec "cmd" }}`

## Installation

`connector.nvim` expects Neovim `>= 0.10`.

### lazy.nvim

```lua
{
  "aikawa9376/connector.nvim",
  build = function()
    require("connector").install()
  end,
  config = function()
    require("connector").setup()
  end,
}
```

## Usage

```lua
require("connector").open()
require("connector").close()
require("connector").toggle()
require("connector").execute("select 1")
require("connector").store("csv", "file", { extra_arg = "/tmp/result.csv" })
```

The same entrypoints are exposed through `:Connector`.

## Default configuration

```lua
require("connector").setup({
  sources = {
    require("connector.sources").EnvSource:new("CONNECTOR_CONNECTIONS"),
    require("connector.sources").FileSource:new(vim.fn.stdpath("state") .. "/connector/connections.json"),
  },
})
```

Connection objects look like this:

```lua
{
  id = "optional-unique-id",
  name = "Local SQLite",
  type = "sqlite",
  url = "~/data/app.db",
}
```

For PostgreSQL and MySQL use URL connection strings.

## Sources

- `MemorySource`
- `EnvSource`
- `FileSource`

Example environment variable:

```sh
export CONNECTOR_CONNECTIONS='[
  {
    "name": "Local Postgres",
    "type": "postgres",
    "url": "postgres://postgres:postgres@localhost:5432/postgres"
  }
]'
```

## Drawer workflow

- `<CR>` select/open the node under cursor
- `o` toggle a tree node
- `cw` edit connection or rename scratchpad
- `dd` delete connection or scratchpad
- `r` refresh

## Editor workflow

- `BB` in visual mode runs the selection
- `BB` in normal mode runs the whole scratchpad
- `<CR>` runs the current line

## Result workflow

- `L` / `H` next/previous page
- `E` / `F` last/first page
- `yaj` / `yac` yank current row or selection as JSON / CSV
- `yaJ` / `yaC` yank all rows as JSON / CSV
- `<C-c>` cancel the active call

## Backend

The backend lives in this repository and builds to `connector-backend`. `require("connector").install()`
builds it with Cargo and copies the binary into Neovim's data directory.
