#!/usr/bin/env node
import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { cp, mkdir, mkdtemp, readFile, readdir, rm, stat } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js";
import { z } from "zod";
import { callBatch, requireAseprite, runCli, type RuntimeResponse } from "./batch.js";
import { Bridge } from "./bridge.js";
import { DATA_DIR, EXTENSION_DIR, EXTENSION_NAME, WORK_DIR, findAseprite, userConfigDir } from "./config.js";
import { upscalePng } from "./images.js";

const VERSION = "0.1.0";
const bridge = new Bridge();

const INSTRUCTIONS = `Controls Aseprite (pixel art editor) through its Lua scripting API.

Two backends:
- live: a running Aseprite GUI with the bridge extension connected. Changes show up on screen, the active sprite/layer/frame/selection persist between calls, undo works. Start it with launch_aseprite.
- batch: a headless "aseprite -b" process per call. Pass 'sprite' as a file path; mutating tools save the file back (set save=false to skip). Selection, undo history and unsaved sprites do not survive between batch calls.
'auto' (default) uses live when connected, else batch.

Conventions: coordinates are canvas pixels with (0,0) at top-left. Frames, layer indices and tag/slice indices are 1-based; palette indices are 0-based.
Colors: "#rrggbb", "#rrggbbaa", names (red, transparent...), a palette index number, or {r,g,b,a}.
Layers: name, "Group/Child" path, or the index from get_sprite_info.

Workflow tips: get_sprite_info to learn the structure; render_preview to look at the result; get_pixels returns a compact character grid + legend, and draw_pixels accepts the same rows+legend format for pixel art. use_tool runs any Aseprite tool (pencil, line, rectangle, ellipse, paint_bucket, spray, gradient, contour, polygon, curve, blur, jumble, marquee tools...).
Anything not covered by a dedicated tool: run_command executes any of the ~180 menu commands (list_commands shows names and params), and run_lua runs arbitrary Lua with the full API (api_docs has the reference).`;

const server = new McpServer({ name: "aseprite", version: VERSION }, { instructions: INSTRUCTIONS });

// ---------------------------------------------------------------------------
// Shared schema pieces

const backend = z
  .enum(["auto", "live", "batch"])
  .optional()
  .describe("auto (default): live Aseprite if connected, else headless batch");
const spriteRef = z
  .union([z.string(), z.number().int()])
  .optional()
  .describe("File path, open tab title, or sprite id. Defaults to the active sprite (live). Batch mode needs a file path.");
const layerRef = z
  .union([z.string(), z.number().int()])
  .optional()
  .describe("Layer name, 'Group/Child' path, or 1-based index from get_sprite_info. Defaults to the active layer.");
const frameRef = z.number().int().min(1).optional().describe("1-based frame number. Defaults to the active frame (or 1).");
const color = z
  .union([z.string(), z.number(), z.record(z.any())])
  .describe("'#rrggbb', '#rrggbbaa', a name, a palette index, or {r,g,b,a} / {h,s,v,a} / {h,s,l,a} / {gray,a}");
const rect = z.object({ x: z.number().int(), y: z.number().int(), width: z.number().int(), height: z.number().int() });
const point = z.union([z.tuple([z.number(), z.number()]), z.object({ x: z.number(), y: z.number() })]);
const imageSpec = z
  .union([z.string(), z.object({ file: z.string().optional(), rows: z.array(z.string()).optional(), legend: z.record(z.any()).optional() })])
  .describe("An image file path, or {rows, legend} pixel art like draw_pixels");
const brushSchema = z
  .object({
    type: z.enum(["circle", "square", "line"]).optional(),
    size: z.number().int().min(1).optional(),
    angle: z.number().optional(),
    image: imageSpec.optional().describe("Custom image brush (replaces type/size)"),
    center: point.optional().describe("Brush hotspot, relative to the brush image"),
    pattern: z.enum(["none", "origin", "target"]).optional().describe("Image brush pattern alignment"),
    patternOrigin: point.optional(),
  })
  .describe("Brush: built-in shape and size, or a custom image brush");
const save = z.boolean().optional().describe("Batch mode: write changes back to the sprite file (default true)");
const properties = z.record(z.any()).optional().describe("User-defined properties to set (object.properties)");
const frameRange = {
  frame: frameRef,
  frames: z.union([z.literal("all"), z.array(z.number().int().min(1))]).optional().describe("'all' or a list of frame numbers"),
  from: z.number().int().min(1).optional().describe("First frame of a range"),
  to: z.number().int().min(1).optional().describe("Last frame of a range"),
  tag: z.string().optional().describe("Use the frames of this tag"),
};

// ---------------------------------------------------------------------------
// Invocation

type Backend = "auto" | "live" | "batch";

const PATH_KEYS = new Set(["file", "out", "textureFilename", "dataFilename", "saveAs"]);
const SPRITE_EXT = /\.(aseprite|ase|png|gif|jpe?g|bmp|webp|tga|pcx|ico|fli|flc|qoi|svg|css|psd|tif|tiff)$/i;

/** Makes file arguments absolute (relative to WORK_DIR), including nested image specs like brush.image.file. */
function resolvePaths(args: Record<string, unknown>, depth = 0): Record<string, unknown> {
  const out: Record<string, unknown> = { ...args };
  for (const [k, v] of Object.entries(out)) {
    if (typeof v === "string" && v !== "") {
      const isPath =
        PATH_KEYS.has(k) ||
        (k === "image" && depth <= 1) ||
        (depth === 0 && (k === "sprite" || k === "fromSprite") && (/[\\/]/.test(v) || SPRITE_EXT.test(v)));
      if (isPath) out[k] = path.resolve(WORK_DIR, v);
    } else if (v && typeof v === "object" && !Array.isArray(v) && depth < 2 && (k === "image" || k === "brush")) {
      out[k] = resolvePaths(v as Record<string, unknown>, depth + 1);
    }
  }
  return out;
}

async function invoke(tool: string, args: Record<string, unknown>, which: Backend = "auto"): Promise<RuntimeResponse> {
  if (which === "live" || (which === "auto" && bridge.connected)) {
    if (!bridge.connected) {
      return { ok: false, error: "No live Aseprite is connected. Run launch_aseprite, or use backend='batch'." };
    }
    return bridge.call(tool, args);
  }
  return callBatch(tool, args);
}

function text(value: unknown): CallToolResult {
  return { content: [{ type: "text", text: typeof value === "string" ? value : JSON.stringify(value) }] };
}

function errorResult(message: string): CallToolResult {
  return { isError: true, content: [{ type: "text", text: message }] };
}

function toResult(r: RuntimeResponse): CallToolResult {
  if (!r.ok) {
    let msg = `Error: ${r.error ?? "unknown error"}`;
    if (r.output?.length) msg += `\nOutput:\n${r.output.join("\n")}`;
    if (r.traceback) msg += `\n${r.traceback}`;
    return errorResult(msg);
  }
  if (r.output?.length || r.saved?.length || r.warning) {
    return text({ result: r.result ?? null, output: r.output, saved: r.saved, warning: r.warning });
  }
  return text(r.result ?? null);
}

interface ToolOpts {
  handler?: string;
  readOnly?: boolean;
  destructive?: boolean;
  title?: string;
  /** Argument naming an output file; the result lists every file the call wrote next to it. */
  outputKey?: string;
}

async function snapshotDir(dir: string): Promise<Map<string, number>> {
  const out = new Map<string, number>();
  try {
    for (const e of await readdir(dir, { withFileTypes: true })) {
      if (e.isFile()) out.set(e.name, (await stat(path.join(dir, e.name))).mtimeMs);
    }
  } catch {
    // Directory may not exist yet.
  }
  return out;
}

/**
 * Lists files created or modified by a save/export. Aseprite writes one file per
 * frame for single-image formats (name1.png, name2.png; a trailing number in the
 * name sets the first index), so the requested name alone is not enough.
 */
