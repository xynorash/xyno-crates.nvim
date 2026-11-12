-- xyno-crates features: Cargo.toml edits (text edit, cargo add) and applying them.
-- Part of xyno_crates.crate_features (the facade merges every part into one table).
local M = {}
local cm = require("xyno_rust.crate_meta")


local Scan = require("xyno_crates.features.scan")
local close_of = Scan._close_of

-- ============================================================ Cargo.toml edit

local KIND_SECTION = { normal = "dependencies", dev = "dev-dependencies", build = "build-dependencies" }

local function norm_header(h)
  return (h:gsub("[%s\"']", ""))
end

local function key_pat(key)
  return (key:gsub("[%-%.]", "%%%0"))
end

local function split_lines(text)
  local lines, p = {}, 1
  while p <= #text + 1 do
    local nl = text:find("\n", p, true)
    local e = nl and nl - 1 or #text
    lines[#lines + 1] = { s = p, e = e, t = text:sub(p, e) }
    if not nl then
      break
    end
    p = nl + 1
  end
  return lines
end

--- Add (op = "add") or remove a feature in the array whose `[` is at `lb`.
--- Returns the new text, or nil when nothing changes.
local function array_edit(text, lb, op, feature)
  -- one walk over the array: `#` comments (which may hold `[` or `]`) are skipped, both
  -- "basic" and 'literal' strings are items
  local rb
  local items = {}
  local i = lb + 1
  while i <= #text do
    local c = text:sub(i, i)
    if c == '"' or c == "'" then
      local e = text:find(c, i + 1, true) or #text
      items[#items + 1] = { s = i, e = e, v = text:sub(i + 1, e - 1) }
      i = e + 1
    elseif c == "#" then
      i = (text:find("\n", i, true) or #text) + 1
    elseif c == "]" then
      rb = i
      break
    else
      i = i + 1
    end
  end
  if not rb then
    return nil
  end
  local inner = text:sub(lb + 1, rb - 1)
  if op == "add" then
    for _, it in ipairs(items) do
      if it.v == feature then
        return nil
      end
    end
    local q = '"' .. feature .. '"'
    if #items == 0 then
      return text:sub(1, lb) .. q .. text:sub(rb)
    end
    local last = items[#items]
    local ins
    if inner:find("\n", 1, true) then
      local ls = last.s
      while ls > 1 and text:sub(ls - 1, ls - 1) ~= "\n" do
        ls = ls - 1
      end
      local indent = text:sub(ls, last.s - 1):match("^%s*") or "  "
      ins = ",\n" .. indent .. q
    else
      ins = ", " .. q
    end
    return text:sub(1, last.e) .. ins .. text:sub(last.e + 1)
  end
  for k, it in ipairs(items) do
    if it.v == feature then
      local s, e = it.s, it.e
      local after = text:match("^[ \t]*,[ \t]*()", e + 1)
      if after then
        e = after - 1
      else
        local before = text:sub(1, s - 1):match("(),[ \t\n]*$")
        if before then
          s = before
        end
      end
      return text:sub(1, s - 1) .. text:sub(e + 1)
    end
  end
  return nil
end

--- Add or remove `features` for dependency `spec.key` in the dependency table
--- of `spec.kind` (and `spec.target`) of a Cargo.toml text. spec = { key,
--- kind, target, workspace }. Returns new text or nil, reason.
function M.edit_manifest(text, spec, op, features)
  local lines = split_lines(text)
  local suffix = spec.workspace and "workspace.dependencies" or KIND_SECTION[spec.kind or "normal"]
  local want = suffix
  if spec.target and not spec.workspace then
    want = "target." .. norm_header(spec.target) .. "." .. suffix
  end
  local kp = key_pat(spec.key)
  local secs

  local result = text
  local function apply_one(f)
    local cur = result
    lines = split_lines(cur)
    -- recompute section ranges on the current text
    secs = {}
    for i, l in ipairs(lines) do
      local h = l.t:match("^%s*%[([%w_%-%.\"' ()%%=,:]-)%]%s*#?.*$")
      if h and not l.t:match("^%s*%[%[") then
        if #secs > 0 then
          secs[#secs].last = i - 1
        end
        secs[#secs + 1] = { name = norm_header(h), first = i }
      end
    end
    if #secs > 0 then
      secs[#secs].last = #lines
    end

    for _, sec in ipairs(secs) do
      if sec.name == want .. "." .. spec.key then
        -- [dependencies.serde]
        for i = sec.first + 1, sec.last do
          local l = lines[i]
          local lb = l.t:match("^%s*features%s*=%s*()%[")
          if lb then
            local new = array_edit(cur, l.s + lb - 1, op, f)
            return new, new == nil and (op == "add" and "already enabled in this manifest" or "feature not declared in this manifest") or nil
          end
        end
        if op == "remove" then
          return nil, "feature not declared in this manifest"
        end
        local at = sec.last
        while at > sec.first and lines[at].t:match("^%s*$") do
          at = at - 1
        end
        local ins = lines[at].e
        return cur:sub(1, ins) .. '\nfeatures = ["' .. f .. '"]' .. cur:sub(ins + 1)
      elseif sec.name == want then
        -- dotted keys: serde.workspace = true / serde.features = [..]
        local last_dotted
        for i = sec.first + 1, sec.last do
          local l = lines[i]
          local dk = l.t:match("^%s*[\"']?" .. kp .. "[\"']?%.([%w_%-]+)%s*=")
          if dk then
            last_dotted = i
            if dk == "features" then
              local lb = l.t:match("=%s*()%[")
              if lb then
                local new = array_edit(cur, l.s + lb - 1, op, f)
                return new, new == nil and (op == "add" and "already enabled in this manifest" or "feature not declared in this manifest") or nil
              end
            end
          end
        end
        if last_dotted then
          if op == "remove" then
            return nil, "feature not declared in this manifest"
          end
          local l = lines[last_dotted]
          local indent = l.t:match("^%s*")
          return cur:sub(1, l.e) .. "\n" .. indent .. spec.key .. '.features = ["' .. f .. '"]' .. cur:sub(l.e + 1)
        end
        for i = sec.first + 1, sec.last do
          local l = lines[i]
          local vstart = l.t:match("^%s*[\"']?" .. kp .. "[\"']?%s*=%s*()")
          if vstart then
            local abs = l.s + vstart - 1
            local c = cur:sub(abs, abs)
            if c == '"' then
              if op == "remove" then
                return nil, "feature not declared in this manifest"
              end
              local e = cur:find('"', abs + 1, true)
              local ver = cur:sub(abs + 1, (e or abs + 1) - 1)
              return cur:sub(1, abs - 1) .. '{ version = "' .. ver .. '", features = ["' .. f .. '"] }' .. cur:sub((e or abs) + 1)
            elseif c == "{" then
              local e = close_of(cur, abs)
              if not e then
                return nil, "cannot read the dependency entry"
              end
              local tbl = cur:sub(abs, e)
              local fl = tbl:match("[{,%s]features%s*=%s*()%[")
              if fl then
                local new = array_edit(cur, abs + fl - 1, op, f)
                return new, new == nil and (op == "add" and "already enabled in this manifest" or "feature not declared in this manifest") or nil
              end
              if op == "remove" then
                return nil, "feature not declared in this manifest"
              end
              local inner = tbl:sub(2, -2):gsub("%s+$", "")
              local ins
              if inner:match("^%s*$") then
                ins = '{ features = ["' .. f .. '"] }'
              else
                ins = "{" .. inner .. (inner:match(",$") and "" or ",") .. ' features = ["' .. f .. '"] }'
              end
              return cur:sub(1, abs - 1) .. ins .. cur:sub(e + 1)
            end
            return nil, "cannot read the dependency entry"
          end
        end
      end
    end
    return nil, "dependency `" .. spec.key .. "` is not declared in this manifest"
  end

  local changed, last_why = false, nil
  for _, f in ipairs(features) do
    local new, why = apply_one(f)
    if new then
      result, changed = new, true
    elseif why and (why:match("^dependency") or why:match("^cannot read")) then
      return nil, why
    else
      last_why = why
    end
  end
  if not changed then
    return nil, last_why or (op == "add" and "already enabled in this manifest" or "feature not declared in this manifest")
  end
  return result
end

-- ============================================================ applying edits

local function read_all(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return s
end

local function write_all(path, text)
  -- a symlinked Cargo.toml: rename onto the real file, or the link is replaced by a copy
  path = vim.uv.fs_realpath(path) or path
  local tmp = ("%s.%d.tmp"):format(path, vim.uv.os_getpid())
  local f = io.open(tmp, "wb")
  if not f then
    return false
  end
  f:write(text)
  f:close()
  local st = vim.uv.fs_stat(path)
  if st then
    pcall(vim.uv.fs_chmod, tmp, st.mode % 4096)
  end
  return require("xyno_rust.fsutil").rename(tmp, path) and true or false
end

local function manifest_buffer_modified(manifest)
  local b = vim.fn.bufnr(manifest)
  return b > 0 and vim.api.nvim_buf_is_loaded(b) and vim.bo[b].modified
end

local valid_features = require("xyno_crates.names").valid_features

local function after_edit(manifest)
  cm.invalidate()
  -- the edit did not go through a buffer save: restart bacon-ls like a save of Cargo.toml would
  pcall(require("xyno_rust.rust_restart").manifest_saved, manifest)
  -- an open, unmodified Cargo.toml buffer picks the new text up
  pcall(vim.cmd, "silent! checktime")
end

--- Switch features of the dependency entry `d` (a cargo metadata dependency of
--- crate_meta) on or off in its member's Cargo.toml. cb(ok, how_or_err), how =
--- "cargo add" | "text edit".
function M.set_features(d, features, on, cb)
  if not valid_features(features) or not cm.valid_name(d.name) then
    return vim.schedule(function()
      cb(false, "invalid crate or feature name")
    end)
  end
  local manifest = d.member_manifest
  if manifest_buffer_modified(manifest) then
    return vim.schedule(function()
      cb(false, manifest .. " has unsaved changes: save it first")
    end)
  end
  local before = read_all(manifest)
  if not before then
    return vim.schedule(function()
      cb(false, "cannot read " .. manifest)
    end)
  end
  local function text_edit()
    local spec = { key = d.rename or d.name, kind = d.kind, target = d.target }
    local cur = read_all(manifest) or before
    local new, why = M.edit_manifest(cur, spec, on and "add" or "remove", features)
    if not new then
      -- already in the manifest after cargo add changed it: fine
      return cb(false, why)
    end
    if not write_all(manifest, new) then
      return cb(false, "cannot write " .. manifest)
    end
    after_edit(manifest)
    cb(true, "text edit")
  end

  local registry = d.source and d.source:match("^registry") ~= nil
  if not on or d.rename or not registry then
    return vim.schedule(text_edit)
  end

  local function argv(offline)
    local a = { "cargo", "add", d.name, "--features", table.concat(features, ","), "--manifest-path", manifest }
    if d.kind == "dev" then
      a[#a + 1] = "--dev"
    elseif d.kind == "build" then
      a[#a + 1] = "--build"
    end
    if d.target then
      vim.list_extend(a, { "--target", d.target })
    end
    if offline then
      a[#a + 1] = "--offline"
    end
    return a
  end
  local function done_ok()
    local now = read_all(manifest) or ""
    local all = now ~= before
    for _, f in ipairs(features) do
      all = all and now:find('"' .. f .. '"', 1, true) ~= nil
    end
    if all then
      after_edit(manifest)
      return cb(true, "cargo add")
    end
    text_edit()
  end
  cm.exec(argv(true), { cwd = vim.fs.dirname(manifest), timeout = 60000 }, function(r1)
    if r1.code == 0 then
      return done_ok()
    end
    cm.exec(argv(false), { cwd = vim.fs.dirname(manifest), timeout = 60000 }, function(r2)
      if r2.code == 0 then
        return done_ok()
      end
      text_edit() -- cargo add refused or is missing: edit the text
    end)
  end)
end

--- Find the dependency entry of a suggestion (or command argument) again in
--- fresh metadata.
local function find_dep(meta, arg)
  for _, d in ipairs(meta.dependencies) do
    if d.member == arg.member and d.kind == arg.kind and d.name == arg.crate and d.target == arg.target then
      return d
    end
  end
end

--- Apply a suggestion: { root, member, kind, crate, features, target }.
--- cb(ok, how_or_err).
function M.apply(arg, cb)
  cm.metadata_async(arg.root, function(meta, err)
    if not meta then
      return cb(false, err or "no cargo metadata")
    end
    local d = find_dep(meta, arg)
    if not d then
      return cb(false, ("`%s` is not a dependency of `%s` any more"):format(arg.crate, arg.member))
    end
    M.set_features(d, arg.features, true, function(ok, how)
      if ok then
        vim.notify(("Enabled %s of `%s` in %s (%s)"):format(table.concat(arg.features, ", "), arg.crate, vim.fn.fnamemodify(d.member_manifest, ":~:."), how), vim.log.levels.INFO)
      else
        vim.notify(("Could not enable %s of `%s`: %s"):format(table.concat(arg.features, ", "), arg.crate, how or "?"), vim.log.levels.WARN)
      end
      cb(ok, how)
    end)
  end)
end

M._find_dep = find_dep

return M
