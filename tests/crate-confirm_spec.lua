-- xyno-os: linux,macos (fake cargo-audit is a POSIX shell script)
-- The confirmation before `cargo add` (preview, typosquat warning, cargo-audit hint),
-- the shared feature-name validation and setup() being repeatable.
-- Hermetic: crates.io lookups, the picker and `cargo add` are stubbed.
local H = require("xyno_crates_test.helpers")
local cm = require("xyno_rust.crate_meta")
local ca = require("xyno_crates.crate_add")
local vet = require("xyno_crates.vet")
local names = require("xyno_crates.names")
local C = require("xyno_crates")

local restores = {}
local function stub(t, k, v)
  local orig = t[k]
  t[k] = v
  restores[#restores + 1] = function()
    t[k] = orig
  end
end

local saved_path = vim.env.PATH
after_each(function()
  for i = #restores, 1, -1 do
    pcall(restores[i])
  end
  restores = {}
  vim.env.PATH = saved_path
  ca.config.confirm = true
  ca.config.typosquat = true
  ca.config.audit = "hint"
  vet.config.extra_popular = {}
  vet.reset()
  pcall(vim.cmd, "silent! %bwipeout!")
end)

local NOW = os.time()
--- RFC 3339 UTC timestamp `secs` before NOW
local function ago(secs)
  return os.date("!%Y-%m-%dT%H:%M:%S", NOW - secs) .. ".000000+00:00"
end

local function fake_lookup(info, meta)
  stub(cm, "info_async", function(_, cb)
    vim.schedule(function()
      cb(info)
    end)
  end)
  stub(vet, "fetch_meta", function(_, cb)
    vim.schedule(function()
      cb(meta)
    end)
  end)
end

describe("feature names", function()
  it("one definition: add and features accept and refuse the same names", function()
    for _, ok in ipairs({ "std", "no-panic", "a_b", "v1.2", "tls+rustls", string.rep("a", 64) }) do
      H.ok(names.valid_feature(ok), ok)
      H.ok(ca.build_argv({ name = "x", features = { ok } }), "build_argv " .. ok)
    end
    for _, bad in ipairs({ "", "-x", "--git", "a b", "a;b", "a,b", string.rep("a", 65), "a/b", 3 }) do
      H.not_ok(names.valid_feature(bad), tostring(bad))
      H.is_nil((ca.build_argv({ name = "x", features = { bad } })), "build_argv " .. tostring(bad))
    end
    H.not_ok(names.valid_features({}))
    H.ok(names.valid_features({}, true))
    local src = {}
    for _, f in ipairs(vim.fn.glob(H.repo .. "/lua/xyno_crates/*.lua", true, true)) do
      local text = table.concat(vim.fn.readfile(f), "\n")
      if text:find("A-Za-z0-9_.", 1, true) and not f:match("names.lua$") then
        src[#src + 1] = f
      end
    end
    H.eq({}, src, "no second feature-name pattern outside names.lua")
  end)
end)

describe("typosquat check", function()
  it("edit distance", function()
    H.eq(0, vet.distance("serde", "serde"))
    H.eq(1, vet.distance("serd", "serde"))
    H.eq(3, vet.distance("kitten", "sitting"))
    H.eq(1, vet.distance("sedre", "serde"), "a swap of neighbours is one edit")
  end)

  it("flags near misses of popular crates, not the crates themselves", function()
    local t = vet.typosquat("serd")
    H.eq("serde", t.similar)
    H.eq(1, t.distance)
    H.eq("tokio", vet.typosquat("tokioo").similar)
    H.eq("reqwest", vet.typosquat("reqwuest").similar)
    H.eq("serde", vet.typosquat("sedre").similar, "swapped letters")
    H.eq("serde_json", vet.typosquat("serde-jsom").similar)
    H.is_nil(vet.typosquat("serde"))
    H.is_nil(vet.typosquat("serde_json"), "_ and - are one spelling")
    H.is_nil(vet.typosquat("Serde"), "case is not part of the name")
    H.is_nil(vet.typosquat("my_own_crate"))
    H.is_nil(vet.typosquat("abc"), "short names are not compared")
  end)

  it("look-alike letters and the download escape hatch", function()
    H.eq("tokio", vet.typosquat("t0kio").similar)
    H.is_nil(vet.typosquat("serd", 50000000), "a crate with that many downloads is not warned about")
    H.ok(vet.typosquat("serd", 12), "a crate with few downloads is")
  end)

  it("extra_popular guards your own names", function()
    H.is_nil(vet.typosquat("acmecorp-utils"))
    vet.config.extra_popular = { "acmecorp-utils" }
    vet.reset()
    H.eq("acmecorp-utils", vet.typosquat("acmecorp-utilz").similar)
  end)
end)

describe("age", function()
  it("parses crates.io timestamps and prints a human age", function()
    local s = vet.age_seconds(ago(2 * 86400), NOW)
    H.eq(2 * 86400, s)
    H.eq("2 days", vet.human_age(s))
    H.eq("less than a day", vet.human_age(3600))
    H.eq("5 months", vet.human_age(5 * 30.5 * 86400))
    H.eq("10.4 years", vet.human_age(vet.age_seconds(ago(math.floor(10.4 * 365.25 * 86400)), NOW)))
    H.is_nil(vet.age_seconds("yesterday", NOW))
    H.is_nil(vet.age_seconds(nil, NOW))
  end)

  it("parse_crate reads the web API answer", function()
    local m = vet.parse_crate(vim.json.encode({ crate = { created_at = "2020-01-01T00:00:00+00:00", updated_at = "2026-01-01T00:00:00+00:00", downloads = 5, recent_downloads = 2, repository = "https://example.org/r" } }))
    H.eq(5, m.downloads)
    H.eq("https://example.org/r", m.repository)
    H.is_nil(vet.parse_crate("not json"))
    H.is_nil(vet.parse_crate("{}"))
  end)
end)

describe("preview", function()
  it("shows crate, version, features, target, downloads and age", function()
    local r = vet.render({
      spec = { name = "itoa", features = { "std", "alloc" }, default_features = false, kind = "dev", package = "app" },
      info = { newest = "1.0.15", repository = "https://github.com/dtolnay/itoa" },
      meta = { downloads = 1600000000, recent_downloads = 20000000, created_at = ago(math.floor(10.4 * 365.25 * 86400)), updated_at = ago(2 * 86400 + 600) },
      now = NOW,
    })
    local text = table.concat(r.lines, "\n")
    H.match(text, "cargo add itoa", true)
    H.match(text, "1.0.15", true)
    H.match(text, "std, alloc", true)
    H.match(text, "default features OFF", true)
    H.match(text, "[dev-dependencies] of app", true)
    H.match(text, "1.6G total, 20.0M in the last 90 days", true)
    H.match(text, "first published 10.4 years ago, last updated 2 days ago", true)
    H.eq({}, r.warnings)
  end)

  it("warns about a typosquat, a very new crate and an unknown name", function()
    local r = vet.render({
      spec = { name = "serd" },
      info = nil,
      meta = { created_at = ago(5 * 86400) },
      typo = vet.typosquat("serd"),
      now = NOW,
    })
    local text = table.concat(r.lines, "\n")
    H.eq(3, #r.warnings)
    H.match(text, "popular crate `serde`", true)
    H.match(text, "less than 30 days", true)
    H.match(text, "no (or no reachable) index entry", true)
  end)

  it("says so when crates.io gave nothing", function()
    local r = vet.render({ spec = { name = "x" }, info = { newest = "1.0.0" }, now = NOW })
    H.match(table.concat(r.lines, "\n"), "no download or age data", true)
  end)

  it("mentions cargo-audit only when it is installed", function()
    local on = vet.render({ spec = { name = "x" }, info = {}, audit = true, now = NOW })
    local off = vet.render({ spec = { name = "x" }, info = {}, audit = false, now = NOW })
    H.match(table.concat(on.lines, "\n"), "cargo-audit is installed", true)
    H.no_match(table.concat(off.lines, "\n"), "cargo-audit", true)
  end)
end)

describe("confirm before cargo add", function()
  local function ws()
    local root = H.tmpdir() .. "/w"
    vim.fn.mkdir(root, "p")
    return root
  end

  it("a refusal runs nothing, an acceptance runs cargo add once", function()
    fake_lookup({ newest = "1.0.0" }, { downloads = 10 })
    local runs = 0
    stub(ca, "run_add", function(_, _, cb)
      runs = runs + 1
      if cb then
        cb(true, "added")
      end
    end)
    local shown
    local answer = false
    stub(ca.ui, "confirm", function(preview, cb)
      shown = preview
      cb(answer)
    end)
    local res
    ca.confirm_and_add(ws(), { name = "itoa" }, function(ok, msg)
      res = { ok, msg }
    end)
    H.wait_for(function()
      return res
    end, 5000, "decision")
    H.eq({ false, "cancelled" }, res)
    H.eq(0, runs)
    H.match(table.concat(shown.lines, "\n"), "cargo add itoa", true)
    answer, res = true, nil
    ca.confirm_and_add(ws(), { name = "itoa" }, function(ok)
      res = { ok }
    end)
    H.wait_for(function()
      return res
    end, 5000, "run")
    H.eq({ true }, res)
    H.eq(1, runs)
  end)

  it("confirm = false skips the question", function()
    ca.config.confirm = false
    local asked = false
    stub(ca.ui, "confirm", function()
      asked = true
    end)
    local ran
    stub(ca, "run_add", function(_, spec)
      ran = spec.name
    end)
    ca.confirm_and_add(ws(), { name = "itoa" })
    H.eq("itoa", ran)
    H.not_ok(asked)
  end)

  it("a typosquat-looking name reaches the question with a warning", function()
    fake_lookup({ newest = "0.1.0" }, { downloads = 40, created_at = "2020-01-01T00:00:00+00:00" })
    local shown
    stub(ca.ui, "confirm", function(preview, cb)
      shown = preview
      cb(false)
    end)
    local done
    ca.confirm_and_add(ws(), { name = "serd" }, function()
      done = true
    end)
    H.wait_for(function()
      return done
    end, 5000, "question")
    H.eq(1, #shown.warnings)
    H.match(shown.warnings[1], "serde", true)
  end)

  it("with a warning the first choice is Cancel (<CR> cancels)", function()
    local seen
    stub(vim.ui, "select", function(items, _, cb)
      seen = items
      cb(items[1])
    end)
    local out
    ca.ui.confirm({ lines = { "x" }, warnings = { "w" } }, function(v)
      out = v
    end)
    H.eq("cancel", seen[1][2])
    H.eq(false, out)
    ca.ui.confirm({ lines = { "x" }, warnings = {} }, function(v)
      out = v
    end)
    H.eq("add", seen[1][2])
    H.eq(true, out)
    stub(vim.ui, "select", function(_, _, cb)
      cb(nil)
    end)
    ca.ui.confirm({ lines = { "x" }, warnings = {} }, function(v)
      out = v
    end)
    H.eq(false, out, "closing the prompt cancels")
  end)

  it("audit = run reports advisories of the added crate (fake cargo-audit)", function()
    local bin = H.tmpdir() .. "/bin"
    vim.fn.mkdir(bin, "p")
    local json = vim.json.encode({ vulnerabilities = { found = true, list = { { advisory = { id = "RUSTSEC-2099-0001", title = "boom" }, package = { name = "itoa" } }, { advisory = { id = "RUSTSEC-2099-0002", title = "other" }, package = { name = "zzz" } } } } })
    vim.fn.writefile({ "#!/bin/sh", "cat <<'EOF'", json, "EOF", "exit 1" }, bin .. "/cargo-audit")
    vim.uv.fs_chmod(bin .. "/cargo-audit", 493)
    vim.env.PATH = bin .. ":" .. saved_path
    local cap = H.capture_notify()
    local n
    ca.audit(ws(), "itoa", function(c)
      n = c
    end)
    H.wait_for(function()
      return n
    end, 20000, "audit")
    H.eq(1, n)
    H.ok(vim.iter(cap.list):any(function(x)
      return x.msg:find("RUSTSEC-2099-0001", 1, true) and not x.msg:find("RUSTSEC-2099-0002", 1, true)
    end))
  end)
end)

describe("setup can be called again", function()
  local function rust_buf()
    local rs = H.tmpdir() .. "/x.rs"
    vim.fn.writefile({ "fn main() {}" }, rs)
    vim.cmd.edit(vim.fn.fnameescape(rs))
    vim.bo.filetype = "rust"
    return vim.api.nvim_get_current_buf()
  end

  it("replaces keys, options and commands of the first call", function()
    C.setup({ keymaps = { add = "<leader>x1", fix = "<leader>x2" } })
    local buf = rust_buf()
    H.wait_for(function()
      return vim.fn.maparg("<leader>x1", "n", false, true).buffer == 1
    end, 3000, "first key")
    H.eq(1, vim.fn.maparg("<leader>x2", "n", false, true).buffer)
    C.setup({ keymaps = { add = "<leader>y1", fix = false }, add = { confirm = false, audit = "run" } })
    H.wait_for(function()
      return vim.fn.maparg("<leader>y1", "n", false, true).buffer == 1
    end, 3000, "second key")
    H.eq("", vim.fn.maparg("<leader>x1", "n"), "the first call's key is gone")
    H.eq("", vim.fn.maparg("<leader>x2", "n"), "the fix key is gone")
    H.eq(false, ca.config.confirm)
    H.eq("run", ca.config.audit)
    C.setup({})
    H.eq(true, ca.config.confirm, "a dropped option returns to its default")
    H.eq("hint", ca.config.audit)
    H.eq("", vim.fn.maparg("<leader>y1", "n"))
    H.ok(vim.api.nvim_buf_is_valid(buf))
  end)

  it("a second call can turn modules and commands off", function()
    C.setup({})
    H.eq(2, vim.fn.exists(":CrateAdd"))
    H.eq(2, vim.fn.exists(":CrateFeatures"))
    C.setup({ modules = { add = false } })
    H.eq(0, vim.fn.exists(":CrateAdd"))
    H.eq(2, vim.fn.exists(":CrateFeatures"))
    C.setup({ commands = false })
    H.eq(0, vim.fn.exists(":CrateAdd"))
    H.eq(0, vim.fn.exists(":CrateFeatures"))
    C.setup({})
    H.eq(2, vim.fn.exists(":CrateAdd"))
  end)

  it("refuses invalid options as a whole, with one message", function()
    C.setup({})
    local cap = H.capture_notify()
    C.setup({ add = { audit = "sometimes", nope = 1 }, modules = { nope = true }, keymaps = "x" })
    local msg = cap.list[#cap.list].msg
    H.match(msg, "add.audit must be one of", true)
    H.match(msg, "unknown add option `nope`", true)
    H.match(msg, "unknown module `nope`", true)
    H.match(msg, "keymaps must be", true)
    H.eq("hint", ca.config.audit, "nothing changed")
    H.eq(2, vim.fn.exists(":CrateAdd"))
  end)

  it("health check runs", function()
    local lines = {}
    local orig = vim.health
    local function rec(m)
      lines[#lines + 1] = m
    end
    vim.health = { start = rec, ok = rec, info = rec, warn = rec, error = rec }
    local ok, err = pcall(require("xyno_crates.health").check)
    vim.health = orig
    H.ok(ok, err)
    H.ok(#lines >= 6)
  end)
end)