async function writtenFiles(file: string, before: Map<string, number>): Promise<string[]> {
  const dir = path.dirname(file);
  const ext = path.extname(file).toLowerCase();
  const after = await snapshotDir(dir);
  const res: string[] = [];
  for (const [name, mtime] of after) {
    if (path.extname(name).toLowerCase() !== ext) continue;
    const prev = before.get(name);
    if (prev === undefined || mtime > prev) res.push(path.join(dir, name));
  }
  return res.sort((a, b) => a.localeCompare(b, undefined, { numeric: true }));
}

/** Registers a tool that runs a runtime.lua handler with the tool's arguments. */
function luaTool(name: string, description: string, shape: z.ZodRawShape, opts: ToolOpts = {}) {
  server.registerTool(
    name,
    {
      title: opts.title,
      description,
      inputSchema: { ...shape, backend },
      annotations: { readOnlyHint: opts.readOnly ?? false, destructiveHint: opts.destructive ?? false },
    },
    (async (args: Record<string, unknown>) => {
      const { backend: which, ...rest } = args;
      try {
        const resolved = resolvePaths(rest);
        const outFile = opts.outputKey ? (resolved[opts.outputKey] as string | undefined) : undefined;
        const before = outFile ? await snapshotDir(path.dirname(outFile)) : undefined;
        const r = await invoke(opts.handler ?? name, resolved, which as Backend);
        if (r.ok && outFile && before && r.result && typeof r.result === "object") {
          (r.result as Record<string, unknown>).files = await writtenFiles(outFile, before);
        }
        return toResult(r);
      } catch (e) {
        return errorResult(`Error: ${e instanceof Error ? e.message : String(e)}`);
      }
    }) as never,
  );
}

function plainTool(name: string, description: string, shape: z.ZodRawShape, fn: (args: any) => Promise<CallToolResult>, readOnly = false) {
  server.registerTool(
    name,
    { description, inputSchema: shape, annotations: { readOnlyHint: readOnly } },
    (async (args: unknown) => {
      try {
        return await fn(args);
      } catch (e) {
        return errorResult(`Error: ${e instanceof Error ? e.message : String(e)}`);
      }
    }) as never,
  );
}

// ---------------------------------------------------------------------------
// Setup and status

async function installExtension(): Promise<string> {
  const dest = path.join(userConfigDir(), "extensions", EXTENSION_NAME);
  await mkdir(dest, { recursive: true });
  for (const f of await readdir(EXTENSION_DIR)) {
    await cp(path.join(EXTENSION_DIR, f), path.join(dest, f), { force: true });
  }
  return dest;
}

plainTool(
  "status",
  "Shows the Aseprite executable in use, its version, and whether a live Aseprite is connected to the bridge.",
  {},
  async () => {
    const exe = findAseprite();
    let batch: unknown = "unavailable";
    if (exe) {
      const r = await callBatch("ping", {});
      batch = r.ok ? r.result : r.error;
    }
    const ext = path.join(userConfigDir(), "extensions", EXTENSION_NAME, "plugin.lua");
    return text({ executable: exe ?? null, batch, live: bridge.status(), extensionInstalled: existsSync(ext), workDir: WORK_DIR });
  },
  true,
);

plainTool(
  "install_extension",
  "Copies the bridge extension into Aseprite's user extensions folder. A running Aseprite must be restarted to load it.",
  {},
  async () => text({ installedTo: await installExtension() }),
);

plainTool(
  "launch_aseprite",
  "Starts the Aseprite GUI with the bridge extension and waits for it to connect, enabling live mode. The first time, Aseprite asks to allow the script's network and file access; tick 'Give full trust' / 'Don't show again' in that dialog.",
  {
    file: z.string().optional().describe("Optional sprite file to open"),
    waitSeconds: z.number().min(0).max(120).optional().describe("How long to wait for the bridge (default 30)"),
  },
  async (a: { file?: string; waitSeconds?: number }) => {
    const dest = await installExtension();
    if (bridge.connected) {
      if (a.file) return toResult(await bridge.call("open_sprite", { file: path.resolve(WORK_DIR, a.file) }));
      return text({ alreadyConnected: true, live: bridge.status() });
    }
    const exe = requireAseprite();
    const args = a.file ? [path.resolve(WORK_DIR, a.file)] : [];
    const child = spawn(exe, args, { detached: true, stdio: "ignore", cwd: WORK_DIR });
    child.unref();
    const ok = await bridge.waitForConnection((a.waitSeconds ?? 30) * 1000);
    return text({
      launched: exe,
      extension: dest,
      connected: ok,
      live: bridge.status(),
      hint: ok
        ? undefined
        : "Not connected yet. If Aseprite shows a security prompt about a WebSocket connection, allow it; then call status.",
    });
  },
);

// ---------------------------------------------------------------------------
// Generic access

luaTool(
  "run_lua",
  "Runs Lua code inside Aseprite with the full scripting API (app, Sprite, Image, Layer, Color, ...). Globals: `args` (your args object), `sprite` (resolved sprite or app.sprite), `MCP` (helper runtime: MCP.color(), MCP.layer(spr, ref), MCP.sprite_info(spr) ...). `print` output is captured. The `return` value is sent back as JSON. Use api_docs for the API reference.",
  {
    code: z.string().describe("Lua source. Use `return` to send a value back."),
    sprite: spriteRef,
    args: z.record(z.any()).optional().describe("Values available to the code as `args`"),
    mutates: z.boolean().optional().describe("Batch mode: false skips saving the sprite afterwards (default true)"),
    save,
  },
);

luaTool(
  "run_command",
  "Executes any Aseprite menu command (app.command.<name>) with parameters, e.g. Flip, Rotate, Outline, BrightnessContrast, ColorQuantization, LinkCels, ReverseFrames, AutocropSprite. See list_commands for names and parameters. Strings like '#ff0000' become Colors; {x,y,width,height} becomes a Rectangle. ui=false is added unless allowUi is true.",
  {
    name: z.string().describe("Command name, e.g. 'Outline'"),
    params: z.record(z.any()).optional().describe("Command parameters"),
    sprite: spriteRef,
    layer: layerRef.describe("Layer to make active before running"),
    frame: frameRef.describe("Frame to make active before running"),
    allowUi: z.boolean().optional().describe("Let the command open its dialog (live mode only)"),
    mutates: z.boolean().optional().describe("Batch mode: false skips saving (default true)"),
    save,
  },
);

plainTool(
  "list_commands",
  "Lists Aseprite commands usable with run_command, with their parameters (extracted from the Aseprite source).",
  {
    query: z.string().optional().describe("Case-insensitive filter on name/description"),
  },
  async (a: { query?: string }) => {
    const all = JSON.parse(await readFile(path.join(DATA_DIR, "commands.json"), "utf8")) as Array<{
      name: string;
      params: Array<{ name: string; type: string; default?: string }>;
      requiresUI?: boolean;
      description?: string;
    }>;
    const q = a.query?.toLowerCase();
    const lines = all
      .filter((c) => !q || c.name.toLowerCase().includes(q) || c.description?.toLowerCase().includes(q))
      .map((c) => {
        const ps = c.params.map((p) => `${p.name}:${p.type.replace(/^.*::/, "")}${p.default ? "=" + p.default : ""}`).join(", ");
        return `${c.name}(${ps})${c.requiresUI ? " [GUI only]" : ""}${c.description ? " - " + c.description : ""}`;
      });
    return text(lines.length ? lines.join("\n") : "No matching commands");
  },
  true,
);

