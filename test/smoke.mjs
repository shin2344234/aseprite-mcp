// End-to-end check: starts the MCP server over stdio and exercises the tools.
// Usage: node test/smoke.mjs [batch|live]   (default batch)
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { mkdirSync, rmSync, writeFileSync, existsSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const backend = process.argv[2] ?? "batch";
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const dir = path.join(os.tmpdir(), "aseprite-mcp-smoke");
rmSync(dir, { recursive: true, force: true });
mkdirSync(dir, { recursive: true });
const file = path.join(dir, "hero.aseprite");

const transport = new StdioClientTransport({ command: process.execPath, args: [path.join(root, "dist", "index.js")], cwd: dir, stderr: "inherit" });
const client = new Client({ name: "smoke", version: "0" });
await client.connect(transport);

const tools = (await client.listTools()).tools;
console.log(`${tools.length} tools`);

let failures = 0;
async function call(name, args = {}, { expectError = false } = {}) {
  const r = await client.callTool({ name, arguments: { backend, ...args } });
  const txt = r.content.filter((c) => c.type === "text").map((c) => c.text).join("\n");
  const ok = !r.isError === !expectError;
  if (!ok) failures++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}: ${txt.slice(0, 300).replace(/\s+/g, " ")}`);
  for (const c of r.content) {
    if (c.type === "image") writeFileSync(path.join(dir, `${name}-${Date.now()}.png`), Buffer.from(c.data, "base64"));
  }
  return r;
}

const S = { sprite: file };
if (backend === "live") {
  const r = await client.callTool({ name: "launch_aseprite", arguments: { waitSeconds: 120 } });
  console.log("launch_aseprite:", r.content[0].text);
}
await call("status", {});
await call("new_sprite", { width: 24, height: 24, frames: 3, frameDurationMs: 100, file });
await call("add_layer", { ...S, name: "Body" });
await call("add_layer", { ...S, name: "FX", type: "group" });
await call("add_layer", { ...S, name: "Glow", parent: "FX", blendMode: "screen", opacity: 180 });
await call("draw_pixels", {
  ...S, layer: "Body", frame: 1, x: 8, y: 6,
  rows: ["..kkkk..", ".kssssk.", "kssssssk", "ksskksk.", "kssssssk", ".kssssk.", "..k..k..", ".kk..kk."],
  legend: { k: "#1a1c2c", s: "#f4b41b" },
});
await call("use_tool", { ...S, layer: "Layer 1", frame: 1, tool: "filled_rectangle", points: [[0, 20], [23, 23]], color: "#38b764" });
await call("use_tool", { ...S, layer: "Layer 1", frame: 1, tool: "ellipse", points: [[2, 2], [7, 7]], color: "#ef7d57" });
await call("use_tool", { ...S, layer: "Glow", frame: 1, tool: "pencil", points: [[1, 12], [5, 16]], color: "#ffffff", brushSize: 2 });
await call("copy_cel", { ...S, fromLayer: "Body", fromFrame: 1, toFrame: 2, x: 9 });
await call("copy_cel", { ...S, fromLayer: "Body", fromFrame: 1, toFrame: 3, x: 10 });
await call("update_cel", { ...S, layer: "Body", frame: 3, dy: -1 });
await call("add_tag", { ...S, name: "walk", from: 1, to: 3, aniDir: "ping_pong", color: "#5d275d" });
await call("add_slice", { ...S, name: "hitbox", bounds: { x: 8, y: 6, width: 8, height: 8 }, pivot: [4, 7], center: { x: 1, y: 1, width: 6, height: 6 } });
await call("set_frame_duration", { ...S, frames: [2], durationMs: 200 });
await call("get_pixels", { ...S, layer: "Body", frame: 1, rect: { x: 8, y: 6, width: 8, height: 8 } });
await call("get_pixels", { ...S, frame: 1, rect: { x: 0, y: 19, width: 6, height: 2 }, format: "hex" });
await call("replace_color", { ...S, layer: "Body", frames: "all", from: "#f4b41b", to: "#a7f070" });
await call("apply_filter", { ...S, layer: "Body", frame: 1, filter: "Outline", params: { color: "#ff004d", place: "outside", matrix: "circle" } });
await call("get_sprite_info", S);
await call("render_preview", { ...S, frames: "all" });
await call("render_preview", { ...S, frame: 1, layer: "Body", maxSize: 256 });
await call("duplicate_layer", { ...S, layer: "Body", name: "Body copy" });
await call("update_layer", { ...S, layer: "Body copy", visible: false, color: "#41a6f6", data: "hidden copy" });
await call("flip_rotate", { ...S, target: "cel", layer: "Body copy", frame: 1, flip: "horizontal" });
await call("delete_layer", { ...S, layer: "Body copy" });
await call("add_frames", { ...S, count: 1, empty: true });
await call("move_frame", { ...S, from: 4, to: 1 });
await call("delete_frames", { ...S, frame: 1 });
await call("set_palette", { ...S, colors: ["#1a1c2c", "#5d275d", "#b13e53", "#ef7d57"], replace: true });
await call("get_palette", S);
await call("export", { ...S, file: path.join(dir, "hero.gif"), scale: 4 });
await call("export", { ...S, file: path.join(dir, "frame_{frame}.png"), layers: ["Body"] });
await call("export_sprite_sheet", { ...S, textureFilename: path.join(dir, "sheet.png"), dataFilename: path.join(dir, "sheet.json"), type: "rows", columns: 2, listTags: true, listSlices: true });
await call("run_command", { ...S, name: "ReverseFrames", params: {} });
await call("run_lua", { ...S, code: "print('layers', #sprite.layers) return { frames = #sprite.frames, tags = #sprite.tags, arg = args.x }", args: { x: 7 } });
await call("run_lua", { ...S, code: "error('boom')" }, { expectError: true });
await call("change_color_mode", { ...S, mode: "indexed", dithering: "ordered" });
await call("get_pixels", { ...S, frame: 2, rect: { x: 8, y: 6, width: 8, height: 4 } });
await call("change_color_mode", { ...S, mode: "rgb" });
await call("resize_sprite", { ...S, scale: 2 });
await call("canvas_size", { ...S, width: 64, height: 64, anchor: "bottom" });
await call("crop_sprite", { ...S, mode: "auto" });
await call("add_layer", { ...S, type: "tilemap", name: "Tiles", tileSize: { width: 8, height: 8 } });
await call("tileset", { ...S, action: "list" });
await call("tileset", { ...S, action: "add_tile", tileset: 1 });
await call("tileset", { ...S, action: "set_tile", tileset: 1, index: 1, rows: ["xxxxxxxx", "x......x", "x......x", "xxxxxxxx"], legend: { x: "#ffffff" } });
await call("tilemap", { ...S, layer: "Tiles", frame: 1, action: "set", cells: [{ col: 0, row: 0, tile: 1 }, { col: 1, row: 1, tile: 1 }] });
await call("tilemap", { ...S, layer: "Tiles", frame: 1 });
await call("tileset", { ...S, action: "get_tile", tileset: 1, index: 1 });
await call("preferences", { action: "get", section: "general", option: "screen_scale" });
await call("list_commands", { query: "outline" });
await call("api_docs", { topic: "tag" });
await call("cli", { args: [file, "--list-tags", "--list-layers", "--format", "json-array", "--data", path.join(dir, "cli.json"), "--sheet", path.join(dir, "cli.png")] });
await call("open_sprite", { file: path.join(dir, "hero.gif") });
await call("get_sprite_info", { sprite: "missing.aseprite" }, { expectError: true });

console.log(`\nfiles: ${dir}`);
for (const f of ["hero.gif", "frame_1.png", "sheet.png", "sheet.json", "cli.png"]) console.log(`${existsSync(path.join(dir, f)) ? "exists " : "MISSING"} ${f}`);
console.log(failures ? `${failures} FAILURES` : "all passed");
await client.close();
process.exit(failures ? 1 : 0);
