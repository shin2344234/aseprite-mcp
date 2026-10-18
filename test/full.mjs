// Full coverage test: calls every registered tool through a real MCP client and
// checks the results (pixels, structure, files), not just the absence of errors.
// Usage: node test/full.mjs [batch|live]
// Live mode starts the Aseprite GUI. ask_user is skipped unless ASK_USER=1
// (it waits for someone to click the dialog).
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { PNG } from "pngjs";

const mode = process.argv[2] ?? "batch";
const live = mode === "live";
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const base = path.join(os.tmpdir(), "aseprite-mcp-full");
const dir = path.join(base, `${mode}-${Date.now()}`);
mkdirSync(dir, { recursive: true });
const F = (n) => path.join(dir, n);

// Fixture: a 4x4 PNG, red/green on top, blue/white below.
{
  const png = new PNG({ width: 4, height: 4 });
  for (let y = 0; y < 4; y++)
    for (let x = 0; x < 4; x++) {
      const i = (y * 4 + x) * 4;
      const c = y < 2 ? (x < 2 ? [255, 0, 0] : [0, 255, 0]) : x < 2 ? [0, 0, 255] : [255, 255, 255];
      png.data.set([...c, 255], i);
    }
  writeFileSync(F("fixture.png"), PNG.sync.write(png));
}

const transport = new StdioClientTransport({
  command: process.execPath,
  args: [path.join(root, "dist", "index.js")],
  cwd: base,
  stderr: "inherit",
});
const client = new Client({ name: "full-test", version: "0" });
await client.connect(transport);
const allTools = (await client.listTools()).tools.map((t) => t.name);

const called = new Set();
const failures = [];
let checks = 0;

function parse(r) {
  const txt = r.content.filter((c) => c.type === "text").map((c) => c.text).join("\n");
  let v;
  try { v = JSON.parse(txt); } catch { v = txt; }
  if (v && typeof v === "object" && !Array.isArray(v) && "result" in v && ("saved" in v || "output" in v || "warning" in v)) {
    return { value: v.result, raw: v, text: txt };
  }
  return { value: v, raw: v, text: txt };
}

async function call(name, args = {}, { expectError = false, timeout = 180_000 } = {}) {
  called.add(name);
  // Pin the backend: "auto" would use a connected GUI even in the batch run.
  const r = await client.callTool({ name, arguments: { backend: mode, ...args } }, undefined, { timeout });
  const p = parse(r);
  p.isError = !!r.isError;
  p.images = r.content.filter((c) => c.type === "image");
  if (p.isError !== expectError) {
    failures.push(`${name}: ${expectError ? "expected an error, got success" : "unexpected error"}: ${p.text.slice(0, 300)}`);
    console.log(`FAIL ${name}: ${p.text.slice(0, 300)}`);
  } else {
    console.log(`ok   ${name}${expectError ? " (expected error)" : ""}: ${p.text.slice(0, 140).replace(/\s+/g, " ")}`);
  }
  return p;
}

function check(label, cond, detail = "") {
  checks++;
  if (!cond) {
    failures.push(`${label} ${detail}`);
    console.log(`FAIL check: ${label} ${typeof detail === "string" ? detail : JSON.stringify(detail)}`.slice(0, 400));
  }
}

const px = async (spr, x, y, extra = {}) => {
  const r = await call("get_pixels", { sprite: spr, rect: { x, y, width: 1, height: 1 }, format: "hex", ...extra });
  return r.value.rows?.[0]?.[0] ?? null;
};

// ---------------------------------------------------------------------------
// Setup, discovery
const st = await call("status");
check("status.executable", !!st.value.executable);
const inst = await call("install_extension");
check("install_extension dir", existsSync(path.join(inst.value.installedTo, "plugin.lua")));
if (live) {
  const l = await call("launch_aseprite", { waitSeconds: 90 });
  check("launch connected", l.value.connected === true || l.value.alreadyConnected === true, l.text);
}
const docs = await call("api_docs");
check("api_docs lists sprite", docs.text.includes("\nsprite\n") || docs.text.startsWith("sprite\n") || docs.text.includes("sprite"));
const doc2 = await call("api_docs", { topic: "command/ExportSpriteSheet" });
check("api_docs topic", doc2.text.includes("ExportSpriteSheet"));
await call("api_docs", { topic: "nope-nope" }, { expectError: true });
const lc = await call("list_commands", { query: "flip" });
check("list_commands Flip", lc.text.includes("Flip("));
const lp = await call("list_preferences");
check("list_preferences has document.grid", Object.keys(lp.value).includes("document.grid"));
const lp2 = await call("list_preferences", { section: "document.symmetry" });
check("list_preferences section", "mode" in lp2.value);

// ---------------------------------------------------------------------------
// Sprite basics
const main = F("main.aseprite");
const S = { sprite: main };
const ns = await call("new_sprite", { width: 32, height: 32, frames: 4, frameDurationMs: 100, layerName: "Base", file: main });
check("new_sprite frames", ns.value.frames === 4 && ns.value.width === 32);
await call("new_sprite", { width: 8, height: 8 }, { expectError: !live }); // batch needs file
const ls = await call("list_sprites");
check("list_sprites array", Array.isArray(ls.value));
if (live) check("list_sprites has main", ls.value.some((s) => s.filename.toLowerCase() === main.toLowerCase()));
const as = await call("app_state");
check("app_state version", typeof as.value.version === "string");
const op = await call("open_sprite", { file: main });
check("open_sprite", op.value.width === 32);
await call("open_sprite", { file: F("missing.png") }, { expectError: true });
await call("set_sprite_properties", { ...S, data: "hello", properties: { speed: 3 }, pixelRatio: { width: 1, height: 1 }, gridBounds: { x: 0, y: 0, width: 8, height: 8 }, color: "#ff8800" });
let info = (await call("get_sprite_info", S)).value;
check("sprite data", info.data === "hello");
check("sprite props", info.properties?.speed === 3, info.properties);
check("sprite grid", info.gridBounds.width === 8);

