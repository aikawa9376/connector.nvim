# Startup performance

`require('connector').setup()` configures the plugin without loading the handler,
editor, drawer, result UI or DDL implementation. The public `api.context`,
`api.core` and `api.ui` modules load on first access. Core-only operations do not
construct or load the editor and drawer. UI module loading is charged to the
first `open()` instead of setup.

`util.get_git_branch` shares successful, detached-HEAD and failed lookups within
one event-loop turn, by project root. Invalidation is scheduled **after** the
blocking process wait, because `vim.system():wait()` itself pumps the event loop.
This avoids retaining a branch across later user actions. It does not remove the
first synchronous Git process or cache project context held by other components.

The project `BufEnter` autocmd uses `DrawerUI:schedule_refresh()` so multiple
window/buffer changes during layout creation share a redraw. Explicit refresh
operations still run immediately. Scheduled refreshes check window validity.

Scratchpad recognition uses the configured `editor.directory`, normalized with
a directory boundary; a sibling such as `scratchpads-backup` is not a scratchpad.
Previously a custom directory fell through to repeated project/Git discovery
and could lose the project and branch encoded in the scratchpad namespace.
An explicit `sources = {}` now disables both default connection sources.

## Reproducing measurements

From the repository directory:

```sh
nvim --headless -u NONE -i NONE -l tests/benchmark.lua
CONNECTOR_BENCH_CUSTOM=1 nvim --headless -u NONE -i NONE -l tests/benchmark.lua
```

`CONNECTOR_BENCH_ROOT` can select a different checkout while retaining the same
working directory/project. Each invocation isolates state and data in a temporary
directory, uses no connections/history, and creates its first scratchpad. It
reports require+setup time, synchronous first-open time, and Git process count
through the subsequent scheduled redraw. Open time excludes deferred redraws.

Local measurements on 2026-09-06, median of 10 fresh Neovim processes per case
(filesystem caches warm; baseline repository HEAD before these changes):

| Scratchpad directory | Version | Require + setup | First open | Git processes |
| --- | --- | ---: | ---: | ---: |
| Default | Before | 9.15 ms | 9.54 ms | 1 |
| Default | After | 3.40 ms | 16.40 ms | 1 |
| Custom | Before | 10.71 ms | 49.46 ms | 18 |
| Custom | After | 3.92 ms | 18.05 ms | 1 |

The default case mainly moves module-loading cost from setup to first use; it
shows no total startup improvement in this sample. The custom-directory case
removes redundant work as well. These numbers do not measure the user's complete
Neovim configuration, database/network latency, or large scratchpad/history sets.

## Regression checks

```sh
nvim --headless -u NONE -i NONE -l tests/startup.lua
CONNECTOR_TEST_DISPLAY=panel nvim --headless -u NONE -i NONE -l tests/startup.lua
```

Checks cover lazy loading, empty/default sources, custom scratchpad context and
path boundaries, Git lookup reuse and invalidation after a real checkout,
detached HEAD, redraw coalescing, and UI close/reopen in both history layouts.
