-- xyno-crates features: cfg gates and the source scanner (what each dependency exports, behind which feature).
-- Part of xyno_crates.crate_features (the facade merges every part into one table).
local M = {}
local cm = require("xyno_rust.crate_meta")

M.config = {
  max_files = 150, -- source files read per crate scan
  max_file_bytes = 600 * 1024,
  max_unused_files = 400, -- workspace files read for the unused hint
  max_unused_bytes = 4 * 1024 * 1024,
  max_alts = 32, -- cap of the cfg alternatives of one item
}

-- ============================================================ cfg and gates
-- A gate is a DNF: a list of alternatives, each a set { feature = true } that
-- must all be on. {} (no alternative) is "never", { {} } is "always".

local ALWAYS = { {} }

local function alt_key(alt)
  local k = vim.tbl_keys(alt)
  table.sort(k)
  return table.concat(k, ",")
end

local function and_gate(a, b)
  local out, seen = {}, {}
  for _, x in ipairs(a) do
    for _, y in ipairs(b) do
      local u = vim.tbl_extend("force", {}, x, y)
      local k = alt_key(u)
      if not seen[k] and #out < M.config.max_alts then
        seen[k] = true
        out[#out + 1] = u
      end
    end
  end
  return out
end

local function or_gate(a, b)
  local out, seen = {}, {}
  for _, g in ipairs({ a, b }) do
    for _, x in ipairs(g) do
      local k = alt_key(x)
      if not seen[k] and #out < M.config.max_alts then
        seen[k] = true
        out[#out + 1] = x
      end
    end
  end
  return out
end

local function split_args(s)
  local out, depth, start, i = {}, 0, 1, 1
  while i <= #s do
    local c = s:sub(i, i)
    if c == '"' then
      i = s:find('"', i + 1, true) or #s
    elseif c == "(" then
      depth = depth + 1
    elseif c == ")" then
      depth = depth - 1
    elseif c == "," and depth == 0 then
      out[#out + 1] = s:sub(start, i - 1)
      start = i + 1
    end
    i = i + 1
  end
  local last = s:sub(start)
  if last:match("%S") then
    out[#out + 1] = last
  end
  return out
end

--- The inside of a `cfg(...)` -> gate. Only `feature = ".."` matters; `not(..)`
--- and other predicates (unix, docsrs, target_*) are treated as true, `test`
--- as false (test modules are no API).
function M.parse_cfg(e)
  e = vim.trim(e)
  local f = e:match('^feature%s*=%s*"([^"]+)"$')
  if f then
    return { { [f] = true } }
  end
  local op, args = e:match("^(%a+)%s*(%b())$")
  if op == "all" then
    local g = ALWAYS
    for _, a in ipairs(split_args(args:sub(2, -2))) do
      g = and_gate(g, M.parse_cfg(a))
    end
    return g
  elseif op == "any" then
    local g = {}
    for _, a in ipairs(split_args(args:sub(2, -2))) do
      g = or_gate(g, M.parse_cfg(a))
    end
    return g
  elseif op == "not" then
    return ALWAYS
  end
  if e == "test" then
    return {}
  end
  return ALWAYS
end

-- ============================================================ source scanner

--- Comments removed (strings kept: the cfg features are in them).
local function strip(text)
  local out, last, i, n = {}, 1, 1, #text
  while i <= n do
    local j = text:find("[/\"'r]", i)
    if not j then
      break
    end
    i = j
    local c = text:sub(i, i)
    if c == "/" then
      local d = text:sub(i + 1, i + 1)
      if d == "/" then
        out[#out + 1] = text:sub(last, i - 1)
        i = text:find("\n", i, true) or n + 1
        last = i
      elseif d == "*" then
        out[#out + 1] = text:sub(last, i - 1)
        local depth, k = 1, i + 2
        while depth > 0 do
          local a = text:find("[/*]", k)
          if not a then
            k = n + 1
            break
          end
          local two = text:sub(a, a + 1)
          if two == "/*" then
            depth, k = depth + 1, a + 2
          elseif two == "*/" then
            depth, k = depth - 1, a + 2
          else
            k = a + 1
          end
        end
        out[#out + 1] = " "
        i, last = k, k
      else
        i = i + 1
      end
    elseif c == '"' then
      local k = i + 1
      while k <= n do
        local ch = text:sub(k, k)
        if ch == "\\" then
          k = k + 2
        elseif ch == '"' then
          break
        else
          k = k + 1
        end
      end
      i = k + 1
    elseif c == "r" then
      local hashes = text:match('^r(#*)"', i)
      local prev = i > 1 and text:sub(i - 1, i - 1) or ""
      if hashes and not prev:match("[%w_]") then
        local close = text:find('"' .. hashes, i + 2 + #hashes, true)
        i = close and close + 1 + #hashes or n + 1
      else
        i = i + 1
      end
    else -- a quote: char literal or lifetime
      if text:match("^'[^'\\\n]'", i) then
        i = i + 3
      elseif text:match("^'\\.[^'\n]*'", i) then
        i = text:find("'", i + 2, true) + 1
      else
        i = i + 1
      end
    end
  end
  out[#out + 1] = text:sub(last)
  return table.concat(out)
end

--- Index of the bracket that closes the one at `p` (strings and char
--- literals skipped), or nil.
local function close_of(t, p)
  local depth, i, n = 0, p, #t
  while i <= n do
    local j = t:find("[%(%)%[%]{}\"']", i)
    if not j then
      return nil
    end
    local c = t:sub(j, j)
    if c == '"' then
      local k = j + 1
      while k <= n do
        local ch = t:sub(k, k)
        if ch == "\\" then
          k = k + 2
        elseif ch == '"' then
          break
        else
          k = k + 1
        end
      end
      i = k + 1
    elseif c == "'" then
      if t:match("^'[^'\\\n]'", j) then
        i = j + 3
      elseif t:match("^'\\.[^'\n]*'", j) then
        i = t:find("'", j + 2, true) + 1
      else
        i = j + 1
      end
    else
      if c == "(" or c == "[" or c == "{" then
        depth = depth + 1
      else
        depth = depth - 1
        if depth == 0 then
          return j
        end
      end
      i = j + 1
    end
  end
  return nil
end

local function skip_ws(t, p, lim)
  local s = t:find("[^%s;]", p)
  return (s and s <= lim) and s or lim + 1
end

--- End (exclusive) of the item that starts at `p`: the first `;` or the end of
--- the first `{}` block at depth 0; for const/static only the `;` after `=`.
local function item_end(t, p, lim, is_const)
  local seen_eq = false
  while p <= lim do
    local q = t:find("[;{%(%[=\"']", p)
    if not q or q > lim then
      return lim + 1
    end
    local c = t:sub(q, q)
    if c == ";" then
      return q + 1
    elseif c == "(" or c == "[" then
      local e = close_of(t, q)
      if not e then
        return lim + 1
      end
      p = e + 1
    elseif c == "{" then
      local e = close_of(t, q)
      if not e then
        return lim + 1
      end
      if not (is_const and seen_eq) then
        return e + 1
      end
      p = e + 1
    elseif c == "=" then
      seen_eq = is_const
      p = q + 1
    elseif c == '"' then
      local e = t:match('^"[^"\\]*"', q) and select(2, t:find('^"[^"\\]*"', q))
      if not e then
        local k = q + 1
        while k <= lim do
          local ch = t:sub(k, k)
          if ch == "\\" then
            k = k + 2
          elseif ch == '"' then
            break
          else
            k = k + 1
          end
        end
        e = k
      end
      p = e + 1
    else
      p = q + 1
    end
  end
  return lim + 1
end

--- `use` tree (text between `use` and `;`) -> { {name, path} | {glob, path} }.
function M.parse_use(s)
  local out, pos = {}, 1
  local function ws()
    pos = s:find("%S", pos) or #s + 1
  end
  local function tree(prefix)
    local segs = vim.list_slice(prefix, 1, #prefix)
    while pos <= #s do
      ws()
      if s:sub(pos, pos + 1) == "::" then
        pos = pos + 2
        ws()
      end
      local c = s:sub(pos, pos)
      if c == "{" then
        pos = pos + 1
        while pos <= #s do
          ws()
          if s:sub(pos, pos) == "}" then
            pos = pos + 1
            break
          end
          local before = pos
          tree(segs)
          ws()
          if s:sub(pos, pos) == "," then
            pos = pos + 1
          end
          if pos == before then
            pos = pos + 1
          end
        end
        return
      elseif c == "*" then
        pos = pos + 1
        out[#out + 1] = { glob = true, path = segs }
        return
      end
      local id = s:match("^[%a_][%w_]*", pos)
      if not id then
        pos = pos + 1
        return
      end
      pos = pos + #id
      segs[#segs + 1] = id
      ws()
      if s:sub(pos, pos + 1) ~= "::" then
        local alias = s:match("^as%s+([%a_][%w_]*)", pos)
        if alias then
          pos = pos + #s:match("^as%s+[%a_][%w_]*", pos)
        end
        local name = alias or id
        if id == "self" and not alias then
          name = segs[#segs - 1]
        end
        if name and name ~= "_" then
          out[#out + 1] = { name = name, path = segs }
        end
        return
      end
    end
  end
  tree({})
  return out
end

local function read_file(path, max)
  local st = vim.uv.fs_stat(path)
  if not st or st.type ~= "file" or st.size > max then
    return nil, st and "big" or nil
  end
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return s
end

local function mtime(path)
  local st = path and vim.uv.fs_stat(path)
  return st and (st.mtime.sec .. "." .. st.mtime.nsec) or "-"
end

--- The gate of a `cfg_xxx!` wrapper macro definition body (tokio style:
--- `($($item:item)*) => { $( #[cfg(feature = "x")] $item )* }`), or nil.
local function wrapper_gate(body)
  -- the transcriber's `$item` (the last one; the matcher has one too)
  local at
  for s in body:gmatch("()%$item") do
    at = s
  end
  if not at then
    return nil
  end
  local before = body:sub(1, at - 1)
  local from = 1
  while true do
    local s = before:find("$(", from, true)
    if not s then
      break
    end
    from = s + 2
  end
  local seg = before:sub(from)
  local g = ALWAYS
  local found = false
  for attr in seg:gmatch("#%s*(%b[])") do
    local cfg = attr:match("^%[%s*cfg%s*(%b())%s*%]$")
    if cfg then
      g = and_gate(g, M.parse_cfg(cfg:sub(2, -2)))
      found = true
    end
  end
  return found and g or nil
end

--- Scan a crate's source: { items = { name = { cand... } }, files, truncated }
--- cand = { gate, reach = bool, kind }. Not cached (see M.scan).
function M.scan_dir(dir)
  local ctx = {
    dir = dir,
    items = {},
    mod_items = {}, -- "a::b" -> { {name, gate} }
    globs = {},
    wrappers = {}, -- macro name -> gate
    pending = {}, -- { name, text, s, e, st }
    nfiles = 0,
    truncated = false,
  }
  local lib_text, lib_path = cm.read_lib(dir)
  if not lib_text then
    return { items = {}, files = 0, truncated = false, no_lib = true }
  end

  local function add(name, st, gate, kind, vis)
    if not name or #gate == 0 then
      return
    end
    local key = table.concat(st.mods, "::")
    ctx.mod_items[key] = ctx.mod_items[key] or {}
    table.insert(ctx.mod_items[key], { name = name, gate = gate, kind = kind })
    ctx.items[name] = ctx.items[name] or {}
    table.insert(ctx.items[name], { gate = gate, reach = vis and st.pubchain or false, kind = kind })
  end

  local parse_region

  local function load_file(path, st_parent, name, vis, gate, dir_for_children)
    if ctx.nfiles >= M.config.max_files then
      ctx.truncated = true
      return
    end
    local raw, why = read_file(path, M.config.max_file_bytes)
    if not raw then
      ctx.truncated = ctx.truncated or why == "big"
      return
    end
    ctx.nfiles = ctx.nfiles + 1
    local t = strip(raw)
    local mods = vim.list_slice(st_parent.mods, 1, #st_parent.mods)
    mods[#mods + 1] = name
    parse_region(t, 1, #t, {
      gate = gate,
      mods = mods,
      pubchain = st_parent.pubchain and vis,
      dir = dir_for_children,
    })
  end

  local function handle_mod(t, p, lim, st, name, vis, gate, path_attr)
    local q = t:find("[^%s]", p) or lim + 1
    if t:sub(q, q) == "{" and q <= lim then
      local e = close_of(t, q)
      if not e then
        return lim + 1
      end
      local mods = vim.list_slice(st.mods, 1, #st.mods)
      mods[#mods + 1] = name
      parse_region(
        t,
        q + 1,
        e - 1,
        { gate = gate, mods = mods, pubchain = st.pubchain and vis, dir = st.dir .. "/" .. name }
      )
      return e + 1
    end
    local rel = path_attr and not path_attr:find("..", 1, true) and path_attr:sub(1, 1) ~= "/" and path_attr or nil
    local cands = rel and { st.dir .. "/" .. rel }
      or { st.dir .. "/" .. name .. ".rs", st.dir .. "/" .. name .. "/mod.rs" }
    for _, c in ipairs(cands) do
      if vim.uv.fs_stat(c) then
        local child_dir = c:match("/mod%.rs$") and vim.fs.dirname(c) or (st.dir .. "/" .. name)
        load_file(c, st, name, vis, gate, child_dir)
        break
      end
    end
    return q + 1
  end

  function parse_region(t, s, lim, st)
    local p = s
    local guard = 0
    while true do
      guard = guard + 1
      p = skip_ws(t, p, lim)
      if p > lim or guard > 20000 then
        break
      end
      local gate, macro_export, path_attr = st.gate, false, nil
      while t:sub(p, p) == "#" do
        local q = p + 1
        local inner = t:sub(q, q) == "!"
        if inner then
          q = q + 1
        end
        q = skip_ws(t, q, lim)
        if t:sub(q, q) ~= "[" then
          break
        end
        local close = close_of(t, q)
        if not close then
          return
        end
        local attr = t:sub(q + 1, close - 1)
        local cfg = attr:match("^%s*cfg%s*(%b())%s*$")
        if cfg and not inner then
          gate = and_gate(gate, M.parse_cfg(cfg:sub(2, -2)))
        elseif attr:match("^%s*macro_export") then
          macro_export = true
        else
          path_attr = attr:match('^%s*path%s*=%s*"([^"]+)"') or path_attr
        end
        p = skip_ws(t, close + 1, lim)
      end
      if p > lim then
        break
      end

      local vis = false
      if t:match("^pub%f[%W]", p) then
        local q = skip_ws(t, p + 3, lim)
        if t:sub(q, q) == "(" then
          p = (close_of(t, q) or lim) + 1
        else
          vis, p = true, q
        end
      end

      local word, wend = t:match("^([%a_][%w_]*)()", p)
      -- modifiers of fn / trait / impl / extern blocks
      local guard2 = 0
      while word and guard2 < 6 do
        guard2 = guard2 + 1
        local nxt = skip_ws(t, wend, lim)
        local nword = t:match("^([%a_][%w_]*)", nxt)
        if word == "async" or word == "unsafe" or word == "default" then
          p, word, wend = nxt, t:match("^([%a_][%w_]*)()", nxt)
        elseif word == "const" and (nword == "fn" or nword == "unsafe" or nword == "async" or nword == "extern") then
          p, word, wend = nxt, t:match("^([%a_][%w_]*)()", nxt)
        elseif word == "extern" and nword ~= "crate" then
          local q = nxt
          if t:sub(q, q) == '"' then
            q = skip_ws(t, (t:find('"', q + 1, true) or q) + 1, lim)
          end
          p, word, wend = q, t:match("^([%a_][%w_]*)()", q)
        else
          break
        end
      end

      if word == "use" then
        local e = item_end(t, wend, lim)
        if vis then
          for _, u in ipairs(M.parse_use(t:sub(wend, e - 2))) do
            if u.glob then
              table.insert(ctx.globs, { path = u.path, gate = gate, st = st, reach = st.pubchain })
            else
              add(u.name, st, gate, "use", true)
            end
          end
        end
        p = e
      elseif word == "mod" then
        local q = skip_ws(t, wend, lim)
        local name, nend = t:match("^([%a_][%w_]*)()", q)
        if name then
          if vis then
            add(name, st, gate, "mod", true)
          end
          p = handle_mod(t, nend, lim, st, name, vis, gate, path_attr)
        else
          p = item_end(t, wend, lim)
        end
      elseif word == "macro_rules" and t:sub(skip_ws(t, wend, lim), skip_ws(t, wend, lim)) == "!" then
        local q = skip_ws(t, skip_ws(t, wend, lim) + 1, lim)
        local name, nend = t:match("^([%a_][%w_]*)()", q)
        local b = name and skip_ws(t, nend, lim)
        local e = b and (t:sub(b, b):match("[{%(%[]") and close_of(t, b))
        if not e then
          p = item_end(t, wend, lim)
        else
          local wg = wrapper_gate(t:sub(b, e))
          if wg then
            ctx.wrappers[name] = wg
          end
          if macro_export then
            -- #[macro_export] puts it at the crate root, whatever the module
            ctx.items[name] = ctx.items[name] or {}
            table.insert(ctx.items[name], { gate = gate, reach = true, kind = "macro" })
          end
          p = e + 1
        end
      elseif word == "extern" or word == "impl" or word == "macro" then
        p = item_end(t, wend, lim)
      elseif word == "const" or word == "static" then
        local q = skip_ws(t, wend, lim)
        if t:match("^mut%f[%W]", q) then
          q = skip_ws(t, q + 3, lim)
        end
        local name = t:match("^([%a_][%w_]*)", q)
        if vis and name and name ~= "_" then
          add(name, st, gate, word, true)
        end
        p = item_end(t, wend, lim, true)
      elseif
        word == "fn"
        or word == "struct"
        or word == "enum"
        or word == "trait"
        or word == "type"
        or word == "union"
      then
        local name = t:match("^([%a_][%w_]*)", skip_ws(t, wend, lim))
        if vis and name then
          add(name, st, gate, word, true)
        end
        p = item_end(t, wend, lim)
      elseif word and t:sub(wend, wend) == "!" then
        -- a macro call; a wrapper macro's body is parsed with its gate (later,
        -- once every file is read: the definition may come after the use)
        local b = skip_ws(t, wend + 1, lim)
        local e = t:sub(b, b):match("[{%(%[]") and close_of(t, b)
        if e then
          ctx.pending[#ctx.pending + 1] = { name = word, t = t, s = b + 1, e = e - 1, st = st, gate = gate }
          p = e + 1
        else
          p = item_end(t, wend, lim)
        end
      else
        p = item_end(t, p, lim)
      end
    end
  end

  local t = strip(lib_text)
  ctx.nfiles = 1
  local root_st = { gate = ALWAYS, mods = {}, pubchain = true, dir = vim.fs.dirname(lib_path) }
  parse_region(t, 1, #t, root_st)

  -- wrapper-macro bodies, until no new ones turn up
  for _ = 1, 40 do
    local todo = ctx.pending
    ctx.pending = {}
    if #todo == 0 then
      break
    end
    for _, c in ipairs(todo) do
      local wg = ctx.wrappers[c.name]
      if wg then
        local st = vim.tbl_extend("force", {}, c.st, { gate = and_gate(c.gate, wg) })
        parse_region(c.t, c.s, c.e, st)
      end
    end
  end

  -- `pub use self::m::*` / `pub use m::*`: the module's pub items at this level
  for _, g in ipairs(ctx.globs) do
    local segs = vim.list_slice(g.path, 1, #g.path)
    local base = vim.list_slice(g.st.mods, 1, #g.st.mods)
    if segs[1] == "crate" then
      table.remove(segs, 1)
      base = {}
    elseif segs[1] == "self" then
      table.remove(segs, 1)
    elseif segs[1] == "super" then
      table.remove(segs, 1)
      base[#base] = nil
    end
    local key = table.concat(vim.list_extend(base, segs), "::")
    for _, it in ipairs(ctx.mod_items[key] or {}) do
      ctx.items[it.name] = ctx.items[it.name] or {}
      table.insert(ctx.items[it.name], { gate = and_gate(g.gate, it.gate), reach = g.reach, kind = it.kind })
    end
  end

  return { items = ctx.items, files = ctx.nfiles, truncated = ctx.truncated }
end

local scans = {} -- dir -> { stamp, idx }

--- Cached scan_dir (a crate in the registry never changes; a path dependency
--- is re-read when its lib.rs changes).
function M.scan(dir)
  local _, lib = cm.read_lib(dir)
  local stamp = mtime(lib)
  local hit = scans[dir]
  if hit and hit.stamp == stamp then
    return hit.idx
  end
  local idx = M.scan_dir(dir)
  scans[dir] = { stamp = stamp, idx = idx }
  return idx
end

function M.clear_cache()
  scans = {}
end

--- The gate (DNF) behind which `name` is exported by the scanned crate, or
--- nil, reason ("not found" | "ungated").
function M.gate_of(idx, name)
  local cands = idx.items[name]
  if not cands then
    return nil, "not found"
  end
  local pref = vim.tbl_filter(function(c)
    return c.reach
  end, cands)
  if #pref == 0 then
    pref = cands
  end
  local g = {}
  for _, c in ipairs(pref) do
    for _, alt in ipairs(c.gate) do
      if next(alt) == nil then
        return nil, "ungated"
      end
    end
    g = or_gate(g, c.gate)
  end
  return g
end

M._close_of = close_of
M._read_file = read_file
M._strip = strip

return M
