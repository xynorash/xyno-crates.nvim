-- xyno-crates features: the in-process language client with the code action, and the fix key.
-- Part of xyno_crates.crate_features (the facade merges every part into one table).
local M = {}
local cm = require("xyno_rust.crate_meta")

local Manifest = require("xyno_crates.features.manifest")
local Suggest = require("xyno_crates.features.suggest")
local valid_features = require("xyno_crates.names").valid_features

M.client_name = "xyno-features"
M.command = "xyno.enable_feature"

-- =========================================================== the code action

local function collect_diags(bufnr, from_line, to_line, extra)
  local out = {}
  for _, d in ipairs(vim.diagnostic.get(bufnr)) do
    if d.lnum <= to_line and (d.end_lnum or d.lnum) >= from_line then
      out[#out + 1] = d
    end
  end
  for _, d in ipairs(extra or {}) do
    out[#out + 1] = d
  end
  return out
end

--- cb(suggestions, root)
function M.suggest_async(bufnr, diags, cb)
  local file = vim.api.nvim_buf_get_name(bufnr)
  local root = file ~= "" and cm.root(file) or nil
  if not root or #diags == 0 then
    return vim.schedule(function()
      cb({}, root)
    end)
  end
  cm.metadata_async(root, function(meta)
    if not meta then
      return cb({}, root)
    end
    local ok, res = pcall(Suggest.suggest, meta, file, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), diags)
    local list = ok and res or {}
    for _, s in ipairs(list) do
      s.root = root
    end
    cb(list, root)
  end)
end

local function action_of(s)
  return {
    title = Suggest.title(s),
    kind = "quickfix",
    command = {
      title = Suggest.title(s),
      command = M.command,
      arguments = {
        { root = s.root, member = s.member, kind = s.kind, crate = s.crate, features = s.features, target = s.target },
      },
    },
  }
end

local function make_server(dispatchers)
  local closing = false
  local next_id = 0
  local srv = {}
  -- on_exit exactly once, from exit and from terminate: a client that never
  -- reports it stays in vim.lsp.get_clients() as a stopped entry
  local function close()
    if not closing then
      closing = true
      dispatchers.on_exit(0, 0)
    end
  end
  function srv.request(method, params, callback)
    next_id = next_id + 1
    local id = next_id
    if method == "initialize" then
      callback(nil, {
        capabilities = {
          codeActionProvider = { codeActionKinds = { "quickfix" } },
          executeCommandProvider = { commands = { M.command } },
        },
        serverInfo = { name = M.client_name },
      })
    elseif method == "textDocument/codeAction" then
      local bufnr = vim.uri_to_bufnr(params.textDocument.uri)
      local diags = collect_diags(bufnr, params.range.start.line, params.range["end"].line)
      M.suggest_async(bufnr, diags, function(list)
        callback(nil, vim.tbl_map(action_of, list))
      end)
    elseif method == "workspace/executeCommand" then
      local arg = params.arguments and params.arguments[1]
      if
        params.command ~= M.command
        or type(arg) ~= "table"
        or not valid_features(arg.features)
        or not cm.valid_name(arg.crate or "")
      then
        return callback({ code = -32602, message = "bad arguments" }), id
      end
      Manifest.apply(arg, function(ok, how)
        callback(not ok and { code = -32603, message = tostring(how) } or nil, nil)
      end)
    else
      callback(nil, nil)
    end
    return true, id
  end
  function srv.notify(method)
    if method == "exit" then
      close()
    end
    return true
  end
  function srv.is_closing()
    return closing
  end
  function srv.terminate()
    close()
  end
  return srv
end

--- Start (or reuse) the in-process client for a Rust buffer.
function M.attach(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].buftype ~= "" then
    return
  end
  local file = vim.api.nvim_buf_get_name(bufnr)
  if file == "" then
    return
  end
  local root = cm.root(file) or vim.fs.dirname(file)
  pcall(vim.lsp.start, { name = M.client_name, cmd = make_server, root_dir = root }, { bufnr = bufnr, silent = true })
end

--- Fix the diagnostics on the cursor line (all lines of a visual range) with
--- one command: no menu when there is a single suggestion.
function M.fix_at_cursor()
  local bufnr = vim.api.nvim_get_current_buf()
  local l = vim.api.nvim_win_get_cursor(0)[1] - 1
  M.suggest_async(bufnr, collect_diags(bufnr, l, l), function(list)
    if #list == 0 then
      return vim.notify("No missing-feature fix for the diagnostics on this line", vim.log.levels.INFO)
    end
    if #list == 1 then
      return Manifest.apply(list[1], function() end)
    end
    vim.ui.select(list, { prompt = "Enable feature", format_item = Suggest.title }, function(choice)
      if choice then
        Manifest.apply(choice, function() end)
      end
    end)
  end)
end

return M
