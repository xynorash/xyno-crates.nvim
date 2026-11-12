-- What the user sees before `cargo add` runs: the crate, the version cargo will take, the
-- features, the target, the downloads and age from crates.io (when it answers), a
-- typosquat warning (edit distance against a list of popular crates) and a hint when
-- cargo-audit is installed. Pure parts (distance, typosquat, age, preview text) are
-- testable without a network; fetching is async and never blocks.
local M = {}

M.config = {
  popular_downloads = 2000000, -- a crate with at least this many downloads is not warned about
  extra_popular = {}, -- more names to guard against (your own crates, an internal registry)
}

-- Names guarded against: widely used crates (not exhaustive; it is a hint, not a verdict).
local POPULAR = vim.split(
  [[serde serde_json serde_derive serde_yaml tokio tokio-util tokio-stream rand rand_core clap clap_derive anyhow thiserror regex
log env_logger reqwest chrono futures futures-util futures-core syn quote proc-macro2 itertools once_cell lazy_static bytes
hyper http tower axum tonic prost tracing tracing-subscriber tracing-appender uuid libc base64 bitflags byteorder cfg-if
crossbeam crossbeam-channel num-traits num rayon smallvec parking_lot sha2 sha1 md5 hex url time toml toml_edit tempfile walkdir
memchr indexmap hashbrown async-trait pin-project unicode-width textwrap termcolor colored crossterm ratatui eyre
color-eyre miette which dirs directories glob ignore mime openssl rustls ring zeroize bincode derive_more strum
num_cpus getrandom fastrand ahash fxhash dashmap arc-swap bumpalo either semver tar flate2 zip image egui eframe bevy wgpu winit
nalgebra ndarray criterion proptest insta mockall assert_cmd predicates sqlx diesel rusqlite sea-orm redis mongodb
openssl-sys cc cmake pkg-config bindgen autocfg rustc-hash itoa ryu half paste ctrlc signal-hook nix windows windows-sys
libloading memmap2 rayon-core crossbeam-utils crossbeam-epoch scopeguard lock_api spin tokio-macros futures-task futures-sink
http-body hyper-util h2 mio socket2 native-tls tokio-rustls rustls-pemfile webpki-roots percent-encoding form_urlencoded
idna unicode-ident unicode-segmentation unicode-normalization heck convert_case serde_with schemars utoipa jsonwebtoken
argon2 bcrypt aes chacha20poly1305 rsa ed25519-dalek x25519-dalek ureq isahc surf actix-web rocket warp tide gotham
log4rs fern slog flexi_logger env_filter pretty_assertions rstest serial_test wiremock httpmock tokio-test
cargo_metadata cargo-edit gix git2 octocrab self_update indicatif dialoguer console comfy-table tabled prettytable-rs
serde_repr serde-xml-rs quick-xml roxmltree xml-rs csv calamine polars arrow parquet datafusion rkyv postcard ron
mlua rhai pyo3 napi wasm-bindgen web-sys js-sys wasm-bindgen-futures gloo yew leptos dioxus tauri iced slint
]],
  "%s+",
  { trimempty = true }
)

local popular_set
local function popular()
  if not popular_set then
    popular_set = {}
    for _, n in ipairs(POPULAR) do
      popular_set[n:lower():gsub("_", "-")] = n
    end
    for _, n in ipairs(M.config.extra_popular or {}) do
      if type(n) == "string" then
        popular_set[n:lower():gsub("_", "-")] = n
      end
    end
  end
  return popular_set
end

--- Forget the cached list (after config.extra_popular changed).
function M.reset()
  popular_set = nil
end

--- crates.io treats `-` and `_` as the same character and ignores case.
local function canon(name)
  return (name:lower():gsub("_", "-"))
end
M.canon = canon

