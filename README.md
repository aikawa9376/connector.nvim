# connector.nvim

Neovim database client inspired by `nvim-dbee`, with a **Rust backend** and **Lua frontend**.

## Current scope

- connector workflow with configurable history placement (bottom panel or drawer)
- connection sources: memory, env, file
- query execution from editor, current line, or selection
- result paging and CSV/JSON/table export
- in-cell updates for simple `select * from table ...` result sets
- structure browsing for SQLite, PostgreSQL, MySQL, and optional DuckDB, ClickHouse, SQL Server, Redis, MongoDB, and Oracle drivers
- connection CRUD for writable sources
- database switching for PostgreSQL, MySQL, ClickHouse, SQL Server, and MongoDB
- secret expansion with `{{ env "VAR" }}` and `{{ exec "cmd" }}`

## Installation

`connector.nvim` expects Neovim `>= 0.10`.

### lazy.nvim

```lua
{
  "aikawa9376/connector.nvim",
  cmd = "Connector",
  -- If you configured lazy.nvim with `defaults = { lazy = false }`, you must opt back in:
  -- lazy = true,

  -- Option A (recommended): let lazy.nvim run cargo so the build log shows up in Lazy's UI.
  -- The default backend includes SQLite, PostgreSQL, and MySQL.
  -- connector.nvim will pick up `target/release/connector-backend` automatically.
  build = "cargo build --release --manifest-path Cargo.toml",

  -- Add optional drivers with Cargo features:
  -- build = "cargo build --release --manifest-path Cargo.toml --features duckdb,redis",
  -- build = "cargo build --release --manifest-path Cargo.toml --features all-drivers",

  -- Option B: install the backend binary into stdpath("data")/connector/bin
  -- build = function()
  --   require("connector").install({
  --     features = { "duckdb", "redis" },
  --     -- all_features = true,
  --   })
  -- end,

  config = function()
    require("connector").setup()
  end,
}
```

Notes:
- With `cmd = "Connector"`, lazy.nvim creates a placeholder `:Connector` command at startup. This does **not** mean the plugin is loaded.
- To verify, check `:lua print(vim.g.loaded_connector)` (should be `nil` on startup, `1` after running `:Connector`).
- If something calls `require("connector")` during startup (e.g. completion provider config), the plugin will be loaded eagerly.

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
  history = {
    display = "drawer", -- or "panel"
    drawer_max_items = 50,
  },
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
      -- Avoid `require("connector")` at startup so connector.nvim can stay lazy-loaded.
      -- blink.cmp will require this module when the source is actually used.
      connector = {
        module = "connector.blink",
        name = "Connector",
        async = true,
        min_keyword_length = 0,
        -- (optional) same opts as `require("connector").blink_source({ ... })`
        opts = {},
      },
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

Supported connection types:

- default build: `sqlite` / `sqlite3`
- default build: `postgres` / `postgresql` / `pg`
- default build: `redshift` (PostgreSQL-compatible driver)
- default build: `mysql` / `mariadb`
- optional feature `duckdb`: `duck` / `duckdb`
- optional feature `clickhouse`: `clickhouse`
- optional feature `sqlserver`: `sqlserver` / `mssql`
- optional feature `redis`: `redis`
- optional feature `mongo`: `mongo` / `mongodb`
- optional feature `oracle`: `oracle`

If a connection type is not enabled in the compiled backend, connector returns an error explaining
which Cargo feature to rebuild with. Use `--features all-drivers` or `require("connector").install({ all_features = true })`
for the previous all-in-one build.

For PostgreSQL, MySQL, ClickHouse, SQL Server, Redis, MongoDB, and Oracle use connection strings.

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

Additional URL examples:

```json
[
  {
    "name": "Local DuckDB",
    "type": "duckdb",
    "url": "~/data/app.duckdb"
  },
  {
    "name": "Local ClickHouse",
    "type": "clickhouse",
    "url": "tcp://default@localhost:9000/default"
  },
  {
    "name": "Local SQL Server",
    "type": "sqlserver",
    "url": "mssql://sa:password@localhost:1433/master?trust_cert=true"
  },
  {
    "name": "Local Redis",
    "type": "redis",
    "url": "redis://127.0.0.1:6379/0"
  },
  {
    "name": "Local MongoDB",
    "type": "mongo",
    "url": "mongodb://127.0.0.1:27017/app"
  },
  {
    "name": "Local Oracle",
    "type": "oracle",
    "url": "oracle://app_user:password@localhost:1521/FREEPDB1"
  }
]
```

Notes:
- ClickHouse uses the native TCP protocol (`tcp://...`). `clickhouse://...` is accepted and normalized to `tcp://...`.
- SQL Server also accepts ADO.NET or JDBC-style connection strings supported by `tiberius`.
- Redis commands use shell-like argument splitting, e.g. `GET key` or `HGETALL user:1`.
- MongoDB commands are JSON objects passed to `runCommand`, e.g. `{"find":"users","limit":10}`.
- Oracle uses the pure Rust `oracle-rs` driver and expects `oracle://user:password@host:port/service`.
- BigQuery and Databricks from `nvim-dbee` are not implemented yet.

## Drawer workflow

- `<CR>` select/open the node under cursor. On a table or column this opens a menu to generate SQL templates (Select/Update/Delete/Insert/DDL). Visual selection of columns is supported — use `v`/`V` to pick multiple columns before `<CR>`.
- `o` toggle (expand/collapse) the node under cursor
- `cw` edit connection details or rename a scratchpad
- `dd` delete connection or scratchpad (use with care)
- `i` ignore / unignore a database or connection for the current project
- `a` add a new connection (context-aware: adds to the selected source/connection)
- `f` toggle the "project only" scratchpad filter
- `[[` / `]]` jump between top-level sections
- expandable nodes below the top level show child counts where connector can derive them cheaply
- when `history.display = "drawer"`, a collapsible `History` section is shown under `Scratchpads` (collapsed by default, showing up to `history.drawer_max_items`; `more…` opens the full list with fzf-lua when available)
- `r` refresh the drawer view
- `<C-c>` cancel the selected executing history entry

## Editor workflow

- `BB` or `<CR>` in visual mode runs the selection; when the selection contains multiple SQL statements, connector opens a dedicated result tab with one split per statement (`q` closes it)
- `BB` in normal mode runs the whole scratchpad
- `<CR>` runs the SQL statement under the cursor
- `<C-Space>` runs the current selection or SQL statement under the cursor in a floating window
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

The default layout keeps the drawer width and the result / call-log heights stable across temporary split changes (for example when another plugin opens and closes a window in the same tab) and restores the configured connector layout sizes when you focus the connector tab again. By default, history is rendered in the drawer (`history.display = "drawer"`); if you switch to `history.display = "panel"`, connector also opens the bottom history panel at the same default height as the result panel.

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

Default Cargo features build only the lighter common drivers: SQLite, PostgreSQL, and MySQL. Optional
drivers can be added at install time:

```lua
require("connector").install({
  features = { "duckdb", "clickhouse" },
})
```

Available driver features: `duckdb`, `clickhouse`, `sqlserver`, `redis`, `mongo`, `oracle`, and
`all-drivers`. Passing `all_features = true` is equivalent to enabling `all-drivers`.

## TODO
- [ ] 対応DBの種類を増やす
- [ ] いい感じにトンネルでダンプできる機能をrustで挟んで実現したい
- [ ] mdでいい感じにリレーション図を表示する

- [ ] gdが機能してなさそう
- [ ] 勝手にDBセレクトはクエリが失敗したときだけためすようにする