// ---------------------------------------------------------------------------
// Layers
await call("add_layer", { ...S, name: "Body" });
await call("add_layer", { ...S, name: "FX", type: "group" });
const glow = await call("add_layer", { ...S, name: "Glow", parent: "FX", blendMode: "screen", opacity: 180 });
check("Glow in FX", glow.value.path === "FX/Glow" && glow.value.blendMode === "screen" && glow.value.opacity === 180);
const ref = await call("add_layer", { ...S, name: "Ref", type: "reference", image: { rows: ["ab", "ba"], legend: { a: "#ff0000", b: "#0000ff" } } });
check("reference layer", ref.value.reference === true, ref.text);
const ff = await call("add_layer", { ...S, name: "FromFile", image: "fixture.png".length ? F("fixture.png") : "", x: 28, y: 28 });
check("layer from file", ff.value.celCount === 1);
check("fixture pixel", (await px(main, 28, 28, { layer: "FromFile", frame: 1 })) === "#ff0000ff");
check("fixture pixel 2", (await px(main, 31, 31, { layer: "FromFile", frame: 1 })) === "#ffffffff");
const ul = await call("update_layer", { ...S, layer: "Body", opacity: 200, blendMode: "multiply", color: "#00ff00", data: "body data" });
check("update_layer", ul.value.opacity === 200 && ul.value.blendMode === "multiply" && ul.value.data === "body data");
await call("update_layer", { ...S, layer: "Body", opacity: 255, blendMode: "normal" });
const dl = await call("duplicate_layer", { ...S, layer: "Body", name: "Body2" });
check("duplicate_layer", dl.value.name === "Body2");
await call("delete_layer", { ...S, layer: "Body2" });
info = (await call("get_sprite_info", S)).value;
check("layer list", info.layers.map((l) => l.path).join(",") === "Base,Body,FX,FX/Glow,Ref,FromFile", info.layers.map((l) => l.path).join(","));
await call("update_layer", { ...S, layer: "Nope" }, { expectError: true });

// ---------------------------------------------------------------------------
// Pixels
await call("draw_pixels", { ...S, layer: "Body", frame: 1, x: 2, y: 2, rows: ["rr.", ".gg", "b.b"], legend: { r: "#ff0000", g: "#00ff00", b: "blue" } });
const gp = await call("get_pixels", { ...S, layer: "Body", frame: 1, rect: { x: 2, y: 2, width: 3, height: 3 } });
const legendInv = Object.fromEntries(Object.entries(gp.value.legend).map(([k, v]) => [v, k]));
check(
  "draw/get_pixels round trip",
  gp.value.rows.join("|") === [`${legendInv["#ff0000ff"]}${legendInv["#ff0000ff"]}.`, `.${legendInv["#00ff00ff"]}${legendInv["#00ff00ff"]}`, `${legendInv["#0000ffff"]}.${legendInv["#0000ffff"]}`].join("|"),
  gp.text,
);
await call("draw_pixels", { ...S, layer: "Body", frame: 1, pixels: [[10, 10, "#ffffff80"], { x: 11, y: 10, color: "#123456" }] });
check("pixel list", (await px(main, 11, 10, { layer: "Body", frame: 1 })) === "#123456ff");
await call("draw_pixels", { ...S, layer: "Body", frame: 1, pixels: [[10, 10, "#ff000080"]], blend: true });
const blended = await px(main, 10, 10, { layer: "Body", frame: 1 });
check("blend changed pixel", blended && blended !== "#ff000080" && blended !== "#ffffff80", blended);
await call("draw_pixels", { ...S, layer: "FX", frame: 1, pixels: [[0, 0, "red"]] }, { expectError: true });