plainTool(
  "api_docs",
  "Reads the Aseprite Lua API reference (bundled from github.com/aseprite/api). Without a topic, lists topics. Topics include app, sprite, layer, cel, image, color, palette, tag, slice, tileset, selection, dialog, websocket, and command/<CommandName>.",
  { topic: z.string().optional().describe("e.g. 'image', 'app', 'command/ExportSpriteSheet'") },
  async (a: { topic?: string }) => {
    const base = path.join(DATA_DIR, "api");
    if (!a.topic) {
      const top = (await readdir(base)).filter((f) => f.endsWith(".md")).map((f) => f.slice(0, -3));
      const cmds = (await readdir(path.join(base, "command"))).filter((f) => f.endsWith(".md")).map((f) => "command/" + f.slice(0, -3));
      return text([...top, ...cmds].join("\n"));
    }
    const name = a.topic.replace(/\.md$/i, "").replace(/\\/g, "/").toLowerCase();
    const candidates = [name, name.replace(/\./g, "_"), "command/" + name];
    for (const dir of [base, path.join(base, "command")]) {
      for (const f of await readdir(dir)) {
        const stem = f.slice(0, -3).toLowerCase();
        const rel = dir === base ? stem : "command/" + stem;
        if (candidates.includes(rel) || candidates.includes(stem)) {
          return text(await readFile(path.join(dir, f), "utf8"));
        }
      }
    }
    return errorResult(`No API doc for '${a.topic}'. Call api_docs without a topic to list them.`);
  },
  true,
);

plainTool(
  "cli",
  "Runs the Aseprite command line in batch mode (aseprite -b <args>) and returns its output. Useful for --sheet/--data exports, --split-layers, --list-tags, --save-as with {layer}/{frame} templates, --scale, --color-mode, etc. See https://www.aseprite.org/docs/cli/.",
  {
    args: z.array(z.string()).describe("Arguments after -b, e.g. ['in.aseprite', '--scale', '4', '--save-as', 'out.png']"),
    timeoutSeconds: z.number().min(1).max(600).optional(),
  },
  async (a: { args: string[]; timeoutSeconds?: number }) => {
    const r = await runCli(["-b", ...a.args], a.timeoutSeconds ? a.timeoutSeconds * 1000 : undefined);
    const res = { exitCode: r.code, timedOut: r.timedOut || undefined, stdout: r.stdout.trim(), stderr: r.stderr.trim() || undefined };
    return r.code === 0 ? text(res) : { ...text(res), isError: true };
  },
);

// ---------------------------------------------------------------------------
// App state

luaTool(
  "app_state",
  "Returns Aseprite's current state: open sprites, active sprite/layer/frame, foreground/background colors, tool, brush, timeline range and editor zoom (live).",
  {},
  { readOnly: true },
);

luaTool(
  "set_active",
  "Changes what is active in the UI: sprite/layer/frame, foreground/background color, tool, brush, editor zoom, and the timeline range (selected frames/layers/colors). Mostly useful in live mode.",
  {
    sprite: spriteRef,
    layer: layerRef,
    frame: frameRef,
    fgColor: color.optional(),
    bgColor: color.optional(),
    tool: z.string().optional().describe("Tool id, e.g. pencil, eraser, paint_bucket, rectangular_marquee"),
    brush: brushSchema.optional(),

    zoom: z.number().positive().optional().describe("Editor zoom factor (1 = 100%)"),
    range: z
      .object({
        frames: z.array(z.number().int()).optional(),
        layers: z.array(z.union([z.string(), z.number().int()])).optional(),
        colors: z.array(z.number().int()).optional(),
      })
      .optional()
      .describe("Timeline/palette selection (live only)"),
  },
);

luaTool(
  "undo_redo",
  "Undoes or redoes steps on a sprite (live mode; batch processes have no history between calls).",
  { action: z.enum(["undo", "redo"]), steps: z.number().int().min(1).optional(), sprite: spriteRef },
);

plainTool(
  "list_preferences",
  "Lists Aseprite preference sections and options (from pref.xml) for use with the preferences tool.",
  { section: z.string().optional().describe("Only this section, e.g. 'grid' or 'tool_box'") },
  async (a: { section?: string }) => {
    const prefs = JSON.parse(await readFile(path.join(DATA_DIR, "preferences.json"), "utf8")) as Record<string, Record<string, string>>;
    if (a.section) {
      const s = prefs[a.section];
      return s ? text(s) : errorResult(`No section '${a.section}'. Sections: ${Object.keys(prefs).join(", ")}`);
    }
    return text(Object.fromEntries(Object.entries(prefs).map(([k, v]) => [k, Object.keys(v)])));
  },
  true,
);

luaTool(
  "preferences",
  "Gets or sets an Aseprite preference (app.preferences.<section>.<option>), a tool preference (tool=<id>) or a per-sprite document preference (document=true). Use list_preferences to discover names.",
  {
    action: z.enum(["get", "set"]),
    section: z.string(),
    option: z.string().describe("Option name; nested options use dots, e.g. 'brush.size' with section from the tool prefs"),
    value: z.any().optional(),
    tool: z.string().optional().describe("Read tool preferences for this tool id"),
    document: z.boolean().optional().describe("Read the sprite's document preferences"),
    sprite: spriteRef,
  },
);

// ---------------------------------------------------------------------------
// Sprites

luaTool("list_sprites", "Lists sprites open in Aseprite.", {}, { readOnly: true });

luaTool(
  "new_sprite",
  "Creates a new sprite. In batch mode 'file' is required (the sprite is saved there).",
  {
    width: z.number().int().min(1).max(65535),
    height: z.number().int().min(1).max(65535),
    colorMode: z.enum(["rgb", "gray", "indexed"]).optional(),
    frames: z.number().int().min(1).optional(),
    frameDurationMs: z.number().int().min(1).optional(),
    background: color.optional().describe("Fill the first layer with this color"),
    backgroundLayer: z.boolean().optional().describe("Turn the first layer into a Background layer"),
    layerName: z.string().optional(),
    palette: z
      .union([z.array(color), z.object({ colors: z.array(color).optional(), preset: z.string().optional(), file: z.string().optional() })])
      .optional()
      .describe("Colors, or {preset:'DB32'} / {file:'pal.gpl'}"),
    file: z.string().optional().describe("Save to this path (.aseprite keeps layers/frames)"),
  },
);

luaTool(
  "open_sprite",
  "Opens a sprite file (any format Aseprite reads: .aseprite, .png, .gif, .jpg, .webp, .bmp, .tga, .pcx, .ico, .flc, .qoi, .psd...) and returns its structure. In live mode it opens a tab.",
  { file: z.string(), oneFrame: z.boolean().optional().describe("Load only the first frame") },
  { readOnly: true },
);

luaTool(
  "get_sprite_info",
  "Returns a sprite's full structure: size, color mode, frames and durations, layer tree (with opacity, blend mode, visibility...), tags, slices, tilesets, palette size, grid, selection and active layer/frame.",
  { sprite: spriteRef, includeCels: z.boolean().optional().describe("Also list every cel") },
  { readOnly: true },
);

luaTool(
  "save_sprite",
  "Saves a sprite (Save / Save As), or with copy=true saves a copy without changing the sprite's file name. The extension picks the format. Single-image formats get one file per frame (name1.png, name2.png...); the result lists the files written.",
  { sprite: spriteRef, file: z.string().optional(), copy: z.boolean().optional() },
  { outputKey: "file" },
);

luaTool(
  "close_sprite",
  "Closes an open sprite (live mode).",
  { sprite: spriteRef, save: z.boolean().optional(), discardChanges: z.boolean().optional() },
  { destructive: true },
);

luaTool(
  "set_sprite_properties",
  "Changes sprite metadata: filename, user data, tab color, transparent color index, pixel ratio, grid bounds, user properties, color space.",
  {
    sprite: spriteRef,
    filename: z.string().optional(),
    data: z.string().optional(),
    color: color.optional(),
    transparentColor: z.number().int().min(0).max(255).optional(),
    pixelRatio: z.object({ width: z.number().int(), height: z.number().int() }).optional(),
    gridBounds: rect.optional(),
    properties,
    useLayerUuids: z.boolean().optional(),
    colorSpace: z.enum(["srgb", "none"]).optional(),
    convertColorSpace: z.boolean().optional().describe("Convert pixels instead of only assigning the color space"),
    save,
  },
);

