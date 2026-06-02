# connector.nvim

Neovim database client inspired by `nvim-dbee`, with a **Rust backend** and **Lua frontend**.

## Current scope

- 4-pane workflow: drawer, editor, result, call log
- connection sources: memory, env, file
- query execution from editor, current line, or selection
- result paging and CSV/JSON/table export
- in-cell updates for simple `select * from table ...` result sets
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
require("connector").scratchpads_fzf_source()
require("connector").pick_scratchpad() -- requires fzf-lua for the picker UI
require("connector").grep_scratchpads() -- requires fzf-lua
require("connector").pick_table() -- uses fzf-lua w/ table-definition preview when available
```

The same entrypoints are exposed through `:Connector`.

Additional commands:

- `:Connector scratchpads` pick a scratchpad (fzf-lua)
- `:Connector scratchgrep [query...]` grep scratchpads (fzf-lua)
- `:Connector tables` pick a table (fzf-lua preview when available)

## Default configuration

```lua
require("connector").setup({
  sources = {
    require("connector.sources").EnvSource:new("CONNECTOR_CONNECTIONS"),
    require("connector.sources").FileSource:new(vim.fn.stdpath("state") .. "/connector/connections.json"),
  },
})
```

## blink.cmp

`connector.nvim` now exposes a blink.cmp source instead of wiring `omnifunc` into scratchpads.

```lua
require("connector").setup()

require("blink.cmp").setup({
  sources = {
    default = { "lsp", "path", "buffer", "connector" },
    providers = {
      connector = require("connector").blink_source(),
    },
  },
})
```

You do **not** need to specify a database in the blink config. The source reuses connector's existing
connection/structure metadata and only enables itself in SQL buffers.

You can override blink provider fields directly:

```lua
providers = {
  connector = require("connector").blink_source({ name = "CO" }),
}
```

If you need to pass connector-specific source options together with provider overrides, use
`source = { ... }` / `provider = { ... }`.

The source completes:

- table names across configured connections, with connection / database context in the docs
- columns for the current SQL statement when the table can be inferred from `FROM` / `JOIN` / aliases like `u.`

## Sources

- `MemorySource`
- `EnvSource`
- `FileSource`

A typical connection entry looks like this:

```lua
{
  id = "optional-unique-id",
  name = "Local SQLite",
  type = "sqlite",
  url = "~/data/app.db",
}
```

For PostgreSQL and MySQL use URL connection strings.

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

- `<CR>` select/open the node under cursor. On a table or column this opens a menu to generate SQL templates (Select/Update/Delete/Insert/DDL). Visual selection of columns is supported — use `v`/`V` to pick multiple columns before `<CR>`.
- `o` toggle (expand/collapse) the node under cursor
- `cw` edit connection details or rename a scratchpad
- `dd` delete connection or scratchpad (use with care)
- `i` ignore / unignore a database or connection for the current project
- `a` add a new connection (context-aware: adds to the selected source/connection)
- `f` toggle the "project only" scratchpad filter
- `r` refresh the drawer view

## Editor workflow

- `BB` or `<CR>` in visual mode runs the selection; when the selection contains multiple SQL statements, connector opens a dedicated result tab with one split per statement (`q` closes it)
- `BB` in normal mode runs the whole scratchpad
- `<CR>` runs the current line under the cursor
- `<C-Space>` runs the current selection or line in a floating window
- `gd` jump-to-table: locate the definition/source table for the item under cursor (focuses the drawer)

## Result workflow

- `?` open the result menu (instant query change / show query in scratchpad)
- `L` / `H` next / previous page
- `E` / `F` go to last / first page
- `]r` / `[r` newer / older result in the current session
- `]q` / `[q` newer / older query history for the current project and branch
- `<CR>` or `i` edit the current cell for editable results (editable results are single-table SELECTs with a primary key)
- `yaj` / `yac` yank current row or selection as JSON / CSV
- `yaJ` / `yaC` yank all rows as JSON / CSV
- `<C-c>` cancel the active call

### Result table highlights

The result buffer uses a few dedicated highlight groups (linked to your colorscheme by default):

- `ConnectorResultTableBorder` (grid separators like `│`, `─`, `┼`)
- `ConnectorResultTableHeader` (column names)
- `ConnectorResultTableIndex` (row numbers)
- `ConnectorResultTableNull` (`NULL` cells)

Override them with `vim.api.nvim_set_hl(0, ...)` if you want a different look.

## Layout behavior

The default layout now keeps the drawer width and the result / call-log heights stable across temporary split changes (for example when another plugin opens and closes a window in the same tab), restores the configured connector layout sizes when you focus the connector tab again, and starts the call-log panel at the same default height as the result panel.

Additional features

- Query generation: in the drawer, pick columns (visual or single) and use `<CR>` on a table/column to generate SELECT/UPDATE/DELETE/INSERT templates or an approximate DDL definition; generated text is appended to the current scratchpad (not executed).
- Table picker: `require("connector").pick_table()` / `require("connector").api.ui.drawer_pick_table()` prompts for a table (DB.table) and focuses it in the left drawer. When `fzf-lua` is available, the picker shows a preview with an approximate table definition (columns / PK).

Query history is stored in Neovim state. `require("connector").history(opts)` returns entries for custom
pickers, and `require("connector").history_fzf_source(opts)` returns one-line labels suitable for fzf-lua.

Scratchpads expose similar helpers: `require("connector").scratchpads(opts)` returns entries, and
`require("connector").scratchpads_fzf_source(opts)` returns one-line labels. `:Connector scratchpads`
uses an `fzf-lua` picker with SQL preview when available, and `<C-g>` jumps into scratchpad grep.

Editable results currently target **single-table `select * from ...` queries with a primary key**. Primary-key
columns stay read-only, and you can type `NULL` to clear nullable cells.

## Backend

The backend lives in this repository and builds to `connector-backend`. `require("connector").install()`
builds it with Cargo and copies the binary into Neovim's data directory.

## TODO
- [ ] 対応DBの種類を増やす
- [ ] いい感じにトンネルでダンプできる機能をrustで挟んで実現したい
- [ ] mdでいい感じにリレーション図を表示する
