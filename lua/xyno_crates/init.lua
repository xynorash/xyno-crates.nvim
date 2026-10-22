-- xyno-crates.nvim: Cargo dependencies from inside Neovim. setup() checks the
-- dependencies and starts the modules; every module can also be required on its own
-- (xyno_crates.crate_add, xyno_crates.crate_features, xyno_crates.crate_import).
local M = {}

M.defaults = {
  commands = true, -- :CrateAdd :CrateFeatures
  keymaps = false, -- false | true | { add = lhs|false, fix = lhs|false } (buffer-local in Rust files; add also in Cargo.toml)
  modules = {
    add = true, -- xyno_crates.crate_add: unknown-crate hint, "Add crate X" action, :CrateAdd
    features = true, -- xyno_crates.crate_features: missing-feature action, :CrateFeatures
    import = true, -- xyno_crates.crate_import: import from crates that are not dependencies yet (needs xyno-imports.nvim)
  },
}

--- Default keys of `keymaps = true`. An entry set to false in a table is skipped.
M.default_keymaps = { add = "<leader>rA", fix = "<leader>rG" }

local REQUIRED = {
  { mod = "xyno_rust.crate_meta", plugin = "xyno-rust.nvim (xynorash/xyno-rust.nvim)" },
  { mod = "xyno_rust.code_actions", plugin = "xyno-rust.nvim (xynorash/xyno-rust.nvim)" },
  { mod = "xyno_rust.fsutil", plugin = "xyno-rust.nvim (xynorash/xyno-rust.nvim)" },
  { mod = "xyno_rust.rust_restart", plugin = "xyno-rust.nvim (xynorash/xyno-rust.nvim)" },
  { mod = "xyno_imports.engine", plugin = "xyno-imports.nvim (xynorash/xyno-imports.nvim)" },
}

--- Configure and start the plugin. The first call wins for the autocommands, the in-process
--- LSP servers and the keys (the modules start once per session).
---@param opts? { commands?: boolean, keymaps?: boolean|table<string, string|false>, modules?: table<string, boolean> }
function M.setup(opts)
  opts = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  if vim.fn.has("nvim-0.12") ~= 1 then
    vim.notify("xyno-crates: Neovim 0.12 or newer is required", vim.log.levels.ERROR)
    return
  end
  local m = opts.modules
  for _, dep in ipairs(REQUIRED) do
    -- xyno-imports is only used by the add and import modules
    local needed = dep.mod ~= "xyno_imports.engine" or m.add or m.import
    if needed and not pcall(require, dep.mod) then
      vim.notify("xyno-crates: needs " .. dep.plugin .. ", which is not installed", vim.log.levels.ERROR)
      return
    end
  end
  local keys = opts.keymaps and (opts.keymaps == true and M.default_keymaps or opts.keymaps) or {}
  if m.add then
    require("xyno_crates.crate_add").setup({ commands = opts.commands, keymap = keys.add })
  end
  if m.features then
    require("xyno_crates.crate_features").setup({ commands = opts.commands, keymap = keys.fix })
  end
  if m.import then
    require("xyno_crates.crate_import").setup()
  end
end

return M