luaTool(
  "resize_sprite",
  "Scales the whole sprite (all layers and frames). Give width and/or height, or scale.",
  {
    sprite: spriteRef,
    width: z.number().int().min(1).optional(),
    height: z.number().int().min(1).optional(),
    scale: z.number().positive().optional(),
    method: z.enum(["nearest", "bilinear", "rotsprite"]).optional(),
    save,
  },
);

luaTool(
  "canvas_size",
  "Grows or shrinks the canvas without scaling pixels: either margins (left/top/right/bottom, negative values cut) or a new width/height with an anchor.",
  {
    sprite: spriteRef,
    left: z.number().int().optional(),
    top: z.number().int().optional(),
    right: z.number().int().optional(),
    bottom: z.number().int().optional(),
    width: z.number().int().min(1).optional(),
    height: z.number().int().min(1).optional(),
    anchor: z
      .enum(["center", "top", "bottom", "left", "right", "top_left", "top_right", "bottom_left", "bottom_right"])
      .optional(),
    trimOutside: z.boolean().optional(),
    save,
  },
);

luaTool(
  "crop_sprite",
  "Crops the sprite to a rectangle, to the selection (mode='selection'), or trims empty borders (mode='auto').",
  { sprite: spriteRef, rect: rect.optional(), mode: z.enum(["rect", "selection", "auto"]).optional(), byGrid: z.boolean().optional(), save },
);

luaTool(
  "change_color_mode",
  "Converts the sprite to RGB, grayscale or indexed, with optional dithering.",
  {
    sprite: spriteRef,
    mode: z.enum(["rgb", "gray", "indexed"]),
    dithering: z.enum(["none", "ordered", "old"]).optional(),
    ditheringMatrix: z.string().optional().describe("e.g. 'bayer2x2', 'bayer4x4', 'bayer8x8'"),
    ditheringFactor: z.number().optional(),
    rgbmap: z.enum(["default", "octree", "rgb5a3"]).optional(),
    toGray: z.enum(["luma", "hsv", "hsl"]).optional(),
    fitCriteria: z.enum(["default", "rgb", "linearizedRGB", "cielab"]).optional(),
    save,
  },
);

luaTool(
  "flip_rotate",
  "Flips and/or rotates the whole sprite, the active cel(s) of a layer/frame, or the selection.",
  {
    sprite: spriteRef,
    target: z.enum(["sprite", "cel", "selection"]).optional(),
    layer: layerRef,
    frame: frameRef,
    flip: z.enum(["horizontal", "vertical"]).optional(),
    rotate: z.union([z.literal(90), z.literal(180), z.literal(-90), z.literal(270)]).optional(),
    save,
  },
);

// ---------------------------------------------------------------------------
// Layers

const layerProps = {
  name: z.string().optional(),
  visible: z.boolean().optional(),
  editable: z.boolean().optional().describe("false locks the layer"),
  opacity: z.number().int().min(0).max(255).optional(),
  blendMode: z
    .string()
    .optional()
    .describe("normal, multiply, screen, overlay, darken, lighten, color_dodge, color_burn, hard_light, soft_light, difference, exclusion, hue, saturation, color, luminosity, addition, subtract, divide"),
  continuous: z.boolean().optional(),
  collapsed: z.boolean().optional().describe("Group layers only"),
  color: color.optional().describe("Timeline color"),
  data: z.string().optional().describe("User data text"),
  properties,
  parent: z.string().optional().describe("Group layer to move into; '' moves to the top level"),
  stackIndex: z.number().int().min(1).optional().describe("Position among siblings (1 = bottom)"),
};

luaTool(
  "add_layer",
  "Adds an image, group or tilemap layer, optionally inside a group or above/below another layer, with its properties set.",
  {
    sprite: spriteRef,
    type: z.enum(["image", "group", "tilemap", "reference"]).optional(),
    ...layerProps,
    above: z.string().optional().describe("Place directly above this layer"),
    below: z.string().optional().describe("Place directly below this layer"),
    tileSize: z.object({ width: z.number().int(), height: z.number().int() }).optional().describe("Tilemap layers: tile size"),
    image: imageSpec.optional().describe("Fill the new layer (image or reference) with this image"),
    frame: frameRef.describe("Frame for 'image' (default 1)"),
    x: z.number().int().optional().describe("Position of 'image'"),
    y: z.number().int().optional(),
    save,
  },
);

luaTool("update_layer", "Changes layer properties: name, visibility, lock, opacity, blend mode, color, data, parent group, stack position.", {
  sprite: spriteRef,
  layer: layerRef,
  ...layerProps,
  tileset: z.union([z.string(), z.number().int()]).optional().describe("Tilemap layers: tileset to use"),
  save,
});

luaTool("delete_layer", "Deletes a layer (and its children if it is a group).", { sprite: spriteRef, layer: layerRef, save }, { destructive: true });

luaTool("duplicate_layer", "Duplicates a layer with all its cels.", { sprite: spriteRef, layer: layerRef, name: z.string().optional(), save });

luaTool(
  "merge_layers",
  "Merges a layer into the one below (mode='down'), flattens all layers ('flatten'), or flattens only visible layers ('visible').",
  { sprite: spriteRef, layer: layerRef, mode: z.enum(["down", "flatten", "visible"]).optional(), save },
  { destructive: true },
);

luaTool(
  "convert_layer",
  "Converts a layer: to a Background layer, from Background to a normal layer, or between image and tilemap layers.",
  { sprite: spriteRef, layer: layerRef, to: z.enum(["background", "layer", "image", "tilemap"]), save },
);

// ---------------------------------------------------------------------------
// Frames

luaTool(
  "add_frames",
  "Adds frames. By default copies the previous frame's cels; empty=true adds blank frames.",
  {
    sprite: spriteRef,
    count: z.number().int().min(1).optional(),
    at: z.number().int().min(1).optional().describe("Frame number for the first new frame (default: end)"),
    copyFrom: z.number().int().min(1).optional().describe("Frame to copy (default: the frame before 'at')"),
    empty: z.boolean().optional(),
    durationMs: z.number().int().min(1).optional(),
    save,
  },
);

luaTool("delete_frames", "Deletes one frame, a range, a list, or a tag's frames.", { sprite: spriteRef, ...frameRange, save }, { destructive: true });

luaTool(
  "set_frame_duration",
  "Sets frame durations in milliseconds for one frame, a range, a list, a tag, or 'all'.",
  { sprite: spriteRef, durationMs: z.number().int().min(1), ...frameRange, save },
);

luaTool("move_frame", "Moves a frame (with its cels) to another position.", {
  sprite: spriteRef,
  from: z.number().int().min(1),
  to: z.number().int().min(1),
  save,
});

// ---------------------------------------------------------------------------
// Cels

luaTool(
  "get_cels",
  "Lists cels (layer/frame pairs with images) with bounds, opacity, z-index and data, filtered by layer and frames.",
  { sprite: spriteRef, layer: layerRef, ...frameRange },
  { readOnly: true },
);

luaTool(
  "update_cel",
  "Changes a cel: position (absolute x/y or relative dx/dy), opacity, z-index, color, data, properties, or moves it to another frame.",
  {
    sprite: spriteRef,
    layer: layerRef,
    frame: frameRef,
    x: z.number().int().optional(),
    y: z.number().int().optional(),
    dx: z.number().int().optional(),
    dy: z.number().int().optional(),
    opacity: z.number().int().min(0).max(255).optional(),
    zIndex: z.number().int().optional(),
    color: color.optional(),
    data: z.string().optional(),
    properties,
    toFrame: z.number().int().min(1).optional(),
    save,
  },
);

