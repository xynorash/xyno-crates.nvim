-- One definition of what a feature name may look like, shared by every place that
-- hands feature names to cargo or to a manifest edit (crate_add, crate_features).
-- Cargo allows letters, digits, `_`, `-`, `+` and `.` (Unicode XID letters too; this
-- plugin accepts ASCII only, which is what crates.io feature names are in practice).
local M = {}

M.FEATURE_PAT = "^[A-Za-z0-9_.+-]+$"
M.FEATURE_MAX = 64

--- A single feature name.
function M.valid_feature(f)
  return type(f) == "string" and #f > 0 and #f <= M.FEATURE_MAX and f:match(M.FEATURE_PAT) ~= nil and f:sub(1, 1) ~= "-"
end

--- A non-empty list of feature names. (`allow_empty`: an empty list is fine too.)
function M.valid_features(list, allow_empty)
  if type(list) ~= "table" or (#list == 0 and not allow_empty) then
    return false
  end
  for _, f in ipairs(list) do
    if not M.valid_feature(f) then
      return false
    end
  end
  return true
end

return M