--- Optimal string alignment distance (insert, delete, substitute, swap of two neighbours).
function M.distance(a, b)
  local la, lb = #a, #b
  if a == b then
    return 0
  end
  if la == 0 or lb == 0 then
    return math.max(la, lb)
  end
  local d = {}
  for i = 0, la do
    d[i] = { [0] = i }
  end
  for j = 0, lb do
    d[0][j] = j
  end
  for i = 1, la do
    for j = 1, lb do
      local cost = a:byte(i) == b:byte(j) and 0 or 1
      local v = math.min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
      if i > 1 and j > 1 and a:byte(i) == b:byte(j - 1) and a:byte(i - 1) == b:byte(j) then
        v = math.min(v, d[i - 2][j - 2] + 1)
      end
      d[i][j] = v
    end
  end
  return d[la][lb]
end

-- look-alike letters collapse to one spelling before the comparison
local function squash(s)
  return (s:gsub("rn", "m"):gsub("vv", "w"):gsub("1", "l"):gsub("0", "o"))
end

--- Does `name` look like a mistyped popular crate? Returns nil, or
--- { similar = "serde", distance = 1, why = "..." }. Names that equal a popular crate (up to
--- case and `-`/`_`) are fine; crates with `downloads` >= config.popular_downloads are fine.
--- The allowed distance is 1 for names up to 7 letters, 2 above; names shorter than 4 letters are
--- not compared (everything is close to everything there).
function M.typosquat(name, downloads)
  if type(name) ~= "string" or #name < 4 then
    return nil
  end
  local c = canon(name)
  local pop = popular()
  if pop[c] then
    return nil
  end
  if tonumber(downloads) and tonumber(downloads) >= M.config.popular_downloads then
    return nil
  end
  local best
  for key, original in pairs(pop) do
    if #key >= 4 and math.abs(#key - #c) <= 2 then
      local limit = math.max(#c, #key) >= 8 and 2 or 1
      local d = M.distance(c, key)
      local why
      if d <= limit then
        why = ("%d edit%s from"):format(d, d == 1 and "" or "s")
      elseif squash(c) == squash(key) then
        d, why = 1, "looks like"
      end
      if why and (not best or d < best.distance or (d == best.distance and key < best.key)) then
        best = { similar = original, key = key, distance = d, why = why }
      end
    end
  end
  if best then
    best.key = nil
    return best
  end
end

-- ----------------------------------------------------------------- age

--- Seconds since an RFC 3339 timestamp ("2019-03-03T11:15:45.123456+00:00"), nil when unparsable.
function M.age_seconds(ts, now)
  if type(ts) ~= "string" then
    return nil
  end
  local y, mo, d, h, mi, s = ts:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)[T ](%d%d):(%d%d):(%d%d)")
  if not y then
    return nil
  end
  -- days from civil (UTC), no os.time/timezone involved
  y, mo, d = tonumber(y), tonumber(mo), tonumber(d)
  local yy = mo <= 2 and y - 1 or y
  local era = math.floor(yy / 400)
  local yoe = yy - era * 400
  local doy = math.floor((153 * (mo + (mo > 2 and -3 or 9)) + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  local days = era * 146097 + doe - 719468
  local t = days * 86400 + tonumber(h) * 3600 + tonumber(mi) * 60 + tonumber(s)
  return (now or os.time()) - t
end

--- "3 days", "5 months", "2.4 years".
function M.human_age(secs)
  if not secs then
    return nil
  end
  if secs < 0 then
    return "in the future?"
  end
  local day = 86400
  if secs < day then
    return "less than a day"
  elseif secs < 60 * day then
    return ("%d days"):format(math.floor(secs / day))
  elseif secs < 730 * day then
    return ("%d months"):format(math.floor(secs / (30.44 * day)))
  end
  return ("%.1f years"):format(secs / (365.25 * day))
end

local function human_n(n)
  n = tonumber(n)
  if not n then
    return nil
  end
  if n >= 1e9 then
    return ("%.1fG"):format(n / 1e9)
  elseif n >= 1e6 then
    return ("%.1fM"):format(n / 1e6)
  elseif n >= 1e3 then
    return ("%.0fk"):format(n / 1e3)
  end
  return tostring(n)
end

-- ------------------------------------------------------------- fetching

local JSON_OPTS = { luanil = { object = true, array = true } }

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local t = f:read("*a")
  f:close()
  return t
end

local function parse_crate(text)
  local ok, j = pcall(vim.json.decode, text, JSON_OPTS)
  local c = ok and type(j) == "table" and j.crate
  if type(c) ~= "table" then
    return nil
  end
  return {
    created_at = type(c.created_at) == "string" and c.created_at or nil,
    updated_at = type(c.updated_at) == "string" and c.updated_at or nil,
    downloads = tonumber(c.downloads),
    recent_downloads = tonumber(c.recent_downloads),
    repository = type(c.repository) == "string" and c.repository or nil,
  }
end
M.parse_crate = parse_crate

--- created_at / updated_at / downloads of a crate from the crates.io web API: cb(meta) or cb(nil, err).
--- Reads the answer xyno-rust's client cached when it looked the crate up, else asks the API
--- itself (curl, the same user agent and protocol limits as xyno-rust's client). Never blocks.
function M.fetch_meta(name, cb)
  local cm = require("xyno_rust.crate_meta")
  if not cm.valid_name(name) then
    return vim.schedule(function()
      cb(nil, "invalid crate name")
    end)
  end
  local lname = name:lower()
  local dir = cm.config.cache_dir or (vim.fn.stdpath("cache") .. "/xyno-rust/crates")
  local cached = read_file(dir .. "/crate-" .. lname .. ".json")
  local meta = cached and parse_crate(cached)
  if meta and meta.created_at then
    return vim.schedule(function()
      cb(meta)
    end)
  end
  local argv = {
    "curl", "--silent", "--show-error", "--max-time", tostring(math.max(1, math.floor((cm.config.timeout_ms or 5000) / 1000))),
    "--proto", cm.config.proto or "=https", "--proto-redir", cm.config.proto or "=https",
    "-A", cm.config.user_agent or "xyno-crates.nvim", "-H", "Accept: application/json",
    cm.config.api_url .. "/crates/" .. lname .. "?include=",
  }
  cm.exec(argv, { timeout = (cm.config.timeout_ms or 5000) + 2000 }, function(r)
    if r.code ~= 0 then
      return cb(meta, "crates.io not reachable")
    end
    local m = parse_crate(r.stdout or "")
    if not m then
      return cb(meta, "unexpected answer")
    end
    cb(m)
  end)
end

-- -------------------------------------------------------------- hostile text

-- Everything that comes from the registry (crates.io or a mirror) is attacker-controlled text. It is
-- never put into the confirmation as is: sanitize() leaves one line of plain printable text.
local BIDI_AND_INVISIBLE = {
  "\226\128[\139-\143]", -- U+200B..U+200F zero-width space/joiners, LRM, RLM
  "\226\128[\170-\174]", -- U+202A..U+202E embeddings and overrides
  "\226\129[\160-\175]", -- U+2060..U+206F word joiner, isolates, deprecated format characters
  "\216\156", -- U+061C Arabic letter mark
  "\239\187\191", -- U+FEFF
  "\225\160\142", -- U+180E Mongolian vowel separator
  "\239\191[\185-\187]", -- U+FFF9..U+FFFB interlinear annotation
}

--- Keeps the valid UTF-8 sequences of `s`; every other byte becomes "?".
local function valid_utf8(s)
  if not s:find("[\128-\255]") then
    return s
  end
  local out, i, n = {}, 1, #s
  while i <= n do
    local c = s:byte(i)
    local len = c < 0x80 and 1 or (c >= 0xC2 and c <= 0xDF) and 2 or (c >= 0xE0 and c <= 0xEF) and 3 or (c >= 0xF0 and c <= 0xF4) and 4 or 0
    local seq = len > 0 and s:sub(i, i + len - 1) or nil
    local ok = seq ~= nil and #seq == len
    for k = 2, len do
      ok = ok and (seq:byte(k) or 0) >= 0x80 and seq:byte(k) <= 0xBF
    end
    if ok and len == 3 then
      local b1, b2 = seq:byte(1), seq:byte(2)
      ok = not (b1 == 0xE0 and b2 < 0xA0) and not (b1 == 0xED and b2 > 0x9F) -- overlong, surrogates
    elseif ok and len == 4 then
      local b1, b2 = seq:byte(1), seq:byte(2)
      ok = not (b1 == 0xF0 and b2 < 0x90) and not (b1 == 0xF4 and b2 > 0x8F)
    end
    if ok then
      out[#out + 1] = seq
      i = i + len
    else
      out[#out + 1] = "?"
      i = i + 1
    end
  end
  return table.concat(out)
end

--- One line of inert text from an untrusted value: terminal escape sequences (CSI, OSC incl. hyperlinks,
--- other ESC sequences) are dropped together with their payload, control characters, C1 controls, bidi
--- overrides / isolates, zero-width and format characters are removed, every run of whitespace
--- (newlines, NBSP, U+2028/9) becomes one space, invalid UTF-8 becomes "?", and the result is cut to
--- `max` bytes (default 120) at a character boundary with "...". Never returns nil.
function M.sanitize(value, max)
  local s = value == nil and "" or tostring(value)
  max = max or 120
  -- a long input is cut first: the patterns below stay cheap on a megabyte of payload
  if #s > max * 8 then
    s = s:sub(1, max * 8)
  end
  s = s:gsub("\27%][^\7\27]*\7", "") -- OSC ... BEL
  s = s:gsub("\27%][^\7\27]*\27\\", "") -- OSC ... ST
  s = s:gsub("\27%][^\7\27]*", "") -- unterminated OSC
  s = s:gsub("\27[P^_X][^\27]*\27\\", "") -- DCS / PM / APC / SOS
  s = s:gsub("\27%[[0-?]*[ -/]*[@-~]", "") -- CSI
  s = s:gsub("\27[ -/]*[0-~]", "") -- two-byte and nF sequences
  s = s:gsub("\194[\133\160]", " ") -- NEL, NBSP are whitespace
  s = s:gsub("\226\128[\168\169]", " ") -- U+2028, U+2029
  s = s:gsub("\226\128[\128-\138]", " ") -- U+2000..U+200A spaces
  s = s:gsub("\226\128\175", " "):gsub("\226\129\159", " "):gsub("\227\128\128", " ")
  s = s:gsub("[%z\1-\8\14-\31\127]", "")
  s = s:gsub("\194[\128-\159]", "") -- C1 controls (CSI 0x9B, OSC 0x9D, ...)
  for _, pat in ipairs(BIDI_AND_INVISIBLE) do
    s = s:gsub(pat, "")
  end
  s = s:gsub("[%s]+", " ")
  s = valid_utf8(s)
  s = vim.trim(s)
  if #s > max then
    local cut = max
    while cut > 0 and s:byte(cut + 1) and s:byte(cut + 1) >= 0x80 and s:byte(cut + 1) < 0xC0 do
      cut = cut - 1
    end
    s = s:sub(1, cut) .. "..."
  end
  return s
end

--- Whether `url` (already sanitised) is a plain http(s) URL: no credentials, no spaces, no other scheme.
local function plain_url(url)
  local rest = url:match("^https?://([^/%s]*)")
  return rest ~= nil and not rest:find("@", 1, true) and not url:find("%s")
end

-- -------------------------------------------------------------- preview

--- The text of the confirmation. `p` = { spec, info (cm.info_async result or nil), meta
--- (fetch_meta or nil), typo (typosquat or nil), audit (bool: cargo-audit installed), now }.
--- Returns { lines, warnings }.
function M.render(p)
  local spec, info, meta = p.spec, p.info, p.meta
  local lines, warns = {}, {}
  local function add(l)
    lines[#lines + 1] = l
  end
  add(("cargo add %s"):format(M.sanitize(spec.name, 80)))
  local newest = info and info.newest and M.sanitize(info.newest, 40) or nil
  add(("  version    %s"):format(newest and newest ~= "" and "newest on crates.io is listed below; cargo picks the newest compatible with the package's rust-version" or "cargo picks the newest compatible release (not looked up)"))
  local feats = spec.features and #spec.features > 0 and M.sanitize(table.concat(spec.features, ", "), 120) or "none"
  add(("  features   %s%s"):format(feats, spec.default_features == false and "  (default features OFF)" or "  (+ default features)"))
  add(("  into       [%s]%s"):format(({ normal = "dependencies", dev = "dev-dependencies", build = "build-dependencies" })[spec.kind or "normal"], spec.package and (" of " .. M.sanitize(spec.package, 80)) or ""))
  local dl = meta and meta.downloads or (info and info.downloads)
  local recent = meta and meta.recent_downloads or (info and info.recent_downloads)
  if dl then
    add(("  downloads  %s total%s"):format(human_n(dl), recent and (", " .. human_n(recent) .. " in the last 90 days") or ""))
  end
  if meta and meta.created_at then
    local created = M.human_age(M.age_seconds(meta.created_at, p.now))
    local updated = meta.updated_at and M.human_age(M.age_seconds(meta.updated_at, p.now))
    add(("  age        first published %s ago%s"):format(created or "?", updated and (", last updated " .. updated .. " ago") or ""))
    local secs = M.age_seconds(meta.created_at, p.now)
    if secs and secs < 30 * 86400 then
      warns[#warns + 1] = "this crate was first published less than 30 days ago"
    end
  end
  if not dl and not (meta and meta.created_at) then
    add("  crates.io  no download or age data (offline or the API did not answer)")
  end
  if info == nil then
    warns[#warns + 1] = "crates.io has no (or no reachable) index entry for this name: check the spelling"
  end
  if p.typo then
    warns[#warns + 1] = ("the name looks like the popular crate `%s` (%s): possible typosquat, check %s"):format(p.typo.similar, p.typo.why, "the repository listed below")
  end
  -- Registry text: its own labelled block, every line prefixed, so nothing in it can pass for the
  -- plugin's own lines (WARNING, version, downloads) above and below.
  local repo = info and info.repository or (meta and meta.repository)
  if newest or repo then
    add("")
    add("  from crates.io (unverified text sent by the registry, shown as is):")
    if newest and newest ~= "" then
      add("  | newest version  " .. newest)
    end
    if repo then
      local url = M.sanitize(repo, 160)
      add("  | repository      " .. url .. (plain_url(url) and "" or "   (not a plain http(s) URL: do not open it)"))
    end
  end
  if #warns > 0 then
    add("")
    for _, w in ipairs(warns) do
      add("  WARNING: " .. w)
    end
  end
  if p.audit then
    add("")
    add("  cargo-audit is installed: `cargo audit` checks the lockfile against RUSTSEC advisories after the add")
  end
  return { lines = lines, warnings = warns }
end

--- Gather everything and call cb(preview) where preview = M.render(...) plus .typo.
--- opts: { typosquat = true, audit = true }. All lookups are async and failures only thin the preview.
function M.preview(spec, opts, cb)
  opts = opts or {}
  local cm = require("xyno_rust.crate_meta")
  cm.info_async(spec.name, function(info)
    M.fetch_meta(spec.name, function(meta)
      local dl = (meta and meta.downloads) or (info and info.downloads)
      local typo = opts.typosquat ~= false and M.typosquat(spec.name, dl) or nil
      local audit = opts.audit ~= false and vim.fn.executable("cargo-audit") == 1
      local r = M.render({ spec = spec, info = info, meta = meta, typo = typo, audit = audit })
      r.typo, r.info, r.meta, r.audit = typo, info, meta, audit
      cb(r)
    end)
  end)
end

return M