luaTool("delete_cel", "Deletes the cel(s) of a layer in the given frames.", { sprite: spriteRef, layer: layerRef, ...frameRange, save }, {
  destructive: true,
});

luaTool(
  "copy_cel",
  "Copies a cel's image to another layer/frame (and optionally another open sprite).",
  {
    sprite: spriteRef.describe("Destination sprite"),
    fromSprite: spriteRef.describe("Source sprite (default: same)"),
    fromLayer: layerRef,
    fromFrame: frameRef,
    toLayer: layerRef,
    toFrame: frameRef,
    x: z.number().int().optional(),
    y: z.number().int().optional(),
    save,
  },
);

// ---------------------------------------------------------------------------
// Pixels and drawing

luaTool(
  "draw_pixels",
  "Sets individual pixels on a layer/frame (one undo step). Either 'pixels' as [[x,y,color],...] / [{x,y,color}], or pixel art as 'rows' of characters with a 'legend' mapping each character to a color; rows start at (x,y). Unmapped ' ' and '.' are skipped; map '.' to 'transparent' to erase. The cel grows as needed; pixels outside the canvas are dropped.",
  {
    sprite: spriteRef,
    layer: layerRef,
    frame: frameRef,
    pixels: z.array(z.union([z.tuple([z.number(), z.number(), color]), z.object({ x: z.number(), y: z.number(), color })])).optional(),
    rows: z.array(z.string()).optional(),
    legend: z.record(color).optional(),
    x: z.number().int().optional().describe("Left of the rows grid (default 0)"),
    y: z.number().int().optional().describe("Top of the rows grid (default 0)"),
    blend: z.boolean().optional().describe("Alpha-blend over existing pixels instead of replacing"),
    save,
  },
);

luaTool(
  "get_pixels",
  "Reads pixels of the rendered frame (all visible layers) or of one layer. Default format 'legend' returns rows of characters plus a legend of colors ('.' = transparent); 'hex' returns a grid of '#rrggbbaa' (null = transparent). Indexed sprites return palette indices.",
  {
    sprite: spriteRef,
    layer: layerRef.describe("Read only this layer (default: the composited frame)"),
    frame: frameRef,
    rect: rect.optional(),
    format: z.enum(["legend", "hex"]).optional(),
    maxPixels: z.number().int().optional().describe("Safety limit on area (default 16384)"),
  },
  { readOnly: true },
);

luaTool(
  "use_tool",
  "Draws with an Aseprite tool as if the user dragged through 'points' (app.useTool). Tools: pencil, brush-like strokes with eraser/spray/blur/jumble, line, curve (4 points), rectangle, filled_rectangle, ellipse, filled_ellipse, paint_bucket (1 point), gradient, contour, polygon, and selection tools (rectangular_marquee, elliptical_marquee, lasso, polygonal_lasso, magic_wand).",
  {
    sprite: spriteRef,
    layer: layerRef,
    frame: frameRef,
    tool: z.string(),
    points: z.array(point).min(1),
    color: color.optional().describe("Default: foreground color"),
    bgColor: color.optional(),
    brush: brushSchema.optional(),

    brushSize: z.number().int().min(1).optional(),
    ink: z.enum(["simple", "alpha_compositing", "copy_color", "lock_alpha", "shading"]).optional(),
    opacity: z.number().int().min(0).max(255).optional(),
    tolerance: z.number().int().min(0).max(255).optional(),
    contiguous: z.boolean().optional(),
    pixelPerfect: z.boolean().optional(),
    button: z.enum(["left", "right"]).optional().describe("right uses the background color"),
    selectionMode: z.enum(["replace", "add", "subtract", "intersect"]).optional(),
    tilemapMode: z.enum(["pixels", "tiles"]).optional(),
    tilesetMode: z.enum(["manual", "auto", "stack"]).optional(),
    save,
  },
);

luaTool(
  "draw_image",
  "Draws an image file (PNG, etc.) into a layer/frame at (x,y). mode 'blend' composites over existing pixels, 'copy' overwrites the area, 'replace' swaps the whole cel image. Optional source crop, scale or target size.",
  {
    sprite: spriteRef,
    layer: layerRef,
    frame: frameRef,
    file: z.string(),
    x: z.number().int().optional(),
    y: z.number().int().optional(),
    mode: z.enum(["blend", "copy", "replace"]).optional(),
    opacity: z.number().int().min(0).max(255).optional(),
    blendMode: z.string().optional(),
    sourceRect: rect.optional(),
    scale: z.number().positive().optional(),
    width: z.number().int().optional(),
    height: z.number().int().optional(),
    save,
  },
);

luaTool(
  "clear",
  "Clears a layer's cel(s) to transparent (or fills with a color): whole cel, a rect, or the selected area.",
  { sprite: spriteRef, layer: layerRef, ...frameRange, rect: rect.optional(), useSelection: z.boolean().optional(), color: color.optional(), save },
  { destructive: true },
);

luaTool(
  "replace_color",
  "Replaces one color with another on a layer (or all layers) across frames, with optional per-channel tolerance (RGB).",
  { sprite: spriteRef, layer: layerRef, ...frameRange, from: color, to: color, tolerance: z.number().int().min(0).max(255).optional(), save },
);

luaTool(
  "apply_filter",
  "Applies an image filter command to the active cel(s) or selection: BrightnessContrast, HueSaturation, ColorCurve, ConvolutionMatrix, Despeckle, InvertColor, Outline, ReplaceColor. Params follow list_commands (e.g. Outline {color:'#000000', place:'outside', matrix:'circle'}; HueSaturation {hue, saturation, lightness, alpha}; BrightnessContrast {brightness, contrast}).",
  {
    sprite: spriteRef,
    layer: layerRef,
    frame: frameRef,
    filter: z.string(),
    params: z.record(z.any()).optional(),
    channels: z.string().optional().describe("e.g. 'rgba', 'rgb', 'a'"),
    save,
  },
);

// ---------------------------------------------------------------------------
// Selection

luaTool(
  "select",
  "Creates or changes the selection: rect, ellipse, polygon, magic_wand (point), by_color, all, none, invert, reselect, content (layer pixels), modify (expand/contract/border), move (dx/dy), get, save or load (to/from a .msk or image file). The selection lives only in live mode or inside one run_lua call.",
  {
    sprite: spriteRef,
    layer: layerRef,
    frame: frameRef,
    action: z.enum(["rect", "ellipse", "polygon", "magic_wand", "by_color", "all", "none", "invert", "reselect", "content", "modify", "move", "get", "save", "load"]),
    file: z.string().optional().describe("save/load: .msk (Aseprite selection file) or an image (opaque pixels = selected)"),
    mode: z.enum(["replace", "add", "subtract", "intersect"]).optional(),
    rect: rect.optional(),
    points: z.array(point).optional(),
    point: point.optional(),
    color: color.optional(),
    tolerance: z.number().int().min(0).max(255).optional(),
    contiguous: z.boolean().optional(),
    modifier: z.enum(["expand", "contract", "border"]).optional(),
    quantity: z.number().int().optional(),
    brush: z.enum(["circle", "square"]).optional(),
    dx: z.number().int().optional(),
    dy: z.number().int().optional(),
  },
);

luaTool(
  "selection_edit",
  "Acts on the selection: copy, copy_merged, cut, paste (optional x,y), delete, fill, stroke (with color), move_content / move_bounds (dx,dy, wrap), new_sprite, new_layer_via_copy, new_layer_via_cut, crop.",
  {
    sprite: spriteRef,
    layer: layerRef,
    frame: frameRef,
    action: z.enum([
      "copy", "copy_merged", "cut", "paste", "delete", "fill", "stroke", "move_content", "move_bounds",
      "new_sprite", "new_layer_via_copy", "new_layer_via_cut", "crop",
    ]),
    color: color.optional(),
    x: z.number().int().optional(),
    y: z.number().int().optional(),
    dx: z.number().int().optional(),
    dy: z.number().int().optional(),
    wrap: z.boolean().optional(),
  },
);

