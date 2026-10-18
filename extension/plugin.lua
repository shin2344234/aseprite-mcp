-- Aseprite MCP bridge.
-- Connects the running Aseprite to the aseprite-mcp server over a local
-- WebSocket. The server sends the Lua runtime on connect, then tool calls.
--
-- Frames (text):
--   client -> server  "HELLO\n<aseprite version>"
--   server -> client  "RUNTIME\n<lua source>"   client replies "READY\n<json>"
--   server -> client  "CALL <id>\n<json>"       client replies "RESULT <id>\n<json>"
--   server -> client  "PING"                    heartbeat, no reply

local DEFAULT_PORT = 41234
local RETRY_SECONDS = 2
-- The server pings every 5 s; silence for longer than this means the link is dead.
local STALE_SECONDS = 15

local ws
local MCP
local status = "disconnected"
local lastAttempt = 0
local lastSeen = 0
local retryTimer
local thePlugin

local function port_of(plugin)
  local p = tonumber(plugin.preferences.port)
  if p and p > 0 and p < 65536 then return math.floor(p) end
  return DEFAULT_PORT
end

local function escape(s)
  return '"' .. tostring(s):gsub('[%c"\\]', function(c)
    return string.format("\\u%04x", c:byte())
  end) .. '"'
end

-- Aseprite stops the socket for good if this callback raises, so sending never throws.
local function send(text)
  local ok = pcall(function() ws:sendText(text) end)
  if not ok then status = "disconnected" end
end

local function handle(mt, data, err)
  if mt == WebSocketMessageType.OPEN then
    status = "connected"
    lastSeen = os.time()
    send("HELLO\n" .. tostring(app.version))
  elseif mt == WebSocketMessageType.TEXT then
    lastSeen = os.time()
    local nl = data:find("\n", 1, true)
    local head = nl and data:sub(1, nl - 1) or data
    local body = nl and data:sub(nl + 1) or ""
    if head == "RUNTIME" then
      local chunk, loadErr = load(body, "@aseprite-mcp", "t")
      if not chunk then
        send('READY\n{"ok":false,"error":' .. escape(loadErr) .. '}')
        return
      end
      local ok, res = pcall(chunk)
      if not ok then
        send('READY\n{"ok":false,"error":' .. escape(res) .. '}')
        return
      end
      MCP = res
      MCP.mode = "live"
      send("READY\n" .. MCP.dispatch('{"tool":"ping"}'))
    elseif head:sub(1, 5) == "CALL " then
      local id = head:sub(6)
      local resp
      if not MCP then
        resp = '{"ok":false,"error":"runtime not loaded"}'
      else
        local ok, res = pcall(MCP.dispatch, body)
        resp = ok and res or ('{"ok":false,"error":' .. escape(res) .. '}')
      end
      send("RESULT " .. id .. "\n" .. resp)
    end
  elseif mt == WebSocketMessageType.CLOSE then
    status = "disconnected"
  elseif mt == WebSocketMessageType.ERROR then
    status = "error: " .. tostring(err)
  end
end

local function on_message(mt, data, err)
  local ok = pcall(handle, mt, data, err)
  if not ok then status = "disconnected" end
end

local function connect(plugin)
  if ws then pcall(function() ws:close() end) end
  ws = WebSocket{
    url = "ws://127.0.0.1:" .. port_of(plugin),
    onreceive = on_message,
    deflate = false,
    minreconnectwait = 1,
    maxreconnectwait = 5,
  }
  status = "connecting"
  lastAttempt = os.time()
  ws:connect()
end

function init(plugin)
  -- Batch runs (aseprite -b) load extensions too; the bridge is only for the GUI.
  if not app.isUIAvailable then return end
  thePlugin = plugin

  plugin:newCommand{
    id = "AsepriteMcpBridgeSettings",
    title = "MCP Bridge...",
    group = "file_scripts",
    onclick = function()
      local dlg = Dialog("MCP Bridge")
      dlg:label{ text = "Status: " .. status }
      dlg:number{ id = "port", label = "Server port:", text = tostring(port_of(plugin)), decimals = 0 }
      dlg:button{ id = "ok", text = "Reconnect" }
      dlg:button{ id = "cancel", text = "Close" }
      dlg:show()
      if dlg.data.ok then
        plugin.preferences.port = math.floor(dlg.data.port)
        connect(plugin)
      end
    end,
  }

  connect(plugin)

  -- Retry while disconnected (the socket gives up once the server goes away),
  -- and treat a connection with no heartbeat as dead.
  retryTimer = Timer{
    interval = RETRY_SECONDS,
    ontick = function()
      local now = os.time()
      if status == "connected" and now - lastSeen <= STALE_SECONDS then return end
      if status == "connecting" and now - lastAttempt < RETRY_SECONDS * 2 then return end
      pcall(connect, thePlugin)
    end,
  }
  retryTimer:start()
end

function exit(plugin)
  if retryTimer then retryTimer:stop() end
  if ws then pcall(function() ws:close() end) end
  ws = nil
end
