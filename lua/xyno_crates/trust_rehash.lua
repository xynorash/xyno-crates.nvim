-- The editor's own edits of a Cargo.toml (`cargo add`, a feature switch) are not a surprise to the workspace
-- trust of xyno-rust.nvim: record the new content, so the next action does not ask again. Only the manifests
-- this plugin edited may differ from what was trusted (a pulled build.rs next to them still asks).
local M = {}

--- `manifests`: the paths written (the member manifest, and the workspace manifest cargo add may touch).
--- Returns whether a trust entry was refreshed. Silent without a trust module (older xyno-rust.nvim).
function M.rehash(root, manifests)
  local ok, trust = pcall(require, "xyno_rust.trust")
  if not ok or type(trust.rehash) ~= "function" then
    return false
  end
  local done = false
  pcall(function()
    root = root or require("xyno_rust.rust_context").root(manifests[1], { nowait = true })
    if root then
      done = trust.rehash(root, manifests) == true
    end
  end)
  return done
end

return M