// ---------------------------------------------------------------------------
// Palette

luaTool("get_palette", "Returns the sprite palette as '#rrggbbaa' colors (index 0 first).", { sprite: spriteRef, index: z.number().int().min(1).optional() }, {
  readOnly: true,
});

luaTool(
  "set_palette",
  "Changes the palette: set colors starting at 'start', replace it entirely, resize, load from a file (.gpl, .pal, .act, .ase, .png...) or a built-in preset (e.g. DB16, DB32, PICO-8...), or generate it from the sprite's colors (fromSprite).",
  {
    sprite: spriteRef,
    colors: z.array(color).optional(),
    start: z.number().int().min(0).optional(),
    replace: z.boolean().optional().describe("Palette becomes exactly 'colors'"),
    size: z.number().int().min(1).max(256).optional(),
    file: z.string().optional(),
    preset: z.string().optional(),
    fromSprite: z.boolean().optional().describe("Build a palette from the sprite (ColorQuantization)"),
    maxColors: z.number().int().min(1).max(256).optional(),
    withAlpha: z.boolean().optional(),
    algorithm: z.enum(["default", "rgb5a3", "octree"]).optional(),
    save,
  },
);

luaTool("save_palette", "Saves the sprite palette to a file (.gpl, .pal, .act, .png, .ase, .hex...).", { sprite: spriteRef, file: z.string() });

// ---------------------------------------------------------------------------
// Tags and slices

const tagProps = {
  name: z.string().optional(),
  from: z.number().int().min(1).optional(),
  to: z.number().int().min(1).optional(),
  aniDir: z.enum(["forward", "reverse", "ping_pong", "ping_pong_reverse"]).optional(),
  repeats: z.number().int().min(0).optional().describe("0 = infinite"),
  color: color.optional(),
  data: z.string().optional(),
  properties,
};
luaTool("add_tag", "Adds an animation tag over a frame range.", { sprite: spriteRef, ...tagProps, save });
luaTool("update_tag", "Changes a tag's name, range, direction, repeats, color or data.", { sprite: spriteRef, tag: z.union([z.string(), z.number().int()]), ...tagProps, save });
luaTool("delete_tag", "Deletes a tag (frames are kept).", { sprite: spriteRef, tag: z.union([z.string(), z.number().int()]), save }, { destructive: true });

const sliceProps = {
  name: z.string().optional(),
  bounds: rect.optional(),
  center: z.union([rect, z.literal(false)]).optional().describe("9-slice center, relative to the slice; false removes it"),
  pivot: z.union([point, z.literal(false)]).optional().describe("Pivot relative to the slice; false removes it"),
  color: color.optional(),
  data: z.string().optional(),
  properties,
};
luaTool("add_slice", "Adds a slice (with optional 9-slice center and pivot), or duplicates one with copyFrom.", { sprite: spriteRef, ...sliceProps, copyFrom: z.union([z.string(), z.number().int()]).optional().describe("Slice to duplicate"), save });
luaTool("update_slice", "Changes a slice.", { sprite: spriteRef, slice: z.union([z.string(), z.number().int()]), ...sliceProps, save });
luaTool("delete_slice", "Deletes a slice.", { sprite: spriteRef, slice: z.union([z.string(), z.number().int()]), save }, { destructive: true });

// ---------------------------------------------------------------------------
// Tilesets and tilemaps

luaTool(
  "tileset",
  "Tileset operations: list, add (tileSize, count), update (name, baseIndex, data), delete, add_tile, delete_tile, get_tile (pixels as rows+legend), set_tile (rows+legend or an image file). Tile index 0 is the empty tile.",
  {
    sprite: spriteRef,
    action: z.enum(["list", "add", "update", "delete", "add_tile", "delete_tile", "get_tile", "set_tile"]),
    tileset: z.union([z.string(), z.number().int()]).optional().describe("Tileset index (1-based), name, or a tilemap layer"),
    index: z.number().int().min(0).optional().describe("Tile index"),
    tileSize: z.object({ width: z.number().int(), height: z.number().int() }).optional(),
    count: z.number().int().min(1).optional(),
    name: z.string().optional(),
    baseIndex: z.number().int().optional(),
    data: z.string().optional(),
    properties,
    rows: z.array(z.string()).optional(),
    legend: z.record(color).optional(),
    file: z.string().optional(),
    save,
  },
);

luaTool(
  "tilemap",
  "Reads (action 'get') or writes (action 'set') the tile indices of a tilemap layer's cel. Set with 'cells' [{col,row,tile}] or 'rows' (2D array of tile indices, -1/null to skip) starting at col/row.",
  {
    sprite: spriteRef,
    layer: layerRef,
    frame: frameRef,
    action: z.enum(["get", "set"]).optional(),
    cells: z.array(z.object({ col: z.number().int(), row: z.number().int(), tile: z.number().int() })).optional(),
    rows: z.array(z.array(z.number().int().nullable())).optional(),
    col: z.number().int().optional(),
    row: z.number().int().optional(),
    save,
  },
);

// ---------------------------------------------------------------------------
// Text, vector shapes, linked cels

luaTool(
  "draw_text",
  "Draws text onto a layer. In live mode it uses Aseprite's text renderer with any font Aseprite knows (its built-in 'Aseprite' pixel font, or an installed system font by name such as 'Arial'). In batch mode, or with font='builtin', it uses a built-in 5x7 pixel font that can be scaled by whole numbers. Multi-line text with \\n is supported.",
  {
    sprite: spriteRef,
    layer: layerRef,
    frame: frameRef,
    text: z.string(),
    x: z.number().int().optional(),
    y: z.number().int().optional(),
    color: color.optional().describe("Default black"),
    font: z.string().optional().describe("'builtin', 'Aseprite', or a system font name (live mode)"),
    size: z.number().positive().optional().describe("Font size for Aseprite/system fonts (default 6)"),
    scale: z.number().int().min(1).optional().describe("Integer scale for the builtin font"),
    letterSpacing: z.number().int().optional().describe("Builtin font: pixels between letters (default 1)"),
    lineSpacing: z.number().int().optional().describe("Builtin font: pixels between lines (default 1)"),
    lineHeight: z.number().int().optional().describe("Other fonts: pixels from one line to the next"),
    align: z.enum(["left", "center", "right"]).optional().describe("Horizontal alignment relative to x"),
    opacity: z.number().int().min(0).max(255).optional(),
    measureOnly: z.boolean().optional().describe("Only return the text size, draw nothing"),
    save,
  },
);

luaTool(
  "draw_shapes",
  "Draws vector shapes with optional antialiasing: rect, rounded_rect, oval/ellipse, line, polyline, polygon, bezier (cubic, points = start then control1, control2, end per segment), or path (ops: move/line/cubic/close). Each shape is stroked (width) or filled. Antialiasing is off by default to keep hard pixel edges. For pixel-exact aliased shapes use_tool is closer to Aseprite's own tools.",
  {
    sprite: spriteRef,
    layer: layerRef,
    frame: frameRef,
    shapes: z
      .array(
        z.object({
          type: z.enum(["rect", "rounded_rect", "oval", "ellipse", "line", "polyline", "polygon", "bezier", "path"]),
          rect: rect.optional(),
          points: z.array(point).optional(),
          ops: z
            .array(z.object({ op: z.enum(["move", "line", "cubic", "close"]), x: z.number().optional(), y: z.number().optional(), c1x: z.number().optional(), c1y: z.number().optional(), c2x: z.number().optional(), c2y: z.number().optional() }))
            .optional(),
          radius: z.number().optional().describe("rounded_rect corner radius"),
          radiusY: z.number().optional(),
          fill: z.boolean().optional(),
          width: z.number().positive().optional().describe("Stroke width (default 1)"),
          color: color.optional(),
          antialias: z.boolean().optional(),
          opacity: z.number().int().min(0).max(255).optional(),
          closed: z.boolean().optional().describe("bezier: close the curve"),
        }),
      )
      .min(1),
    color: color.optional().describe("Default color for shapes without one"),
    width: z.number().positive().optional().describe("Default stroke width"),
    antialias: z.boolean().optional().describe("Default antialiasing (false)"),
    opacity: z.number().int().min(0).max(255).optional().describe("Opacity of the whole drawing when composited"),
    blendMode: z.string().optional(),
    save,
  },
);

