-- xyno-crates features: feature tables: closures, effective sets, resolving a gate.
-- Part of xyno_crates.crate_features (the facade merges every part into one table).
local M = {}
local cm = require("xyno_rust.crate_meta")



-- =========================================================== feature tables

local function is_implicit(ft, f)
  local v = ft[f]
  return v ~= nil and #v == 1 and v[1] == "dep:" .. f
end

--- Every feature switched on by enabling `f` (itself included).
function M.closure(ft, f, acc)
  acc = acc or {}
  if acc[f] then
    return acc
  end
  acc[f] = true
  for _, item in ipairs(ft[f] or {}) do
    if not item:match("^dep:") then
      local feat = item:match("^([^/?]+)[/?]") or item
      if ft[feat] or not item:find("/", 1, true) then
        M.closure(ft, feat, acc)
      end
    end
  end
  return acc
end

local function closure_set(ft, list)
  local acc = {}
  for _, f in ipairs(list) do
    M.closure(ft, f, acc)
  end
  return acc
end

local function count(set)
  local n = 0
  for _ in pairs(set) do
    n = n + 1
  end
  return n
end

--- Drop every feature another one of the list already implies.
local function reduce(ft, list)
  local out = {}
  for _, r in ipairs(list) do
    local implied = false
    for _, o in ipairs(list) do
      if o ~= r and M.closure(ft, o)[r] and not M.closure(ft, r)[o] then
        implied = true
      end
    end
    if not implied then
      out[#out + 1] = r
    end
  end
  table.sort(out)
  return out
end

--- The user-facing feature to switch on for the requirement `r`: `r` itself
--- unless it is only the implicit feature of an optional dependency and a
--- named feature (derive = ["serde_derive"]) switches it on.
local function nice_feature(ft, r)
  if ft[r] and not is_implicit(ft, r) then
    return r
  end
  local best, best_n
  for f in pairs(ft) do
    if f ~= r and f ~= "default" and not is_implicit(ft, f) then
      local c = M.closure(ft, f)
      if c[r] then
        local n = count(c)
        if not best or n < best_n or (n == best_n and f < best) then
          best, best_n = f, n
        end
      end
    end
  end
  return best or r
end

--- The minimal set of features to enable so that `gate` holds, given the
--- features that are on (`enabled` = set). nil when `gate` is already
--- satisfied (the name is not missing because of a feature) or cannot be.
--- Returns list, alternative-chosen.
function M.resolve(gate, ft, enabled)
  local best
  for _, alt in ipairs(gate) do
    local missing = {}
    for f in pairs(alt) do
      if not enabled[f] then
        missing[#missing + 1] = f
      end
    end
    if #missing == 0 then
      return nil, "enabled"
    end
    table.sort(missing)
    local mapped = {}
    for _, r in ipairs(missing) do
      mapped[#mapped + 1] = nice_feature(ft, r)
    end
    local list = reduce(ft, vim.fn.uniq(vim.fn.sort(mapped)))
    local key = string.format("%03d", #list) .. table.concat(list, ",")
    if not best or key < best.key then
      best = { key = key, list = list }
    end
  end
  if not best then
    return nil, "never"
  end
  return best.list
end

--- Features on for a declared dependency: the declared ones and what they
--- imply, plus the default set unless default-features = false.
function M.enabled_set(d, ft)
  local list = vim.deepcopy(d.features or {})
  if d.uses_default_features and ft.default then
    list[#list + 1] = "default"
  end
  return closure_set(ft, list)
end

--- The [features] table of a dependency (metadata first, the registry
--- manifest otherwise: the implicit features of optional deps are added).
function M.features_of(d)
  if d.resolved and d.resolved.features and next(d.resolved.features) ~= nil then
    return d.resolved.features
  end
  local dir = d.resolved and d.resolved.dir or cm.registry_dir(d.name)
  local toml = dir and cm.read_manifest(dir)
  if not toml then
    return (d.resolved and d.resolved.features) or {}
  end
  local ft = cm.parse_features(toml)
  local explicit = {}
  for _, list in pairs(ft) do
    for _, item in ipairs(list) do
      local x = item:match("^dep:(.+)$")
      if x then
        explicit[x] = true
      end
    end
  end
  local section
  for line in (toml .. "\n"):gmatch("(.-)\n") do
    local h = line:match("^%[(.-)%]")
    if h then
      section = h
      local n = h:match("^dependencies%.([%w_%-]+)$") or h:match("^target%..*%.dependencies%.([%w_%-]+)$")
      if n then
        section = { name = n }
      end
    end
    local name = type(section) == "string" and (section == "dependencies" or section:match("^target%..*%.dependencies$")) and line:match("^([%w_%-]+)%s*=.*optional%s*=%s*true")
    if type(section) == "table" and line:match("^optional%s*=%s*true") then
      name = section.name
    end
    if name and not explicit[name] and not ft[name] then
      ft[name] = { "dep:" .. name }
    end
  end
  return ft
end

M._is_implicit = is_implicit

return M
