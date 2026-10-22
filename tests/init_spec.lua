-- xyno_crates.setup(): the one-line messages for a missing dependency, the modules
-- option, commands, and that no key is mapped by default. The modules start once per
-- process, so the opt-in keys are checked in init-keymaps_spec.lua.
local H = require("xyno_crates_test.helpers")
local C = require("xyno_crates")

--- Run fn with `blocked` modules unloadable; returns the notifications it produced.
local function without(blocked, fn)
  local notes = {}
  local orig = vim.notify
  vim.notify = function(msg, level)
    notes[#notes + 1] = { msg = msg, level = level }
  end
  local saved = {}
  for _, m in ipairs(blocked) do
    saved[m] = package.loaded[m]
    package.loaded[m] = nil
  end
  local searchers = package.loaders or package.searchers
  local block = function(name)
    if vim.tbl_contains(blocked, name) then
      return function()
        error("module '" .. name .. "' not found")
      end
    end
  end
  table.insert(searchers, 1, block)
  local ok, err = pcall(fn)
  table.remove(searchers, 1)
  for _, m in ipairs(blocked) do
    package.loaded[m] = saved[m] -- also nil: a failed require leaves a marker behind
  end
  vim.notify = orig
  return notes, ok, err
end

describe("setup without its dependencies", function()
  it("says which plugin is missing in one line, no Lua error, and starts nothing", function()
    local notes, ok = without({ "xyno_rust.crate_meta" }, function()
      C.setup({})
    end)
    H.ok(ok)
    H.eq(1, #notes)
    H.match(notes[1].msg, "needs xyno-rust.nvim", true)
    H.match(notes[1].msg, "xynorash/xyno-rust.nvim", true)
    H.not_ok(notes[1].msg:find("\n", 1, true), "one line")
    H.eq(vim.log.levels.ERROR, notes[1].level)
    H.eq(0, vim.fn.exists(":CrateAdd"))
    H.eq(0, vim.fn.exists(":CrateFeatures"))
  end)

  it("names xyno-imports.nvim when only that one is missing", function()
    local notes, ok = without({ "xyno_imports.engine" }, function()
      C.setup({})
    end)
    H.ok(ok)
    H.eq(1, #notes)
    H.match(notes[1].msg, "needs xyno-imports.nvim", true)
    H.eq(0, vim.fn.exists(":CrateAdd"))
  end)

  it("does not need xyno-imports.nvim when the add and import modules are off", function()
    local notes, ok = without({ "xyno_imports.engine" }, function()
      C.setup({ modules = { add = false, import = false, features = false } })
    end)
    H.ok(ok)
    H.eq(0, #notes)
  end)
end)

describe("setup", function()
  it("starts nothing for a module that is switched off", function()
    C.setup({ modules = { add = false, features = false, import = false } })
    H.eq(0, vim.fn.exists(":CrateAdd"))
    H.eq(0, vim.fn.exists(":CrateFeatures"))
  end)

  it("registers both commands and maps no key by default", function()
    C.setup({})
    H.eq(2, vim.fn.exists(":CrateAdd"))
    H.eq(2, vim.fn.exists(":CrateFeatures"))
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(buf)
    vim.bo[buf].filetype = "rust"
    H.eq("", vim.fn.maparg("<leader>rA", "n"))
    H.eq("", vim.fn.maparg("<leader>rG", "n"))
  end)

  it("serves the in-process code actions without a language server process", function()
    H.eq("xyno-crates", require("xyno_crates.crate_add").server_name)
    H.eq("xyno-features", require("xyno_crates.crate_features").client_name)
  end)
end)