luaTool(
  "link_cels",
  "Links cels so several frames share one image (edits to one show in all), or unlinks them. Linking needs live mode. Unlinking works in both modes.",
  {
    sprite: spriteRef,
    action: z.enum(["link", "unlink"]).optional(),
    layer: layerRef,
    layers: z.array(z.union([z.string(), z.number().int()])).optional().describe("Several layers at once"),
    ...frameRange,
    save,
  },
);

// ---------------------------------------------------------------------------
// Palette editing, view, clipboard, properties

luaTool(
  "palette_edit",
  "Edits the palette structure: add or insert colors, remove entries, move entries, sort (by hue, saturation, value, lightness, luminance, red, green, blue, alpha), reverse a range, generate a ramp between two colors, or dedupe. In indexed sprites pixels are remapped so they keep their colors (set remapPixels=false to skip); pixels using removed colors move to the nearest remaining one.",
  {
    sprite: spriteRef,
    action: z.enum(["add", "insert", "remove", "move", "sort", "reverse", "ramp", "dedupe"]),
    colors: z.array(color).optional().describe("add/insert"),
    at: z.number().int().min(0).optional().describe("insert/ramp: target index (default end)"),
    indices: z.array(z.number().int().min(0)).optional().describe("remove/move: entries to act on"),
    from: z.number().int().min(0).optional().describe("Range start for remove/move/sort/reverse"),
    to: z.number().int().min(0).optional().describe("Range end, or the destination index for move"),
    by: z.enum(["hue", "saturation", "value", "brightness", "lightness", "luminance", "red", "green", "blue", "alpha"]).optional(),
    descending: z.boolean().optional(),
    fromColor: color.optional().describe("ramp start"),
    toColor: color.optional().describe("ramp end"),
    steps: z.number().int().min(2).max(256).optional(),
    space: z.enum(["rgb", "hsv"]).optional().describe("ramp interpolation (default rgb)"),
    insert: z.boolean().optional().describe("ramp: insert instead of overwriting entries"),
    remapPixels: z.boolean().optional(),
    save,
  },
);

luaTool(
  "view_settings",
  "Reads or changes per-sprite view settings: grid (show, snap, bounds, color, opacity), pixel grid, symmetry mode and axes, tiled mode, onion skin, overlays (layer edges, selection edges, slices, auto guides, tile numbers, brush preview), checkerboard colors; and in live mode zoom, scroll, fit to screen, playback, timeline and preview window. Call with no options to read them.",
  {
    sprite: spriteRef,
    grid: z.object({ show: z.boolean().optional(), snap: z.boolean().optional(), bounds: rect.optional(), color: color.optional(), opacity: z.number().int().min(0).max(255).optional() }).optional(),
    pixelGrid: z.object({ show: z.boolean().optional(), color: color.optional(), opacity: z.number().int().min(0).max(255).optional() }).optional(),
    symmetry: z
      .object({
        mode: z.enum(["none", "horizontal", "vertical", "both", "right_diag", "left_diag", "both_diag", "all"]).optional(),
        x: z.number().optional().describe("Vertical axis position (pixels)"),
        y: z.number().optional().describe("Horizontal axis position (pixels)"),
      })
      .optional(),
    tiledMode: z.enum(["none", "x", "y", "both"]).optional(),
    onionSkin: z
      .object({
        active: z.boolean().optional(),
        prevFrames: z.number().int().min(0).optional(),
        nextFrames: z.number().int().min(0).optional(),
        opacityBase: z.number().int().min(0).max(255).optional(),
        opacityStep: z.number().int().min(0).max(255).optional(),
        type: z.enum(["merge", "red_blue_tint"]).optional(),
        position: z.enum(["behind", "infront"]).optional(),
        loopTag: z.boolean().optional(),
        currentLayer: z.boolean().optional(),
      })
      .optional(),
    show: z
      .object({
        layerEdges: z.boolean().optional(),
        selectionEdges: z.boolean().optional(),
        slices: z.boolean().optional(),
        autoGuides: z.boolean().optional(),
        tileNumbers: z.boolean().optional(),
        brushPreview: z.boolean().optional(),
      })
      .optional(),
    background: z.object({ color1: color.optional(), color2: color.optional(), size: z.number().int().min(1).optional() }).optional().describe("Checkerboard behind transparent pixels"),
    zoom: z.number().positive().optional().describe("Live: editor zoom (1 = 100%)"),
    scroll: point.optional().describe("Live: sprite pixel to center the editor on"),
    fitScreen: z.boolean().optional().describe("Live: zoom to fit"),
    playback: z.enum(["toggle", "play", "stop"]).optional().describe("Live: start/stop animation playback (toggles)"),
    timeline: z.boolean().optional().describe("Live: open (true) or close (false) the timeline"),
    togglePreview: z.boolean().optional().describe("Live: show/hide the preview window"),
  },
);

