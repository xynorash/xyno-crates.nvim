# xyno-crates.nvim

Cargo dependencies from inside Neovim: search crates.io, add crates with their features, enable a missing feature from a code action, and import from crates that are not dependencies yet.

I use this in my own Rust setup, [xynovim](https://github.com/xynorash/xynovim), and pulled it out as a standalone plugin.

The crate-adding flow is inspired by the dependency handling of the JetBrains IDEs. I still use JetBrains tools; this plugin is my own independent project and is not affiliated with JetBrains.

## Why

Adding a dependency means leaving the editor for crates.io, copying a name, finding out which features exist, and running `cargo add` with the right flags. And when `#[derive(Serialize)]` fails because `serde` was added without its `derive` feature, the error does not say which feature to turn on. This does those steps where the cursor is: a picker for the crate and its features, a code action for the unknown crate and for the missing feature, and an import that adds the crate first when it is not a dependency yet.

## Requirements

- Neovim 0.12+
- [xyno-rust.nvim](https://github.com/xynorash/xyno-rust.nvim) (crate metadata, code actions, file helpers, server restart after a manifest change) and [xyno-imports.nvim](https://github.com/xynorash/xyno-imports.nvim) (the import engine the crate import plugs into). Both are checked in `setup()`: without them you get one error line naming the missing plugin and nothing starts. xyno-imports.nvim is only needed while the `add` or `import` module is on.
- `cargo` in `$PATH` (`cargo add`, `cargo metadata`)
- the tree-sitter `rust` parser (the unknown-crate scan)
- network access to crates.io for the search (the sparse index and a cache are used where possible)
- rust-analyzer started through `vim.lsp` (I use [rustaceanvim](https://github.com/mrcjkb/rustaceanvim)), for importing the items of a freshly added crate
- [snacks.nvim](https://github.com/folke/snacks.nvim) for the `:CrateAdd` pickers; without it `:CrateAdd` prints one error line. `:CrateFeatures` falls back to `vim.ui.select()`.

## Install (lazy.nvim)

```lua
{
  "xynorash/xyno-crates.nvim",
  dependencies = {
    "xynorash/xyno-rust.nvim",
    "xynorash/xyno-imports.nvim",
    "folke/snacks.nvim", -- pickers
  },
  ft = "rust",
  cmd = { "CrateAdd", "CrateFeatures" },
  opts = {},
  keys = {
    { "<leader>rA", "<cmd>CrateAdd<cr>", ft = { "rust", "toml" }, desc = "Add crate (crates.io search)" },
    { "<leader>rG", function() require("xyno_crates.crate_features").fix_at_cursor() end, ft = "rust", desc = "Fix missing crate feature" },
  },
}
```

The code actions and the hint come from in-process language clients that start with `setup()`, so load the plugin with `ft = "rust"` (as above) or `event = "VeryLazy"`, not only on the commands, if you want them while you edit. `:CrateFeatures` and the `fix_at_cursor()` key work as soon as the plugin is loaded.

## Options

`require("xyno_crates").setup(opts)`; the defaults:

```lua
{
  commands = true, -- :CrateAdd :CrateFeatures
  keymaps = false, -- false | true | { add = lhs|false, fix = lhs|false }
  modules = {
    add = true,      -- xyno_crates.crate_add: unknown-crate hint, "Add crate X", :CrateAdd
    features = true, -- xyno_crates.crate_features: missing-feature action, :CrateFeatures
    import = true,   -- xyno_crates.crate_import: import from a crate that is not a dependency yet
  },
}
```

No global keymap is set by default. `keymaps = true` maps `<leader>rA` (`:CrateAdd`, buffer-local in Rust and `Cargo.toml` buffers) and `<leader>rG` (the missing-feature fix for the cursor line, buffer-local in Rust buffers); a table maps only what you list, to the keys you choose.

The modules start once per session: a second `setup()` call does not redefine their autocommands, language servers or keys.

`vim.g.xyno_crate_check = false` switches the unknown-crate hint off. The limits live in each module's `config` table, for example `require("xyno_crates.crate_add").config`: `debounce_ms = 300`, `max_diagnostics = 50` per buffer, `cargo_timeout_ms = 180000`, `max_lines = 20000` (larger buffers get no hint). `crate_features.config` has the scan limits (`max_files`, `max_file_bytes`, `max_unused_files`, `max_unused_bytes`, `max_alts`), `crate_import.config` has `max_guesses = 3`, `min_guess_len = 3`, `poll_ms = 1000`, `reload_timeout_ms = 60000`.

## Commands

| Command | What it does |
| --- | --- |
| `:CrateAdd [query]` | Search crates.io, pick the crate, pick its features (`default` is preselected; unticking it means `--no-default-features`), pick the target (member and kind: dependencies, dev-dependencies, build-dependencies; entries of `[workspace.dependencies]` are marked) and run `cargo add`. The line cargo wrote is reported. |
| `:CrateFeatures [crate]` | Explore the cargo features of a dependency: declared and effective features, what each unlocks (the gated public items found in the crate's source), the default set, and an "unused?" hint for a feature none of whose items appears in the workspace. Toggle one from the list: `Cargo.toml` is edited. |

## Code actions

Two in-process language clients (no process is started) put these into the normal code-action menu (`vim.lsp.buf.code_action()`), next to rust-analyzer's own:

- **Unknown crate.** A path whose first segment is not known (`std`, a dependency of the file's package, the own crate, a local module, an import, ...) gets the hint `crate 'rand' is not a dependency` and the actions `Add crate rand` (add with the defaults, then import) and the `:CrateAdd` flow for it. The rules are conservative: a false positive is worse than a miss.
- **Missing feature.** rustc, rust-analyzer or bacon-ls report `cannot find derive macro Serialize in this scope`: the name is looked up in the source of the package's dependencies, the gate is resolved through the `[features]` table, and the action ``Enable feature `derive` of `serde` `` edits `Cargo.toml`.
- **Import from a crate that is not a dependency yet.** When rust-analyzer offers nothing for an unresolved name, the crate named like it, or crates.io search hits whose name equals or contains it, are added to the candidates of xyno-imports.nvim. Search is by crate name, not by exported items, so these are labelled as guesses. Accepting one adds the crate, waits for rust-analyzer to load it and applies the import.

The hint is rescanned after `InsertLeave`, `TextChanged`, `BufWritePost`, `BufReadPost`, a change of `Cargo.toml` or `Cargo.lock`, and the user event `AutoSaveWritePost` (`data = { saved_buffer = bufnr }`) for an auto-save plugin that writes without autocommands.

## Lua API

- `require("xyno_crates.crate_add")`: `scan(buf, meta)`, `refresh(buf, cb)`, `add(query?, cb?)`, `add_direct(buf, name, cb)` (newest release, no features, into the package of the buffer), `build_argv(spec)`, `run_add(root, spec, cb)`, `applicable_file(file)`, `ui.pick` and `ui.input` (the picker seams).
- `require("xyno_crates.crate_features")`: `suggest_async(buf, diags, cb)`, `features_of(dep)`, `set_features(dep, features, on, cb)`, `edit_manifest(text, spec, op, features)` (pure), `open(crate?)`, `fix_at_cursor()`.
- `require("xyno_crates.crate_import")`: `source(name, ctx, cb)`, `add_and_import(buf, spec, cb)`.

`:help xyno-crates` has the same in vim help form.

## How it works

Crate metadata comes from `cargo metadata` and the crates.io sparse index (through xyno-rust.nvim), cached. The unknown-crate scan walks the tree-sitter tree of the buffer, debounced. The missing-feature lookup reads the unpacked source of the dependencies (`lib.rs` and the modules it declares, behind `#[cfg(feature = "...")]`, `pub use`, `macro_rules!`). `Cargo.toml` is edited with `cargo add --features` for registry dependencies and with a careful text edit (formatting and comments kept) for the rest. Everything that comes from the network or from files (crate and feature names) is validated before it reaches a command line, and commands run as argv lists.

## Platforms

- Linux: tested by the specs in this repository (`nvim -l tests/run.lua`): the scan, the picker flow with a stubbed crates.io client and `cargo add`, the manifest editor, the code actions through the in-process clients, a real snacks.nvim picker, and the flows against the real crates.io, cargo and rust-analyzer on small fixture crates (they skip with a printed reason when the network, cargo, rust-analyzer or the registry crates are not available).
- Windows: the Windows guards of the original code are kept, but I have no evidence for them from this repository. In xynovim's CI the Windows job passed overall (run 39673715062), but the live rust-analyzer flows of the hint, code action and import specs failed or hung there as a known issue, so I do not claim those work on Windows.
- macOS: nothing tested here. The macOS runs in xynovim's CI were not stable (one fully green run, others flaky or failed elsewhere), so I do not claim it works.

## Extracted from xynovim

These modules come from [xynovim](https://github.com/xynorash/xynovim), my Neovim configuration for Rust. The code is the same apart from the namespace (`config.*` became `xyno_crates.*`, `xyno_rust.*` and `xyno_imports.*`), `setup()` taking options, the keys being opt-in (the original bound `<leader>rA` and `<leader>rG` itself) and the commands switchable, the `:CrateAdd` picker checking that snacks.nvim is there instead of assuming its global, and renamed identifiers: the in-process clients are `xyno-crates` and `xyno-features`, the diagnostic source is `xyno-crates`, the switch is `vim.g.xyno_crate_check`, and the autocommand groups are `xyno-crates-add` and `xyno_crates_features`.

## Tests

```sh
nvim -l tests/run.lua    # specs, each file in its own headless nvim; needs xyno-rust.nvim and xyno-imports.nvim next to this checkout (or XYNO_RUST_DIR, XYNO_IMPORTS_DIR)
XYNO_LAZY=/path/to/lazy.nvim nvim --headless -u tests/e2e/init.lua -c "luafile tests/e2e/smoke.lua"
```

`XYNO_TEST_RTP` adds a directory holding `parser/rust.so`; `XYNO_SNACKS_DIR` is a snacks.nvim checkout for the real-picker spec (skipped without it).

## License

MIT, Copyright (c) 2026 Xynorash.
