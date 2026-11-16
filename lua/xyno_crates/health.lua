-- :checkhealth xyno_crates
local M = {}

function M.check()
  local h = vim.health
  h.start("xyno-crates")
  if vim.fn.has("nvim-0.12") == 1 then
    h.ok("Neovim " .. tostring(vim.version()))
  else
    h.error("Neovim 0.12 or newer is required")
  end
  for _, mod in ipairs({
    "xyno_rust.crate_meta",
    "xyno_rust.code_actions",
    "xyno_rust.fsutil",
    "xyno_rust.rust_restart",
  }) do
    if pcall(require, mod) then
      h.ok(mod .. " (xyno-rust.nvim)")
    else
      h.error(mod .. " not found", { "install xynorash/xyno-rust.nvim" })
    end
  end
  if pcall(require, "xyno_imports.engine") then
    h.ok("xyno_imports.engine (xyno-imports.nvim: import from crates that are not dependencies yet)")
  else
    h.warn(
      "xyno-imports.nvim not found: the add and import modules cannot start",
      { "install xynorash/xyno-imports.nvim" }
    )
  end
  for _, tool in ipairs({ "cargo", "curl" }) do
    if vim.fn.executable(tool) == 1 then
      h.ok(tool .. " found")
    else
      h.error(tool .. " not found", { tool == "cargo" and "install a Rust toolchain" or "crates.io lookups use curl" })
    end
  end
  if pcall(vim.treesitter.language.add, "rust") then
    h.ok("tree-sitter parser for rust (the unknown-crate scan)")
  else
    h.warn("no tree-sitter parser for rust: unknown crates are not found", { ":TSInstall rust" })
  end

  h.start("xyno-crates: cargo add confirmation")
  local ca = require("xyno_crates.crate_add")
  if ca.config.confirm then
    h.ok("a preview and a question come before `cargo add` (crate, version, features, downloads, age)")
  else
    h.warn("confirm = false: `cargo add` runs without a question (add = { confirm = true } turns it back on)")
  end
  h.info(
    "typosquat warning: "
      .. (ca.config.typosquat and "on (edit distance against a list of popular crates, hint only)" or "off")
  )
  local audit = vim.fn.executable("cargo-audit") == 1
  if ca.config.audit == "off" then
    h.info("cargo-audit: off")
  elseif audit then
    h.ok(
      ("cargo-audit installed, mode `%s` (%s)"):format(
        ca.config.audit,
        ca.config.audit == "run" and "runs after each add" or "mentioned in the preview"
      )
    )
  else
    h.info("cargo-audit not installed (optional): no advisory hint", { "cargo install cargo-audit" })
  end
  local cm = require("xyno_rust.crate_meta")
  h.info(("crates.io API: %s, index: %s"):format(cm.config.api_url, cm.config.index_url))
  if tostring(cm.config.api_url):match("^http://") or tostring(cm.config.index_url):match("^http://") then
    h.warn("the crates.io URLs use plain http")
  end
  local v = require("xyno_crates.vet").config
  h.info(
    ("typosquat: crates with %d+ downloads are not warned about; %d extra guarded names"):format(
      v.popular_downloads,
      #v.extra_popular
    )
  )
end

return M
