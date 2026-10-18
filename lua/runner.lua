-- Batch-mode entry point:
--   aseprite -b --script-param runtime=<runtime.lua> --script-param request=<req.json>
--            --script-param response=<resp.json> --script runner.lua
local p = app.params
local MCP = dofile(p.runtime)
MCP.mode = "batch"

local f = assert(io.open(p.request, "rb"))
local req = f:read("a")
f:close()

local resp = MCP.dispatch(req)

local o = assert(io.open(p.response, "wb"))
o:write(resp)
o:close()