plainTool(
  "clipboard",
  "Reads or writes the system clipboard: info, get_text, set_text, clear, get_image (returned as a preview image, or saved to 'file'), set_image (from an image file, or a rendered sprite frame/layer/rect).",
  {
    action: z.enum(["info", "get_text", "set_text", "clear", "get_image", "set_image"]),
    text: z.string().optional(),
    file: z.string().optional().describe("get_image: save here; set_image: load from here"),
    sprite: spriteRef,
    layer: layerRef,
    frame: frameRef,
    rect: rect.optional(),
    backend,
  },
  async (a: Record<string, unknown>) => {
    const { backend: which, ...rest } = a;
    if (rest.action !== "get_image" || rest.file) {
      const args = resolvePaths(rest);
      if (args.action === "get_image") args.out = args.file;
      return toResult(await invoke("clipboard", args, which as Backend));
    }
    const dir = await mkdtemp(path.join(os.tmpdir(), "aseprite-mcp-clip-"));
    try {
      const out = path.join(dir, "clipboard.png");
      const r = await invoke("clipboard", { ...rest, out }, which as Backend);
      if (!r.ok) return toResult(r);
      const img = await upscalePng(out, { maxSize: 512, checkerboard: true, pixelGrid: true });
      const meta = r.result as Record<string, unknown>;
      delete meta.file;
      return {
        content: [
          { type: "image", data: img.base64, mimeType: "image/png" },
          { type: "text", text: JSON.stringify({ ...meta, previewScale: img.scale }) },
        ],
      };
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  },
);

luaTool(
  "duplicate_sprite",
  "Makes a copy of a whole sprite (all layers, frames, tags, slices). In batch mode 'file' is required.",
  { sprite: spriteRef, file: z.string().optional() },
);

luaTool(
  "properties",
  "Gets, sets, deletes or replaces custom properties on a sprite, layer, cel, tag, slice, tileset or tile. With pluginKey ('publisher/extension') it reads/writes that extension's properties instead of the user properties.",
  {
    sprite: spriteRef,
    action: z.enum(["get", "set", "delete", "replace"]).optional(),
    target: z.enum(["sprite", "layer", "cel", "tag", "slice", "tileset", "tile"]).optional(),
    layer: layerRef,
    frame: frameRef,
    tag: z.union([z.string(), z.number().int()]).optional(),
    slice: z.union([z.string(), z.number().int()]).optional(),
    tileset: z.union([z.string(), z.number().int()]).optional(),
    index: z.number().int().optional().describe("Tile index for target=tile"),
    pluginKey: z.string().optional(),
    values: z.record(z.any()).optional(),
    keys: z.array(z.string()).optional().describe("delete: property names"),
    save,
  },
);

// ---------------------------------------------------------------------------
// Live-only: what the user did, and asking the user

luaTool(
  "recent_events",
  "Live mode: returns what happened in Aseprite since a sequence number: sprite changes (including undo/redo), switching sprite/layer/frame, commands run, and color changes. Events caused by MCP calls are hidden unless includeMcp is true. Pass the returned lastSeq as 'since' next time.",
  {
    since: z.number().int().min(0).optional(),
    types: z.array(z.enum(["sprite_change", "site_change", "command", "fg_color", "bg_color"])).optional(),
    includeMcp: z.boolean().optional(),
    limit: z.number().int().min(1).max(500).optional(),
  },
  { readOnly: true },
);

plainTool(
  "ask_user",
  "Live mode: shows a dialog in Aseprite and waits for the user to answer. Can show text plus input fields (entry, number, slider, check, combobox, color, label) and buttons. Returns the pressed button and field values.",
  {
    title: z.string().optional(),
    text: z.string().optional(),
    fields: z
      .array(
        z.object({
          id: z.string(),
          type: z.enum(["entry", "number", "slider", "check", "combobox", "color", "label"]).optional(),
          label: z.string().optional(),
          value: z.any().optional(),
          text: z.string().optional().describe("check: text next to the box"),
          options: z.array(z.string()).optional().describe("combobox choices"),
          min: z.number().optional(),
          max: z.number().optional(),
          decimals: z.number().int().optional(),
        }),
      )
      .optional(),
    buttons: z.array(z.string()).optional().describe("Default ['OK', 'Cancel']"),
    timeoutSeconds: z.number().min(1).max(3600).optional().describe("Close the dialog and return timedOut=true after this many seconds (default 300)"),
  },
  async (a: Record<string, unknown>) => {
    if (!bridge.connected) return errorResult("Error: ask_user needs a live Aseprite. Run launch_aseprite first.");
    const { timeoutSeconds, ...rest } = a;
    const seconds = (timeoutSeconds as number) ?? 300;
    // The dialog closes itself after `seconds`; allow a little extra for the reply.
    return toResult(await bridge.call("ask_user", { ...rest, timeoutSeconds: seconds }, (seconds + 15) * 1000));
  },
);

// ---------------------------------------------------------------------------
// Rendering and export

plainTool(
  "render_preview",
  "Renders frames as an image you can look at (nearest-neighbor upscaled, transparency shown as a checkerboard). Multiple frames are laid out in a grid in frame order. Use this after edits to check the result.",
  {
    sprite: spriteRef,
    layer: layerRef.describe("Render only this layer (default: all visible layers)"),
    ...frameRange,
    columns: z.number().int().min(1).optional(),
    maxSize: z.number().int().min(64).max(2048).optional().describe("Longest side of the preview (default 512)"),
    checkerboard: z.boolean().optional(),
    pixelGrid: z.boolean().optional().describe("Faint lines between pixels at high zoom (default true)"),
    crop: rect.optional().describe("Only this area of the rendered strip"),
    backend,
  },
  async (a: Record<string, unknown>) => {
    const dir = await mkdtemp(path.join(os.tmpdir(), "aseprite-mcp-preview-"));
    try {
      const out = path.join(dir, "preview.png");
      const { backend: which, maxSize, checkerboard, pixelGrid, ...rest } = a;
      const r = await invoke("render", { ...resolvePaths(rest), out }, which as Backend);
      if (!r.ok) return toResult(r);
      const meta = r.result as { frameWidth: number; frameHeight: number; gap: number; file?: string };
      const img = await upscalePng(
        out,
        {
          maxSize: (maxSize as number) ?? 512,
          checkerboard: (checkerboard as boolean) ?? true,
          pixelGrid: (pixelGrid as boolean) ?? true,
        },
        rest.crop ? undefined : meta,
      );
      delete meta.file;
      return {
        content: [
          { type: "image", data: img.base64, mimeType: "image/png" },
          { type: "text", text: JSON.stringify({ ...meta, previewScale: img.scale }) },
        ],
      };
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  },
  true,
);

luaTool(
  "export",
  "Exports a copy of the sprite to any format (png, gif, webp, jpg, bmp, tga, pcx, ico, qoi, flc, svg, css, ...). Options: scale, a tag or a 1-based frame range, a slice, specific layers, or a filename template like 'out_{frame}.png' ({frame} counts from 0). Single-image formats with several frames get one file per frame (name1.png, name2.png..., or starting from a trailing number in the name); the result lists every file written.",
  {
    sprite: spriteRef,
    file: z.string(),
    scale: z.number().positive().optional(),
    tag: z.string().optional(),
    fromFrame: z.number().int().min(1).optional(),
    toFrame: z.number().int().min(1).optional(),
    slice: z.string().optional(),
    layers: z.array(z.string()).optional().describe("Export only these layers"),
    bounds: rect.optional(),
    aniDir: z.enum(["forward", "reverse", "ping_pong", "ping_pong_reverse"]).optional(),
    filenameFormat: z.string().optional(),
    ignoreEmpty: z.boolean().optional(),
    playSubtags: z.boolean().optional(),
  },
  { outputKey: "file" },
);

luaTool(
  "export_sprite_sheet",
  "Exports a sprite sheet image plus optional JSON data (File > Export Sprite Sheet). Supports layouts, padding, trimming, extrusion, splitting by layers/tags, tilesets, and listing layers/tags/slices in the JSON.",
  {
    sprite: spriteRef,
    textureFilename: z.string(),
    dataFilename: z.string().optional(),
    dataFormat: z.enum(["json-hash", "json-array"]).optional(),
    type: z.enum(["horizontal", "vertical", "rows", "columns", "packed"]).optional(),
    columns: z.number().int().optional(),
    rows: z.number().int().optional(),
    width: z.number().int().optional(),
    height: z.number().int().optional(),
    borderPadding: z.number().int().optional(),
    shapePadding: z.number().int().optional(),
    innerPadding: z.number().int().optional(),
    trimSprite: z.boolean().optional(),
    trim: z.boolean().optional(),
    trimByGrid: z.boolean().optional(),
    extrude: z.boolean().optional(),
    ignoreEmpty: z.boolean().optional(),
    mergeDuplicates: z.boolean().optional(),
    powerOfTwoSize: z.boolean().optional(),
    layer: z.string().optional(),
    tag: z.string().optional(),
    splitLayers: z.boolean().optional(),
    splitTags: z.boolean().optional(),
    splitGrid: z.boolean().optional(),
    listLayers: z.boolean().optional(),
    listTags: z.boolean().optional(),
    listSlices: z.boolean().optional(),
    fromTilesets: z.boolean().optional(),
    filenameFormat: z.string().optional(),
    tagnameFormat: z.string().optional(),
  },
  { outputKey: "textureFilename" },
);

luaTool(
  "import_sprite_sheet",
  "Opens an image and slices it into frames (File > Import Sprite Sheet). Optionally saves the result.",
  {
    file: z.string(),
    frameWidth: z.number().int().min(1),
    frameHeight: z.number().int().min(1),
    type: z.enum(["horizontal", "vertical", "rows", "columns"]).optional(),
    x: z.number().int().optional(),
    y: z.number().int().optional(),
    padding: z.union([z.number().int(), z.object({ width: z.number().int(), height: z.number().int() })]).optional(),
    partialTiles: z.boolean().optional(),
    saveAs: z.string().optional().describe("Save the imported sprite here (needed in batch mode)"),
  },
);

// ---------------------------------------------------------------------------

async function main() {
  bridge.start();
  await server.connect(new StdioServerTransport());
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
