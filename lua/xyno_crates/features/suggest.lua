-- xyno-crates features: compiler diagnostics to names, and the feature that would fix them.
-- Part of xyno_crates.crate_features (the facade merges every part into one table).
local M = {}
local cm = require("xyno_rust.crate_meta")


local Scan = require("xyno_crates.features.scan")
local Tables = require("xyno_crates.features.tables")

-- ================================================== diagnostics -> names

local function ident(s)
  return s and s:match("^[A-Za-z_][A-Za-z0-9_]*$") ~= nil
end

--- Names a rustc / rust-analyzer message says it cannot find:
--- { { name, qual } } (qual: the path before the name, when the message has one).
function M.names_from_message(msg)
  local out, seen = {}, {}
  local function add(path, qual)
    path = path:gsub("^::", "")
    local head, last = path:match("^(.*)::([^:]+)$")
    local name = last or path
    qual = qual or (head and head:match("^([^:]+)")) or nil
    if ident(name) and not seen[name] then
      seen[name] = true
      out[#out + 1] = { name = name, qual = qual }
    end
  end
  for n in msg:gmatch("cannot find [%w%- ]-`([^`]+)`") do
    add(n)
  end
  for n, q in msg:gmatch("could not find `([^`]+)` in `([^`]+)`") do
    add(n, (q:match("^([^:]+)")))
  end
  for n, q in msg:gmatch("no `([^`]+)` in `([^`]+)`") do
    add(n, (q:match("^([^:]+)")))
  end
  for n in msg:gmatch("unresolved import `([^`]+)`") do
    add(n)
  end
  for n in msg:gmatch("unresolved macro `([^`]+)`") do
    add(n)
  end
  for n in msg:gmatch("no `([^`]+)` in the root") do
    add(n)
  end
  for n in msg:gmatch("failed to resolve: could not find `([^`]+)`") do
    add(n)
  end
  return out
end

local function vim_diag(d)
  return {
    message = d.message or "",
    lnum = d.lnum or (d.range and d.range.start.line) or 0,
    col = d.col or (d.range and d.range.start.character) or 0,
    end_lnum = d.end_lnum or (d.range and d.range["end"].line),
    end_col = d.end_col or (d.range and d.range["end"].character),
  }
end

local function diag_names(d, lines)
  local names = M.names_from_message(d.message)
  if #names > 0 or not (d.message:match("[Uu]nresolved") or d.message:match("cannot find") or d.message:match("could not find")) then
    return names
  end
  -- no name in the message: the identifier under the diagnostic, when it
  -- sits in an attribute (`#[derive(Serialize)]`, `#[tokio::main]`)
  local line = lines[d.lnum + 1] or ""
  if line:find("#%s*%[") and (d.end_lnum == nil or d.end_lnum == d.lnum) and d.end_col then
    local path = line:sub(d.col + 1, d.end_col):match("^[%a_][%w_:]*$")
    if path then
      local head, last = path:match("^(.*)::([^:]+)$")
      names[1] = { name = last or path, qual = head and head:match("^([^:]+)") or nil }
    end
  end
  return names
end

-- ================================================================ suggest

local function kind_of_file(file)
  if file:match("/build%.rs$") then
    return "build"
  end
  if file:match("/tests/") or file:match("/examples/") or file:match("/benches/") then
    return "dev"
  end
  return "normal"
end

--- Does `lines` mention `name` imported or written through the alias?
local function mentions_via(text, alias, name)
  for usepath in text:gmatch("use%s+" .. alias .. "%s*::(.-);") do
    if usepath:find("%f[%w_]" .. name .. "%f[^%w_]") then
      return true
    end
  end
  return text:find(alias .. "%s*::[%w_:%s{},]-%f[%w_]" .. name .. "%f[^%w_]") ~= nil
end

--- Suggestions for the diagnostics of a file, from the metadata of its
--- workspace. diags: vim.Diagnostic-like { message, lnum, col, end_lnum,
--- end_col } (0-based). Pure apart from the cached source scans.
--- Returns { { name, crate, alias, features, member, manifest, kind, truncated } }
function M.suggest(meta, file, lines, diags)
  local out, seen = {}, {}
  local member = cm.member_of(meta, file)
  local text = table.concat(lines, "\n")
  local want_kind = kind_of_file(file)
  local deps = {}
  for _, d in ipairs(meta.dependencies) do
    if not member or d.member == member.name then
      deps[#deps + 1] = d
    end
  end
  -- the kind the file belongs to first (a test file reads dev-dependencies too)
  table.sort(deps, function(a, b)
    local ra, rb = a.kind == want_kind and 0 or 1, b.kind == want_kind and 0 or 1
    return ra < rb
  end)
  for _, diag in ipairs(diags) do
    local dd = vim_diag(diag)
    for _, n in ipairs(diag_names(dd, lines)) do
      local cands = deps
      local hinted = {}
      for _, d in ipairs(deps) do
        if (n.qual and (n.qual == d.alias or n.qual == d.name)) or mentions_via(text, d.alias, n.name) then
          hinted[#hinted + 1] = d
        end
      end
      if #hinted > 0 then
        cands = hinted
      end
      for _, d in ipairs(cands) do
        local key = d.member .. "|" .. d.kind .. "|" .. d.name .. "|" .. n.name
        local dir = d.resolved and d.resolved.dir
        if not (dir and vim.uv.fs_stat(dir)) then
          dir = cm.registry_dir(d.name, d.resolved and d.resolved.version)
        end
        if dir and not seen[key] and cm.valid_name(d.name) then
          seen[key] = true
          local idx = Scan.scan(dir)
          local gate = Scan.gate_of(idx, n.name)
          if gate then
            local ft = Tables.features_of(d)
            local feats = Tables.resolve(gate, ft, Tables.enabled_set(d, ft))
            if feats and #feats > 0 then
              local dup = false
              for _, s in ipairs(out) do
                if s.member == d.member and s.kind == d.kind and s.crate == d.name and table.concat(s.features, ",") == table.concat(feats, ",") then
                  dup = true
                  s.names[#s.names + 1] = n.name
                end
              end
              if not dup then
                out[#out + 1] = {
                  name = n.name,
                  names = { n.name },
                  crate = d.name,
                  alias = d.alias,
                  features = feats,
                  member = d.member,
                  manifest = d.member_manifest,
                  kind = d.kind,
                  target = d.target,
                  truncated = idx.truncated,
                }
              end
            end
          end
        end
      end
    end
  end
  return out
end

function M.title(s)
  local q = vim.tbl_map(function(f)
    return "`" .. f .. "`"
  end, s.features)
  return ("Enable feature%s %s of `%s`"):format(#q > 1 and "s" or "", table.concat(q, ", "), s.crate)
end

return M
