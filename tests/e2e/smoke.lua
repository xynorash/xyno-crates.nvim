-- End-to-end smoke test (see tests/e2e/init.lua): the plugin is loaded by lazy.nvim,
-- setup() ran, every documented command exists, :help xyno-crates resolves, the
-- in-process language servers are configured, no key is mapped, and a missing
-- dependency gives one notification line.
local failures = {}
local function check(name, ok, detail)
  io.stdout:write(("%s %s%s\n"):format(ok and "ok  " or "FAIL", name, (not ok and detail) and (": " .. tostring(detail)) or ""))
  if not ok then
    failures[#failures + 1] = name
  end
end

check("lazy.nvim loaded xyno_crates", package.loaded["xyno_crates"] ~= nil)
for _, c in ipairs({ "CrateAdd", "CrateFeatures" }) do
  check("command :" .. c, vim.fn.exists(":" .. c) == 2)
end
for _, m in ipairs({ "crate_add", "crate_features", "crate_import" }) do
  check("require xyno_crates." .. m, (pcall(require, "xyno_crates." .. m)))
end
check("autocmd group xyno-crates-add", #vim.api.nvim_get_autocmds({ group = "xyno-crates-add" }) >= 4)
check("autocmd group xyno_crates_features", #vim.api.nvim_get_autocmds({ group = "xyno_crates_features" }) >= 1)
check("in-process server xyno-crates configured", vim.lsp.config["xyno-crates"] ~= nil)
check("no global <leader>rA by default", vim.fn.maparg("<leader>rA", "n") == "")
check("no global <leader>rG by default", vim.fn.maparg("<leader>rG", "n") == "")

local repo = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
vim.cmd("helptags " .. vim.fn.fnameescape(repo .. "/doc"))
for _, tag in ipairs({ "xyno-crates", "xyno-crates-setup", "xyno-crates-api", ":CrateAdd", ":CrateFeatures" }) do
  local ok, err = pcall(vim.cmd, "help " .. tag)
  check(":help " .. tag, ok, err)
end
vim.cmd("only")

-- a missing dependency gives one notification line and no Lua error
local notes = {}
local orig = vim.notify
vim.notify = function(msg)
  notes[#notes + 1] = msg
end
local mods = { "xyno_rust.crate_meta", "xyno_rust.code_actions", "xyno_rust.fsutil", "xyno_rust.rust_restart", "xyno_imports.engine" }
local saved = {}
for _, k in ipairs(mods) do
  saved[k] = package.loaded[k]
  package.loaded[k] = nil
end
local saved_path = package.path
local saved_loaders = package.loaders
package.loaders = { function() return nil end }
package.path = ""
local rtp = vim.o.runtimepath
vim.o.runtimepath = ""
local ok = pcall(require("xyno_crates").setup, {})
vim.o.runtimepath = rtp
package.path = saved_path
package.loaders = saved_loaders
for _, k in ipairs(mods) do
  package.loaded[k] = saved[k]
end
vim.notify = orig
check("setup() without xyno-rust: no error", ok)
check("setup() without xyno-rust: one line", #notes == 1 and not notes[1]:find("\n"), vim.inspect(notes))

if #failures > 0 then
  vim.cmd("cquit 1")
end
vim.cmd("qa!")
