-- xyno_crates.setup{ keymaps = true }: the default keys are buffer-local in Rust
-- files (and <leader>rA also in Cargo.toml), never global.
local H = require("xyno_crates_test.helpers")
local C = require("xyno_crates")

describe("setup with keymaps = true", function()
  it("maps the default keys in Rust buffers only", function()
    C.setup({ keymaps = true })
    H.eq(C.default_keymaps.add, "<leader>rA")
    local rs = H.tmpdir() .. "/x.rs"
    vim.fn.writefile({ "fn main() {}" }, rs)
    vim.cmd.edit(vim.fn.fnameescape(rs))
    vim.bo.filetype = "rust"
    local add = H.wait_for(function()
      local m = vim.fn.maparg("<leader>rA", "n", false, true)
      return m.buffer == 1 and m
    end, 3000, "the buffer-local add key")
    H.match(add.rhs, "CrateAdd", true)
    local fix = vim.fn.maparg("<leader>rG", "n", false, true)
    H.eq(1, fix.buffer)
    H.eq("Fix missing crate feature", fix.desc)
    vim.cmd("enew")
    H.eq("", vim.fn.maparg("<leader>rA", "n"))
    H.eq("", vim.fn.maparg("<leader>rG", "n"))
  end)

  it("maps <leader>rA in a Cargo.toml too", function()
    local dir = H.tmpdir()
    vim.fn.writefile({ "[package]", 'name = "x"' }, dir .. "/Cargo.toml")
    vim.cmd.edit(vim.fn.fnameescape(dir .. "/Cargo.toml"))
    vim.bo.filetype = "toml"
    H.wait_for(function()
      return vim.fn.maparg("<leader>rA", "n", false, true).buffer == 1
    end, 3000, "the key in Cargo.toml")
  end)
end)