// use_tool: every drawing tool on its own layer/frame region
await call("add_layer", { ...S, name: "Tools" });
const T = { ...S, layer: "Tools", frame: 2 };
await call("use_tool", { ...T, tool: "filled_rectangle", points: [[0, 0], [5, 5]], color: "#ff0000" });
check("filled_rectangle", (await px(main, 3, 3, { layer: "Tools", frame: 2 })) === "#ff0000ff");
await call("use_tool", { ...T, tool: "rectangle", points: [[8, 0], [13, 5]], color: "#00ff00" });
check("rectangle edge", (await px(main, 8, 3, { layer: "Tools", frame: 2 })) === "#00ff00ff");
check("rectangle hollow", (await px(main, 10, 3, { layer: "Tools", frame: 2 })) === null);
await call("use_tool", { ...T, tool: "filled_ellipse", points: [[16, 0], [23, 7]], color: "#0000ff" });
check("filled_ellipse center", (await px(main, 19, 3, { layer: "Tools", frame: 2 })) === "#0000ffff");
await call("use_tool", { ...T, tool: "ellipse", points: [[24, 0], [31, 7]], color: "#00ffff" });
await call("use_tool", { ...T, tool: "line", points: [[0, 10], [31, 10]], color: "#ffff00" });
check("line", (await px(main, 20, 10, { layer: "Tools", frame: 2 })) === "#ffff00ff");
await call("use_tool", { ...T, tool: "pencil", points: [[0, 12], [5, 12]], color: "#ff00ff", brushSize: 1, pixelPerfect: true });
check("pencil", (await px(main, 3, 12, { layer: "Tools", frame: 2 })) === "#ff00ffff");
await call("use_tool", { ...T, tool: "curve", points: [[0, 14], [10, 20], [20, 8], [31, 14]], color: "#ffffff" });
await call("use_tool", { ...T, tool: "polygon", points: [[0, 22], [6, 22], [3, 28]], color: "#ff8800" });
await call("use_tool", { ...T, tool: "contour", points: [[8, 22], [14, 22], [11, 28]], color: "#88ff00" });
await call("use_tool", { ...T, tool: "spray", points: [[20, 24], [22, 26]], color: "#8800ff" });
await call("add_layer", { ...S, name: "Grad" });
await call("use_tool", { ...S, layer: "Grad", frame: 1, tool: "gradient", points: [[0, 0], [31, 0]], color: "#000000", bgColor: "#ffffff" });
check("gradient start", (await px(main, 0, 5, { layer: "Grad", frame: 1 })) === "#000000ff");
check("gradient end", (await px(main, 31, 5, { layer: "Grad", frame: 1 })) === "#ffffffff");
const mid = await px(main, 16, 5, { layer: "Grad", frame: 1 });
check("gradient middle is gray", /^#([0-9a-f]{2})\1\1ff$/.test(mid ?? "") && mid !== "#000000ff" && mid !== "#ffffffff", mid);
await call("update_layer", { ...S, layer: "Grad", visible: false });
await call("use_tool", { ...T, tool: "blur", points: [[2, 22], [4, 24]] });
await call("use_tool", { ...T, tool: "jumble", points: [[10, 22], [12, 24]] });
await call("use_tool", { ...T, tool: "eraser", points: [[3, 3], [3, 3]], brushSize: 1 });
check("eraser", (await px(main, 3, 3, { layer: "Tools", frame: 2 })) === null);
await call("use_tool", { ...T, tool: "paint_bucket", points: [[10, 3]], color: "#abcdef" });
check("paint_bucket fills inside rect", (await px(main, 10, 3, { layer: "Tools", frame: 2 })) === "#abcdefff");
await call("use_tool", { ...T, tool: "pencil", points: [[1, 30]], brush: { image: { rows: ["x.x", ".x."], legend: { x: "#00ff00" } }, center: [0, 0] } });
check("image brush", (await px(main, 1, 30, { layer: "Tools", frame: 2 })) === "#00ff00ff");
const mq = await call("use_tool", { ...T, tool: "rectangular_marquee", points: [[1, 1], [4, 4]] });
check("marquee selection", mq.value.selection?.width === 4, mq.text);
await call("use_tool", { ...T, tool: "no_such_tool", points: [[0, 0]] }, { expectError: true });

// draw_shapes
await call("add_layer", { ...S, name: "Shapes" });
const sh = await call("draw_shapes", {
  ...S, layer: "Shapes", frame: 1,
  shapes: [
    { type: "rect", rect: { x: 0, y: 0, width: 4, height: 4 }, fill: true, color: "#ff0000" },
    { type: "rect", rect: { x: 6, y: 0, width: 5, height: 5 }, color: "#00ff00" },
    { type: "oval", rect: { x: 12, y: 0, width: 8, height: 8 }, fill: true, color: "#0000ff" },
    { type: "rounded_rect", rect: { x: 22, y: 0, width: 9, height: 9 }, radius: 3, fill: true, color: "#ffff00", antialias: true },
    { type: "line", points: [[0, 12], [31, 12]], color: "#ffffff" },
    { type: "polyline", points: [[0, 14], [5, 18], [10, 14]], color: "#ff00ff" },
    { type: "polygon", points: [[12, 14], [20, 14], [16, 20]], fill: true, color: "#00ffff" },
    { type: "bezier", points: [[0, 24], [8, 16], [16, 31], [24, 24]], color: "#ff8800", width: 2 },
    { type: "path", ops: [{ op: "move", x: 26, y: 20 }, { op: "line", x: 31, y: 20 }, { op: "line", x: 31, y: 25 }, { op: "close" }], fill: true, color: "#8888ff" },
  ],
});
check("draw_shapes count", sh.value.drawn === 9, sh.text);
check("shape fill rect", (await px(main, 1, 1, { layer: "Shapes", frame: 1 })) === "#ff0000ff");
check("shape stroke rect edge", (await px(main, 6, 2, { layer: "Shapes", frame: 1 })) === "#00ff00ff");
check("shape stroke rect hollow", (await px(main, 8, 2, { layer: "Shapes", frame: 1 })) === null);
check("shape oval center", (await px(main, 16, 4, { layer: "Shapes", frame: 1 })) === "#0000ffff");
check("shape line", (await px(main, 20, 12, { layer: "Shapes", frame: 1 })) === "#ffffffff");
check("shape polygon", (await px(main, 16, 15, { layer: "Shapes", frame: 1 })) === "#00ffffff");
await call("draw_shapes", { ...S, layer: "Shapes", frame: 1, shapes: [{ type: "star" }] }, { expectError: true });

// draw_text
await call("add_layer", { ...S, name: "Text" });
const dt = await call("draw_text", { ...S, layer: "Text", frame: 3, text: "HI", x: 1, y: 1, color: "#ff0000", font: "builtin" });
check("text builtin", dt.value.font === "builtin" && dt.value.bounds.width === 11 && dt.value.bounds.height === 7, dt.text);
// 'H' = columns 7F 08 08 08 7F: column 0 full, column 1 only row 3.
check("text H col0", (await px(main, 1, 1, { layer: "Text", frame: 3 })) === "#ff0000ff");
check("text H col0 bottom", (await px(main, 1, 7, { layer: "Text", frame: 3 })) === "#ff0000ff");
check("text H col1 gap", (await px(main, 2, 1, { layer: "Text", frame: 3 })) === null);
check("text H bar", (await px(main, 2, 4, { layer: "Text", frame: 3 })) === "#ff0000ff");
const dt2 = await call("draw_text", { ...S, layer: "Text", frame: 3, text: "Ab\ncd", x: 1, y: 12, color: "#00ff00", scale: 2, font: "builtin" });
check("text multiline size", dt2.value.bounds.height === 30, dt2.text);
const dt3 = await call("draw_text", { ...S, layer: "Text", frame: 4, text: "Hello", x: 0, y: 0, font: "Aseprite", color: "#ffffff" });
if (live) check("text Aseprite font (live)", dt3.value.font === "Aseprite", dt3.text);
else check("text falls back in batch", dt3.value.font === "builtin" && !!dt3.value.note, dt3.text);
const meas = await call("draw_text", { ...S, layer: "Text", text: "abc", measureOnly: true, font: "builtin" });
check("measureOnly", meas.value.width === 17 && meas.value.height === 7, meas.text);

// draw_image
await call("add_layer", { ...S, name: "Img" });
await call("draw_image", { ...S, layer: "Img", frame: 1, file: F("fixture.png"), x: 0, y: 0 });
check("draw_image", (await px(main, 3, 3, { layer: "Img", frame: 1 })) === "#ffffffff");
await call("draw_image", { ...S, layer: "Img", frame: 1, file: F("fixture.png"), x: 10, y: 0, scale: 2, sourceRect: { x: 0, y: 0, width: 2, height: 2 } });
check("draw_image scaled crop", (await px(main, 13, 3, { layer: "Img", frame: 1 })) === "#ff0000ff");
check("draw_image scaled crop edge", (await px(main, 14, 0, { layer: "Img", frame: 1 })) === null);
await call("draw_image", { ...S, layer: "Img", frame: 1, file: F("fixture.png"), x: 0, y: 0, mode: "replace" });
check("draw_image replace", (await call("get_cels", { ...S, layer: "Img", frame: 1 })).value[0].bounds.width === 4);
await call("draw_image", { ...S, layer: "Img", frame: 1, file: F("missing.png") }, { expectError: true });
await call("update_layer", { ...S, layer: "Img", visible: false });

// get_pixels formats + composite
const comp = await call("get_pixels", { ...S, frame: 1, rect: { x: 0, y: 0, width: 4, height: 4 }, format: "hex" });
check("composite hex", comp.value.rows.length === 4);
await call("get_pixels", { ...S, frame: 1, rect: { x: 0, y: 0, width: 200, height: 200 }, maxPixels: 100 }, { expectError: true });

// replace_color / apply_filter / clear
const rc = await call("replace_color", { ...S, layer: "Tools", frames: [2], from: "#ffff00", to: "#112233" });
check("replace_color count", rc.value.changedPixels > 0);
check("replace_color pixel", (await px(main, 20, 10, { layer: "Tools", frame: 2 })) === "#112233ff");
const before = await px(main, 1, 1, { layer: "Shapes", frame: 1 });
await call("apply_filter", { ...S, layer: "Shapes", frame: 1, filter: "InvertColor" });
const after = await px(main, 1, 1, { layer: "Shapes", frame: 1 });
check("InvertColor", before === "#ff0000ff" && after === "#00ffffff", `${before} -> ${after}`);
for (const [filter, params] of [
  ["Outline", { color: "#000000", place: "outside", matrix: "circle" }],
  ["BrightnessContrast", { brightness: 20, contrast: 10 }],
  ["HueSaturation", { hue: 30, saturation: 10, lightness: 0, alpha: 0 }],
  ["Despeckle", { width: 3, height: 3 }],
  ["ReplaceColor", { from: "#00ffff", to: "#ff0000", tolerance: 0 }],
  ["ConvolutionMatrix", { fromResource: "blur-3x3" }],
  ["ColorCurve", { curve: "0,0,255,255" }],
]) {
  const r = await call("apply_filter", { ...S, layer: "Tools", frame: 2, filter, params });
  check(`filter ${filter} ran`, r.value.result !== false, r.text);
}
await call("apply_filter", { ...S, filter: "NoSuchFilter" }, { expectError: true });
await call("clear", { ...S, layer: "Shapes", frame: 1, rect: { x: 0, y: 0, width: 4, height: 4 } });
check("clear rect", (await px(main, 1, 1, { layer: "Shapes", frame: 1 })) === null);
await call("clear", { ...S, layer: "Shapes", frame: 1, color: "#010203" });
check("clear with color", (await px(main, 30, 30, { layer: "Shapes", frame: 1 })) === "#010203ff");

// ---------------------------------------------------------------------------
// Cels
const cc = await call("copy_cel", { ...S, fromLayer: "Body", fromFrame: 1, toFrame: 2, x: 5 });
check("copy_cel position", cc.value.bounds.x === 5);
const uc = await call("update_cel", { ...S, layer: "Body", frame: 2, dx: 1, dy: 2, opacity: 128, zIndex: 1, data: "cel data" });
check("update_cel", uc.value.bounds.x === 6 && uc.value.bounds.y === 2 && uc.value.opacity === 128 && uc.value.zIndex === 1 && uc.value.data === "cel data", uc.text);
const gc = await call("get_cels", { ...S, layer: "Body" });
check("get_cels", gc.value.length === 2, gc.text);
await call("delete_cel", { ...S, layer: "Body", frame: 2 });
check("delete_cel", (await call("get_cels", { ...S, layer: "Body" })).value.length === 1);

// Linked cels: continuous layer + copied frame gives links in both modes.
await call("add_layer", { ...S, name: "Cont", continuous: true });
await call("draw_pixels", { ...S, layer: "Cont", frame: 1, pixels: [[0, 0, "#ff0000"]] });
const lk = await call("link_cels", { ...S, layer: "Cont", from: 1, to: 2 }, { expectError: !live });
if (live) check("link_cels linked", lk.value.some((c) => c.linkedFrames), lk.text);


const cels2 = (await call("get_cels", { ...S, layer: "Cont" })).value;
if (live) check("Cont linked", cels2.some((c) => c.linkedFrames?.includes(2)), JSON.stringify(cels2));
const ul2 = await call("link_cels", { ...S, layer: "Cont", action: "unlink", from: 1, to: 2 });
check("unlink", Array.isArray(ul2.value) && ul2.value.every((c) => !c.linkedFrames), ul2.text);

// ---------------------------------------------------------------------------
// Frames
const af = await call("add_frames", { ...S, count: 2, empty: true, durationMs: 250 });
check("add_frames", af.value.frames === 6);
const sd = await call("set_frame_duration", { ...S, from: 1, to: 2, durationMs: 50 });
check("set_frame_duration", sd.value.frameDurationsMs.slice(0, 2).join() === "50,50" && sd.value.frameDurationsMs[5] === 250);
await call("move_frame", { ...S, from: 6, to: 1 });
info = (await call("get_sprite_info", S)).value;
check("move_frame", info.frameDurationsMs[0] === 250 && info.frameDurationsMs[1] === 50, info.frameDurationsMs);
await call("delete_frames", { ...S, frames: [1, 6] });
info = (await call("get_sprite_info", S)).value;
check("delete_frames", info.frames === 4 && info.frameDurationsMs[0] === 50, info.frameDurationsMs);
await call("delete_frames", { ...S, frames: "all" }, { expectError: true });

// ---------------------------------------------------------------------------
// Tags and slices
await call("add_tag", { ...S, name: "walk", from: 1, to: 3, aniDir: "ping_pong", color: "#ff0000", repeats: 2 });
const ut = await call("update_tag", { ...S, tag: "walk", name: "run", aniDir: "reverse", to: 4, data: "tag data" });
check("update_tag", ut.value.name === "run" && ut.value.aniDir === "reverse" && ut.value.to === 4 && ut.value.repeats === 2);
await call("add_tag", { ...S, name: "tmp", from: 2, to: 2 });
await call("delete_tag", { ...S, tag: "tmp" });
info = (await call("get_sprite_info", S)).value;
check("tags", info.tags.map((t) => t.name).join() === "run");
await call("add_slice", { ...S, name: "hit", bounds: { x: 1, y: 1, width: 10, height: 10 }, center: { x: 2, y: 2, width: 6, height: 6 }, pivot: [5, 9] });
const us = await call("update_slice", { ...S, slice: "hit", center: false, bounds: { x: 2, y: 2, width: 12, height: 12 } });
check("update_slice", !us.value.center && us.value.bounds.width === 12, us.text);
const cs = await call("add_slice", { ...S, copyFrom: "hit" });
check("copy slice", cs.value.name === "hit copy" && cs.value.pivot?.x === 5, cs.text);
await call("delete_slice", { ...S, slice: "hit copy" });
info = (await call("get_sprite_info", S)).value;
check("slices", info.slices.map((s) => s.name).join() === "hit");

// ---------------------------------------------------------------------------
// Properties
await call("properties", { ...S, action: "set", target: "layer", layer: "Body", values: { hp: 10, tags: ["a", "b"], pos: { x: 1, y: 2 } } });
const pr = await call("properties", { ...S, target: "layer", layer: "Body" });
check("properties set/get", pr.value.properties.hp === 10 && pr.value.properties.pos?.y === 2, pr.text);
await call("properties", { ...S, action: "delete", target: "layer", layer: "Body", keys: ["hp"] });
check("properties delete", !("hp" in (await call("properties", { ...S, target: "layer", layer: "Body" })).value.properties));
await call("properties", { ...S, action: "set", target: "tag", tag: "run", pluginKey: "seth/test", values: { fps: 12 } });
const pk = await call("properties", { ...S, target: "tag", tag: "run", pluginKey: "seth/test" });
check("plugin properties", pk.value.properties.fps === 12, pk.text);
await call("properties", { ...S, action: "replace", target: "slice", slice: "hit", values: { kind: "hurt" } });
check("properties replace", (await call("properties", { ...S, target: "slice", slice: "hit" })).value.properties.kind === "hurt");
await call("properties", { ...S, target: "cel", layer: "Body", frame: 1 });

// ---------------------------------------------------------------------------
// Palette
const sp = await call("set_palette", { ...S, colors: ["#000000", "#ff0000", "#00ff00", "#0000ff"], replace: true });
check("set_palette", sp.value.size === 4 && sp.value.colors[2] === "#00ff00ff");
check("get_palette", (await call("get_palette", S)).value.colors[3] === "#0000ffff");
await call("save_palette", { ...S, file: F("pal.gpl") });
check("save_palette file", existsSync(F("pal.gpl")));
const preset = await call("set_palette", { ...S, preset: "DB16" });
check("preset DB16", preset.value.size === 16, preset.text);
const fs1 = await call("set_palette", { ...S, fromSprite: true, maxColors: 16 });
check("palette from sprite", fs1.value.size >= 2, fs1.text);
await call("set_palette", { ...S, file: F("pal.gpl") });
check("palette from file", (await call("get_palette", S)).value.size === 4);

// palette_edit on an indexed sprite: pixels must keep their colors.
const idx = F("indexed.aseprite");
await call("new_sprite", { width: 4, height: 4, colorMode: "indexed", palette: ["#000000", "#ff0000", "#00ff00", "#0000ff"], file: idx });
await call("draw_pixels", { sprite: idx, layer: 1, frame: 1, pixels: [[0, 0, 2], [1, 0, 3], [2, 0, 1]] });
const mv = await call("palette_edit", { sprite: idx, action: "move", indices: [2], to: 0 });
check("move palette", mv.value.colors[0] === "#00ff00ff" && mv.value.remappedPixels > 0, mv.text);
check("move keeps pixel color", (await px(idx, 0, 0)) === "#00ff00ff");
await call("palette_edit", { sprite: idx, action: "sort", by: "hue" });
check("sort keeps pixel color", (await px(idx, 1, 0)) === "#0000ffff");
await call("palette_edit", { sprite: idx, action: "reverse" });
check("reverse keeps pixel color", (await px(idx, 2, 0)) === "#ff0000ff");
const add = await call("palette_edit", { sprite: idx, action: "add", colors: ["#ffffff"] });
check("palette add", add.value.size === 5);
const ins = await call("palette_edit", { sprite: idx, action: "insert", at: 0, colors: ["#808080"] });
check("palette insert", ins.value.size === 6 && ins.value.colors[0] === "#808080ff");
check("insert keeps pixel color", (await px(idx, 0, 0)) === "#00ff00ff");
const rmp = await call("palette_edit", { sprite: idx, action: "ramp", fromColor: "#000000", toColor: "#ffffff", steps: 3, insert: true });
check("palette ramp", rmp.value.size === 9 && rmp.value.colors[7] === "#808080ff", rmp.text);
const dd = await call("palette_edit", { sprite: idx, action: "dedupe" });
check("palette dedupe", dd.value.size < 9, dd.text);
const pal = (await call("get_palette", { sprite: idx })).value.colors;
const greenIdx = pal.indexOf("#00ff00ff");
const rm = await call("palette_edit", { sprite: idx, action: "remove", indices: [greenIdx] });
check("palette remove", !rm.value.colors.includes("#00ff00ff"), rm.text);
check("removed color pixel remapped", (await px(idx, 0, 0)) !== null);

// ---------------------------------------------------------------------------
// Selection
const sel = await call("select", { ...S, action: "rect", rect: { x: 2, y: 2, width: 5, height: 5 } });
check("select rect", sel.value.bounds?.width === 5);
const all = await call("select", { ...S, action: "all" });
check("select all", all.value.bounds?.width === 32);
const el = await call("select", { ...S, action: "ellipse", rect: { x: 0, y: 0, width: 9, height: 9 } });
check("select ellipse", el.value.bounds?.width === 9, el.text);
await call("select", { ...S, action: "polygon", points: [[0, 0], [10, 0], [5, 8]] });
const mw = await call("select", { ...S, action: "magic_wand", layer: "Tools", frame: 2, point: [10, 3] });
check("magic_wand", !mw.value.empty, mw.text);
await call("select", { ...S, action: "by_color", layer: "Tools", frame: 2, color: "#abcdef" });
const sc = await call("select", { ...S, action: "content", layer: "FromFile", frame: 1 });
check("select content", sc.value.bounds?.x === 28, sc.text);
await call("select", { ...S, action: "save", file: F("sel.png") });
check("select save png", existsSync(F("sel.png")));
const ld = await call("select", { ...S, action: "load", file: F("fixture.png") });
check("select load png", ld.value.bounds?.width === 4, ld.text);
await call("select", { ...S, action: "save", file: F("sel.msk") });
await call("select", { ...S, action: "load", file: F("sel.msk") });
if (live) {
  await call("select", { ...S, action: "rect", rect: { x: 4, y: 4, width: 4, height: 4 } });
  const md = await call("select", { ...S, action: "modify", modifier: "expand", quantity: 1 });
  check("select modify", md.value.bounds?.width === 6, md.text);
  const mvs = await call("select", { ...S, action: "move", dx: 2, dy: 0 });
  check("select move", mvs.value.bounds?.x === 5, mvs.text);
  await call("select", { ...S, action: "invert" });
  await call("select", { ...S, action: "none" });
  const rs = await call("select", { ...S, action: "reselect" });
  check("reselect", !rs.value.empty, rs.text);
  const g = await call("select", { ...S, action: "get" });
  check("select get", !g.value.empty);
} else {
  for (const action of ["modify", "move", "invert", "none", "reselect", "get"]) await call("select", { ...S, action, quantity: 1 });
}

// selection_edit
if (live) {
  await call("select", { ...S, action: "rect", rect: { x: 0, y: 0, width: 2, height: 2 } });
  await call("selection_edit", { ...S, layer: "Shapes", frame: 2, action: "fill", color: "#ff00ff" });
  check("selection fill", (await px(main, 1, 1, { layer: "Shapes", frame: 2 })) === "#ff00ffff");
  await call("selection_edit", { ...S, layer: "Shapes", frame: 2, action: "copy" });
  await call("selection_edit", { ...S, layer: "Shapes", frame: 2, action: "paste", x: 10, y: 10 });
  check("paste", (await px(main, 10, 10, { layer: "Shapes", frame: 2 })) === "#ff00ffff");
  await call("select", { ...S, action: "rect", rect: { x: 20, y: 20, width: 4, height: 4 } });
  await call("selection_edit", { ...S, layer: "Shapes", frame: 2, action: "stroke", color: "#00ff00" });
  check("stroke", (await px(main, 20, 21, { layer: "Shapes", frame: 2 })) === "#00ff00ff");
  await call("selection_edit", { ...S, layer: "Shapes", frame: 2, action: "delete" });
  check("delete selection", (await px(main, 20, 21, { layer: "Shapes", frame: 2 })) === null);
  await call("select", { ...S, action: "rect", rect: { x: 0, y: 0, width: 2, height: 2 } });
  await call("selection_edit", { ...S, layer: "Shapes", frame: 2, action: "move_content", dx: 3, dy: 0 });
  check("move_content", (await px(main, 4, 1, { layer: "Shapes", frame: 2 })) === "#ff00ffff");
  await call("selection_edit", { ...S, layer: "Shapes", frame: 2, action: "move_bounds", dx: 1, dy: 1 });
  await call("selection_edit", { ...S, layer: "Shapes", frame: 2, action: "copy_merged" });
  await call("selection_edit", { ...S, layer: "Shapes", frame: 2, action: "new_layer_via_copy" });
  await call("selection_edit", { ...S, layer: "Shapes", frame: 2, action: "cut" });
  await call("selection_edit", { ...S, layer: "Shapes", frame: 2, action: "new_layer_via_cut" });
  await call("select", { ...S, action: "rect", rect: { x: 0, y: 0, width: 6, height: 5 } });
  const nsel = await call("selection_edit", { ...S, layer: "Shapes", frame: 2, action: "new_sprite" });
  check("new_sprite from selection", nsel.value.sprite?.width === 6 && nsel.value.sprite.filename !== main, nsel.text);
  await call("close_sprite", { sprite: nsel.value.sprite.id, discardChanges: true });
  check("main still open", (await call("list_sprites")).value.some((s) => s.filename.toLowerCase() === main.toLowerCase()));
} else {
  await call("selection_edit", { ...S, layer: "Shapes", frame: 2, action: "copy" });
}

// ---------------------------------------------------------------------------
// Whole-sprite transforms on a duplicate
const dup = F("dup.aseprite");
const ds = await call("duplicate_sprite", { ...S, file: dup });
check("duplicate_sprite", ds.value.frames === 4);
const D = { sprite: dup };
const beforeFlip = await px(dup, 28, 28, { layer: "FromFile", frame: 1 });
await call("flip_rotate", { ...D, target: "sprite", flip: "horizontal" });
check("flip sprite", (await px(dup, 3, 28, { layer: "FromFile", frame: 1 })) === beforeFlip, beforeFlip);
await call("flip_rotate", { ...D, target: "sprite", rotate: 180 });
check("rotate 180", (await px(dup, 28, 3, { layer: "FromFile", frame: 1 })) === beforeFlip);
await call("flip_rotate", { ...D, target: "sprite", flip: "vertical" });
await call("flip_rotate", { ...D, target: "cel", layer: "FromFile", frame: 1, flip: "horizontal" });
await call("flip_rotate", { ...D, target: "cel", layer: "FromFile", frame: 1, rotate: 90 });
if (live) {
  await call("select", { ...D, action: "rect", rect: { x: 0, y: 0, width: 8, height: 8 } });
  await call("flip_rotate", { ...D, target: "selection", layer: "Tools", frame: 2, flip: "vertical" });
  await call("select", { ...D, action: "none" });
}
const rz = await call("resize_sprite", { ...D, scale: 2, method: "nearest" });
check("resize", rz.value.width === 64);
const cv = await call("canvas_size", { ...D, width: 80, height: 70, anchor: "top_left" });
check("canvas_size", cv.value.width === 80 && cv.value.height === 70);
const cv2 = await call("canvas_size", { ...D, left: -8, right: 0, top: 0, bottom: -6 });
check("canvas margins", cv2.value.width === 72 && cv2.value.height === 64, cv2.text);
const cr = await call("crop_sprite", { ...D, rect: { x: 0, y: 0, width: 64, height: 64 } });
check("crop rect", cr.value.width === 64);
await call("crop_sprite", { ...D, mode: "auto" });
const cm = await call("change_color_mode", { ...D, mode: "indexed", dithering: "ordered" });
check("to indexed", cm.value.colorMode === "indexed");
const cg = await call("change_color_mode", { ...D, mode: "gray" });
check("to gray", cg.value.colorMode === "gray");
await call("change_color_mode", { ...D, mode: "rgb" });
const mdn = await call("merge_layers", { ...D, layer: "Body", mode: "down" });
check("merge down", !mdn.value.layers.includes("Body"), mdn.text);
await call("merge_layers", { ...D, mode: "visible" });
const fl = await call("merge_layers", { ...D, mode: "flatten" });
check("flatten", fl.value.layers.length === 1, fl.text);
const cb = await call("convert_layer", { ...D, layer: 1, to: "background" });
check("to background", cb.value.background === true, cb.text);
const cl = await call("convert_layer", { ...D, layer: 1, to: "layer" });
check("from background", !cl.value.background, cl.text);
const ct = await call("convert_layer", { ...D, layer: 1, to: "tilemap" });
check("to tilemap", ct.value.type === "tilemap", ct.text);
const ci = await call("convert_layer", { ...D, layer: 1, to: "image" });
check("to image", ci.value.type === "image", ci.text);

// ---------------------------------------------------------------------------
// Tilesets and tilemaps
const tm = F("tiles.aseprite");
await call("new_sprite", { width: 32, height: 32, file: tm });
const TM = { sprite: tm };
const tl = await call("add_layer", { ...TM, type: "tilemap", name: "Map", tileSize: { width: 8, height: 8 } });
check("tilemap layer", tl.value.type === "tilemap");
check("tileset list", (await call("tileset", { ...TM, action: "list" })).value.length === 1);
await call("tileset", { ...TM, action: "update", tileset: 1, name: "ground", baseIndex: 1, data: "ts data" });
check("tileset name", (await call("tileset", { ...TM, action: "list" })).value[0].name === "ground");
await call("tileset", { ...TM, action: "add_tile", tileset: "ground" });
await call("tileset", { ...TM, action: "add_tile", tileset: "ground" });
await call("tileset", { ...TM, action: "set_tile", tileset: "ground", index: 1, rows: ["xxxxxxxx", "x......x", "x......x", "x......x", "x......x", "x......x", "x......x", "xxxxxxxx"], legend: { x: "#ffffff" } });
await call("tileset", { ...TM, action: "set_tile", tileset: "ground", index: 2, file: F("fixture.png") });
const gt = await call("tileset", { ...TM, action: "get_tile", tileset: "ground", index: 1 });
check("get_tile", gt.value.rows[1] === "a......a", gt.text);
await call("tilemap", { ...TM, layer: "Map", frame: 1, action: "set", rows: [[1, 2, 1], [null, 1, -1]], col: 0, row: 0 });
const tg = await call("tilemap", { ...TM, layer: "Map", frame: 1 });
check("tilemap get", tg.value.rows[0].slice(0, 3).join() === "1,2,1" && tg.value.rows[1][1] === 1 && tg.value.rows[1][0] === 0, tg.text);
check("tilemap renders tile", (await px(tm, 0, 0)) === "#ffffffff");
check("tilemap renders tile 2", (await px(tm, 8, 0)) === "#ff0000ff");
await call("tileset", { ...TM, action: "delete_tile", tileset: "ground", index: 2 });
check("delete_tile", (await call("tileset", { ...TM, action: "list" })).value[0].tiles === 2);
const at = await call("tileset", { ...TM, action: "add", tileSize: { width: 16, height: 16 }, name: "big" });
check("tileset add", at.value.tileSize.width === 16);
await call("tileset", { ...TM, action: "delete", tileset: "big" });
check("tileset delete", (await call("tileset", { ...TM, action: "list" })).value.length === 1);
await call("properties", { ...TM, action: "set", target: "tile", tileset: 1, index: 1, values: { solid: true } });
check("tile property", (await call("properties", { ...TM, target: "tile", tileset: 1, index: 1 })).value.properties.solid === true);
await call("export_sprite_sheet", { ...TM, textureFilename: F("tileset.png"), dataFilename: F("tileset.json"), fromTilesets: true });
check("tileset export", existsSync(F("tileset.png")));

// ---------------------------------------------------------------------------
// Preferences and view settings
const pg = await call("preferences", { action: "get", section: "general", option: "screen_scale" });
check("preferences get", typeof pg.value.value === "number");
const ps = await call("preferences", { action: "set", section: "tool.brush", tool: "pencil", option: "size", value: 3 });
check("tool preference", ps.value.value === 3, ps.text);
await call("preferences", { action: "set", section: "tool.brush", tool: "pencil", option: "size", value: 1 });
await call("preferences", { action: "get", section: "nonexistent_section", option: "x" }, { expectError: true });
const vs = await call("view_settings", {
  ...S,
  grid: { show: true, snap: true, bounds: { x: 0, y: 0, width: 4, height: 4 }, opacity: 100 },
  pixelGrid: { show: true },
  symmetry: { mode: "vertical", x: 16 },
  tiledMode: "both",
  onionSkin: { active: true, prevFrames: 2, nextFrames: 0, type: "red_blue_tint" },
  show: { layerEdges: true, slices: false },
  background: { color1: "#202020", color2: "#404040", size: 4 },
});
check("view grid", vs.value.grid.show === true && vs.value.grid.snap === true && vs.value.grid.bounds.width === 4, vs.text);
check("view symmetry", vs.value.symmetry.mode === "vertical" && vs.value.symmetry.x === 16, vs.text);
check("view tiled", vs.value.tiledMode === "both");
check("view onion", vs.value.onionSkin.active === true && vs.value.onionSkin.prevFrames === 2);
check("view show", vs.value.show.layerEdges === true && vs.value.show.slices === false);
if (live) {
  const vz = await call("view_settings", { ...S, zoom: 4, scroll: [16, 16], timeline: true });
  check("view zoom", vz.value.zoom === 4, vz.text);
  await call("view_settings", { ...S, fitScreen: true });
  await call("view_settings", { ...S, playback: "play" });
  await call("view_settings", { ...S, playback: "stop" });
  await call("view_settings", { ...S, togglePreview: true });
  await call("view_settings", { ...S, togglePreview: true });
} else {
  await call("view_settings", { ...S, zoom: 2 }, { expectError: true });
}
await call("view_settings", { ...S, grid: { show: false, snap: false }, pixelGrid: { show: false }, symmetry: { mode: "none" }, tiledMode: "none", onionSkin: { active: false }, show: { layerEdges: false, slices: true } });

// ---------------------------------------------------------------------------
// Clipboard (restores the user's clipboard text afterwards)
const original = (await call("clipboard", { action: "info" })).value;
await call("clipboard", { action: "set_text", text: "aseprite-mcp test" });
check("clipboard text", (await call("clipboard", { action: "get_text" })).value.text === "aseprite-mcp test");
await call("clipboard", { action: "set_image", sprite: main, layer: "FromFile", frame: 1, rect: { x: 28, y: 28, width: 4, height: 4 } });
const ci1 = await call("clipboard", { action: "get_image" });
check("clipboard image preview", ci1.images.length === 1 && ci1.value.width === 4, ci1.text);
await call("clipboard", { action: "get_image", file: F("clip.png") });
check("clipboard image file", existsSync(F("clip.png")));
await call("clipboard", { action: "set_image", file: F("fixture.png") });
await call("clipboard", { action: "clear" });
if (original.hasText && typeof original.text === "string") await call("clipboard", { action: "set_text", text: original.text });

// ---------------------------------------------------------------------------
// Rendering and export
const rp = await call("render_preview", { ...S, frames: "all" });
check("render_preview image", rp.images.length === 1 && rp.value.frames.length === 4);
const rp2 = await call("render_preview", { ...S, frame: 1, layer: "FromFile", crop: { x: 24, y: 24, width: 8, height: 8 }, checkerboard: false });
check("render_preview crop", rp2.value.width === 8, rp2.text);
await call("render_preview", { ...S, tag: "run" });
await call("export", { ...S, file: F("anim.gif"), scale: 2 });
check("export gif", existsSync(F("anim.gif")));
const ef = await call("export", { ...S, file: F("f_{frame}.png"), layers: ["FromFile"] });
check("export frames (0-based)", existsSync(F("f_0.png")) && existsSync(F("f_3.png")) && ef.value.files.length === 4, ef.text);
await call("export", { ...S, file: F("tag.gif"), tag: "run" });
check("export tag", existsSync(F("tag.gif")));
const es = await call("export", { ...S, file: F("slice.png"), slice: "hit" });
check("export slice (numbered per frame)", es.value.files.length === 4 && existsSync(F("slice1.png")), es.text);
const es1 = await call("export", { ...S, file: F("slice_one.png"), slice: "hit", fromFrame: 1, toFrame: 1 });
check("export slice single frame", existsSync(F("slice_one.png")) && es1.value.files.length === 1, es1.text);
const want = await px(main, 3, 12, { layer: "Tools", frame: 2 });
const fr2 = await call("export", { ...S, file: F("frame_two.png"), fromFrame: 2, toFrame: 2, layers: ["Tools"] });
check("export frame 2 only", fr2.value.files.length === 1, fr2.text);
const fr2open = await call("get_pixels", { sprite: F("frame_two.png"), rect: { x: 3, y: 12, width: 1, height: 1 }, format: "hex" });
check("exported frame is frame 2", want && fr2open.value.rows[0][0] === want, `${want} vs ${fr2open.text}`);
const fr3 = await call("export", { ...S, file: F("range23.png"), fromFrame: 2, toFrame: 3 });
check("export range 2-3 numbered from 23", fr3.value.files.length === 2 && fr3.value.files[1].endsWith("range24.png"), fr3.text);
await call("export", { ...S, file: F("range.webp"), fromFrame: 2, toFrame: 3 });
check("export range", existsSync(F("range.webp")));
await call("export_sprite_sheet", { ...S, textureFilename: F("sheet.png"), dataFilename: F("sheet.json"), type: "rows", columns: 2, dataFormat: "json-array", listTags: true, listSlices: true, listLayers: true, borderPadding: 1, shapePadding: 1 });
const sheet = JSON.parse(readFileSync(F("sheet.json"), "utf8"));
check("sheet json frames", sheet.frames.length === 4 && sheet.meta.frameTags.length === 1 && sheet.meta.slices.length === 1, JSON.stringify(sheet.meta).slice(0, 200));
await call("export_sprite_sheet", { ...S, textureFilename: F("split.png"), dataFilename: F("split.json"), splitLayers: true, type: "packed", trim: true });
check("split sheet", existsSync(F("split.png")));
const imp = await call("import_sprite_sheet", { file: F("sheet.png"), frameWidth: 32, frameHeight: 32, x: 1, y: 1, padding: 1, type: "rows", saveAs: F("imported.aseprite") });
check("import_sprite_sheet", imp.value.frames === 4, imp.text);

// save / close
const sc2 = await call("save_sprite", { ...S, file: F("copy.png"), copy: true });
check("save copy (numbered per frame)", sc2.value.files.length === 4 && existsSync(F("copy1.png")), sc2.text);
const sv = await call("save_sprite", { ...S });
check("save in place", sv.value.saved.toLowerCase() === main.toLowerCase());
await call("save_sprite", { sprite: dup, file: F("dup2.aseprite") });
check("save as", existsSync(F("dup2.aseprite")));

// ---------------------------------------------------------------------------
// Generic access
const rl = await call("run_lua", { ...S, code: "print('n', #sprite.layers) return { frames = #sprite.frames, x = args.x }", args: { x: 5 }, mutates: false });
check("run_lua", rl.value.frames === 4 && rl.value.x === 5 && /^n\t\d+$/.test(rl.raw.output?.[0] ?? ""), rl.text);
await call("run_lua", { code: "error('boom')" }, { expectError: true });
await call("run_lua", { code: "this is not lua" }, { expectError: true });
const cmd = await call("run_command", { sprite: dup, name: "Flip", params: { target: "canvas", orientation: "horizontal" } });
check("run_command Flip", cmd.value.result === true, cmd.text);
await call("run_command", { name: "NoSuchCommand" }, { expectError: true });
const cli = await call("cli", { args: [main, "--list-layers", "--list-tags", "--data", F("cli.json"), "--format", "json-array", "--sheet", F("cli.png")] });
check("cli", cli.value.exitCode === 0 && existsSync(F("cli.json")));
await call("cli", { args: ["no-such-file.aseprite", "--save-as", F("x.png")] }, { expectError: false });

// ---------------------------------------------------------------------------
// Live-only: active state, undo, events, ask_user
if (live) {
  const sa = await call("set_active", { ...S, layer: "Body", frame: 2, fgColor: "#ff0000", bgColor: "#0000ff", tool: "pencil", brush: { type: "square", size: 3 } });
  check("set_active", sa.value.activeLayer === "Body" && sa.value.activeFrame === 2 && sa.value.fgColor === "#ff0000ff" && sa.value.tool === "pencil" && sa.value.brush?.size === 3, sa.text);
  const rg = await call("set_active", { ...S, range: { frames: [1, 2, 3] } });
  check("set range", rg.value.range?.frames?.length === 3, rg.text);
  const rev = await call("run_command", { ...S, name: "ReverseFrames" });
  check("ReverseFrames with range", rev.value.result !== false, rev.text);
  await call("set_active", { ...S, zoom: 2 });

  await call("draw_pixels", { ...S, layer: "Body", frame: 1, pixels: [[31, 0, "#00ff00"]] });
  check("before undo", (await px(main, 31, 0, { layer: "Body", frame: 1 })) === "#00ff00ff");
  await call("undo_redo", { ...S, action: "undo" });
  check("undo", (await px(main, 31, 0, { layer: "Body", frame: 1 })) === null);
  const rd = await call("undo_redo", { ...S, action: "redo" });
  check("redo", (await px(main, 31, 0, { layer: "Body", frame: 1 })) === "#00ff00ff" && rd.value.redoSteps >= 0);

  const ev0 = await call("recent_events", { includeMcp: true });
  await call("run_command", { ...S, name: "Flip", params: { target: "canvas", orientation: "vertical" } });
  const ev1 = await call("recent_events", { since: ev0.value.lastSeq, includeMcp: true });
  check("events recorded", ev1.value.events.some((e) => e.type === "command" && e.name === "Flip") && ev1.value.events.some((e) => e.type === "sprite_change"), ev1.text);
  check("events marked as MCP", ev1.value.events.every((e) => e.byMcp), ev1.text);
  const ev2 = await call("recent_events", { since: ev0.value.lastSeq });
  check("events hide MCP by default", ev2.value.events.length === 0, ev2.text);

  // Without anyone clicking: the dialog must close itself and still return field values.
  const askT = await call("ask_user", { title: "MCP test", text: "This closes by itself", fields: [{ id: "name", type: "entry", value: "pixel" }, { id: "n", type: "number", value: 7 }, { id: "c", type: "color", value: "#ff0000" }, { id: "ok", type: "check", value: true }], timeoutSeconds: 3 });
  check("ask_user timeout", askT.value.timedOut === true && askT.value.values.name === "pixel" && askT.value.values.n === 7 && askT.value.values.c === "#ff0000ff" && askT.value.values.ok === true, askT.text);
  if (process.env.ASK_USER === "1") {
    const ask = await call("ask_user", { title: "MCP test", text: "Click OK", fields: [{ id: "name", type: "entry", value: "pixel" }, { id: "c", type: "color", value: "#ff0000" }], timeoutSeconds: 120 }, { timeout: 130_000 });
    check("ask_user", ask.value.button === "OK" && ask.value.values.name === "pixel" && ask.value.values.c === "#ff0000ff", ask.text);
  } else {
    console.log("skip clicking ask_user (set ASK_USER=1 and click OK in Aseprite to test the button path)");
  }
  const close = await call("close_sprite", { sprite: dup, discardChanges: true });
  check("close_sprite", !!close.value.closed);
  check("closed sprite gone", !(await call("list_sprites")).value.some((s) => s.filename.toLowerCase() === dup.toLowerCase()));
  await call("close_sprite", { sprite: main }, { expectError: true }); // unsaved changes
} else {
  await call("set_active", { ...S, layer: "Body", frame: 2, fgColor: "#ff0000" });
  await call("undo_redo", { ...S, action: "undo" });
  await call("recent_events", {}, { expectError: true });
  await call("ask_user", { text: "x" }, { expectError: true });
  const cs2 = await call("close_sprite", { sprite: main });
  check("close_sprite batch", !!cs2.value.closed, cs2.text);
}

// ---------------------------------------------------------------------------
if (!live) called.add("launch_aseprite"); // GUI only; exercised by the live run
const uncalled = allTools.filter((t) => !called.has(t));
console.log(`\n${allTools.length} tools, ${called.size} called, ${checks} checks`);
if (uncalled.length) {
  failures.push(`never called: ${uncalled.join(", ")}`);
  console.log(`NEVER CALLED: ${uncalled.join(", ")}`);
}
console.log(`output: ${dir}`);
if (failures.length) {
  console.log(`\n${failures.length} FAILURES:\n- ${failures.join("\n- ")}`);
} else {
  console.log("all passed");
}
await client.close();
process.exit(failures.length ? 1 : 0);
