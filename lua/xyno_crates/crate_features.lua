-- Cargo features of dependencies, from the crate's own source:
--
--   * Missing-feature fix. rustc / rust-analyzer / bacon-ls report `cannot find
--     derive macro `Serialize` in this scope` when the feature that exports the
--     name is off. The name is looked up in the unpacked source of the
--     member's dependencies (lib.rs and the modules it declares, behind
--     `#[cfg(feature = "...")]`, `pub use`, `macro_rules!` and the crate's own
--     `cfg_xxx! { .. }` wrapper macros), the gate is resolved through the
--     crate's [features] table (derive = ["serde_derive"] where serde_derive
--     is an optional dependency) and the code action "Enable feature `derive`
--     of `serde`" edits Cargo.toml. The action lives in a small in-process
--     LSP client ("xyno-features") so it shows in the normal code-action
--     menu (<leader>ca) next to rust-analyzer's own; the optional fix key applies the
--     fix for the diagnostics on the cursor line without the menu.
--   * Feature explorer :CrateFeatures [crate]: per dependency the declared
--     and effective features, what each feature unlocks (the gated pub items
--     of the same scan), the default set and an "unused?" hint for a declared
--     feature none of whose items appears in the workspace sources.
--
-- Cargo.toml edits: `cargo add <crate> --features ..` (argv, offline first) for
-- registry dependencies when a feature is switched on, a careful text edit
-- (formatting and comments kept) for everything else: switching off, renamed,
-- path and git dependencies, and when cargo add changed nothing. The member
-- that declares the dependency is edited; `workspace = true` stays and gets
-- the feature in the member's own entry (additive), the workspace table is not
-- touched. Everything that comes from the network or from files (crate and
-- feature names) is validated before it reaches an argv.
--
-- This file is the facade (setup and the keys); the parts are in features/:
--   scan, tables, suggest, manifest (pure and file level), action (language client), explorer.
local M = {}

for _, name in ipairs({ "scan", "tables", "suggest", "manifest", "action", "explorer" }) do
  for k, v in pairs(require("xyno_crates.features." .. name)) do
    if k:sub(1, 1) ~= "_" then
      M[k] = v
    end
  end
end

-- ================================================================== setup

local did_setup = false

local keymap = false -- false | lhs: the key of the cursor-line fix (opts.keymaps.fix)
local mapped = {} -- buf -> lhs of the fix key set by setup

--- What a Rust buffer gets: the in-process client and, when a key is configured, the fix key.
function M.on_rust_buffer(buf)
  M.attach(buf)
  if type(keymap) == "string" then
    vim.keymap.set("n", keymap, M.fix_at_cursor, { buffer = buf, desc = "Fix missing crate feature" })
    mapped[buf] = keymap
  end
end

local function teardown()
  pcall(vim.api.nvim_del_augroup_by_name, "xyno_crates_features")
  pcall(vim.api.nvim_del_user_command, "CrateFeatures")
  for b, lhs in pairs(mapped) do
    if vim.api.nvim_buf_is_valid(b) then
      pcall(vim.keymap.del, "n", lhs, { buffer = b })
    end
  end
  mapped = {}
  keymap = false
end

function M.stop()
  teardown()
  did_setup = false
end

--- opts: { commands = true, keymap = false | lhs } (see xyno_crates.setup). Safe to call again:
--- the second call replaces the first one's autocommands, command and key.
function M.setup(opts)
  if did_setup then
    teardown()
  end
  did_setup = true
  opts = opts or {}
  keymap = opts.keymap or false
  local group = vim.api.nvim_create_augroup("xyno_crates_features", { clear = true })

  if opts.commands ~= false then
    vim.api.nvim_create_user_command("CrateFeatures", function(o)
      M.open(o.args)
    end, {
      nargs = "?",
      desc = "Explore and toggle the cargo features of a dependency",
      complete = function(lead)
        return vim.tbl_filter(function(n)
          return vim.startswith(n, lead)
        end, M.complete())
      end,
    })
  end

  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "rust",
    callback = function(ev)
      M.on_rust_buffer(ev.buf)
    end,
  })
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].filetype == "rust" then
      M.on_rust_buffer(b)
    end
  end
end

return M
