# Drawer and history performance

The drawer reads `Handler.current_connection_id` when deciding row colors,
instead of copying the current connection for each row. Candy rendering copies
only the three scalar fields it uses. Table/view labels in the selected
connection's current DB use `Identifier` (or a configured candy text highlight).
Other DB/connection tables and columns use `Comment`. Connections without a DB
list, such as SQLite, apply the accent to their active connection's tables.
Disabling drawer icons preserves the table label distinction.

`buffer_line.render` accepts an optional previous render state and returns the
next state. The drawer and history panel retain it. Builders in that state must
remain immutable. Identical text and marks cause no buffer/namespace writes;
highlight-only changes do not rewrite text. When row counts match, only the span
of changed rows is rebuilt. A changed row count or an external text edit
(`changedtick`) causes a full rebuild. The state belongs to one buffer and
namespace; callers without a previous state retain full-render behavior.
The renderer owns its namespace. Code changing its marks directly must discard
the saved state, since namespace edits do not change the buffer's `changedtick`.

History pane rendering uses `Handler:get_call_summaries` through
`call_history.visible_calls(handler, { summary = true })`. It copies only
`id`, `state`, and `query`, preserving project/branch filters, call order and the
fallback to all matching connections when the selected connection has no calls.
The public full-call APIs and history picker keep their complete copied results.

## Measurement

```sh
nvim --headless -u NONE -i NONE -l tests/drawer_benchmark.lua
```

`CONNECTOR_BENCH_ROOT` may select a different checkout. The fixture uses two
cached DBs with 2,000 tables each, isolated temporary state, and no backend or
network requests. It measures 20 unchanged refreshes after the initial render.
History retrieval is measured separately using 10 calls with 3,000 five-cell
result rows each, and a fixed project/branch so calls are actually included.

Local results on 2026-10-09: medians of five fresh Neovim invocations per version,
comparing repository HEAD before the change with the modified checkout.

| Operation | Before | After |
| --- | ---: | ---: |
| Unchanged drawer refresh (4,009 rows) | 25.58 ms | 8.22 ms |
| Current-connection copies per refresh | 4,011 | 1 |
| Buffer text writes per refresh | 1 | 0 |
| Extmark writes per refresh | 4,014 | 0 |
| History data retrieval for pane rendering | 15.89 ms | 0.003 ms |

These measurements cover cached UI work, not database query latency, first-open
time, or the user's complete Neovim configuration. Row building, metadata copies
and table sorting still occur on each refresh.

## Regression checks

```sh
nvim --headless -u NONE -i NONE -l tests/ui_performance.lua
nvim --headless -u NONE -i NONE -l tests/startup.lua
CONNECTOR_TEST_DISPLAY=panel nvim --headless -u NONE -i NONE -l tests/startup.lua
nvim --headless -u NONE -i NONE -l tests/pane_features.lua
```

UI checks cover retained extmarks on unchanged rows, highlight-only changes,
UTF-8 byte offsets, text replacement, external edits, row count changes, active
DB/connection transitions, views and icon-free labels, cache isolation, and
history filtering/fallback with full-call copy isolation.
