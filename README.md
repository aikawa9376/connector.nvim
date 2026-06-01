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

## blink.cmp

`connector.nvim` now exposes a blink.cmp source instead of wiring `omnifunc` into scratchpads.

```lua
require("connector").setup()

require("blink.cmp").setup({
  sources = {
    default = { "lsp", "path", "buffer" },
    per_filetype = {
      sql = { inherit_defaults = true, "connector" },
    },
    providers = {
      connector = require("connector").blink_source(),
    },
  },
})
```

The source completes:

- table names across configured connections, with connection / database context in the docs
- columns for the current SQL statement when the table can be inferred from `FROM` / `JOIN` / aliases like `u.`

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

- `<CR>` select/open the node under cursor. On a table or column this opens a menu to generate SQL templates (Select/Update/Delete/Insert). Visual selection of columns is supported — use `v`/`V` to pick multiple columns before `<CR>`.
- `o` toggle (expand/collapse) the node under cursor
- `cw` edit connection details or rename a scratchpad
- `dd` delete connection or scratchpad (use with care)
- `i` ignore / unignore a database or connection for the current project
- `a` add a new connection (context-aware: adds to the selected source/connection)
- `f` toggle the "project only" scratchpad filter
- `r` refresh the drawer view

## Editor workflow

- `BB` in visual mode runs the selection
- `BB` in normal mode runs the whole scratchpad
- `<CR>` runs the current line under the cursor
- `<C-Space>` runs the current selection or line in a floating window
- `gd` jump-to-table: locate the definition/source table for the item under cursor (focuses the drawer)

## Result workflow

- `L` / `H` next / previous page
- `E` / `F` go to last / first page
- `]r` / `[r` newer / older result in the current session
- `]q` / `[q` newer / older query history for the current project and branch
- `<CR>` or `i` edit the current cell for editable results (editable results are single-table SELECTs with a primary key)
- `yaj` / `yac` yank current row or selection as JSON / CSV
- `yaJ` / `yaC` yank all rows as JSON / CSV
- `<C-c>` cancel the active call

Additional features

- Query generation: in the drawer, pick columns (visual or single) and use `<CR>` on a table/column to generate SELECT/UPDATE/DELETE/INSERT templates; generated queries are appended to the current scratchpad (not executed).
- Table picker: `require("connector").api.ui.drawer_pick_table()` prompts for a table (Connection · schema.table) and focuses it in the left drawer.

Query history is stored in Neovim state. `require("connector").history(opts)` returns entries for custom
pickers, and `require("connector").history_fzf_source(opts)` returns one-line labels suitable for fzf-lua.

Editable results currently target **single-table `select * from ...` queries with a primary key**. Primary-key
columns stay read-only, and you can type `NULL` to clear nullable cells.

## Backend

The backend lives in this repository and builds to `connector-backend`. `require("connector").install( )`
builds it with Cargo and copies the binary into Neovim's data directory.

## TODO
- [x] スクラッチのプロジェクト対応
- [x] 開いた場所からプロジェクトをなんとなく解決する
  - [x] プロジェクト名を左ナビにいい感じに表示する
  - [x] 切り替えれるようにするとなおよい (開いているsqlベースで切り替えたい)
  - [x] connection名のところでiするとconnectionがプロジェクトに紐づいた除外される
    - [x] 除外されたconnectionはignoreみたいな名前でグルーピングされる(操作自体は可能) グレーアウトされている
    - [x] ignoreグループからiでもとにもどせる
- [x] スクラッチのテーブル名から左ナビひらく(gdとかで定義元いくイメージ)
- [x] 一時ウインドウ(フロート？)でのクエリ実行
- [x] 補完ソース
- [ ] スクラッチファイルのfzf-lua検索
- [X] DB tabgle でfzf-lua検索 左ナビ連動
- [ ] リフレッシュボタン
- [ ] ~結果からクエリを逆生成~ よく考えると不可能だし便利じゃない気がする
- [ ] 自動DB選択は副作用があるものはconfirmを挟む
- [x] テーブルから過去に使用したクエリ一覧かだせる(これはプロジェクトごとではない)
  - [x] そのための保存領域を確保(sqlite？)
    - [x] ここまでやるならクエリ履歴のfzf-lua検索も欲しいよね(ソースとしてfzf-luaで使いやすいリストを出す関数を用意すればいいかな)
    - [x] 複数行のクエリは一行として保存されるが改行はデータとしてもって復元可能にしたい
      - [x] プロジェクト・ブランチ・テーブル等々 条件指定できると良い
  - [x] resultテーブルから前後のクエリに移動(これはプロジェクト・ブランチを意識する)
  - [x] 合わせて左下の実行クエリも保存された以前のクエリを表示する
- [ ] クエリをビジュアル選択して複数発火するとスプリットでいい具合に表示してくれる
  - [ ] タブでだせてカジュアルに閉じれるといいなと
- [X] 左ナビでカラム出したとしてvせんたくでクエリ自動生成
- [ ] いい感じにトンネルでダンプできる機能をrustで挟んで実現したい

- [ ] ~er図を出せちゃったりする~
- [ ] mdでいい感じにリレーション図を表示する
