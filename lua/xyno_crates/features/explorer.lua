-- xyno-crates features: the feature explorer (:CrateFeatures) and its picker.
-- Part of xyno_crates.crate_features (the facade merges every part into one table).
local M = {}
local cm = require("xyno_rust.crate_meta")


local Scan = require("xyno_crates.features.scan")
local Tables = require("xyno_crates.features.tables")
local Manifest = require("xyno_crates.features.manifest")
local read_file = Scan._read_file
local strip = Scan._strip
local find_dep = Manifest._find_dep
local is_implicit = Tables._is_implicit

-- ============================================================ the explorer

--- Words of the workspace sources (cached for a few seconds).
local words_cache = {}
local function workspace_words(meta)
  local hit = words_cache[meta.root]
  if hit and os.time() - hit.at < 30 then
    return hit.words, hit.truncated
  end
  local words, files, bytes, truncated = {}, 0, 0, false
  for _, m in ipairs(meta.members) do
    for _, sub in ipairs({ "src", "tests", "examples", "benches", "build.rs" }) do
      local p = m.dir .. "/" .. sub
      local list = {}
      if sub == "build.rs" then
        list = { p }
      else
        for name, t in vim.fs.dir(p, { depth = 8 }) do
          if t == "file" and name:match("%.rs$") then
            list[#list + 1] = p .. "/" .. name
          end
        end
      end
      for _, f in ipairs(list) do
        if files >= Scan.config.max_unused_files or bytes >= Scan.config.max_unused_bytes then
          truncated = true
          break
        end
        local text = read_file(f, Scan.config.max_file_bytes)
        if text then
          files, bytes = files + 1, bytes + #text
          for w in strip(text):gmatch("[%a_][%w_]*") do
            words[w] = true
          end
        end
      end
    end
  end
  words_cache[meta.root] = { words = words, at = os.time(), truncated = truncated }
  return words, truncated
end

--- Everything the explorer shows about one dependency entry.
--- { crate, version, member, kind, default = {..}, truncated, scanned_files,
---   features = { { name, declared, on, implicit, in_default, implies = {..},
---   items = {..}, unused } } }
function M.explore(meta, d)
  local ft = Tables.features_of(d)
  local declared = {}
  for _, f in ipairs(d.features or {}) do
    declared[f] = true
  end
  local on = Tables.enabled_set(d, ft)
  for _, f in ipairs(d.resolved and d.resolved.enabled_features or {}) do
    on[f] = on[f] or "unified"
  end
  local default_set = ft.default and Tables.closure(ft, "default") or {}
  local dir = d.resolved and d.resolved.dir
  if not (dir and vim.uv.fs_stat(dir)) then
    dir = cm.registry_dir(d.name, d.resolved and d.resolved.version)
  end
  local idx = dir and Scan.scan(dir) or { items = {}, files = 0, truncated = false }

  -- item -> the features that unlock it (from scratch)
  local unlocks = {}
  for name in pairs(idx.items) do
    local gate = Scan.gate_of(idx, name)
    if gate then
      local feats = Tables.resolve(gate, ft, {})
      for _, f in ipairs(feats or {}) do
        unlocks[f] = unlocks[f] or {}
        table.insert(unlocks[f], name)
      end
    end
  end
  local words, words_truncated = workspace_words(meta)

  local list = {}
  for f, v in pairs(ft) do
    local items = unlocks[f] or {}
    table.sort(items)
    local implies = {}
    for g in pairs(Tables.closure(ft, f)) do
      if g ~= f then
        implies[#implies + 1] = g
      end
    end
    table.sort(implies)
    local used = false
    for _, it in ipairs(items) do
      used = used or words[it] == true
    end
    list[#list + 1] = {
      name = f,
      declared = declared[f] or false,
      on = on[f] and true or false,
      via_default = d.uses_default_features and default_set[f] and not declared[f] or false,
      unified = on[f] == "unified",
      implicit = is_implicit(ft, f),
      in_default = default_set[f] or false,
      implies = implies,
      items = items,
      unused = (declared[f] or false) and #items > 0 and not used,
    }
  end
  table.sort(list, function(a, b)
    if a.implicit ~= b.implicit then
      return not a.implicit
    end
    return a.name < b.name
  end)
  local default_list = vim.tbl_filter(function(f)
    return f ~= "default"
  end, vim.tbl_keys(default_set))
  table.sort(default_list)
  return {
    crate = d.name,
    alias = d.alias,
    version = d.resolved and d.resolved.version,
    member = d.member,
    kind = d.kind,
    uses_default_features = d.uses_default_features,
    default = default_list,
    features = list,
    truncated = idx.truncated,
    scanned_files = idx.files,
    words_truncated = words_truncated,
    dep = d,
  }
end

--- One line of the feature list.
function M.feature_line(f)
  local mark = f.declared and "[x]" or (f.on and "[~]" or "[ ]")
  local bits = {}
  if f.in_default then
    bits[#bits + 1] = "default"
  end
  if f.via_default then
    bits[#bits + 1] = "on by default"
  elseif f.on and not f.declared then
    bits[#bits + 1] = f.unified and "on (other crate)" or "on (implied)"
  end
  if #f.items > 0 then
    local shown = vim.list_slice(f.items, 1, 4)
    bits[#bits + 1] = "unlocks " .. table.concat(shown, ", ") .. (#f.items > 4 and (" +" .. (#f.items - 4)) or "")
  end
  if f.unused then
    bits[#bits + 1] = "unused?"
  end
  return mark .. " " .. f.name .. (#bits > 0 and ("  " .. table.concat(bits, "; ")) or "")
end

--- Preview text of a feature.
function M.feature_preview(info, f)
  local out = { "# " .. info.crate .. " " .. (info.version or "") .. " / " .. f.name, "" }
  out[#out + 1] = "declared in Cargo.toml: " .. (f.declared and "yes" or "no") .. "; effective: " .. (f.on and "yes" or "no")
  if #f.implies > 0 then
    out[#out + 1] = "implies: " .. table.concat(f.implies, ", ")
  end
  if f.implicit then
    out[#out + 1] = "(implicit feature of the optional dependency `" .. f.name .. "`)"
  end
  out[#out + 1] = ""
  if #f.items > 0 then
    out[#out + 1] = "unlocks (" .. #f.items .. "):"
    for i, it in ipairs(f.items) do
      if i > 200 then
        out[#out + 1] = "  ..."
        break
      end
      out[#out + 1] = "  " .. it
    end
  else
    out[#out + 1] = "no gated public item found by the source scan"
  end
  if f.unused then
    out[#out + 1] = ""
    out[#out + 1] = "unused?: none of these names appears in the workspace sources"
  end
  if info.truncated then
    out[#out + 1] = ""
    out[#out + 1] = ("(the source scan stopped after %d files: the list can be incomplete)"):format(info.scanned_files)
  end
  return out
end

--- The picker. Specs replace it. items = { { text, data } }, opts = { title,
--- preview = fn(item) -> lines, on_confirm = fn(item), on_toggle = fn(item) }.
function M.pick(items, opts)
  local Snacks = rawget(_G, "Snacks")
  if Snacks and Snacks.picker and Snacks.picker.pick then
    local snacks_items = {}
    for _, it in ipairs(items) do
      snacks_items[#snacks_items + 1] = { text = it.text, data = it.data }
    end
    local function toggle(picker, item)
      if item and opts.on_toggle then
        picker:close()
        vim.schedule(function()
          opts.on_toggle(item)
        end)
      end
    end
    return Snacks.picker.pick({
      title = opts.title,
      items = snacks_items,
      format = function(item)
        return { { item.text } }
      end,
      preview = opts.preview and function(ctx)
        ctx.preview:reset()
        ctx.preview:set_lines(opts.preview(ctx.item))
        ctx.preview:highlight({ ft = "markdown" })
      end or "none", -- the default previews item.file: an error plus a table dump for these
      confirm = function(picker, item)
        if not item then
          return
        end
        picker:close()
        vim.schedule(function()
          (opts.on_confirm or opts.on_toggle)(item)
        end)
      end,
      actions = { toggle_feature = toggle },
      win = {
        input = { keys = { ["<C-t>"] = { "toggle_feature", mode = { "i", "n" }, desc = "Toggle feature" } } },
        list = { keys = { ["t"] = "toggle_feature" } },
      },
    })
  end
  vim.ui.select(items, {
    prompt = opts.title,
    format_item = function(it)
      return it.text
    end,
  }, function(choice)
    if choice then
      (opts.on_confirm or opts.on_toggle)(choice)
    end
  end)
end

local open_features

local function toggle_feature(info, f)
  local d = info.dep
  local features = { f.name }
  -- declared in this manifest: remove it; anything else (off, on by default,
  -- implied, unified from another crate) is switched on by declaring it
  local turn_on = not f.declared
  Manifest.set_features(d, features, turn_on, function(ok, how)
    if ok then
      vim.notify(("%s feature `%s` of `%s` (%s)"):format(turn_on and "Enabled" or "Disabled", f.name, info.crate, how), vim.log.levels.INFO)
    else
      vim.notify(("Cannot %s `%s`: %s"):format(turn_on and "enable" or "disable", f.name, how or "?"), vim.log.levels.WARN)
    end
    -- the manifest changed: show the list again with fresh metadata
    cm.metadata_async(info.root, function(meta)
      if meta then
        local nd = find_dep(meta, { member = d.member, kind = d.kind, crate = d.name, target = d.target })
        if nd then
          open_features(meta, nd, info.root)
        end
      end
    end, { refresh = true })
  end)
end

function open_features(meta, d, root)
  local info = M.explore(meta, d)
  info.root = root
  local items = {}
  for _, f in ipairs(info.features) do
    items[#items + 1] = { text = M.feature_line(f), data = f }
  end
  local title = ("%s %s  (%s%s)  default: %s%s"):format(
    info.crate,
    info.version or "",
    info.member,
    info.kind ~= "normal" and (", " .. info.kind) or "",
    info.uses_default_features and (#info.default > 0 and table.concat(info.default, ", ") or "none") or "off",
    info.truncated and "  [scan capped]" or ""
  )
  require("xyno_crates.crate_features").pick(items, {
    title = title .. "  <CR>/<C-t> toggle",
    preview = function(item)
      return M.feature_preview(info, item.data)
    end,
    on_toggle = function(item)
      toggle_feature(info, item.data)
    end,
  })
  return info
end

--- :CrateFeatures [crate]
function M.open(crate)
  local root = cm.root()
  if not root then
    return vim.notify("CrateFeatures: not in a cargo workspace", vim.log.levels.WARN)
  end
  cm.metadata_async(root, function(meta, err)
    if not meta then
      return vim.notify("CrateFeatures: " .. tostring(err), vim.log.levels.WARN)
    end
    local deps = vim.tbl_filter(function(d)
      return not crate or crate == "" or d.name == crate or d.alias == crate
    end, meta.dependencies)
    if #deps == 0 then
      return vim.notify(("CrateFeatures: no dependency %s"):format(crate and ("`" .. crate .. "`") or ""), vim.log.levels.WARN)
    end
    if #deps == 1 then
      return open_features(meta, deps[1], root)
    end
    local items = {}
    for _, d in ipairs(deps) do
      local declared = #d.features > 0 and table.concat(d.features, ", ") or "-"
      items[#items + 1] = {
        text = ("%s %s  %s%s  features: %s%s"):format(d.name, d.resolved and d.resolved.version or "", d.member, d.kind ~= "normal" and (" (" .. d.kind .. ")") or "", declared, d.uses_default_features and "" or "  (no default)"),
        data = d,
      }
    end
    require("xyno_crates.crate_features").pick(items, {
      title = "Dependencies  <CR> features",
      on_confirm = function(item)
        open_features(meta, item.data, root)
      end,
    })
  end)
end

function M.complete()
  local root = cm.root()
  local seen, out = {}, {}
  local meta = root and cm.metadata(root, { timeout = 3000 })
  for _, d in ipairs(meta and meta.dependencies or {}) do
    if not seen[d.name] then
      seen[d.name] = true
      out[#out + 1] = d.name
    end
  end
  table.sort(out)
  return out
end

return M
