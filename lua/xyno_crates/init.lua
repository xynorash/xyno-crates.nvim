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
  add = {}, -- the confirmation before `cargo add`: { confirm = true, typosquat = true, audit = "hint"|"run"|"off", extra_popular = {names} }
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

local ADD_KEYS = {
  confirm = "boolean",
  typosquat = "boolean",
  audit = { "hint", "run", "off" },
  extra_popular = "table",
}

--- Check the options; returns the problems (the call goes on with what is valid).
local function validate(opts)
  local problems = {}
  if type(opts.commands) ~= "boolean" then
    problems[#problems + 1] = "commands must be a boolean"
  end
  if opts.keymaps ~= false and opts.keymaps ~= true and type(opts.keymaps) ~= "table" then
    problems[#problems + 1] = "keymaps must be false, true or a table"
  end
  if type(opts.modules) ~= "table" then
    problems[#problems + 1] = "modules must be a table"
  else
    for k, v in pairs(opts.modules) do
      if M.defaults.modules[k] == nil then
        problems[#problems + 1] = ("unknown module `%s`"):format(tostring(k))
      elseif type(v) ~= "boolean" then
        problems[#problems + 1] = ("module `%s` must be a boolean"):format(k)
      end
    end
  end
  if type(opts.add) ~= "table" then
    problems[#problems + 1] = "add must be a table"
  else
    for k, v in pairs(opts.add) do
      local want = ADD_KEYS[k]
      if want == nil then
        problems[#problems + 1] = ("unknown add option `%s`"):format(tostring(k))
      elseif type(want) == "string" and type(v) ~= want then
        problems[#problems + 1] = ("add.%s must be a %s"):format(k, want)
      elseif type(want) == "table" and not vim.tbl_contains(want, v) then
        problems[#problems + 1] = ("add.audit must be one of %s"):format(table.concat(want, ", "))
      end
    end
  end
  return problems
end

--- Configure and start the plugin. Safe to call again: the second call replaces the first one's
--- autocommands, commands, keys and options (modules switched off are stopped; the in-process
--- language servers are kept running, not restarted).
---@param opts? { commands?: boolean, keymaps?: boolean|table<string, string|false>, modules?: table<string, boolean>, add?: table }
function M.setup(opts)
  opts = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  if vim.fn.has("nvim-0.12") ~= 1 then
    vim.notify("xyno-crates: Neovim 0.12 or newer is required", vim.log.levels.ERROR)
    return
  end
  local problems = validate(opts)
  if #problems > 0 then
    vim.notify("xyno-crates: invalid options, nothing changed:\n  " .. table.concat(problems, "\n  "), vim.log.levels.ERROR)
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
  local add = require("xyno_crates.crate_add")
  local feat = require("xyno_crates.crate_features")
  local imp = require("xyno_crates.crate_import")
  -- options of the add module: defaults first, so a key dropped from opts returns to its default
  for k, v in pairs({ confirm = true, typosquat = true, audit = "hint" }) do
    add.config[k] = opts.add[k] == nil and v or opts.add[k]
  end
  local vet = require("xyno_crates.vet")
  vet.config.extra_popular = opts.add.extra_popular or {}
  vet.reset()
  if m.add then
    add.setup({ commands = opts.commands, keymap = keys.add })
  else
    add.stop()
  end
  if m.features then
    feat.setup({ commands = opts.commands, keymap = keys.fix })
  else
    feat.stop()
  end
  if m.import then
    imp.setup()
  else
    imp.stop()
  end
end

return M
