-- Aseprite MCP runtime.
-- Runs inside Aseprite, either in --batch mode (one process per call, see
-- runner.lua) or inside the GUI through the bridge extension. Every MCP tool
-- that touches sprites is a handler in MCP.handlers.

local MCP = { version = "0.1.0", mode = "batch", handlers = {} }

----------------------------------------------------------------------
-- JSON (plain Lua tables; Aseprite's json.decode returns userdata proxies)
----------------------------------------------------------------------

local json = {}
MCP.json = json

json.null = setmetatable({}, { __tostring = function() return "null" end })
local ARRAY_MT = { __jsontype = "array" }
local OBJECT_MT = { __jsontype = "object" }
function json.array(t) return setmetatable(t or {}, ARRAY_MT) end
function json.object(t) return setmetatable(t or {}, OBJECT_MT) end

local escapes = { ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
                  ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }

local function encode_string(s)
  return '"' .. s:gsub('[%c"\\]', function(c)
    return escapes[c] or string.format("\\u%04x", c:byte())
  end) .. '"'
end

local function is_array(t)
  local mt = getmetatable(t)
  if mt == ARRAY_MT then return true end
  if mt == OBJECT_MT then return false end
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" or k <= 0 or math.floor(k) ~= k then return false end
    n = n + 1
  end
  if n == 0 then return false end
  for i = 1, n do if t[i] == nil then return false end end
  return true
end

local function encode(v, out, depth)
  if depth > 64 then error("json: nesting too deep", 0) end
  local t = type(v)
  if v == nil or v == json.null then out[#out + 1] = "null"
  elseif t == "boolean" then out[#out + 1] = v and "true" or "false"
  elseif t == "number" then
    if v ~= v or v == math.huge or v == -math.huge then out[#out + 1] = "null"
    elseif math.type(v) == "integer" or (v == math.floor(v) and math.abs(v) < 2^53) then
      out[#out + 1] = string.format("%d", math.floor(v))
    else out[#out + 1] = string.format("%.14g", v) end
  elseif t == "string" then out[#out + 1] = encode_string(v)
  elseif t == "table" then
    if is_array(v) then
      out[#out + 1] = "["
      for i = 1, #v do
        if i > 1 then out[#out + 1] = "," end
        encode(v[i], out, depth + 1)
      end
      out[#out + 1] = "]"
    else
      local keys = {}
      for k in pairs(v) do keys[#keys + 1] = tostring(k) end
      table.sort(keys)
      out[#out + 1] = "{"
      for i, k in ipairs(keys) do
        local val = v[k]
        if val == nil then val = v[tonumber(k)] end
        if i > 1 then out[#out + 1] = "," end
        out[#out + 1] = encode_string(k)
        out[#out + 1] = ":"
        encode(val, out, depth + 1)
      end
      out[#out + 1] = "}"
    end
  else
    out[#out + 1] = encode_string(MCP.describe(v))
  end
end

function json.encode(v)
  local out = {}
  encode(v, out, 0)
  return table.concat(out)
end

function json.decode(s)
  local pos = 1
  local function ws() pos = s:find("[^ \t\r\n]", pos) or (#s + 1) end
  local function err(msg) error(string.format("json: %s at position %d", msg, pos), 0) end
  local value
  local function str()
    pos = pos + 1
    local buf = {}
    while true do
      local c = s:sub(pos, pos)
      if c == "" then err("unterminated string") end
      if c == '"' then pos = pos + 1; break end
      if c == "\\" then
        local e = s:sub(pos + 1, pos + 1)
        local map = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }
        if map[e] then buf[#buf + 1] = map[e]; pos = pos + 2
        elseif e == "u" then
          local cp = tonumber(s:sub(pos + 2, pos + 5), 16) or err("bad unicode escape")
          pos = pos + 6
          if cp >= 0xD800 and cp <= 0xDBFF and s:sub(pos, pos + 1) == "\\u" then
            local lo = tonumber(s:sub(pos + 2, pos + 5), 16)
            if lo and lo >= 0xDC00 and lo <= 0xDFFF then
              cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
              pos = pos + 6
            end
          end
          buf[#buf + 1] = utf8.char(cp)
        else err("bad escape") end
      else
        local j = s:find('["\\]', pos) or (#s + 1)
        buf[#buf + 1] = s:sub(pos, j - 1)
        pos = j
      end
    end
    return table.concat(buf)
  end
  value = function()
    ws()
    local c = s:sub(pos, pos)
    if c == "{" then
      pos = pos + 1
      local obj = {}
      ws()
      if s:sub(pos, pos) == "}" then pos = pos + 1; return obj end
      while true do
        ws()
        if s:sub(pos, pos) ~= '"' then err("expected key") end
        local k = str()
        ws()
        if s:sub(pos, pos) ~= ":" then err("expected ':'") end
        pos = pos + 1
        local v = value()
        obj[k] = v
        ws()
        local d = s:sub(pos, pos)
        pos = pos + 1
        if d == "}" then return obj end
        if d ~= "," then err("expected ',' or '}'") end
      end
    elseif c == "[" then
      pos = pos + 1
      local arr = json.array({})
      ws()
      if s:sub(pos, pos) == "]" then pos = pos + 1; return arr end
      local n = 0
      while true do
        n = n + 1
        local v = value()
        if v == nil then v = json.null end -- keep array positions for nulls
        arr[n] = v
        ws()
        local d = s:sub(pos, pos)
        pos = pos + 1
        if d == "]" then return arr end
        if d ~= "," then err("expected ',' or ']'") end
      end
    elseif c == '"' then return str()
    elseif s:sub(pos, pos + 3) == "true" then pos = pos + 4; return true
    elseif s:sub(pos, pos + 4) == "false" then pos = pos + 5; return false
    elseif s:sub(pos, pos + 3) == "null" then pos = pos + 4; return nil
    else
      local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
      if not num or num == "" then err("unexpected character '" .. c .. "'") end
      pos = pos + #num
      return math.tointeger(tonumber(num)) or tonumber(num)
    end
  end
  local ok, res = pcall(value)
  if not ok then error(res, 0) end
  return res
end

----------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------

local function fail(fmt, ...)
  error(select("#", ...) > 0 and string.format(fmt, ...) or fmt, 0)
end
MCP.fail = fail

local function enum_name(enum, value)
  for k, v in pairs(enum) do if v == value then return k end end
  return value
end

local COLOR_MODES = { rgb = ColorMode.RGB, rgba = ColorMode.RGB, gray = ColorMode.GRAY,
                      grayscale = ColorMode.GRAY, indexed = ColorMode.INDEXED }
local function color_mode_name(m)
  if m == ColorMode.RGB then return "rgb" elseif m == ColorMode.GRAY then return "gray"
  elseif m == ColorMode.INDEXED then return "indexed" elseif m == ColorMode.TILEMAP then return "tilemap" end
  return tostring(m)
end
MCP.color_mode_name = color_mode_name

local BLEND_MODES = {
  normal = BlendMode.NORMAL, multiply = BlendMode.MULTIPLY, screen = BlendMode.SCREEN,
  overlay = BlendMode.OVERLAY, darken = BlendMode.DARKEN, lighten = BlendMode.LIGHTEN,
  color_dodge = BlendMode.COLOR_DODGE, color_burn = BlendMode.COLOR_BURN,
  hard_light = BlendMode.HARD_LIGHT, soft_light = BlendMode.SOFT_LIGHT,
  difference = BlendMode.DIFFERENCE, exclusion = BlendMode.EXCLUSION, hue = BlendMode.HSL_HUE,
  saturation = BlendMode.HSL_SATURATION, color = BlendMode.HSL_COLOR,
  luminosity = BlendMode.HSL_LUMINOSITY, addition = BlendMode.ADDITION,
  subtract = BlendMode.SUBTRACT, divide = BlendMode.DIVIDE, src = BlendMode.SRC,
}
local function blend_mode(v)
  if v == nil then return nil end
  if type(v) == "number" then return v end
  local m = BLEND_MODES[tostring(v):lower():gsub("[%s%-]", "_")]
  if m == nil then fail("Unknown blend mode '%s'", tostring(v)) end
  return m
end
local function blend_name(v)
  if v == nil then return nil end
  for k, m in pairs(BLEND_MODES) do if m == v then return k end end
  return v
end

local ANI_DIRS = { forward = AniDir.FORWARD, reverse = AniDir.REVERSE,
                   ping_pong = AniDir.PING_PONG, pingpong = AniDir.PING_PONG,
                   ping_pong_reverse = AniDir.PING_PONG_REVERSE }
local function ani_dir(v)
  if v == nil then return nil end
  if type(v) == "number" then return v end
  local d = ANI_DIRS[tostring(v):lower():gsub("[%s%-]", "_")]
  if d == nil then fail("Unknown animation direction '%s'", tostring(v)) end
  return d
end
local function ani_dir_name(v)
  for k, d in pairs(ANI_DIRS) do if d == v and k ~= "pingpong" then return k end end
  return v
end

local function rect_in(v, what)
  if v == nil then return nil end
  if type(v) ~= "table" then fail("%s must be an object {x, y, width, height}", what or "rect") end
  return Rectangle(v.x or 0, v.y or 0, v.width or v.w or 0, v.height or v.h or 0)
end
local function rect_out(r)
  if r == nil then return nil end
  return { x = r.x, y = r.y, width = r.width, height = r.height }
end
local function point_in(v)
  if v == nil then return nil end
  if type(v) == "table" then
    if v.x ~= nil then return Point(v.x, v.y or 0) end
    return Point(v[1] or 0, v[2] or 0)
  end
  fail("point must be [x, y] or {x, y}")
end
local function point_out(p) if p == nil then return nil end return { x = p.x, y = p.y } end
local function size_out(s) if s == nil then return nil end return { width = s.width, height = s.height } end
MCP.rect_in, MCP.rect_out, MCP.point_in, MCP.point_out = rect_in, rect_out, point_in, point_out

function MCP.describe(v)
  local ok, s = pcall(tostring, v)
  return ok and s or type(v)
end

----------------------------------------------------------------------
-- Colors
----------------------------------------------------------------------

local NAMED = {
  transparent = { 0, 0, 0, 0 }, black = { 0, 0, 0, 255 }, white = { 255, 255, 255, 255 },
  red = { 255, 0, 0, 255 }, green = { 0, 255, 0, 255 }, blue = { 0, 0, 255, 255 },
  yellow = { 255, 255, 0, 255 }, cyan = { 0, 255, 255, 255 }, magenta = { 255, 0, 255, 255 },
  gray = { 128, 128, 128, 255 }, grey = { 128, 128, 128, 255 }, orange = { 255, 165, 0, 255 },
}

-- Accepts "#rgb", "#rgba", "#rrggbb", "#rrggbbaa", a named color, a palette
-- index (number), {index=n}, {r,g,b,a}, {h,s,v,a}, {h,s,l,a} or {gray,a}.
function MCP.color(v)
  if v == nil or v == json.null then return nil end
  local t = type(v)
  if t == "userdata" then return v end
  if t == "number" then return Color{ index = math.tointeger(v) or math.floor(v) } end
  if t == "string" then
    local named = NAMED[v:lower()]
    if named then return Color{ r = named[1], g = named[2], b = named[3], a = named[4] } end
    local h = v:gsub("^#", ""):gsub("^0x", "")
    if not h:match("^%x+$") then fail("Bad color '%s' (use #rrggbb or #rrggbbaa)", v) end
    if #h == 3 or #h == 4 then h = h:gsub("%x", "%0%0") end
    if #h ~= 6 and #h ~= 8 then fail("Bad color '%s' (use #rrggbb or #rrggbbaa)", v) end
    return Color{ r = tonumber(h:sub(1, 2), 16), g = tonumber(h:sub(3, 4), 16),
                  b = tonumber(h:sub(5, 6), 16), a = #h == 8 and tonumber(h:sub(7, 8), 16) or 255 }
  end
  if t == "table" then
    local a = v.a or v.alpha or 255
    if v.index ~= nil then return Color{ index = v.index } end
    if v.gray ~= nil then return Color{ gray = v.gray, alpha = a } end
    if v.h ~= nil or v.hue ~= nil then
      local hue = v.h or v.hue
      if v.l ~= nil or v.lightness ~= nil then
        return Color{ h = hue, s = v.s or v.saturation or 0, l = v.l or v.lightness, a = a }
      end
      return Color{ h = hue, s = v.s or v.saturation or 0, v = v.v or v.value or 0, a = a }
    end
    return Color{ r = v.r or v.red or 0, g = v.g or v.green or 0, b = v.b or v.blue or 0, a = a }
  end
  fail("Bad color value of type %s", t)
end

function MCP.color_out(c)
  if c == nil then return nil end
  return string.format("#%02x%02x%02x%02x", c.red, c.green, c.blue, c.alpha)
end

local pc = app.pixelColor

-- Converts a color spec into a raw pixel value for the given image.
function MCP.pixel(img, v)
  local cm = img.colorMode
  if cm == ColorMode.TILEMAP then
    if type(v) ~= "number" then fail("Tilemap pixels are tile indices (numbers)") end
    return v
  end
  if cm == ColorMode.INDEXED then
    if type(v) == "number" then return v end
    if type(v) == "table" and v.index ~= nil then return v.index end
    local c = MCP.color(v)
    if c.alpha == 0 then return img.spec.transparentColor end
    return c.index
  end
  local c = MCP.color(v)
  if cm == ColorMode.GRAY then return c.grayPixel end
  return c.rgbaPixel
end

-- Converts a raw pixel value into "#rrggbbaa" (or an index for indexed images).
function MCP.pixel_out(img, px)
  local cm = img.colorMode
  if cm == ColorMode.RGB then
    return string.format("#%02x%02x%02x%02x", pc.rgbaR(px), pc.rgbaG(px), pc.rgbaB(px), pc.rgbaA(px))
  elseif cm == ColorMode.GRAY then
    local g = pc.grayaV(px)
    return string.format("#%02x%02x%02x%02x", g, g, g, pc.grayaA(px))
  end
  return px
end

----------------------------------------------------------------------
-- Object resolution
----------------------------------------------------------------------

local function norm_path(p)
  if p == nil then return nil end
  local ok, n = pcall(app.fs.normalizePath, p)
  n = ok and n or p
  if app.os.windows then n = n:lower():gsub("/", "\\") end
  return n
end

MCP.ctx = { touched = {} }
MCP.last_selection = {}

local function touch(spr)
  MCP.ctx.touched[spr] = true
  return spr
end

-- ref: nil (active sprite), sprite id (number), file path or tab title.
function MCP.sprite(ref)
  if ref == nil or ref == "" then
    local s = app.sprite
    if not s then fail("No active sprite. Pass 'sprite' (a file path or sprite id), or open/create one first.") end
    return touch(s)
  end
  if type(ref) == "number" then
    for _, s in ipairs(app.sprites) do
      if s.id == ref then app.sprite = s; return touch(s) end
    end
    fail("No open sprite with id %d", ref)
  end
  local want = norm_path(ref)
  for _, s in ipairs(app.sprites) do
    if norm_path(s.filename) == want then app.sprite = s; return touch(s) end
  end
  if app.fs.isFile(ref) then
    local s = app.open(ref)
    if not s then fail("Aseprite could not open '%s'", ref) end
    app.sprite = s
    return touch(s)
  end
  for _, s in ipairs(app.sprites) do
    if app.fs.fileName(s.filename) == ref then app.sprite = s; return touch(s) end
  end
  fail("Sprite '%s' is not open and no such file exists", ref)
end

local function walk_layers(container, out, prefix)
  for _, l in ipairs(container.layers) do
    local path = prefix and (prefix .. "/" .. l.name) or l.name
    out[#out + 1] = { layer = l, path = path }
    if l.isGroup then walk_layers(l, out, path) end
  end
  return out
end
MCP.walk_layers = walk_layers

function MCP.layer_path(layer)
  local parts = { layer.name }
  local p = layer.parent
  while p and p ~= layer.sprite do
    table.insert(parts, 1, p.name)
    p = p.parent
  end
  return table.concat(parts, "/")
end

-- ref: nil (active layer), index into the flattened layer list, "Group/Name" path, or name.
function MCP.layer(spr, ref, opts)
  opts = opts or {}
  if ref == nil or ref == "" then
    local l = app.layer
    if l and l.sprite == spr then return l end
    if opts.optional then return nil end
    local all = walk_layers(spr, {})
    for i = #all, 1, -1 do
      if all[i].layer.isImage then return all[i].layer end
    end
    fail("Sprite has no image layers")
  end
  local all = walk_layers(spr, {})
  if type(ref) == "number" then
    local e = all[ref]
    if not e then fail("Layer index %d out of range (1..%d)", ref, #all) end
    return e.layer
  end
  for _, e in ipairs(all) do if e.path == ref then return e.layer end end
  if ref:match("^%x+%-%x+%-%x+%-%x+%-%x+$") then
    for _, e in ipairs(all) do
      local ok, u = pcall(function() return tostring(e.layer.uuid) end)
      if ok and u == ref then return e.layer end
    end
  end
  local found = {}
  for _, e in ipairs(all) do if e.layer.name == ref then found[#found + 1] = e end end
  if #found == 1 then return found[1].layer end
  if #found > 1 then
    local paths = {}
    for _, e in ipairs(found) do paths[#paths + 1] = e.path end
    fail("Layer name '%s' is ambiguous; use a path: %s", ref, table.concat(paths, ", "))
  end
  local names = {}
  for _, e in ipairs(all) do names[#names + 1] = e.path end
  fail("No layer '%s'. Layers: %s", ref, table.concat(names, ", "))
end

function MCP.frame(spr, ref)
  if ref == nil or ref == "" then
    local f = app.frame
    if f and f.sprite == spr then return f end
    return spr.frames[1]
  end
  local n = math.tointeger(ref)
  if not n then fail("frame must be a 1-based frame number") end
  local f = spr.frames[n]
  if not f then fail("Frame %d out of range (1..%d)", n, #spr.frames) end
  return f
end

-- Resolves {from, to} | frames list | tag name | "all" into a list of frame numbers.
function MCP.frame_list(spr, a)
  local res = {}
  if a.frames == "all" then
    for i = 1, #spr.frames do res[#res + 1] = i end
  elseif type(a.frames) == "table" then
    for _, n in ipairs(a.frames) do MCP.frame(spr, n); res[#res + 1] = n end
  elseif a.tag ~= nil then
    local tag = MCP.tag(spr, a.tag)
    for i = tag.fromFrame.frameNumber, tag.toFrame.frameNumber do res[#res + 1] = i end
  elseif a.from ~= nil or a.to ~= nil then
    local from, to = a.from or 1, a.to or #spr.frames
    MCP.frame(spr, from); MCP.frame(spr, to)
    for i = from, to do res[#res + 1] = i end
  elseif a.frame ~= nil then
    res[1] = MCP.frame(spr, a.frame).frameNumber
  else
    res[1] = MCP.frame(spr, nil).frameNumber
  end
  return res
end

function MCP.tag(spr, ref)
  for _, t in ipairs(spr.tags) do if t.name == ref then return t end end
  if type(ref) == "number" and spr.tags[ref] then return spr.tags[ref] end
  fail("No tag '%s'", tostring(ref))
end

function MCP.slice(spr, ref)
  for _, s in ipairs(spr.slices) do if s.name == ref then return s end end
  if type(ref) == "number" and spr.slices[ref] then return spr.slices[ref] end
  fail("No slice '%s'", tostring(ref))
end

function MCP.tileset(spr, ref)
  if ref == nil then
    local l = app.layer
    if l and l.sprite == spr and l.isTilemap then return l.tileset end
    if #spr.tilesets == 1 then return spr.tilesets[1] end
    fail("Pass 'tileset' (index or name); the sprite has %d tilesets", #spr.tilesets)
  end
  if type(ref) == "number" then
    local ts = spr.tilesets[ref]
    if not ts then fail("Tileset %d out of range (1..%d)", ref, #spr.tilesets) end
    return ts
  end
  for _, ts in ipairs(spr.tilesets) do if ts.name == ref then return ts end end
  local ok, l = pcall(MCP.layer, spr, ref)
  if ok and l.isTilemap then return l.tileset end
  fail("No tileset '%s'", tostring(ref))
end

-- Makes sprite/layer/frame active so commands and app.useTool act on them.
function MCP.activate(spr, layer, frame)
  if spr and app.sprite ~= spr then app.sprite = spr end
  if layer then app.layer = layer end
  if frame then app.frame = frame end
end

----------------------------------------------------------------------
-- Serialization
----------------------------------------------------------------------

local function props_out(obj)
  local ok, p = pcall(function() return obj.properties end)
  if not ok or p == nil then return nil end
  local res, any = {}, false
  local ok2 = pcall(function()
    for k, v in pairs(p) do res[k] = v; any = true end
  end)
  if not ok2 or not any then return nil end
  return res
end

local function nonempty(s) if s == nil or s == "" then return nil end return s end

function MCP.layer_info(l, index, path)
  local info = {
    index = index, name = l.name, path = path or MCP.layer_path(l),
    type = l.isGroup and "group" or (l.isTilemap and "tilemap" or "image"),
    visible = l.isVisible, editable = l.isEditable, stackIndex = l.stackIndex,
    data = nonempty(l.data), properties = props_out(l),
  }
  if l.isGroup then
    info.collapsed = l.isCollapsed
    info.childCount = #l.layers
  else
    info.opacity = l.opacity
    info.blendMode = blend_name(l.blendMode)
    info.background = l.isBackground or nil
    info.continuous = l.isContinuous or nil
    info.reference = l.isReference or nil
    info.celCount = #l.cels
  end
  if l.isTilemap and l.tileset then
    for i, ts in ipairs(l.sprite.tilesets) do if ts == l.tileset then info.tileset = i end end
  end
  if l.color and l.color.alpha > 0 then info.color = MCP.color_out(l.color) end
  if l.sprite.useLayerUuids then
    local ok, u = pcall(function() return tostring(l.uuid) end)
    if ok then info.uuid = u end
  end
  return info
end

function MCP.cel_info(c)
  local info = {
    layer = MCP.layer_path(c.layer), frame = c.frameNumber, bounds = rect_out(c.bounds),
    opacity = c.opacity, zIndex = c.zIndex, imageId = c.image.id,
    data = nonempty(c.data), properties = props_out(c),
  }
  if c.color and c.color.alpha > 0 then info.color = MCP.color_out(c.color) end
  -- Linked cels share one image.
  local linked = {}
  for _, other in ipairs(c.layer.cels) do
    if other.frameNumber ~= c.frameNumber and other.image.id == c.image.id then
      linked[#linked + 1] = other.frameNumber
    end
  end
  if #linked > 0 then info.linkedFrames = json.array(linked) end
  return info
end

-- Builds an image from {file=...} or {rows=..., legend=...} (RGB).
function MCP.image_from_spec(spec)
  if type(spec) == "string" then spec = { file = spec } end
  if spec.file then
    local img = Image{ fromFile = spec.file }
    if not img then fail("Could not load image '%s'", spec.file) end
    return img
  end
  if not spec.rows then fail("Image spec needs 'file' or 'rows'+'legend'") end
  local w = 0
  for _, row in ipairs(spec.rows) do w = math.max(w, utf8.len(row)) end
  local img = Image(math.max(1, w), math.max(1, #spec.rows), ColorMode.RGB)
  img:clear()
  local legend = spec.legend or {}
  for y, row in ipairs(spec.rows) do
    local x = 0
    for ch in row:gmatch(utf8.charpattern) do
      local c = legend[ch]
      if c ~= nil and c ~= json.null then img:drawPixel(x, y - 1, MCP.color(c).rgbaPixel) end
      x = x + 1
    end
  end
  return img
end

-- Brush from {type, size, angle, image, center, pattern, patternOrigin}.
function MCP.brush(b, spr)
  if b == nil then return nil end
  local t = {}
  if b.image ~= nil then
    local img = MCP.image_from_spec(b.image)
    t.image = spr and MCP.to_sprite_mode(spr, img) or img
    t.type = BrushType.IMAGE
  else
    t.type = BrushType[(b.type or "circle"):upper()] or fail("Unknown brush type '%s'", tostring(b.type))
    t.size = b.size or 1
    t.angle = b.angle or 0
  end
  if b.center ~= nil then t.center = point_in(b.center) end
  if b.pattern ~= nil then
    t.pattern = BrushPattern[b.pattern:upper()] or fail("pattern must be none, origin or target")
  end
  if b.patternOrigin ~= nil then t.patternOrigin = point_in(b.patternOrigin) end
  return Brush(t)
end

function MCP.tag_info(t)
  local info = {
    name = t.name, from = t.fromFrame.frameNumber, to = t.toFrame.frameNumber,
    aniDir = ani_dir_name(t.aniDir), repeats = t.repeats, data = nonempty(t.data),
    properties = props_out(t),
  }
  if t.color then info.color = MCP.color_out(t.color) end
  return info
end

function MCP.slice_info(s)
  local info = {
    name = s.name, bounds = rect_out(s.bounds), center = rect_out(s.center),
    pivot = point_out(s.pivot), data = nonempty(s.data), properties = props_out(s),
  }
  if s.color then info.color = MCP.color_out(s.color) end
  return info
end

function MCP.tileset_info(ts, index)
  return {
    index = index, name = ts.name, tiles = #ts, baseIndex = ts.baseIndex,
    tileSize = size_out(ts.grid.tileSize), origin = point_out(ts.grid.origin),
    data = nonempty(ts.data), properties = props_out(ts),
  }
end

function MCP.sprite_summary(s)
  return {
    id = s.id, filename = s.filename, width = s.width, height = s.height,
    colorMode = color_mode_name(s.colorMode), frames = #s.frames,
    layers = #walk_layers(s, {}), modified = s.isModified, hasFile = s.hasAssociatedFile,
    active = (app.sprite == s) or nil,
  }
end

function MCP.sprite_info(s, opts)
  opts = opts or {}
  local info = MCP.sprite_summary(s)
  info.bounds = nil
  info.transparentColor = s.transparentColor
  info.pixelRatio = size_out(s.pixelRatio)
  info.gridBounds = rect_out(s.gridBounds)
  info.data = nonempty(s.data)
  info.properties = props_out(s)
  info.paletteSize = #s.palettes[1]
  info.palettes = #s.palettes > 1 and #s.palettes or nil
  info.undoSteps = s.undoHistory and s.undoHistory.undoSteps or nil
  info.redoSteps = s.undoHistory and s.undoHistory.redoSteps or nil
  if not s.selection.isEmpty then info.selection = rect_out(s.selection.bounds) end
  local fr = {}
  for i, f in ipairs(s.frames) do fr[i] = math.floor(f.duration * 1000 + 0.5) end
  info.frameDurationsMs = fr
  local layers = {}
  for i, e in ipairs(walk_layers(s, {})) do layers[i] = MCP.layer_info(e.layer, i, e.path) end
  info.layers = json.array(layers)
  local tags = {}
  for i, t in ipairs(s.tags) do tags[i] = MCP.tag_info(t) end
  info.tags = json.array(tags)
  local slices = {}
  for i, sl in ipairs(s.slices) do slices[i] = MCP.slice_info(sl) end
  info.slices = json.array(slices)
  local tilesets = {}
  for i, ts in ipairs(s.tilesets) do tilesets[i] = MCP.tileset_info(ts, i) end
  info.tilesets = json.array(tilesets)
  if opts.cels then
    local cels = {}
    for i, c in ipairs(s.cels) do cels[i] = MCP.cel_info(c) end
    info.cels = json.array(cels)
  end
  if app.sprite == s then
    info.activeLayer = app.layer and MCP.layer_path(app.layer) or nil
    info.activeFrame = app.frame and app.frame.frameNumber or nil
  end
  return info
end

----------------------------------------------------------------------
-- Image helpers
----------------------------------------------------------------------

local function new_image(spr, w, h, colorMode)
  return Image(ImageSpec{ width = w, height = h, colorMode = colorMode or spr.colorMode,
                          transparentColor = spr.transparentColor })
end
MCP.new_image = new_image

-- Returns the cel at layer/frame, creating an empty one if needed.
function MCP.editable_cel(spr, layer, frame)
  if layer.isGroup then fail("Layer '%s' is a group; pick an image layer", layer.name) end
  if not layer.isEditable then fail("Layer '%s' is locked", layer.name) end
  local cel = layer:cel(frame)
  if not cel then
    cel = spr:newCel(layer, frame, new_image(spr, spr.width, spr.height, layer.isTilemap and ColorMode.TILEMAP or nil), Point(0, 0))
  end
  return cel
end

-- Returns a copy of the cel image grown to cover `rect` (canvas coords) and its new origin.
function MCP.grow_image(spr, cel, rect)
  local b = cel.bounds
  local u = rect and b:union(rect) or b
  if u.x == b.x and u.y == b.y and u.width == b.width and u.height == b.height then
    return cel.image:clone(), Point(b.x, b.y)
  end
  local img = new_image(spr, u.width, u.height, cel.image.colorMode)
  img:clear()
  img:drawImage(cel.image, Point(b.x - u.x, b.y - u.y), 255, BlendMode.SRC)
  return img, Point(u.x, u.y)
end

-- Converts an image (any mode) to the sprite's color mode, mapping colors through its palette.
function MCP.to_sprite_mode(spr, src)
  if src.colorMode == spr.colorMode then return src end
  local tmp = Sprite(src.width, src.height, src.colorMode == ColorMode.INDEXED and ColorMode.INDEXED or ColorMode.RGB)
  if src.colorMode == ColorMode.INDEXED or spr.colorMode == ColorMode.INDEXED then tmp:setPalette(spr.palettes[1]) end
  tmp.cels[1].image = src
  app.sprite = tmp
  app.command.ChangePixelFormat{ ui = false, format = color_mode_name(spr.colorMode) }
  local out = tmp.cels[1].image:clone()
  tmp:close()
  app.sprite = spr
  return out
end

-- Puts `src` on layer/frame at canvas position `pos`.
-- opts.mode: "blend" (composite, default), "copy" (overwrite the area) or "replace" (whole cel).
function MCP.place_image(spr, layer, frame, src, pos, opts)
  opts = opts or {}
  if layer.isGroup then fail("Layer '%s' is a group; pick an image layer", layer.name) end
  if not layer.isEditable then fail("Layer '%s' is locked", layer.name) end
  src = MCP.to_sprite_mode(spr, src)
  local mode = opts.mode or "blend"
  local cel = layer:cel(frame)
  if cel == nil then
    return spr:newCel(layer, frame, src, pos)
  end
  if mode == "replace" then
    MCP.commit_cel(cel, src, pos)
    return cel
  end
  local img, origin = MCP.grow_image(spr, cel, Rectangle(pos.x, pos.y, src.width, src.height))
  img:drawImage(src, Point(pos.x - origin.x, pos.y - origin.y), opts.opacity or 255,
                mode == "copy" and BlendMode.SRC or (blend_mode(opts.blendMode) or BlendMode.NORMAL))
  MCP.commit_cel(cel, img, origin)
  return cel
end

-- Linear gradient from p1 (color c1) to p2 (color c2) over the selection, or the whole canvas.
function MCP.linear_gradient(spr, layer, frame, p1, p2, c1, c2, opacity)
  local cel = MCP.editable_cel(spr, layer, frame)
  local region = spr.selection.isEmpty and spr.bounds or spr.selection.bounds:intersect(spr.bounds)
  local img, origin = MCP.grow_image(spr, cel, region)
  local dx, dy = p2.x - p1.x, p2.y - p1.y
  local len2 = dx * dx + dy * dy
  local useSel = not spr.selection.isEmpty
  local over = Image(1, 1, ColorMode.RGB)
  for y = region.y, region.y + region.height - 1 do
    for x = region.x, region.x + region.width - 1 do
      if not useSel or spr.selection:contains(x, y) then
        local t = len2 == 0 and 0 or math.max(0, math.min(1, ((x - p1.x) * dx + (y - p1.y) * dy) / len2))
        local function lerp(p, q) return math.floor(p + (q - p) * t + 0.5) end
        local c = Color{ r = lerp(c1.red, c2.red), g = lerp(c1.green, c2.green), b = lerp(c1.blue, c2.blue),
                         a = lerp(c1.alpha, c2.alpha) }
        local ix, iy = x - origin.x, y - origin.y
        if img.colorMode == ColorMode.RGB and (opacity < 255 or c.alpha < 255) then
          over:drawPixel(0, 0, c.rgbaPixel)
          img:drawImage(over, Point(ix, iy), opacity, BlendMode.NORMAL)
        else
          img:drawPixel(ix, iy, MCP.pixel(img, c))
        end
      end
    end
  end
  MCP.commit_cel(cel, img, origin)
end

-- Files a save/export produced. Single-image formats get one numbered file
-- per frame (name1.png, name2.png...) when the sprite has several frames.
function MCP.written_files(file)
  if app.fs.isFile(file) then return json.array({ file }) end
  local dir, title, ext = app.fs.filePath(file), app.fs.fileTitle(file), app.fs.fileExtension(file)
  local out = {}
  if title:find("{") then
    local pattern = "^" .. title:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"):gsub("{.-}", ".+") .. "%." .. ext .. "$"
    for _, name in ipairs(app.fs.listFiles(dir)) do
      if name:match(pattern) then out[#out + 1] = app.fs.joinPath(dir, name) end
    end
  else
    for _, name in ipairs(app.fs.listFiles(dir)) do
      local rest = name:sub(#title + 1)
      if name:sub(1, #title) == title and rest:match("^%d+%." .. ext .. "$") then
        out[#out + 1] = app.fs.joinPath(dir, name)
      end
    end
  end
  table.sort(out)
  return json.array(out)
end

-- Commits a new image + position to a cel as one undo step.
function MCP.commit_cel(cel, img, pos)
  app.transaction("MCP edit", function()
    cel.image = img
    if pos then cel.position = pos end
  end)
end

local function is_ancestor(group, layer)
  local p = layer.parent
  while p and p ~= layer.sprite do
    if p == group then return true end
    p = p.parent
  end
  return false
end

-- Runs fn with only `layers` (plus their ancestors and children) visible, then restores visibility.
function MCP.with_only_layers(spr, layers, fn)
  local saved = {}
  for _, e in ipairs(walk_layers(spr, {})) do
    local l = e.layer
    local keep = false
    for _, k in ipairs(layers) do
      if l == k or is_ancestor(l, k) or is_ancestor(k, l) then keep = true; break end
    end
    saved[#saved + 1] = { l, l.isVisible }
    if l.isVisible ~= keep then l.isVisible = keep end
  end
  local ok, err = pcall(fn)
  for _, s in ipairs(saved) do
    if s[1].isVisible ~= s[2] then s[1].isVisible = s[2] end
  end
  if not ok then error(err, 0) end
end

-- Renders one frame (all visible layers, or only `layer`) into an RGB image.
function MCP.render(spr, frameNumber, layer)
  local img = Image(spr.width, spr.height, ColorMode.RGB)
  img:clear()
  if layer == nil then
    img:drawSprite(spr, frameNumber)
  else
    MCP.with_only_layers(spr, { layer }, function() img:drawSprite(spr, frameNumber) end)
  end
  return img
end

----------------------------------------------------------------------
-- Dispatch
----------------------------------------------------------------------

-- Confirmation alerts that would block a call waiting for a click in the GUI.
local QUIET_PREFS = {
  { "save_file", "show_file_format_doesnt_support_alert" },
  { "save_file", "show_export_animation_in_sequence_alert" },
  { "export_file", "show_overwrite_files_alert" },
  { "sprite_sheet", "show_overwrite_files_alert" },
  { "gif", "show_alert" }, { "jpeg", "show_alert" }, { "svg", "show_alert" },
  { "tga", "show_alert" }, { "css", "show_alert" }, { "webp", "show_alert" },
  { "tilemap", "show_delete_unused_tileset_alert" },
}

-- Runs fn with those alerts off, restoring the user's settings afterwards.
function MCP.quietly(fn)
  if not app.isUIAvailable then return fn() end
  local saved = {}
  for i, p in ipairs(QUIET_PREFS) do
    local ok, v = pcall(function() return app.preferences[p[1]][p[2]] end)
    if ok and v ~= nil then
      saved[i] = v
      pcall(function() app.preferences[p[1]][p[2]] = false end)
    end
  end
  local res = table.pack(xpcall(fn, function(e) return e end))
  for i, p in ipairs(QUIET_PREFS) do
    if saved[i] ~= nil then pcall(function() app.preferences[p[1]][p[2]] = saved[i] end) end
  end
  if not res[1] then error(res[2], 0) end
  return table.unpack(res, 2, res.n)
end

local function handler(name, mutates, fn)
  MCP.handlers[name] = { mutates = mutates, fn = fn }
end
MCP.handler = handler

function MCP.dispatch(reqText)
  local ok, req = pcall(json.decode, reqText)
  if not ok then return json.encode({ ok = false, error = "Bad request: " .. tostring(req) }) end
  local h = MCP.handlers[req.tool]
  if not h then return json.encode({ ok = false, error = "Unknown tool '" .. tostring(req.tool) .. "'" }) end
  local args = req.args or {}
  MCP.ctx = { touched = {}, output = {}, args = args, inCall = true }
  local tb
  -- In the GUI, pasted or transformed pixels float until dropped; commit them
  -- so every call starts and ends with plain cel contents.
  local function drop_floating()
    if app.isUIAvailable then pcall(function() app.command.Apply() end) end
  end
  drop_floating()
  local ok2, result = xpcall(function()
    local r = MCP.quietly(function() return h.fn(args) end)
    drop_floating()
    return r
  end, function(e)
    tb = debug.traceback(nil, 2)
    if type(e) == "table" then return json.encode(e) end
    return tostring(e)
  end)
  local resp = { ok = ok2 }
  if ok2 then resp.result = result else resp.error = result; resp.traceback = req.debug and tb or nil end
  if #MCP.ctx.output > 0 then resp.output = MCP.ctx.output end

  -- Batch mode works on files: write back sprites that a mutating tool touched.
  local mutates = h.mutates
  if type(mutates) == "function" then mutates = mutates(args) end
  if ok2 and MCP.mode == "batch" and mutates and args.save ~= false then
    local saved, seen = {}, {}
    for spr in pairs(MCP.ctx.touched) do
      if spr.isValid and spr.hasAssociatedFile and not seen[spr.id] then
        seen[spr.id] = true
        local okSave, errSave = pcall(function() spr:saveAs(spr.filename) end)
        if okSave then saved[#saved + 1] = spr.filename
        else resp.warning = "Save failed for " .. spr.filename .. ": " .. tostring(errSave) end
      end
    end
    if #saved > 0 then resp.saved = saved end
  end
  if MCP.mode == "live" and app.isUIAvailable then pcall(app.refresh) end
  MCP.ctx.inCall = false
  local okEnc, text = pcall(json.encode, resp)
  if not okEnc then
    return json.encode({ ok = false, error = "Could not encode result: " .. tostring(text) })
  end
  return text
end

----------------------------------------------------------------------
-- Handlers: app / generic
----------------------------------------------------------------------

handler("ping", false, function()
  return {
    version = tostring(app.version), apiVersion = app.apiVersion, mode = MCP.mode,
    ui = app.isUIAvailable, os = app.os.fullName, runtime = MCP.version,
    sprites = #app.sprites,
  }
end)

handler("run_lua", function(a) return a.mutates ~= false end, function(a)
  if type(a.code) ~= "string" then fail("'code' must be a string") end
  local spr
  if a.sprite ~= nil then spr = MCP.sprite(a.sprite) end
  local env = setmetatable({}, { __index = _G })
  env.args = a.args or {}
  env.MCP = MCP
  env.sprite = spr or app.sprite
  env.print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = MCP.describe((select(i, ...))) end
    MCP.ctx.output[#MCP.ctx.output + 1] = table.concat(parts, "\t")
  end
  local chunk, err = load(a.code, "@aseprite-mcp", "t", env)
  if not chunk then fail("Lua syntax error: %s", err) end
  local results = table.pack(chunk())
  if a.sprite == nil and app.sprite then touch(app.sprite) end
  if results.n <= 1 then return results[1] end
  results.n = nil
  return json.array(results)
end)

local function convert_command_value(v)
  if type(v) == "string" and v:match("^#%x%x%x%x%x%x%x?%x?$") then return MCP.color(v) end
  if type(v) == "table" and getmetatable(v) ~= ARRAY_MT then
    if v.width ~= nil and v.x ~= nil then return rect_in(v) end
    if v.width ~= nil and v.height ~= nil then return Size(v.width, v.height) end
    if v.x ~= nil and v.y ~= nil then return Point(v.x, v.y) end
    if v.r ~= nil or v.gray ~= nil or v.h ~= nil or v.index ~= nil then return MCP.color(v) end
  end
  return v
end

handler("run_command", function(a) return a.mutates ~= false end, function(a)
  local name = a.name
  if type(name) ~= "string" then fail("'name' must be a command name, e.g. 'Flip'") end
  local spr = (a.sprite ~= nil) and MCP.sprite(a.sprite) or app.sprite
  if spr then
    touch(spr)
    local layer = a.layer ~= nil and MCP.layer(spr, a.layer) or nil
    local frame = a.frame ~= nil and MCP.frame(spr, a.frame) or nil
    MCP.activate(spr, layer, frame)
  end
  local cmd = app.command[name]
  if cmd == nil then fail("Unknown command '%s'", name) end
  local params = {}
  for k, v in pairs(a.params or {}) do params[k] = convert_command_value(v) end
  if params.ui == nil and a.allowUi ~= true then params.ui = false end
  local result = cmd(params)
  return { command = name, result = result, sprite = app.sprite and MCP.sprite_summary(app.sprite) or nil }
end)

handler("undo_redo", true, function(a)
  local spr = MCP.sprite(a.sprite)
  local steps = a.steps or 1
  for _ = 1, steps do
    if a.action == "redo" then app.redo() else app.undo() end
  end
  return { undoSteps = spr.undoHistory.undoSteps, redoSteps = spr.undoHistory.redoSteps }
end)

handler("app_state", false, function()
  local res = {
    version = tostring(app.version), apiVersion = app.apiVersion, mode = MCP.mode,
    ui = app.isUIAvailable, fgColor = MCP.color_out(app.fgColor), bgColor = MCP.color_out(app.bgColor),
  }
  local okT, tool = pcall(function() return app.tool end)
  if okT and tool then res.tool = tool.id end
  local okB, brush = pcall(function() return app.brush end)
  if okB and brush then
    res.brush = { type = enum_name(BrushType, brush.type), size = brush.size, angle = brush.angle }
  end
  local sprites = {}
  for i, s in ipairs(app.sprites) do sprites[i] = MCP.sprite_summary(s) end
  res.sprites = json.array(sprites)
  if app.sprite then
    res.activeSprite = app.sprite.filename
    res.activeLayer = app.layer and MCP.layer_path(app.layer) or nil
    res.activeFrame = app.frame and app.frame.frameNumber or nil
    if app.isUIAvailable then
      local okR, range = pcall(function()
        local r = app.range
        local fr, ly = {}, {}
        for i, f in ipairs(r.frames) do fr[i] = f.frameNumber end
        for i, l in ipairs(r.layers) do ly[i] = MCP.layer_path(l) end
        return { type = enum_name(RangeType, r.type), frames = json.array(fr), layers = json.array(ly) }
      end)
      if okR then res.range = range end
      local okE, ed = pcall(function()
        local e = app.editor
        if not e then return nil end
        return { zoom = e.zoom, scroll = e.scroll and { x = e.scroll.x, y = e.scroll.y } or nil }
      end)
      if okE then res.editor = ed end
    end
  end
  return res
end)

handler("set_active", false, function(a)
  local spr = a.sprite ~= nil and MCP.sprite(a.sprite) or app.sprite
  if spr then
    MCP.activate(spr, a.layer ~= nil and MCP.layer(spr, a.layer) or nil,
                 a.frame ~= nil and MCP.frame(spr, a.frame) or nil)
  end
  if a.fgColor ~= nil then app.fgColor = MCP.color(a.fgColor) end
  if a.bgColor ~= nil then app.bgColor = MCP.color(a.bgColor) end
  if a.tool ~= nil then app.tool = a.tool end
  if a.brush ~= nil then app.brush = MCP.brush(a.brush, spr) end
  if a.zoom ~= nil and app.editor then app.editor.zoom = a.zoom end
  if a.range ~= nil and app.isUIAvailable then
    app.command.Timeline{ open = true }
    local r = app.range
    if a.range.frames then r.frames = a.range.frames end
    if a.range.layers then
      local ls = {}
      for i, ref in ipairs(a.range.layers) do ls[i] = MCP.layer(spr, ref) end
      r.layers = ls
    end
    if a.range.colors then r.colors = a.range.colors end
  end
  return MCP.handlers.app_state.fn({})
end)

----------------------------------------------------------------------
-- Handlers: sprites
----------------------------------------------------------------------

handler("list_sprites", false, function()
  local res = {}
  for i, s in ipairs(app.sprites) do res[i] = MCP.sprite_summary(s) end
  return json.array(res)
end)

handler("new_sprite", false, function(a)
  local mode = COLOR_MODES[(a.colorMode or "rgb"):lower()]
  if not mode then fail("colorMode must be rgb, gray or indexed") end
  local spr = Sprite(a.width or 32, a.height or 32, mode)
  if a.frames and a.frames > 1 then
    for i = 2, a.frames do spr:newEmptyFrame(i) end
  end
  if a.frameDurationMs then
    for _, f in ipairs(spr.frames) do f.duration = a.frameDurationMs / 1000 end
  end
  if a.palette then MCP.set_palette(spr, a.palette) end
  if a.background ~= nil then
    local layer = spr.layers[1]
    local cel = layer:cel(1)
    local img = cel.image:clone()
    img:clear(MCP.pixel(img, a.background))
    cel.image = img
    if a.backgroundLayer then app.command.BackgroundFromLayer() end
  end
  if a.layerName then spr.layers[1].name = a.layerName end
  local saved
  if a.file then
    spr:saveAs(a.file)
    saved = spr.filename
  elseif MCP.mode == "batch" then
    fail("In batch mode new_sprite needs 'file' (a path to save to), otherwise the sprite is lost when the process exits")
  end
  local info = MCP.sprite_info(spr)
  info.saved = saved
  return info
end)

handler("open_sprite", false, function(a)
  if type(a.file) ~= "string" then fail("'file' is required") end
  local spr
  if a.oneFrame then
    spr = Sprite{ fromFile = a.file, oneFrame = true }
  else
    spr = MCP.sprite(a.file)
  end
  return MCP.sprite_info(spr)
end)

handler("get_sprite_info", false, function(a)
  return MCP.sprite_info(MCP.sprite(a.sprite), { cels = a.includeCels })
end)

handler("save_sprite", false, function(a)
  local spr = MCP.sprite(a.sprite)
  local file = a.file or spr.filename
  if a.copy then
    if not a.file then fail("'file' is required when copy=true") end
    spr:saveCopyAs(file)
  else
    if not a.file and not spr.hasAssociatedFile then fail("Sprite has never been saved; pass 'file'") end
    spr:saveAs(file)
  end
  return { saved = file, files = MCP.written_files(file), sprite = MCP.sprite_summary(spr) }
end)

handler("close_sprite", false, function(a)
  local spr = MCP.sprite(a.sprite)
  if spr.isModified and not a.discardChanges and not a.save then
    fail("Sprite has unsaved changes; pass save=true or discardChanges=true")
  end
  local name = spr.filename
  if a.save then spr:saveAs(spr.filename) end
  MCP.ctx.touched[spr] = nil
  spr:close()
  return { closed = name }
end)

handler("set_sprite_properties", true, function(a)
  local spr = MCP.sprite(a.sprite)
  app.transaction("MCP sprite properties", function()
    if a.filename ~= nil then spr.filename = a.filename end
    if a.data ~= nil then spr.data = a.data end
    if a.color ~= nil then spr.color = MCP.color(a.color) end
    if a.transparentColor ~= nil then spr.transparentColor = a.transparentColor end
    if a.pixelRatio ~= nil then spr.pixelRatio = Size(a.pixelRatio.width, a.pixelRatio.height) end
    if a.gridBounds ~= nil then spr.gridBounds = rect_in(a.gridBounds) end
    if a.properties ~= nil then
      for k, v in pairs(a.properties) do spr.properties[k] = v end
    end
    if a.useLayerUuids ~= nil then spr.useLayerUuids = a.useLayerUuids end
    if a.colorSpace ~= nil then
      local cs = a.colorSpace == "srgb" and ColorSpace{ sRGB = true } or ColorSpace()
      if a.convertColorSpace then spr:convertColorSpace(cs) else spr:assignColorSpace(cs) end
    end
  end)
  return MCP.sprite_info(spr)
end)

handler("resize_sprite", true, function(a)
  local spr = MCP.sprite(a.sprite)
  local w, h = a.width, a.height
  if a.scale then w = math.floor(spr.width * a.scale + 0.5); h = math.floor(spr.height * a.scale + 0.5) end
  if w and not h then h = math.floor(spr.height * w / spr.width + 0.5) end
  if h and not w then w = math.floor(spr.width * h / spr.height + 0.5) end
  if not w then fail("Pass width/height or scale") end
  app.command.SpriteSize{ ui = false, width = w, height = h, method = a.method or "nearest", lockRatio = false }
  return MCP.sprite_summary(spr)
end)

handler("canvas_size", true, function(a)
  local spr = MCP.sprite(a.sprite)
  if a.width or a.height then
    local w, h = a.width or spr.width, a.height or spr.height
    local anchor = a.anchor or "center"
    local dx, dy = w - spr.width, h - spr.height
    local left, top
    if anchor:find("left") then left = 0 elseif anchor:find("right") then left = dx else left = dx // 2 end
    if anchor:find("top") then top = 0 elseif anchor:find("bottom") then top = dy else top = dy // 2 end
    app.command.CanvasSize{ ui = false, left = left, top = top, right = dx - left, bottom = dy - top,
                            trimOutside = a.trimOutside or false }
  else
    app.command.CanvasSize{ ui = false, left = a.left or 0, top = a.top or 0, right = a.right or 0,
                            bottom = a.bottom or 0, trimOutside = a.trimOutside or false }
  end
  return MCP.sprite_summary(spr)
end)

handler("crop_sprite", true, function(a)
  local spr = MCP.sprite(a.sprite)
  if a.mode == "auto" or a.mode == "trim" then
    app.command.AutocropSprite{ byGrid = a.byGrid or false }
  elseif a.mode == "selection" then
    if spr.selection.isEmpty then fail("No selection to crop to") end
    app.command.CropSprite()
  else
    local r = rect_in(a.rect, "rect")
    if not r then fail("Pass rect, or mode='auto'/'selection'") end
    spr:crop(r)
  end
  return MCP.sprite_summary(spr)
end)

handler("change_color_mode", true, function(a)
  local spr = MCP.sprite(a.sprite)
  local p = { ui = false, format = a.mode }
  if a.dithering then p.dithering = a.dithering end
  if a.ditheringMatrix then p["dithering-matrix"] = a.ditheringMatrix end
  if a.ditheringFactor then p["dithering-factor"] = a.ditheringFactor end
  if a.rgbmap then p.rgbmap = a.rgbmap end
  if a.toGray then p.toGray = a.toGray end
  if a.fitCriteria then p.fitCriteria = a.fitCriteria end
  app.command.ChangePixelFormat(p)
  return MCP.sprite_summary(spr)
end)

handler("flip_rotate", true, function(a)
  local spr = MCP.sprite(a.sprite)
  local layer = a.layer ~= nil and MCP.layer(spr, a.layer) or nil
  local frame = a.frame ~= nil and MCP.frame(spr, a.frame) or nil
  MCP.activate(spr, layer, frame)
  local target = a.target or "sprite"
  local angle = a.rotate == 270 and -90 or a.rotate
  local function run(cmdTarget)
    if a.flip then app.command.Flip{ target = cmdTarget, orientation = a.flip } end
    if angle then app.command.Rotate{ ui = false, target = cmdTarget, angle = tostring(angle) } end
  end
  if target == "sprite" then
    run("canvas")
  elseif target == "cel" then
    -- "mask" without a visible selection transforms the whole active cel.
    local saved = Selection()
    saved:add(spr.selection)
    spr.selection = Selection()
    local ok, err = pcall(run, "mask")
    if not saved.isEmpty then spr.selection = saved end
    if not ok then error(err, 0) end
  elseif target == "selection" then
    if spr.selection.isEmpty then fail("No selection") end
    run("mask")
    -- In the GUI the command starts an interactive transform; commit it.
    if app.isUIAvailable and app.command.Apply.enabled then app.command.Apply() end
  else
    fail("target must be sprite, cel or selection")
  end
  return MCP.sprite_summary(spr)
end)

----------------------------------------------------------------------
-- Handlers: layers
----------------------------------------------------------------------

local function apply_layer_props(spr, l, a)
  if a.name ~= nil then l.name = a.name end
  if a.visible ~= nil then l.isVisible = a.visible end
  if a.editable ~= nil then l.isEditable = a.editable end
  if a.opacity ~= nil and not l.isGroup then l.opacity = a.opacity end
  if a.blendMode ~= nil and not l.isGroup then l.blendMode = blend_mode(a.blendMode) end
  if a.continuous ~= nil and not l.isGroup then l.isContinuous = a.continuous end
  if a.collapsed ~= nil and l.isGroup then l.isCollapsed = a.collapsed end
  if a.color ~= nil then l.color = MCP.color(a.color) end
  if a.data ~= nil then l.data = a.data end
  if a.properties ~= nil then for k, v in pairs(a.properties) do l.properties[k] = v end end
  if a.parent ~= nil then
    if a.parent == "" or a.parent == json.null then l.parent = spr
    else
      local p = MCP.layer(spr, a.parent)
      if not p.isGroup then fail("Parent '%s' is not a group", a.parent) end
      l.parent = p
    end
  end
  if a.stackIndex ~= nil then l.stackIndex = a.stackIndex end
  if a.tileset ~= nil and l.isTilemap then l.tileset = MCP.tileset(spr, a.tileset) end
end

handler("add_layer", true, function(a)
  local spr = MCP.sprite(a.sprite)
  local kind = a.type or "image"
  local l
  app.transaction("MCP add layer", function()
    if kind == "group" then
      l = spr:newGroup()
    elseif kind == "tilemap" then
      MCP.activate(spr, nil, nil)
      local p = { ui = false, tilemap = true, name = a.name or "Tilemap" }
      if a.tileSize then
        p.gridBounds = Rectangle(0, 0, a.tileSize.width, a.tileSize.height)
      end
      app.command.NewLayer(p)
      l = app.layer
    elseif kind == "reference" then
      MCP.activate(spr, nil, nil)
      app.command.NewLayer{ ui = false, reference = true, name = a.name or "Reference" }
      l = app.layer
    elseif kind == "image" then
      l = spr:newLayer()
    else
      fail("type must be image, group, tilemap or reference")
    end
    apply_layer_props(spr, l, a)
    if a.below ~= nil or a.above ~= nil then
      local ref = MCP.layer(spr, a.below or a.above)
      if l.parent ~= ref.parent then l.parent = ref.parent end
      local idx = ref.stackIndex
      if a.above ~= nil then idx = idx + 1 end
      l.stackIndex = idx
    end
  end)
  if a.below == nil and a.above == nil and a.parent == nil and a.stackIndex == nil and l.parent == spr then
    if l.stackIndex ~= #spr.layers then l.stackIndex = #spr.layers end
  end
  if a.image ~= nil then
    if l.isGroup or l.isTilemap then fail("'image' only applies to image and reference layers") end
    local src = MCP.image_from_spec(a.image)
    local frame = MCP.frame(spr, a.frame or 1)
    local pos = Point(a.x or 0, a.y or 0)
    if l.isReference then
      -- Reference layers keep the image's own colors.
      spr:newCel(l, frame, src, pos)
    else
      MCP.place_image(spr, l, frame, src, pos, { mode = "replace" })
    end
  end
  app.layer = l
  return MCP.layer_info(l)
end)

handler("update_layer", true, function(a)
  local spr = MCP.sprite(a.sprite)
  local l = MCP.layer(spr, a.layer)
  app.transaction("MCP update layer", function() apply_layer_props(spr, l, a) end)
  return MCP.layer_info(l)
end)

handler("delete_layer", true, function(a)
  local spr = MCP.sprite(a.sprite)
  local l = MCP.layer(spr, a.layer)
  local name = MCP.layer_path(l)
  spr:deleteLayer(l)
  return { deleted = name, layers = #walk_layers(spr, {}) }
end)

handler("duplicate_layer", true, function(a)
  local spr = MCP.sprite(a.sprite)
  local l = MCP.layer(spr, a.layer)
  MCP.activate(spr, l, nil)
  app.command.DuplicateLayer()
  local dup = app.layer
  if a.name then dup.name = a.name end
  return MCP.layer_info(dup)
end)

handler("merge_layers", true, function(a)
  local spr = MCP.sprite(a.sprite)
  local mode = a.mode or "down"
  if mode == "down" then
    local l = MCP.layer(spr, a.layer)
    MCP.activate(spr, l, nil)
    app.command.MergeDownLayer()
  elseif mode == "flatten" then
    app.command.FlattenLayers{ visibleOnly = false }
  elseif mode == "visible" then
    app.command.FlattenLayers{ visibleOnly = true }
  else
    fail("mode must be down, flatten or visible")
  end
  local layers = {}
  for i, e in ipairs(walk_layers(spr, {})) do layers[i] = e.path end
  return { layers = json.array(layers) }
end)

handler("convert_layer", true, function(a)
  local spr = MCP.sprite(a.sprite)
  local l = MCP.layer(spr, a.layer)
  MCP.activate(spr, l, nil)
  if a.to == "background" then app.command.BackgroundFromLayer()
  elseif a.to == "layer" then app.command.LayerFromBackground()
  elseif a.to == "tilemap" or a.to == "image" then app.command.ConvertLayer{ ui = false, to = a.to == "image" and "layer" or "tilemap" }
  else fail("to must be background, layer, image or tilemap") end
  return MCP.layer_info(app.layer)
end)

----------------------------------------------------------------------
-- Handlers: frames
----------------------------------------------------------------------

handler("add_frames", true, function(a)
  local spr = MCP.sprite(a.sprite)
  local count = a.count or 1
  local at = a.at or (#spr.frames + 1)
  local created = {}
  app.transaction("MCP add frames", function()
    for i = 1, count do
      local f
      if a.empty then
        f = spr:newEmptyFrame(at + i - 1)
      else
        local src = a.copyFrom or (at + i - 2)
        if src < 1 then src = 1 end
        f = spr:newFrame(src)
        if f.frameNumber ~= at + i - 1 and at + i - 1 <= #spr.frames then
          -- newFrame inserts after src; nothing else to do when at == src + 1
        end
      end
      if a.durationMs then f.duration = a.durationMs / 1000 end
      created[#created + 1] = f.frameNumber
    end
  end)
  return { created = json.array(created), frames = #spr.frames }
end)

handler("delete_frames", true, function(a)
  local spr = MCP.sprite(a.sprite)
  local list = MCP.frame_list(spr, a)
  if #list >= #spr.frames then fail("Cannot delete every frame") end
  table.sort(list, function(x, y) return x > y end)
  app.transaction("MCP delete frames", function()
    for _, n in ipairs(list) do spr:deleteFrame(spr.frames[n]) end
  end)
  return { deleted = json.array(list), frames = #spr.frames }
end)

handler("set_frame_duration", true, function(a)
  local spr = MCP.sprite(a.sprite)
  if a.durationMs == nil then fail("durationMs is required") end
  local list = MCP.frame_list(spr, a)
  app.transaction("MCP frame duration", function()
    for _, n in ipairs(list) do spr.frames[n].duration = a.durationMs / 1000 end
  end)
  local fr = {}
  for i, f in ipairs(spr.frames) do fr[i] = math.floor(f.duration * 1000 + 0.5) end
  return { frameDurationsMs = json.array(fr) }
end)

handler("move_frame", true, function(a)
  local spr = MCP.sprite(a.sprite)
  local from = MCP.frame(spr, a.from).frameNumber
  local to = a.to
  if to < 1 or to > #spr.frames then fail("'to' out of range") end
  if from == to then return { frames = #spr.frames } end
  -- Copy the source frame to its new spot, then delete the original.
  app.transaction("MCP move frame", function()
    local dur = spr.frames[from].duration
    local insertAt = to > from and to + 1 or to
    spr:newEmptyFrame(insertAt)
    local src = from >= insertAt and from + 1 or from
    for _, e in ipairs(walk_layers(spr, {})) do
      local l = e.layer
      if l.isImage then
        local c = l:cel(src)
        if c then spr:newCel(l, insertAt, c.image:clone(), c.position).opacity = c.opacity end
      end
    end
    spr.frames[insertAt].duration = dur
    spr:deleteFrame(spr.frames[src])
  end)
  return { frames = #spr.frames }
end)

----------------------------------------------------------------------
-- Handlers: cels
----------------------------------------------------------------------

handler("get_cels", false, function(a)
  local spr = MCP.sprite(a.sprite)
  local res = {}
  local layer = a.layer ~= nil and MCP.layer(spr, a.layer) or nil
  local frames
  if a.frame ~= nil or a.frames ~= nil or a.from ~= nil or a.tag ~= nil then frames = {}
    for _, n in ipairs(MCP.frame_list(spr, a)) do frames[n] = true end
  end
  for _, c in ipairs(spr.cels) do
    if (layer == nil or c.layer == layer) and (frames == nil or frames[c.frameNumber]) then
      res[#res + 1] = MCP.cel_info(c)
    end
  end
  return json.array(res)
end)

handler("update_cel", true, function(a)
  local spr = MCP.sprite(a.sprite)
  local l = MCP.layer(spr, a.layer)
  local f = MCP.frame(spr, a.frame)
  local c = l:cel(f)
  if not c then fail("No cel at layer '%s' frame %d", l.name, f.frameNumber) end
  app.transaction("MCP update cel", function()
    if a.x ~= nil or a.y ~= nil then c.position = Point(a.x or c.position.x, a.y or c.position.y) end
    if a.dx ~= nil or a.dy ~= nil then c.position = Point(c.position.x + (a.dx or 0), c.position.y + (a.dy or 0)) end
    if a.opacity ~= nil then c.opacity = a.opacity end
    if a.zIndex ~= nil then c.zIndex = a.zIndex end
    if a.color ~= nil then c.color = MCP.color(a.color) end
    if a.data ~= nil then c.data = a.data end
    if a.properties ~= nil then for k, v in pairs(a.properties) do c.properties[k] = v end end
    if a.toFrame ~= nil then c.frame = MCP.frame(spr, a.toFrame) end
  end)
  return MCP.cel_info(c)
end)

handler("delete_cel", true, function(a)
  local spr = MCP.sprite(a.sprite)
  local l = MCP.layer(spr, a.layer)
  local list = MCP.frame_list(spr, a)
  local deleted = {}
  app.transaction("MCP delete cels", function()
    for _, n in ipairs(list) do
      local c = l:cel(n)
      if c then spr:deleteCel(c); deleted[#deleted + 1] = n end
    end
  end)
  return { layer = MCP.layer_path(l), deletedFrames = json.array(deleted) }
end)

handler("copy_cel", true, function(a)
  local spr = MCP.sprite(a.sprite)
  local srcSpr = a.fromSprite ~= nil and MCP.sprite(a.fromSprite) or spr
  if srcSpr ~= spr then app.sprite = spr end
  local sl = MCP.layer(srcSpr, a.fromLayer)
  local sf = MCP.frame(srcSpr, a.fromFrame)
  local c = sl:cel(sf)
  if not c then fail("No source cel") end
  local dl = a.toLayer ~= nil and MCP.layer(spr, a.toLayer) or sl
  local df = a.toFrame ~= nil and MCP.frame(spr, a.toFrame) or sf
  local img = c.image:clone()
  local pos = c.position
  if a.x ~= nil or a.y ~= nil then pos = Point(a.x or pos.x, a.y or pos.y) end
  local nc = spr:newCel(dl, df, img, pos)
  nc.opacity = c.opacity
  return MCP.cel_info(nc)
end)

----------------------------------------------------------------------
-- Handlers: pixels
----------------------------------------------------------------------

-- Collects pixel writes from `pixels`, `rows`+`legend`, returning {x, y, value-spec}.
local function collect_pixels(a)
  local list = {}
  if a.pixels then
    for _, p in ipairs(a.pixels) do
      local x, y, c = p.x or p[1], p.y or p[2], p.color or p.c or p[3]
      list[#list + 1] = { x, y, c }
    end
  end
  if a.rows then
    local legend = a.legend or {}
    local ox, oy = a.x or 0, a.y or 0
    for ry, row in ipairs(a.rows) do
      local cx = 0
      for ch in row:gmatch(utf8.charpattern) do
        local spec = legend[ch]
        if spec == nil and ch ~= " " and ch ~= "." then
          fail("Character '%s' in rows has no entry in legend", ch)
        end
        if spec ~= nil and spec ~= json.null then
          list[#list + 1] = { ox + cx, oy + ry - 1, spec }
        elseif ch == "." and legend["."] == nil and a.dotIsTransparent ~= false then
          -- "." without a legend entry is left untouched
        end
        cx = cx + 1
      end
    end
  end
  return list
end

handler("draw_pixels", true, function(a)
  local spr = MCP.sprite(a.sprite)
  local layer = MCP.layer(spr, a.layer)
  local frame = MCP.frame(spr, a.frame)
  local list = collect_pixels(a)
  if #list == 0 then fail("Nothing to draw: pass 'pixels' or 'rows'+'legend'") end
  local cel = MCP.editable_cel(spr, layer, frame)
  local minx, miny, maxx, maxy = math.huge, math.huge, -math.huge, -math.huge
  local canvas = spr.bounds
  local kept = {}
  for _, p in ipairs(list) do
    if a.clip == false or canvas:contains(Point(p[1], p[2])) then
      kept[#kept + 1] = p
      if p[1] < minx then minx = p[1] end
      if p[2] < miny then miny = p[2] end
      if p[1] > maxx then maxx = p[1] end
      if p[2] > maxy then maxy = p[2] end
    end
  end
  if #kept == 0 then return { drawn = 0, note = "All pixels fell outside the canvas" } end
  local img, origin = MCP.grow_image(spr, cel, Rectangle(minx, miny, maxx - minx + 1, maxy - miny + 1))
  local cache = {}
  local blend = a.blend == true
  for _, p in ipairs(kept) do
    local key = type(p[3]) == "table" and json.encode(p[3]) or p[3]
    local px = cache[key]
    if px == nil then px = MCP.pixel(img, p[3]); cache[key] = px end
    local x, y = p[1] - origin.x, p[2] - origin.y
    if blend and img.colorMode == ColorMode.RGB then
      local one = Image(1, 1, ColorMode.RGB)
      one:drawPixel(0, 0, px)
      img:drawImage(one, Point(x, y), 255, BlendMode.NORMAL)
    else
      img:drawPixel(x, y, px)
    end
  end
  MCP.commit_cel(cel, img, origin)
  return { drawn = #kept, cel = MCP.cel_info(cel) }
end)

handler("get_pixels", false, function(a)
  local spr = MCP.sprite(a.sprite)
  local frame = MCP.frame(spr, a.frame)
  local r = a.rect and rect_in(a.rect) or Rectangle(0, 0, spr.width, spr.height)
  local maxArea = a.maxPixels or 16384
  if r.width * r.height > maxArea then
    fail("Region %dx%d exceeds maxPixels=%d; pass a smaller rect or raise maxPixels", r.width, r.height, maxArea)
  end
  local src, ox, oy
  if a.layer ~= nil then
    local l = MCP.layer(spr, a.layer)
    local c = l:cel(frame)
    if c and l.isTilemap then
      fail("Layer is a tilemap; use the tilemap tool to read tile indices")
    end
    if c then src, ox, oy = c.image, c.position.x, c.position.y
    else src, ox, oy = new_image(spr, 1, 1), 0, 0; src:clear() end
  else
    src, ox, oy = MCP.render(spr, frame.frameNumber), 0, 0
  end
  local format = a.format or "legend"
  local transparent = src.colorMode == ColorMode.INDEXED and src.spec.transparentColor or nil
  local function read(x, y)
    local ix, iy = x - ox, y - oy
    if ix < 0 or iy < 0 or ix >= src.width or iy >= src.height then return nil end
    local px = src:getPixel(ix, iy)
    if src.colorMode == ColorMode.INDEXED then
      if px == transparent then return nil end
      return px
    end
    local v = MCP.pixel_out(src, px)
    if v:sub(-2) == "00" then return nil end
    return v
  end
  local res = { rect = rect_out(r), colorMode = color_mode_name(src.colorMode) }
  if format == "hex" then
    local rows = {}
    for y = r.y, r.y + r.height - 1 do
      local row = {}
      for x = r.x, r.x + r.width - 1 do row[#row + 1] = read(x, y) or json.null end
      rows[#rows + 1] = json.array(row)
    end
    res.rows = json.array(rows)
  else
    local symbols = ".abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789#$%&*+-=?@^~!<>/|"
    local legend, lookup, nextSym = { ["."] = "transparent" }, {}, 2
    local rows = {}
    for y = r.y, r.y + r.height - 1 do
      local row = {}
      for x = r.x, r.x + r.width - 1 do
        local v = read(x, y)
        if v == nil then row[#row + 1] = "."
        else
          local sym = lookup[v]
          if not sym then
            if nextSym > #symbols then fail("More than %d distinct colors; use format='hex'", #symbols - 1) end
            sym = symbols:sub(nextSym, nextSym)
            nextSym = nextSym + 1
            lookup[v] = sym
            legend[sym] = v
          end
          row[#row + 1] = sym
        end
      end
      rows[#rows + 1] = table.concat(row)
    end
    res.rows = json.array(rows)
    res.legend = legend
  end
  return res
end)

local TOOL_INKS = { simple = Ink.SIMPLE, alpha_compositing = Ink.ALPHA_COMPOSITING,
                    copy_color = Ink.COPY_COLOR, lock_alpha = Ink.LOCK_ALPHA, shading = Ink.SHADING }

handler("use_tool", true, function(a)
  local spr = MCP.sprite(a.sprite)
  local layer = MCP.layer(spr, a.layer)
  local frame = MCP.frame(spr, a.frame)
  if not a.tool then fail("'tool' is required") end
  local pts = {}
  for i, p in ipairs(a.points or {}) do pts[i] = point_in(p) end
  if #pts == 0 then fail("'points' is required") end
  MCP.activate(spr, layer, frame)
  local opts = { tool = a.tool, points = pts, layer = layer, frame = frame }
  if a.color ~= nil then opts.color = MCP.color(a.color) end
  if a.bgColor ~= nil then opts.bgColor = MCP.color(a.bgColor) end
  if a.brush ~= nil then
    opts.brush = MCP.brush(a.brush, spr)
  elseif a.brushSize ~= nil then
    opts.brush = Brush{ type = BrushType.CIRCLE, size = a.brushSize }
  end
  if a.ink ~= nil then
    local ink = TOOL_INKS[a.ink:lower():gsub("[%s%-]", "_")]
    if ink == nil then fail("Unknown ink '%s'", a.ink) end
    opts.ink = ink
  end
  if a.opacity ~= nil then opts.opacity = a.opacity end
  if a.tolerance ~= nil then opts.tolerance = a.tolerance end
  if a.contiguous ~= nil then opts.contiguous = a.contiguous end
  if a.pixelPerfect ~= nil then opts.freehandAlgorithm = a.pixelPerfect and 1 or 0 end
  if a.button == "right" then opts.button = MouseButton.RIGHT end
  if a.selectionMode ~= nil then opts.selection = SelectionMode[a.selectionMode:upper()] end
  if a.tilemapMode ~= nil then opts.tilemapMode = TilemapMode[a.tilemapMode:upper()] end
  if a.tilesetMode ~= nil then opts.tilesetMode = TilesetMode[a.tilesetMode:upper()] end
  if a.tool == "gradient" and not app.isUIAvailable then
    -- Aseprite's gradient tool reads dithering options from the context bar,
    -- which does not exist in batch mode (it crashes), so draw it here.
    MCP.linear_gradient(spr, layer, frame, pts[1], pts[#pts], opts.color or app.fgColor,
                        opts.bgColor or app.bgColor, a.opacity or 255)
  else
    app.useTool(opts)
  end
  local res = { tool = a.tool, points = #pts }
  local c = layer.isImage and layer:cel(frame) or nil
  if c then res.cel = MCP.cel_info(c) end
  if not spr.selection.isEmpty then res.selection = rect_out(spr.selection.bounds) end
  return res
end)

handler("draw_image", true, function(a)
  local spr = MCP.sprite(a.sprite)
  local layer = MCP.layer(spr, a.layer)
  local frame = MCP.frame(spr, a.frame)
  if type(a.file) ~= "string" then fail("'file' (an image path) is required") end
  local src = Image{ fromFile = a.file }
  if not src then fail("Could not load image '%s'", a.file) end
  if a.sourceRect then
    src = Image(src, rect_in(a.sourceRect))
  end
  if a.scale and a.scale ~= 1 then
    src:resize{ width = math.max(1, math.floor(src.width * a.scale + 0.5)),
                height = math.max(1, math.floor(src.height * a.scale + 0.5)) }
  end
  if a.width or a.height then
    src:resize{ width = a.width or src.width, height = a.height or src.height }
  end
  local cel = MCP.place_image(spr, layer, frame, src, Point(a.x or 0, a.y or 0),
                              { mode = a.mode, opacity = a.opacity, blendMode = a.blendMode })
  return MCP.cel_info(cel)
end)

handler("clear", true, function(a)
  local spr = MCP.sprite(a.sprite)
  local layer = MCP.layer(spr, a.layer)
  local list = MCP.frame_list(spr, a)
  local r = a.rect and rect_in(a.rect) or nil
  local n = 0
  app.transaction("MCP clear", function()
    for _, fn in ipairs(list) do
      local cel = layer:cel(fn)
      if cel then
        local img = cel.image:clone()
        local pos = cel.position
        local fillPx = a.color ~= nil and MCP.pixel(img, a.color) or nil
        if r then
          local local_r = Rectangle(r.x - pos.x, r.y - pos.y, r.width, r.height)
          if fillPx then img:clear(local_r, fillPx) else img:clear(local_r) end
        elseif a.useSelection and not spr.selection.isEmpty then
          for it in img:pixels() do
            if spr.selection:contains(it.x + pos.x, it.y + pos.y) then
              it(fillPx or img.spec.transparentColor)
            end
          end
        else
          if fillPx then
            -- Fill the whole canvas area, not just the current cel bounds.
            img, pos = MCP.grow_image(spr, cel, spr.bounds)
            img:clear(fillPx)
            cel.position = pos
          else
            img:clear()
          end
        end
        cel.image = img
        n = n + 1
      end
    end
  end)
  return { clearedCels = n }
end)

handler("replace_color", true, function(a)
  local spr = MCP.sprite(a.sprite)
  local list = MCP.frame_list(spr, a)
  local layers = {}
  if a.layer ~= nil then layers[1] = MCP.layer(spr, a.layer)
  else for _, e in ipairs(walk_layers(spr, {})) do if e.layer.isImage and not e.layer.isTilemap then layers[#layers + 1] = e.layer end end end
  local tol = a.tolerance or 0
  local changed = 0
  app.transaction("MCP replace color", function()
    for _, l in ipairs(layers) do
      for _, fn in ipairs(list) do
        local cel = l:cel(fn)
        if cel and l.isEditable then
          local img = cel.image:clone()
          local from = MCP.pixel(img, a.from)
          local to = MCP.pixel(img, a.to)
          local n = 0
          for it in img:pixels() do
            local px = it()
            local match = px == from
            if not match and tol > 0 and img.colorMode == ColorMode.RGB then
              match = math.abs(pc.rgbaR(px) - pc.rgbaR(from)) <= tol and math.abs(pc.rgbaG(px) - pc.rgbaG(from)) <= tol
                and math.abs(pc.rgbaB(px) - pc.rgbaB(from)) <= tol and math.abs(pc.rgbaA(px) - pc.rgbaA(from)) <= tol
            end
            if match then it(to); n = n + 1 end
          end
          if n > 0 then cel.image = img; changed = changed + n end
        end
      end
    end
  end)
  return { changedPixels = changed }
end)

handler("apply_filter", true, function(a)
  local spr = MCP.sprite(a.sprite)
  local layer = a.layer ~= nil and MCP.layer(spr, a.layer) or nil
  local frame = a.frame ~= nil and MCP.frame(spr, a.frame) or nil
  MCP.activate(spr, layer, frame)
  local cmd = app.command[a.filter]
  if not cmd then fail("Unknown filter command '%s'", tostring(a.filter)) end
  local params = { ui = false }
  for k, v in pairs(a.params or {}) do params[k] = convert_command_value(v) end
  if a.channels then params.channels = a.channels end
  local ok = cmd(params)
  return { filter = a.filter, result = ok }
end)

----------------------------------------------------------------------
-- Handlers: selection
----------------------------------------------------------------------

handler("select", true, function(a)
  local spr = MCP.sprite(a.sprite)
  local sel = spr.selection
  local mode = a.mode or "replace"
  local action = a.action or "rect"
  local layer = a.layer ~= nil and MCP.layer(spr, a.layer) or nil
  local frame = a.frame ~= nil and MCP.frame(spr, a.frame) or nil
  MCP.activate(spr, layer, frame)
  if action == "rect" then
    local r = rect_in(a.rect, "rect")
    if not r then fail("rect is required") end
    local s = Selection()
    s:select(r)
    if mode == "replace" then spr.selection = s
    else
      local cur = Selection()
      cur:add(sel)
      if mode == "add" then cur:add(s) elseif mode == "subtract" then cur:subtract(s)
      elseif mode == "intersect" then cur:intersect(s) else fail("bad mode") end
      spr.selection = cur
    end
  elseif action == "ellipse" then
    local r = rect_in(a.rect, "rect")
    app.useTool{ tool = "elliptical_marquee", points = { Point(r.x, r.y), Point(r.x + r.width - 1, r.y + r.height - 1) },
                 selection = SelectionMode[mode:upper()] }
  elseif action == "polygon" then
    local pts = {}
    for i, p in ipairs(a.points or {}) do pts[i] = point_in(p) end
    app.useTool{ tool = "polygonal_lasso", points = pts, selection = SelectionMode[mode:upper()] }
  elseif action == "magic_wand" then
    app.useTool{ tool = "magic_wand", points = { point_in(a.point) }, selection = SelectionMode[mode:upper()],
                 tolerance = a.tolerance or 0, contiguous = a.contiguous ~= false }
  elseif action == "by_color" then
    app.command.MaskByColor{ ui = false, color = MCP.color(a.color), tolerance = a.tolerance or 0,
                             mode = mode }
  elseif action == "all" then app.command.MaskAll()
  elseif action == "none" then
    if not sel.isEmpty then
      local keep = Selection()
      keep:add(sel)
      MCP.last_selection[spr.id] = keep
    end
    app.command.DeselectMask()
  elseif action == "invert" then app.command.InvertMask()
  elseif action == "reselect" then
    app.command.ReselectMask()
    -- ReselectMask refuses to run from scripts in some states; fall back to
    -- the selection this runtime saw before its last deselect.
    if spr.selection.isEmpty and MCP.last_selection[spr.id] then
      spr.selection = MCP.last_selection[spr.id]
    end
  elseif action == "content" then app.command.MaskContent()
  elseif action == "modify" then
    app.command.ModifySelection{ ui = false, modifier = a.modifier or "expand", quantity = a.quantity or 1,
                                 brush = a.brush or "circle" }
  elseif action == "move" then
    local s = Selection()
    s:add(sel)
    s.origin = Point(sel.origin.x + (a.dx or 0), sel.origin.y + (a.dy or 0))
    spr.selection = s
  elseif action == "get" then
    -- read only
  elseif action == "save" then
    if type(a.file) ~= "string" then fail("'file' is required") end
    if a.file:lower():match("%.msk$") then
      app.command.SaveMask{ ui = false, filename = a.file }
    else
      -- Any image format: selected pixels are opaque white, the rest transparent.
      local img = Image(spr.width, spr.height, ColorMode.RGB)
      img:clear()
      local white = pc.rgba(255, 255, 255, 255)
      local b = sel.bounds
      for y = math.max(0, b.y), math.min(spr.height, b.y + b.height) - 1 do
        for x = math.max(0, b.x), math.min(spr.width, b.x + b.width) - 1 do
          if sel:contains(x, y) then img:drawPixel(x, y, white) end
        end
      end
      img:saveAs(a.file)
    end
  elseif action == "load" then
    if type(a.file) ~= "string" then fail("'file' is required") end
    local loaded
    if a.file:lower():match("%.msk$") then
      app.command.LoadMask{ ui = false, filename = a.file }
    else
      local img = Image{ fromFile = a.file }
      if not img then fail("Could not load '%s'", a.file) end
      loaded = Selection()
      for y = 0, img.height - 1 do
        local runStart
        for x = 0, img.width do
          local on = false
          if x < img.width then
            local px = img:getPixel(x, y)
            if img.colorMode == ColorMode.RGB then on = pc.rgbaA(px) > 0
            elseif img.colorMode == ColorMode.GRAY then on = pc.grayaA(px) > 0 and pc.grayaV(px) > 0
            else on = px ~= img.spec.transparentColor end
          end
          if on and not runStart then runStart = x
          elseif not on and runStart then
            loaded:add(Rectangle(runStart, y, x - runStart, 1))
            runStart = nil
          end
        end
      end
      if mode == "replace" then spr.selection = loaded
      else
        local cur = Selection()
        cur:add(sel)
        if mode == "add" then cur:add(loaded) elseif mode == "subtract" then cur:subtract(loaded)
        else cur:intersect(loaded) end
        spr.selection = cur
      end
    end
  else
    fail("Unknown select action '%s'", action)
  end
  local res = { empty = spr.selection.isEmpty }
  if not spr.selection.isEmpty then res.bounds = rect_out(spr.selection.bounds) end
  return res
end)

handler("selection_edit", true, function(a)
  local spr = MCP.sprite(a.sprite)
  local layer = a.layer ~= nil and MCP.layer(spr, a.layer) or nil
  local frame = a.frame ~= nil and MCP.frame(spr, a.frame) or nil
  MCP.activate(spr, layer, frame)
  local act = a.action
  local C = app.command
  if act == "copy" then C.Copy()
  elseif act == "copy_merged" then C.CopyMerged()
  elseif act == "cut" then C.Cut()
  elseif act == "paste" then
    if a.x ~= nil then C.Paste{ x = a.x, y = a.y or 0 } else C.Paste() end
  elseif act == "delete" then C.Clear()
  elseif act == "fill" then
    if a.color then app.fgColor = MCP.color(a.color) end
    C.Fill()
  elseif act == "stroke" then
    if a.color then app.fgColor = MCP.color(a.color) end
    C.Stroke()
  elseif act == "move_content" or act == "move_bounds" then
    local dx, dy = a.dx or 0, a.dy or 0
    local target = act == "move_content" and "content" or "boundaries"
    if dx ~= 0 then C.MoveMask{ target = target, direction = dx > 0 and "right" or "left", units = "pixel", quantity = math.abs(dx), wrap = a.wrap or false } end
    if dy ~= 0 then C.MoveMask{ target = target, direction = dy > 0 and "down" or "up", units = "pixel", quantity = math.abs(dy), wrap = a.wrap or false } end
  elseif act == "new_sprite" then C.NewSpriteFromSelection()
  elseif act == "new_layer_via_copy" then C.NewLayer{ viaCopy = true }
  elseif act == "new_layer_via_cut" then C.NewLayer{ viaCut = true }
  elseif act == "crop" then C.CropSprite()
  else fail("Unknown selection_edit action '%s'", tostring(act)) end
  local res = { action = act, sprite = app.sprite and MCP.sprite_summary(app.sprite) or nil }
  if app.sprite and not app.sprite.selection.isEmpty then res.selection = rect_out(app.sprite.selection.bounds) end
  return res
end)

----------------------------------------------------------------------
-- Handlers: palette
----------------------------------------------------------------------

function MCP.set_palette(spr, a)
  if type(a) ~= "table" or a[1] ~= nil then a = { colors = a, replace = true } end
  local pal
  if a.file then pal = Palette{ fromFile = a.file }
  elseif a.preset then pal = Palette{ fromResource = a.preset }
  else pal = Palette(spr.palettes[1]) end
  if not pal then fail("Could not load palette") end
  if a.colors then
    local start = a.start or 0
    local needed = start + #a.colors
    if a.replace then pal:resize(needed)
    elseif needed > #pal then pal:resize(needed) end
    for i, c in ipairs(a.colors) do pal:setColor(start + i - 1, MCP.color(c)) end
  end
  if a.size then pal:resize(a.size) end
  spr:setPalette(pal)
  return pal
end

handler("get_palette", false, function(a)
  local spr = MCP.sprite(a.sprite)
  local pal = spr.palettes[a.index or 1]
  local colors = {}
  for i = 0, #pal - 1 do colors[i + 1] = MCP.color_out(pal:getColor(i)) end
  return { size = #pal, colors = json.array(colors), transparentIndex = spr.colorMode == ColorMode.INDEXED and spr.transparentColor or nil }
end)

handler("set_palette", true, function(a)
  local spr = MCP.sprite(a.sprite)
  if a.fromSprite then
    app.command.ColorQuantization{ ui = false, withAlpha = a.withAlpha ~= false, maxColors = a.maxColors or 256,
                                   useRange = false, algorithm = a.algorithm }
  else
    MCP.set_palette(spr, a)
  end
  return MCP.handlers.get_palette.fn({ sprite = spr.id })
end)

handler("save_palette", false, function(a)
  local spr = MCP.sprite(a.sprite)
  if type(a.file) ~= "string" then fail("'file' is required") end
  spr.palettes[1]:saveAs(a.file)
  return { saved = a.file }
end)

----------------------------------------------------------------------
-- Handlers: tags and slices
----------------------------------------------------------------------

local function apply_tag(spr, t, a)
  if a.name ~= nil then t.name = a.name end
  if a.from ~= nil or a.to ~= nil then
    local from, to = a.from or t.fromFrame.frameNumber, a.to or t.toFrame.frameNumber
    t.fromFrame = MCP.frame(spr, from)
    t.toFrame = MCP.frame(spr, to)
  end
  if a.aniDir ~= nil then t.aniDir = ani_dir(a.aniDir) end
  if a.repeats ~= nil then t.repeats = a.repeats end
  if a.color ~= nil then t.color = MCP.color(a.color) end
  if a.data ~= nil then t.data = a.data end
  if a.properties ~= nil then for k, v in pairs(a.properties) do t.properties[k] = v end end
end

handler("add_tag", true, function(a)
  local spr = MCP.sprite(a.sprite)
  local from, to = a.from or 1, a.to or (a.from or #spr.frames)
  MCP.frame(spr, from); MCP.frame(spr, to)
  local t
  app.transaction("MCP add tag", function()
    t = spr:newTag(from, to)
    apply_tag(spr, t, a)
  end)
  return MCP.tag_info(t)
end)

handler("update_tag", true, function(a)
  local spr = MCP.sprite(a.sprite)
  local t = MCP.tag(spr, a.tag)
  app.transaction("MCP update tag", function() apply_tag(spr, t, a) end)
  return MCP.tag_info(t)
end)

handler("delete_tag", true, function(a)
  local spr = MCP.sprite(a.sprite)
  local t = MCP.tag(spr, a.tag)
  spr:deleteTag(t)
  return { deleted = a.tag }
end)

local function apply_slice(s, a)
  if a.name ~= nil then s.name = a.name end
  if a.bounds ~= nil then s.bounds = rect_in(a.bounds) end
  if a.center == false then s.center = nil
  elseif a.center ~= nil then s.center = rect_in(a.center) end
  if a.pivot == false then s.pivot = nil
  elseif a.pivot ~= nil then s.pivot = point_in(a.pivot) end
  if a.color ~= nil then s.color = MCP.color(a.color) end
  if a.data ~= nil then s.data = a.data end
  if a.properties ~= nil then for k, v in pairs(a.properties) do s.properties[k] = v end end
end

handler("add_slice", true, function(a)
  local spr = MCP.sprite(a.sprite)
  local src = a.copyFrom ~= nil and MCP.slice(spr, a.copyFrom) or nil
  local r = rect_in(a.bounds, "bounds") or (src and src.bounds)
  if not r then fail("bounds is required (or copyFrom)") end
  local s
  app.transaction("MCP add slice", function()
    s = spr:newSlice(r)
    if src then
      s.name = src.name .. " copy"
      if src.center then s.center = src.center end
      if src.pivot then s.pivot = src.pivot end
      if src.color then s.color = src.color end
      s.data = src.data
      local okP, props = pcall(function()
        local t = {}
        for k, v in pairs(src.properties) do t[k] = v end
        return t
      end)
      if okP then for k, v in pairs(props) do s.properties[k] = v end end
    end
    apply_slice(s, a)
  end)
  return MCP.slice_info(s)
end)

handler("update_slice", true, function(a)
  local spr = MCP.sprite(a.sprite)
  local s = MCP.slice(spr, a.slice)
  app.transaction("MCP update slice", function() apply_slice(s, a) end)
  return MCP.slice_info(s)
end)

handler("delete_slice", true, function(a)
  local spr = MCP.sprite(a.sprite)
  spr:deleteSlice(MCP.slice(spr, a.slice))
  return { deleted = a.slice }
end)

----------------------------------------------------------------------
-- Handlers: tilesets and tilemaps
----------------------------------------------------------------------

handler("tileset", function(a) return a.action ~= "list" and a.action ~= "get_tile" end, function(a)
  local spr = MCP.sprite(a.sprite)
  local act = a.action or "list"
  if act == "list" then
    local res = {}
    for i, ts in ipairs(spr.tilesets) do res[i] = MCP.tileset_info(ts, i) end
    return json.array(res)
  elseif act == "add" then
    local size = a.tileSize or { width = 16, height = 16 }
    local ts = spr:newTileset(Rectangle(0, 0, size.width, size.height), a.count or 1)
    if a.name then ts.name = a.name end
    return MCP.tileset_info(ts, #spr.tilesets)
  end
  local ts = MCP.tileset(spr, a.tileset)
  if act == "update" then
    app.transaction("MCP tileset", function()
      if a.name ~= nil then ts.name = a.name end
      if a.baseIndex ~= nil then ts.baseIndex = a.baseIndex end
      if a.data ~= nil then ts.data = a.data end
      if a.properties ~= nil then for k, v in pairs(a.properties) do ts.properties[k] = v end end
    end)
    return MCP.tileset_info(ts)
  elseif act == "delete" then
    spr:deleteTileset(ts)
    return { deleted = true }
  elseif act == "add_tile" then
    local tile = spr:newTile(ts, a.index)
    return { index = tile.index, tiles = #ts }
  elseif act == "delete_tile" then
    spr:deleteTile(ts, a.index)
    return { tiles = #ts }
  elseif act == "get_tile" then
    local tile = ts:tile(a.index)
    if not tile then fail("No tile %s", tostring(a.index)) end
    local img = tile.image
    local symbols = ".abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    local legend, lookup, nextSym, rows = { ["."] = "transparent" }, {}, 2, {}
    for y = 0, img.height - 1 do
      local row = {}
      for x = 0, img.width - 1 do
        local px = img:getPixel(x, y)
        local v = MCP.pixel_out(img, px)
        if (type(v) == "string" and v:sub(-2) == "00") or (img.colorMode == ColorMode.INDEXED and px == img.spec.transparentColor) then
          row[#row + 1] = "."
        else
          local sym = lookup[v]
          if not sym then
            sym = symbols:sub(nextSym, nextSym); nextSym = nextSym + 1
            lookup[v] = sym; legend[sym] = v
          end
          row[#row + 1] = sym
        end
      end
      rows[#rows + 1] = table.concat(row)
    end
    return { index = a.index, rows = json.array(rows), legend = legend, data = nonempty(tile.data) }
  elseif act == "set_tile" then
    local tile = ts:tile(a.index)
    if not tile then fail("No tile %s", tostring(a.index)) end
    local img = tile.image:clone()
    if a.file then
      local src = Image{ fromFile = a.file }
      img:drawImage(src, Point(0, 0), 255, BlendMode.SRC)
    end
    for _, p in ipairs(collect_pixels(a)) do img:drawPixel(p[1], p[2], MCP.pixel(img, p[3])) end
    tile.image = img
    if a.data ~= nil then tile.data = a.data end
    return { index = a.index }
  end
  fail("Unknown tileset action '%s'", act)
end)

handler("tilemap", function(a) return a.action == "set" end, function(a)
  local spr = MCP.sprite(a.sprite)
  local layer = MCP.layer(spr, a.layer)
  if not layer.isTilemap then fail("Layer '%s' is not a tilemap", layer.name) end
  local frame = MCP.frame(spr, a.frame)
  local grid = layer.tileset.grid
  local tw, th = grid.tileSize.width, grid.tileSize.height
  if (a.action or "get") == "get" then
    local cel = layer:cel(frame)
    if not cel then return { empty = true, tileSize = size_out(grid.tileSize) } end
    local img = cel.image
    local rows = {}
    for y = 0, img.height - 1 do
      local row = {}
      for x = 0, img.width - 1 do row[#row + 1] = pc.tileI(img:getPixel(x, y)) end
      rows[#rows + 1] = json.array(row)
    end
    return { origin = point_out(cel.position), tileSize = size_out(grid.tileSize),
             columns = img.width, rows = json.array(rows) }
  end
  local cel = layer:cel(frame)
  if not cel then
    local cols, rws = math.ceil(spr.width / tw), math.ceil(spr.height / th)
    local img = Image(cols, rws, ColorMode.TILEMAP)
    img:clear(0)
    cel = spr:newCel(layer, frame, img, Point(grid.origin.x, grid.origin.y))
  end
  local img = cel.image:clone()
  local origin = cel.position
  local function put(col, row, tile)
    if col < 0 or row < 0 or col >= img.width or row >= img.height then
      fail("Tile cell (%d,%d) is outside the tilemap (%dx%d)", col, row, img.width, img.height)
    end
    img:drawPixel(col, row, pc.tile(tile, 0))
  end
  for _, c in ipairs(a.cells or {}) do put(c.col or c[1], c.row or c[2], c.tile or c[3]) end
  if a.rows then
    for ry, row in ipairs(a.rows) do
      for rx, tile in ipairs(row) do
        if tile ~= json.null and tile ~= nil and tile >= 0 then put((a.col or 0) + rx - 1, (a.row or 0) + ry - 1, tile) end
      end
    end
  end
  MCP.commit_cel(cel, img, origin)
  return { columns = img.width, rows = img.height }
end)

----------------------------------------------------------------------
-- Handlers: export / import / render
----------------------------------------------------------------------

handler("export", false, function(a)
  local spr = MCP.sprite(a.sprite)
  if type(a.file) ~= "string" then fail("'file' is required") end
  local p = { ui = false, filename = a.file }
  if a.scale then p.scale = a.scale end
  if a.tag then p.tag = a.tag end
  if a.slice then p.slice = a.slice end

  if a.aniDir then p.aniDir = a.aniDir end
  if a.filenameFormat then p.filenameFormat = a.filenameFormat end
  if a.bounds then p.bounds = rect_in(a.bounds) end
  if a.ignoreEmpty ~= nil then p.ignoreEmpty = a.ignoreEmpty end
  if a.playSubtags ~= nil then p.playSubtags = a.playSubtags end
  local function run()
    if a.fromFrame == nil and a.toFrame == nil then
      app.command.SaveFileCopyAs(p)
      return
    end
    -- SaveFileCopyAs keeps its frame list between calls in the GUI and appends
    -- fromFrame/toFrame to it, so export a copy trimmed to the range instead.
    local from = MCP.frame(spr, a.fromFrame or 1).frameNumber
    local to = MCP.frame(spr, a.toFrame or #spr.frames).frameNumber
    if from > to then fail("fromFrame is after toFrame") end
    local copy = Sprite(spr)
    local ok, err = pcall(function()
      for i = #copy.frames, 1, -1 do
        if i < from or i > to then copy:deleteFrame(copy.frames[i]) end
      end
      -- Plain frame order: tags would make the export follow playback direction/repeats.
      if not p.tag then
        for i = #copy.tags, 1, -1 do copy:deleteTag(copy.tags[i]) end
      end
      app.sprite = copy
      app.command.SaveFileCopyAs(p)
    end)
    copy:close()
    app.sprite = spr
    if not ok then error(err, 0) end
  end
  if a.layers then
    local layers = {}
    for i, ref in ipairs(a.layers) do layers[i] = MCP.layer(spr, ref) end
    MCP.with_only_layers(spr, layers, run)
  else
    run()
  end
  return { exported = a.file, files = MCP.written_files(a.file) }
end)

handler("export_sprite_sheet", false, function(a)
  local spr = MCP.sprite(a.sprite)
  local p = { ui = false, askOverwrite = false }
  for k, v in pairs(a) do
    if k ~= "sprite" and k ~= "backend" and k ~= "save" then p[k] = v end
  end
  if p.textureFilename == nil then fail("'textureFilename' is required") end
  if p.type == nil then p.type = "horizontal" end
  app.command.ExportSpriteSheet(p)
  local res = { texture = p.textureFilename, data = p.dataFilename }
  return res
end)

handler("import_sprite_sheet", false, function(a)
  if type(a.file) ~= "string" then fail("'file' is required") end
  local spr = MCP.sprite(a.file)
  local p = { ui = false, type = a.type or "horizontal" }
  local fw, fh = a.frameWidth, a.frameHeight
  if not fw or not fh then fail("frameWidth and frameHeight are required") end
  p.frameBounds = Rectangle(a.x or 0, a.y or 0, fw, fh)
  if type(a.padding) == "number" then p.padding = Size(a.padding, a.padding)
  elseif a.padding then p.padding = Size(a.padding.width or 0, a.padding.height or 0) end
  if a.partialTiles ~= nil then p.partialTiles = a.partialTiles end
  app.command.ImportSpriteSheet(p)
  if a.saveAs then spr:saveAs(a.saveAs) end
  return MCP.sprite_info(spr)
end)

-- Renders frames to a PNG strip at a.out (the MCP server upscales it for viewing).
handler("render", false, function(a)
  local spr = MCP.sprite(a.sprite)
  local layer = a.layer ~= nil and MCP.layer(spr, a.layer) or nil
  local list = MCP.frame_list(spr, a)
  if #list > 64 then fail("At most 64 frames per preview") end
  local cols = math.min(#list, a.columns or math.ceil(math.sqrt(#list)))
  local rows = math.ceil(#list / cols)
  local gap = (#list > 1) and 1 or 0
  local W = cols * spr.width + (cols - 1) * gap
  local H = rows * spr.height + (rows - 1) * gap
  local sheet = Image(W, H, ColorMode.RGB)
  sheet:clear()
  for i, fn in ipairs(list) do
    local img = MCP.render(spr, fn, layer)
    local cx, cy = (i - 1) % cols, (i - 1) // cols
    sheet:drawImage(img, Point(cx * (spr.width + gap), cy * (spr.height + gap)), 255, BlendMode.SRC)
  end
  if a.crop then
    sheet = Image(sheet, rect_in(a.crop))
  end
  sheet:saveAs(a.out)
  return { file = a.out, frames = json.array(list), columns = cols, rows = rows, gap = gap,
           frameWidth = spr.width, frameHeight = spr.height, width = sheet.width, height = sheet.height }
end)

----------------------------------------------------------------------
-- Handlers: preferences
----------------------------------------------------------------------

handler("preferences", function(a) return a.action == "set" end, function(a)
  local root
  local section = a.section or ""
  if section:sub(1, 5) == "tool." then
    section = section:sub(6)
    root = app.preferences.tool(a.tool or (app.tool and app.tool.id) or "pencil")
  elseif section:sub(1, 9) == "document." then
    section = section:sub(10)
    root = app.preferences.document(MCP.sprite(a.sprite))
  elseif a.tool then root = app.preferences.tool(a.tool)
  elseif a.document then root = app.preferences.document(MCP.sprite(a.sprite))
  else root = app.preferences end
  local sec = root[section]
  if sec == nil then fail("Unknown preferences section '%s'", tostring(a.section)) end
  local target, key = sec, a.option
  if key and key:find("%.") then
    for part in key:gmatch("[^.]+") do
      if target[part] ~= nil and type(target[part]) == "userdata" and part ~= key:match("[^.]+$") then
        target = target[part]
      end
    end
    key = key:match("[^.]+$")
  end
  if a.action == "set" then
    local v = a.value
    if type(v) == "string" and v:match("^#%x+$") then v = MCP.color(v) end
    target[key] = v
  end
  local v = target[key]
  if type(v) == "userdata" then
    local okc, c = pcall(MCP.color_out, v)
    v = okc and c or MCP.describe(v)
  end
  return { section = a.section, option = a.option, value = v }
end)

----------------------------------------------------------------------
-- Text
----------------------------------------------------------------------

-- Built-in 5x7 font for printable ASCII (column-major, bit 0 = top row).
-- Used in batch mode, where Aseprite does not load its fonts.
local FONT5x7 = {
  "0000000000", "00005F0000", "0007000700", "147F147F14", "242A7F2A12", "2313086462",
  "3649552250", "0005030000", "001C224100", "0041221C00", "082A1C2A08", "08083E0808",
  "0050300000", "0808080808", "0060600000", "2010080402", "3E5149453E", "00427F4000",
  "4261514946", "2141454B31", "1814127F10", "2745454539", "3C4A494930", "0171090503",
  "3649494936", "064949291E", "0036360000", "0056360000", "0814224100", "1414141414",
  "0041221408", "0201510906", "324979413E", "7E1111117E", "7F49494936", "3E41414122",
  "7F4141221C", "7F49494941", "7F09090101", "3E41415132", "7F0808087F", "00417F4100",
  "2040413F01", "7F08142241", "7F40404040", "7F0204027F", "7F0408107F", "3E4141413E",
  "7F09090906", "3E4151215E", "7F09192946", "4649494931", "01017F0101", "3F4040403F",
  "1F2040201F", "7F2018207F", "6314081463", "0304780403", "6151494543", "007F414100",
  "0204081020", "0041417F00", "0402010204", "4040404040", "0001020400", "2054545478",
  "7F48444438", "3844444420", "384444487F", "3854545418", "087E090102", "0814545430",
  "7F08040478", "00447D4000", "2040443D00", "007F102844", "00417F4000", "7C04180478",
  "7C08040478", "3844444438", "7C14141408", "081414187C", "7C08040408", "4854545420",
  "043F444020", "3C4040207C", "1C2040201C", "3C4030403C", "4428102844", "0C5050503C",
  "4464544C44", "0008364100", "00007F0000", "0041360800", "0804081008",
}

local function builtin_text_image(text, color, scale, spacing, lineSpacing)
  scale = math.max(1, math.floor(scale or 1))
  spacing = spacing or 1
  lineSpacing = lineSpacing or 1
  local lines = {}
  for line in (text .. "\n"):gmatch("(.-)\r?\n") do lines[#lines + 1] = line end
  local maxLen = 0
  for _, l in ipairs(lines) do maxLen = math.max(maxLen, #l) end
  local w = math.max(1, (maxLen * (5 + spacing) - spacing) * scale)
  local h = math.max(1, (#lines * (7 + lineSpacing) - lineSpacing) * scale)
  local img = Image(w, h, ColorMode.RGB)
  img:clear()
  local px = color.rgbaPixel
  for li, line in ipairs(lines) do
    for ci = 1, #line do
      local code = line:byte(ci)
      local glyph = FONT5x7[code - 31] or FONT5x7[32] -- unknown chars draw as '?'
      for col = 0, 4 do
        local bits = tonumber(glyph:sub(col * 2 + 1, col * 2 + 2), 16)
        for row = 0, 6 do
          if (bits >> row) & 1 == 1 then
            local x0 = ((ci - 1) * (5 + spacing) + col) * scale
            local y0 = ((li - 1) * (7 + lineSpacing) + row) * scale
            for dy = 0, scale - 1 do
              for dx = 0, scale - 1 do img:drawPixel(x0 + dx, y0 + dy, px) end
            end
          end
        end
      end
    end
  end
  return img
end

-- Renders one line with an Aseprite/system font through the PasteText command (GUI only).
local function font_line_image(text, color, fontName, fontSize)
  local w = math.min(4096, math.max(64, math.floor(#text * fontSize * 1.5 + 32)))
  local h = math.min(4096, math.max(32, math.floor(fontSize * 3 + 16)))
  local prev = app.sprite
  local tmp = Sprite(w, h, ColorMode.RGB)
  app.sprite = tmp
  local ok, err = pcall(function()
    app.command.PasteText{ ui = false, text = text, fontName = fontName, fontSize = fontSize,
                           color = color, x = 0, y = 0 }
  end)
  local img = tmp.cels[1] and tmp.cels[1].image:clone() or nil
  tmp:close()
  if prev and prev.isValid then app.sprite = prev end
  if not ok then fail("Text rendering failed: %s", tostring(err)) end
  if not img or img:isEmpty() then return nil end
  local b = img:shrinkBounds()
  return Image(img, Rectangle(0, 0, b.x + b.width, b.y + b.height))
end

handler("draw_text", true, function(a)
  local spr = MCP.sprite(a.sprite)
  local layer = MCP.layer(spr, a.layer)
  local frame = MCP.frame(spr, a.frame)
  if type(a.text) ~= "string" or a.text == "" then fail("'text' is required") end
  local color = MCP.color(a.color or "#000000")
  local font = a.font or (app.isUIAvailable and "Aseprite" or "builtin")
  local img, used, note
  if font ~= "builtin" then
    if not app.isUIAvailable then
      note = "Aseprite only loads fonts when its window is open; used the built-in 5x7 font"
    else
      local size = a.size or 6
      local lines, imgs, width, height = {}, {}, 0, 0
      for line in (a.text .. "\n"):gmatch("(.-)\r?\n") do lines[#lines + 1] = line end
      local lineHeight = a.lineHeight
      for i, line in ipairs(lines) do
        local li = line ~= "" and font_line_image(line, color, font, size) or nil
        imgs[i] = li
        lineHeight = lineHeight or (li and li.height or math.ceil(size)) + 1
        if li then width = math.max(width, li.width) end
      end
      if width == 0 then
        note = "Font '" .. font .. "' produced no pixels; used the built-in 5x7 font"
      else
        height = lineHeight * #lines
        img = Image(width, height, ColorMode.RGB)
        img:clear()
        for i, li in pairs(imgs) do img:drawImage(li, Point(0, (i - 1) * lineHeight)) end
        used = font
      end
    end
  end
  if not img then
    img = builtin_text_image(a.text, color, a.scale, a.letterSpacing, a.lineSpacing)
    used = "builtin"
  end
  local x, y = a.x or 0, a.y or 0
  if a.align == "center" then x = x - img.width // 2 elseif a.align == "right" then x = x - img.width + 1 end
  if a.measureOnly then
    return { font = used, width = img.width, height = img.height, note = note }
  end
  local cel = MCP.place_image(spr, layer, frame, img, Point(x, y), { opacity = a.opacity })
  return { font = used, bounds = { x = x, y = y, width = img.width, height = img.height },
           cel = MCP.cel_info(cel), note = note }
end)

----------------------------------------------------------------------
-- Vector shapes (GraphicsContext): lines, curves, polygons, ovals, rounded rects
----------------------------------------------------------------------

handler("draw_shapes", true, function(a)
  local spr = MCP.sprite(a.sprite)
  local layer = MCP.layer(spr, a.layer)
  local frame = MCP.frame(spr, a.frame)
  if type(a.shapes) ~= "table" or #a.shapes == 0 then fail("'shapes' must be a non-empty list") end
  local img = Image(spr.width, spr.height, ColorMode.RGB)
  img:clear()
  local gc = img.context
  for i, s in ipairs(a.shapes) do
    local kind = s.type or fail("shape %d needs a 'type'", i)
    local fill = s.fill == true
    local width = s.width or a.width or 1
    gc.antialias = (s.antialias == nil) and (a.antialias == true) or s.antialias
    gc.color = MCP.color(s.color or a.color or "#000000")
    gc.strokeWidth = width
    gc.opacity = s.opacity or 255
    -- Odd stroke widths sit on pixel centers, so offset outlines by half a pixel.
    local o = (not fill and width % 2 == 1) and 0.5 or 0
    local function P(p) local q = point_in(p); return q.x + o, q.y + o end
    gc:beginPath()
    if kind == "rect" or kind == "oval" or kind == "ellipse" or kind == "rounded_rect" then
      local r = rect_in(s.rect, "rect") or fail("shape %d needs 'rect'", i)
      if not fill then
        -- Outline inside the rect bounds, like Aseprite's own rectangle tool.
        local inset = width / 2
        local x0, y0 = r.x + inset, r.y + inset
        local x1, y1 = r.x + r.width - inset, r.y + r.height - inset
        if kind == "rect" then
          gc:moveTo(x0, y0); gc:lineTo(x1, y0); gc:lineTo(x1, y1); gc:lineTo(x0, y1); gc:closePath()
        else
          r = Rectangle(r.x, r.y, r.width, r.height)
          if kind == "rounded_rect" then gc:roundedRect(r, s.radius or 2, s.radiusY or s.radius or 2)
          else gc:oval(r) end
        end
      elseif kind == "rect" then gc:rect(r)
      elseif kind == "rounded_rect" then gc:roundedRect(r, s.radius or 2, s.radiusY or s.radius or 2)
      else gc:oval(r) end
    elseif kind == "line" or kind == "polyline" or kind == "polygon" then
      local pts = s.points or fail("shape %d needs 'points'", i)
      if #pts < 2 then fail("shape %d needs at least 2 points", i) end
      gc:moveTo(P(pts[1]))
      for j = 2, #pts do gc:lineTo(P(pts[j])) end
      if kind == "polygon" then gc:closePath() end
    elseif kind == "bezier" then
      local pts = s.points or fail("shape %d needs 'points'", i)
      if #pts < 4 or (#pts - 1) % 3 ~= 0 then fail("bezier needs 1 + 3n points (start, then control1, control2, end per segment)") end
      gc:moveTo(P(pts[1]))
      for j = 2, #pts, 3 do
        local ax, ay = P(pts[j]); local bx, by = P(pts[j + 1]); local cx, cy = P(pts[j + 2])
        gc:cubicTo(ax, ay, bx, by, cx, cy)
      end
      if s.closed then gc:closePath() end
    elseif kind == "path" then
      for _, op in ipairs(s.ops or {}) do
        local c = op.op or op[1]
        if c == "move" then gc:moveTo(op.x + o, op.y + o)
        elseif c == "line" then gc:lineTo(op.x + o, op.y + o)
        elseif c == "cubic" then gc:cubicTo(op.c1x + o, op.c1y + o, op.c2x + o, op.c2y + o, op.x + o, op.y + o)
        elseif c == "close" then gc:closePath()
        else fail("Unknown path op '%s'", tostring(c)) end
      end
    else
      fail("Unknown shape type '%s'", kind)
    end
    if fill then gc:fill() else gc:stroke() end
  end
  if img:isEmpty() then return { drawn = 0, note = "Shapes produced no pixels inside the canvas" } end
  local b = img:shrinkBounds()
  local part = Image(img, b)
  local cel = MCP.place_image(spr, layer, frame, part, Point(b.x, b.y),
                              { opacity = a.opacity, blendMode = a.blendMode })
  return { drawn = #a.shapes, bounds = rect_out(b), cel = MCP.cel_info(cel) }
end)

----------------------------------------------------------------------
-- Linked cels
----------------------------------------------------------------------

handler("link_cels", true, function(a)
  local spr = MCP.sprite(a.sprite)
  local layers = {}
  if a.layers then for i, ref in ipairs(a.layers) do layers[i] = MCP.layer(spr, ref) end
  else layers[1] = MCP.layer(spr, a.layer) end
  local frames = MCP.frame_list(spr, a)
  local action = a.action or "link"
  if action == "link" then
    if #frames < 2 then fail("Linking needs at least 2 frames") end
    if not app.isUIAvailable then
      fail("Linking cels needs the timeline, which only exists in live mode. Use launch_aseprite, or duplicate frames on a continuous layer (update_layer continuous=true, then add_frames) to get linked cels in batch mode.")
    end
    MCP.activate(spr, layers[1], spr.frames[frames[1]])
    -- The range only takes effect while the timeline is open.
    app.command.Timeline{ open = true }
    app.range.layers = layers
    app.range.frames = frames
    app.command.LinkCels()
    app.range:clear()
  elseif action == "unlink" then
    for _, l in ipairs(layers) do
      for _, fn in ipairs(frames) do
        if l:cel(fn) then
          MCP.activate(spr, l, spr.frames[fn])
          app.command.UnlinkCel()
        end
      end
    end
  else
    fail("action must be link or unlink")
  end
  local res = {}
  for _, l in ipairs(layers) do
    for _, fn in ipairs(frames) do
      local c = l:cel(fn)
      if c then res[#res + 1] = MCP.cel_info(c) end
    end
  end
  return json.array(res)
end)

----------------------------------------------------------------------
-- Palette editing (keeps indexed pixels pointing at the same colors)
----------------------------------------------------------------------

-- map[old] = new for 0-based indices; applies to indexed cels and tiles.
local function remap_indices(spr, map)
  if spr.colorMode ~= ColorMode.INDEXED then return 0 end
  local seen, changed = {}, 0
  local function remap_image(img)
    local copy = img:clone()
    local n = 0
    for it in copy:pixels() do
      local v = it()
      local nv = map[v]
      if nv ~= nil and nv ~= v then it(nv); n = n + 1 end
    end
    return copy, n
  end
  app.transaction("MCP remap palette", function()
    for _, c in ipairs(spr.cels) do
      if c.image.colorMode == ColorMode.INDEXED and not seen[c.image.id] then
        seen[c.image.id] = true
        local img, n = remap_image(c.image)
        if n > 0 then c.image = img; changed = changed + n end
      end
    end
    for _, ts in ipairs(spr.tilesets) do
      for i = 1, #ts - 1 do
        local t = ts:tile(i)
        if t and t.image.colorMode == ColorMode.INDEXED then
          local img, n = remap_image(t.image)
          if n > 0 then t.image = img; changed = changed + n end
        end
      end
    end
    local tc = map[spr.transparentColor]
    if tc ~= nil and tc ~= spr.transparentColor then spr.transparentColor = tc end
  end)
  return changed
end

local function color_key(c, by)
  if by == "hue" then return c.hsvHue + (c.hsvSaturation == 0 and -1 or 0)
  elseif by == "saturation" then return c.hsvSaturation
  elseif by == "value" or by == "brightness" then return c.hsvValue
  elseif by == "lightness" then return c.hslLightness
  elseif by == "luminance" then return 0.2126 * c.red + 0.7152 * c.green + 0.0722 * c.blue
  elseif by == "red" then return c.red elseif by == "green" then return c.green
  elseif by == "blue" then return c.blue elseif by == "alpha" then return c.alpha end
  fail("Unknown sort key '%s'", tostring(by))
end

local function nearest_index(cols, c, exclude)
  local best, bestD = nil, math.huge
  for i, o in ipairs(cols) do
    if not exclude[i] then
      local d = (o.red - c.red)^2 + (o.green - c.green)^2 + (o.blue - c.blue)^2 + (o.alpha - c.alpha)^2
      if d < bestD then best, bestD = i, d end
    end
  end
  return best
end

handler("palette_edit", true, function(a)
  local spr = MCP.sprite(a.sprite)
  local pal = spr.palettes[1]
  local n = #pal
  -- entries[i] = { color = Color, old = 0-based original index or nil }
  local entries = {}
  for i = 0, n - 1 do entries[i + 1] = { color = pal:getColor(i), old = i } end
  local function range(default_all)
    local from = a.from or 0
    local to = a.to or (n - 1)
    if from < 0 or to >= n or from > to then fail("Palette range %d..%d is outside 0..%d", from, to, n - 1) end
    return from, to
  end
  local act = a.action
  local removedMap = {}
  if act == "add" or act == "insert" then
    local at = act == "add" and n or (a.at or n)
    if at < 0 or at > n then fail("'at' must be 0..%d", n) end
    local new = {}
    for i, c in ipairs(a.colors or fail("'colors' is required")) do new[i] = { color = MCP.color(c) } end
    for i = #new, 1, -1 do table.insert(entries, at + 1, new[i]) end
  elseif act == "remove" then
    local drop = {}
    if a.indices then for _, i in ipairs(a.indices) do drop[i + 1] = true end
    else local f, t = range(); for i = f, t do drop[i + 1] = true end end
    local kept = {}
    for i, e in ipairs(entries) do if not drop[i] then kept[#kept + 1] = e end end
    if #kept == 0 then fail("Cannot remove every color") end
    -- Pixels using removed colors move to the nearest remaining color.
    local cols = {}
    for i, e in ipairs(entries) do cols[i] = e.color end
    for i in pairs(drop) do
      local near = nearest_index(cols, entries[i].color, drop)
      removedMap[i - 1] = entries[near].old
    end
    entries = kept
  elseif act == "move" then
    local idx = {}
    if a.indices then for _, i in ipairs(a.indices) do idx[#idx + 1] = i end
    else local f, t = range(); for i = f, t do idx[#idx + 1] = i end end
    table.sort(idx)
    local moving, set = {}, {}
    for _, i in ipairs(idx) do moving[#moving + 1] = entries[i + 1]; set[i + 1] = true end
    local rest = {}
    for i, e in ipairs(entries) do if not set[i] then rest[#rest + 1] = e end end
    local at = a.to or fail("'to' (destination index) is required")
    at = math.max(0, math.min(at, #rest))
    for k = #moving, 1, -1 do table.insert(rest, at + 1, moving[k]) end
    entries = rest
  elseif act == "sort" or act == "reverse" then
    local f, t = range()
    local seg = {}
    for i = f, t do seg[#seg + 1] = entries[i + 1] end
    if act == "sort" then
      local by = a.by or "hue"
      table.sort(seg, function(x, y)
        local kx, ky = color_key(x.color, by), color_key(y.color, by)
        if kx == ky then return x.old < y.old end
        if a.descending then return kx > ky end
        return kx < ky
      end)
    else
      for i = 1, #seg // 2 do seg[i], seg[#seg - i + 1] = seg[#seg - i + 1], seg[i] end
    end
    for i = f, t do entries[i + 1] = seg[i - f + 1] end
  elseif act == "ramp" then
    local c1, c2 = MCP.color(a.fromColor or fail("'fromColor' is required")), MCP.color(a.toColor or fail("'toColor' is required"))
    local steps = a.steps or 8
    if steps < 2 then fail("steps must be at least 2") end
    local at = a.at or n
    local hsv = a.space == "hsv"
    for k = 0, steps - 1 do
      local t = k / (steps - 1)
      local c
      if hsv then
        local h1, h2 = c1.hsvHue, c2.hsvHue
        if math.abs(h2 - h1) > 180 then if h2 > h1 then h1 = h1 + 360 else h2 = h2 + 360 end end
        c = Color{ h = (h1 + (h2 - h1) * t) % 360, s = c1.hsvSaturation + (c2.hsvSaturation - c1.hsvSaturation) * t,
                   v = c1.hsvValue + (c2.hsvValue - c1.hsvValue) * t, a = math.floor(c1.alpha + (c2.alpha - c1.alpha) * t + 0.5) }
      else
        local function lerp(p, q) return math.floor(p + (q - p) * t + 0.5) end
        c = Color{ r = lerp(c1.red, c2.red), g = lerp(c1.green, c2.green), b = lerp(c1.blue, c2.blue), a = lerp(c1.alpha, c2.alpha) }
      end
      local pos = at + k + 1
      if a.insert then table.insert(entries, pos, { color = c })
      elseif pos <= #entries then entries[pos] = { color = c, old = entries[pos].old }
      else entries[pos] = { color = c } end
    end
  elseif act == "dedupe" then
    local seenColor, kept = {}, {}
    for _, e in ipairs(entries) do
      local key = e.color.rgbaPixel
      if seenColor[key] == nil then
        seenColor[key] = e.old
        kept[#kept + 1] = e
      else
        removedMap[e.old] = seenColor[key]
      end
    end
    entries = kept
  else
    fail("Unknown palette_edit action '%s'", tostring(act))
  end
  if #entries > 256 and spr.colorMode == ColorMode.INDEXED then fail("Indexed palettes hold at most 256 colors") end

  -- Build the new palette and the old->new index map.
  local newPal = Palette(#entries)
  local map = {}
  for i, e in ipairs(entries) do
    newPal:setColor(i - 1, e.color)
    if e.old ~= nil then map[e.old] = i - 1 end
  end
  for old, target in pairs(removedMap) do map[old] = map[target] end
  local remapped = 0
  app.transaction("MCP palette edit", function()
    if a.remapPixels ~= false then remapped = remap_indices(spr, map) end
    spr:setPalette(newPal)
  end)
  local colors = {}
  for i = 0, #newPal - 1 do colors[i + 1] = MCP.color_out(newPal:getColor(i)) end
  return { size = #newPal, colors = json.array(colors), remappedPixels = remapped }
end)

----------------------------------------------------------------------
-- View settings (grid, symmetry, tiled mode, onion skin, overlays, playback)
----------------------------------------------------------------------

local SYMMETRY = { none = 0, horizontal = 1, vertical = 2, both = 3, right_diag = 4, left_diag = 8, both_diag = 12, all = 15 }
local TILED = { none = 0, x = 1, y = 2, both = 3 }

handler("view_settings", false, function(a)
  local spr = MCP.sprite(a.sprite)
  local doc = app.preferences.document(spr)
  local function set(sec, key, v)
    if v ~= nil then doc[sec][key] = v end
  end
  if a.grid then
    local g = a.grid
    set("show", "grid", g.show)
    set("grid", "snap", g.snap)
    if g.bounds then
      local r = rect_in(g.bounds)
      doc.grid.bounds = r
      spr.gridBounds = r
    end
    if g.color then doc.grid.color = MCP.color(g.color) end
    set("grid", "opacity", g.opacity)
  end
  if a.pixelGrid then
    set("show", "pixel_grid", a.pixelGrid.show)
    if a.pixelGrid.color then doc.pixel_grid.color = MCP.color(a.pixelGrid.color) end
    set("pixel_grid", "opacity", a.pixelGrid.opacity)
  end
  if a.symmetry then
    local s = a.symmetry
    if s.mode then
      local m = SYMMETRY[s.mode] or fail("symmetry.mode must be one of none, horizontal, vertical, both, right_diag, left_diag, both_diag, all")
      doc.symmetry.mode = m
      pcall(function() app.preferences.symmetry_mode.enabled = (m ~= 0) end)
    end
    set("symmetry", "x_axis", s.x)
    set("symmetry", "y_axis", s.y)
  end
  if a.tiledMode then
    doc.tiled.mode = TILED[a.tiledMode] or fail("tiledMode must be none, x, y or both")
  end
  if a.onionSkin then
    local o = a.onionSkin
    set("onionskin", "active", o.active)
    set("onionskin", "prev_frames", o.prevFrames)
    set("onionskin", "next_frames", o.nextFrames)
    set("onionskin", "opacity_base", o.opacityBase)
    set("onionskin", "opacity_step", o.opacityStep)
    set("onionskin", "loop_tag", o.loopTag)
    set("onionskin", "current_layer", o.currentLayer)
    if o.type then doc.onionskin.type = (o.type == "red_blue_tint") and 1 or 0 end
    if o.position then doc.onionskin.position = (o.position == "infront") and 1 or 0 end
  end
  if a.show then
    local s = a.show
    set("show", "layer_edges", s.layerEdges)
    set("show", "selection_edges", s.selectionEdges)
    set("show", "slices", s.slices)
    set("show", "auto_guides", s.autoGuides)
    set("show", "tile_numbers", s.tileNumbers)
    set("show", "brush_preview", s.brushPreview)
  end
  if a.background then
    local b = a.background
    if b.color1 then doc.bg.color1 = MCP.color(b.color1) end
    if b.color2 then doc.bg.color2 = MCP.color(b.color2) end
    if b.size then doc.bg.size = Size(b.size, b.size) end
  end
  if app.isUIAvailable then
    if a.zoom and app.editor then app.editor.zoom = a.zoom end
    if a.scroll and app.editor then app.editor.scroll = point_in(a.scroll) end
    if a.fitScreen then app.command.FitScreen() end
    if a.playback == "toggle" or a.playback == "play" or a.playback == "stop" then app.command.PlayAnimation() end
    if a.timeline ~= nil then app.command.Timeline{ open = a.timeline == true, close = a.timeline == false } end
    if a.togglePreview then app.command.TogglePreview() end
    pcall(app.refresh)
  elseif a.zoom or a.scroll or a.fitScreen or a.playback or a.timeline ~= nil or a.togglePreview then
    fail("zoom, scroll, fitScreen, playback, timeline and togglePreview need live mode")
  end
  local function name_of(tbl, v) for k, x in pairs(tbl) do if x == v then return k end end return v end
  local res = {
    grid = { show = doc.show.grid, snap = doc.grid.snap, bounds = rect_out(spr.gridBounds), opacity = doc.grid.opacity },
    pixelGrid = { show = doc.show.pixel_grid, opacity = doc.pixel_grid.opacity },
    symmetry = { mode = name_of(SYMMETRY, doc.symmetry.mode), x = doc.symmetry.x_axis, y = doc.symmetry.y_axis },
    tiledMode = name_of(TILED, doc.tiled.mode),
    onionSkin = { active = doc.onionskin.active, prevFrames = doc.onionskin.prev_frames, nextFrames = doc.onionskin.next_frames,
                  opacityBase = doc.onionskin.opacity_base, opacityStep = doc.onionskin.opacity_step },
    show = { layerEdges = doc.show.layer_edges, selectionEdges = doc.show.selection_edges, slices = doc.show.slices,
             autoGuides = doc.show.auto_guides, tileNumbers = doc.show.tile_numbers, brushPreview = doc.show.brush_preview },
  }
  if app.isUIAvailable and app.editor then
    res.zoom = app.editor.zoom
    local okS, s = pcall(function() return app.editor.scroll end)
    if okS and s then res.scroll = { x = s.x, y = s.y } end
  end
  return res
end)

----------------------------------------------------------------------
-- Clipboard
----------------------------------------------------------------------

handler("clipboard", false, function(a)
  local cb = app.clipboard
  local act = a.action or "info"
  if act == "info" then
    local t = cb.text
    return { hasText = cb.hasText, hasImage = cb.hasImage,
             text = t and (#t > 2000 and t:sub(1, 2000) .. "..." or t) or nil }
  elseif act == "get_text" then
    return { text = cb.text }
  elseif act == "set_text" then
    if type(a.text) ~= "string" then fail("'text' is required") end
    cb.text = a.text
    return { ok = true }
  elseif act == "clear" then
    cb.clear()
    return { ok = true }
  elseif act == "get_image" then
    local img = cb.image
    if not img then fail("The clipboard has no image") end
    if not a.out then fail("'out' (a file path) is required") end
    if img.colorMode == ColorMode.INDEXED and app.sprite then
      img:saveAs{ filename = a.out, palette = app.sprite.palettes[1] }
    else
      img:saveAs(a.out)
    end
    return { file = a.out, width = img.width, height = img.height, colorMode = color_mode_name(img.colorMode) }
  elseif act == "set_image" then
    local img
    if a.file then
      img = MCP.image_from_spec(a.file)
    else
      local spr = MCP.sprite(a.sprite)
      local frame = MCP.frame(spr, a.frame)
      img = MCP.render(spr, frame.frameNumber, a.layer ~= nil and MCP.layer(spr, a.layer) or nil)
      if a.rect then img = Image(img, rect_in(a.rect)) end
    end
    cb.image = img
    return { width = img.width, height = img.height }
  end
  fail("Unknown clipboard action '%s'", tostring(act))
end)

----------------------------------------------------------------------
-- Sprites: duplicate
----------------------------------------------------------------------

handler("duplicate_sprite", false, function(a)
  local spr = MCP.sprite(a.sprite)
  if MCP.mode == "batch" and not a.file then fail("In batch mode duplicate_sprite needs 'file'") end
  local copy = Sprite(spr)
  if a.file then copy:saveAs(a.file) end
  app.sprite = copy
  return MCP.sprite_summary(copy)
end)

----------------------------------------------------------------------
-- User and extension properties on any object
----------------------------------------------------------------------

local function property_target(spr, a)
  local kind = a.target or "sprite"
  if kind == "sprite" then return spr
  elseif kind == "layer" then return MCP.layer(spr, a.layer)
  elseif kind == "cel" then
    local l = MCP.layer(spr, a.layer)
    local c = l:cel(MCP.frame(spr, a.frame))
    return c or fail("No cel at that layer/frame")
  elseif kind == "tag" then return MCP.tag(spr, a.tag)
  elseif kind == "slice" then return MCP.slice(spr, a.slice)
  elseif kind == "tileset" then return MCP.tileset(spr, a.tileset)
  elseif kind == "tile" then
    local ts = MCP.tileset(spr, a.tileset)
    return ts:tile(a.index or fail("'index' is required for tiles")) or fail("No tile %s", tostring(a.index))
  end
  fail("target must be sprite, layer, cel, tag, slice, tileset or tile")
end

local function props_table(p)
  local t, any = {}, false
  for k, v in pairs(p) do t[k] = v; any = true end
  return any and t or json.object({})
end

handler("properties", function(a) return a.action ~= "get" end, function(a)
  local spr = MCP.sprite(a.sprite)
  local obj = property_target(spr, a)
  local key = a.pluginKey
  local function P() if key then return obj.properties(key) end return obj.properties end
  local act = a.action or "get"
  if act == "set" then
    local p = P()
    for k, v in pairs(a.values or fail("'values' is required")) do p[k] = v end
  elseif act == "delete" then
    local p = P()
    for _, k in ipairs(a.keys or fail("'keys' is required")) do p[k] = nil end
  elseif act == "replace" then
    if key then obj.properties(key, a.values or {}) else obj.properties = a.values or {} end
  elseif act ~= "get" then
    fail("action must be get, set, delete or replace")
  end
  return { target = a.target or "sprite", pluginKey = key, properties = props_table(P()) }
end)

----------------------------------------------------------------------
-- Event log (live mode): what the user did between calls
----------------------------------------------------------------------

MCP.events = { seq = 0, log = {}, max = 500 }

local function log_event(kind, data)
  local ev = MCP.events
  ev.seq = ev.seq + 1
  data = data or {}
  data.seq = ev.seq
  data.type = kind
  data.time = os.time()
  data.byMcp = MCP.ctx and MCP.ctx.inCall or nil
  ev.log[#ev.log + 1] = data
  if #ev.log > ev.max then table.remove(ev.log, 1) end
end

function MCP.start_events()
  if not app.isUIAvailable then return end
  -- Drop listeners left by a previous runtime load (the bridge reloads it on reconnect).
  local old = rawget(_G, "__aseprite_mcp_listeners")
  if old then
    for _, l in ipairs(old) do pcall(function() l.events:off(l.id) end) end
  end
  local listeners = {}
  rawset(_G, "__aseprite_mcp_listeners", listeners)
  local watched = {}
  local function watch(spr)
    if not spr or watched[spr.id] then return end
    watched[spr.id] = true
    local id = spr.events:on("change", function(ev)
      log_event("sprite_change", { sprite = spr.isValid and spr.filename or nil, fromUndo = ev and ev.fromUndo or nil })
    end)
    listeners[#listeners + 1] = { events = spr.events, id = id }
  end
  for _, s in ipairs(app.sprites) do watch(s) end
  listeners[#listeners + 1] = { events = app.events, id = app.events:on("sitechange", function()
    local s = app.sprite
    watch(s)
    log_event("site_change", { sprite = s and s.filename or nil,
                                layer = app.layer and MCP.layer_path(app.layer) or nil,
                                frame = app.frame and app.frame.frameNumber or nil })
  end) }
  listeners[#listeners + 1] = { events = app.events, id = app.events:on("aftercommand", function(ev)
    log_event("command", { name = ev.name })
  end) }
  listeners[#listeners + 1] = { events = app.events, id = app.events:on("fgcolorchange", function()
    log_event("fg_color", { color = MCP.color_out(app.fgColor) })
  end) }
  listeners[#listeners + 1] = { events = app.events, id = app.events:on("bgcolorchange", function()
    log_event("bg_color", { color = MCP.color_out(app.bgColor) })
  end) }
end

handler("recent_events", false, function(a)
  if not app.isUIAvailable then fail("The event log only exists in live mode") end
  local out = {}
  local since = a.since or 0
  for _, e in ipairs(MCP.events.log) do
    if e.seq > since and (a.includeMcp or not e.byMcp) and (not a.types or (function()
      for _, t in ipairs(a.types) do if t == e.type then return true end end
      return false
    end)()) then
      out[#out + 1] = e
    end
  end
  local limit = a.limit or 100
  if #out > limit then
    local trimmed = {}
    for i = #out - limit + 1, #out do trimmed[#trimmed + 1] = out[i] end
    out = trimmed
  end
  return { lastSeq = MCP.events.seq, events = json.array(out) }
end)

----------------------------------------------------------------------
-- Asking the user (live mode)
----------------------------------------------------------------------

handler("ask_user", false, function(a)
  if not app.isUIAvailable then fail("ask_user needs live mode (the Aseprite window)") end
  local dlg = Dialog{ title = a.title or "Claude" }
  if a.text then
    local i = 0
    for line in (a.text .. "\n"):gmatch("(.-)\r?\n") do
      i = i + 1
      dlg:label{ id = "__text" .. i, text = line }
      dlg:newrow()
    end
  end
  for _, f in ipairs(a.fields or {}) do
    local t = f.type or "entry"
    local id = f.id or fail("Every field needs an 'id'")
    if t == "entry" then dlg:entry{ id = id, label = f.label, text = f.value or "" }
    elseif t == "number" then dlg:number{ id = id, label = f.label, text = tostring(f.value or 0), decimals = f.decimals or 0 }
    elseif t == "slider" then dlg:slider{ id = id, label = f.label, min = f.min or 0, max = f.max or 100, value = f.value or f.min or 0 }
    elseif t == "check" then dlg:check{ id = id, label = f.label, text = f.text, selected = f.value == true }
    elseif t == "combobox" then dlg:combobox{ id = id, label = f.label, option = f.value, options = f.options or {} }
    elseif t == "color" then dlg:color{ id = id, label = f.label, color = MCP.color(f.value or "#000000") }
    elseif t == "label" then dlg:label{ id = id, label = f.label, text = f.value or "" }
    else fail("Unknown field type '%s'", t) end
    dlg:newrow()
  end
  local buttons = a.buttons or { "OK", "Cancel" }
  for i, b in ipairs(buttons) do dlg:button{ id = "__button" .. i, text = b, focus = i == 1 } end
  -- Close the dialog on timeout so it never outlives the caller's wait.
  local timedOut = false
  local timer
  if a.timeoutSeconds then
    timer = Timer{ interval = a.timeoutSeconds, ontick = function()
      timer:stop()
      timedOut = true
      dlg:close()
    end }
    timer:start()
  end
  dlg:show{ wait = true }
  if timer then timer:stop() end
  local data = dlg.data
  local pressed
  for i, b in ipairs(buttons) do if data["__button" .. i] then pressed = b end end
  local values = {}
  for _, f in ipairs(a.fields or {}) do
    local v = data[f.id]
    if type(v) == "userdata" then
      local ok, c = pcall(MCP.color_out, v)
      v = ok and c or MCP.describe(v)
    end
    values[f.id] = v
  end
  return { button = pressed, values = values, timedOut = timedOut or nil }
end)

if app.isUIAvailable then MCP.start_events() end

return MCP
