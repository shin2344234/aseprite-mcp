# aseprite-mcp

An MCP server for [Aseprite](https://www.aseprite.org/), the pixel art and sprite animation editor. It exposes 73 tools that cover sprites, layers, frames, cels, drawing, selections, palettes, tags, slices, tilemaps, filters, preferences and export. Anything without a dedicated tool is still reachable through `run_command`, which runs any of Aseprite's 183 menu commands, and `run_lua`, which runs arbitrary Lua against the full scripting API.

The server can run Aseprite two ways. Batch mode starts a headless `aseprite -b` process for each call and works on files. Live mode talks to an Aseprite window you have open, so you watch the edits happen and can undo them.

The full parameter reference for every tool is in [docs/tools.md](docs/tools.md).

## Requirements

- Node.js 20 or newer.
- Aseprite 1.3. Development and testing used 1.3.18.6. A bought copy from Steam or the Aseprite website works, and so does a build from source.

The server looks for Aseprite in this order: the `ASEPRITE_PATH` environment variable, `aseprite/build/bin/` inside the package folder, the default Steam and installer locations for Windows, macOS and Linux, and finally `aseprite` on `PATH`. If yours is somewhere else, set `ASEPRITE_PATH` to the executable. On macOS that is `Aseprite.app/Contents/MacOS/aseprite`, not the `.app` folder.

## Install

There is nothing to install by hand. MCP clients start the server with `npx`.

For Claude Code:

```bash
claude mcp add aseprite -- npx -y aseprite-mcp
```

With a custom Aseprite location:

```bash
claude mcp add aseprite -e ASEPRITE_PATH="D:/Tools/Aseprite/Aseprite.exe" -- npx -y aseprite-mcp
```

For Claude Desktop, Cursor, VS Code and other clients that read a JSON config, add this to the `mcpServers` section:

```json
{
  "mcpServers": {
    "aseprite": {
      "command": "npx",
      "args": ["-y", "aseprite-mcp"],
      "env": {
        "ASEPRITE_PATH": "C:/Program Files/Aseprite/Aseprite.exe"
      }
    }
  }
}
```

Leave out `env` if Aseprite is in one of the default locations. Ask the client to call the `status` tool to confirm the server found the executable.

To run from a clone instead:

```bash
git clone https://github.com/shin2344234/aseprite-mcp.git
```

```bash
cd aseprite-mcp && npm install && npm run build
```

Then point the client at `node /path/to/aseprite-mcp/dist/index.js`.

## Batch and live mode

Every tool takes a `backend` parameter. The default, `auto`, uses live mode when an Aseprite window is connected and batch mode otherwise. Pass `"live"` or `"batch"` to force one.

In batch mode each call is a fresh Aseprite process. Tools that touch a sprite need `sprite` set to a file path, and tools that change it save the file when they finish. Pass `save: false` to leave the file alone, which is useful for a dry run. Selections, undo history and unsaved sprites do not carry over from one call to the next. Batch mode has no fonts beyond a built-in 5x7 pixel font, no event log and no dialogs.

Live mode needs the bridge extension inside Aseprite. Ask the client to call `launch_aseprite`, which copies the extension into Aseprite's extensions folder and opens the window. You can also call `install_extension` and start Aseprite yourself. The extension connects to the server over a WebSocket on `127.0.0.1:41234`. Once it is connected, `sprite` is optional and defaults to the active sprite, and the active layer, frame and selection stay put between calls. Every change goes through Aseprite's undo history.

The first time the extension opens its socket, Aseprite's script security asks for permission. The same prompt can appear the first time a live call writes a file. Choosing "Give full trust to this script" stops it coming back. If a live call times out, an unanswered prompt like this is the usual cause.

The extension adds File > Scripts > MCP Bridge... to Aseprite, which shows the connection state and lets you change the port. It reconnects on its own when the server restarts.

## Conventions

Coordinates are canvas pixels with (0, 0) at the top left. Frame numbers, layer indices, tag indices and slice indices start at 1. Palette indices start at 0, matching Aseprite.

A color can be `"#rrggbb"`, `"#rrggbbaa"`, a CSS-style name such as `"red"` or `"transparent"`, a palette index as a number, or an object: `{r,g,b,a}`, `{h,s,v,a}`, `{h,s,l,a}` or `{gray,a}`.

A layer can be its name, a path through groups such as `"Body/Arm"`, or the index that `get_sprite_info` reports.

Relative file paths resolve against `ASEPRITE_MCP_WORKDIR`, which defaults to the directory the client started the server in. `export` and `save_sprite` return the full list of files they wrote, because Aseprite writes numbered files for multi-frame PNG exports.

## What the tools cover

The groups below match the sections of [docs/tools.md](docs/tools.md).

| Group | Tools |
| --- | --- |
| Setup and status | `status`, `install_extension`, `launch_aseprite` |
| Generic access | `run_lua`, `run_command`, `list_commands`, `api_docs`, `cli` |
| Application state | `app_state`, `set_active`, `undo_redo`, `list_preferences`, `preferences`, `view_settings` |
| Sprites | `list_sprites`, `new_sprite`, `open_sprite`, `get_sprite_info`, `save_sprite`, `close_sprite`, `duplicate_sprite`, `set_sprite_properties`, `resize_sprite`, `canvas_size`, `crop_sprite`, `change_color_mode`, `flip_rotate` |
| Layers | `add_layer`, `update_layer`, `delete_layer`, `duplicate_layer`, `merge_layers`, `convert_layer` |
| Frames | `add_frames`, `delete_frames`, `set_frame_duration`, `move_frame` |
| Cels | `get_cels`, `update_cel`, `delete_cel`, `copy_cel`, `link_cels` |
| Drawing and pixels | `draw_pixels`, `get_pixels`, `use_tool`, `draw_shapes`, `draw_text`, `draw_image`, `clear`, `replace_color`, `apply_filter` |
| Selection and clipboard | `select`, `selection_edit`, `clipboard` |
| Palette | `get_palette`, `set_palette`, `palette_edit`, `save_palette` |
| Tags, slices and properties | `add_tag`, `update_tag`, `delete_tag`, `add_slice`, `update_slice`, `delete_slice`, `properties` |
| Tilesets and tilemaps | `tileset`, `tilemap` |
| Rendering and export | `render_preview`, `export`, `export_sprite_sheet`, `import_sprite_sheet` |
| Live session | `recent_events`, `ask_user` |

A few of these do more than the name suggests.

`render_preview` returns an upscaled PNG of the sprite that the model can look at. Transparent pixels sit on a checkerboard aligned to the sprite's pixels, frames are laid out side by side with gray gutters, and an optional grid marks each pixel.

`get_pixels` returns a region as character rows plus a legend that maps each character to a color. `draw_pixels` accepts the same format, so a model can read a sprite, change a few characters and write it back.

`use_tool` drives Aseprite's own tools along a list of points, the same as dragging the mouse: pencil, line, curve, rectangles, ellipses, paint bucket, spray, gradient, contour, polygon, blur, jumble, eraser and the marquee, lasso and magic wand selection tools. It takes ink, opacity, tolerance, pixel-perfect mode and custom image brushes.

`draw_shapes` draws rectangles, rounded rectangles, ovals, lines, polylines, polygons, cubic beziers and free paths through Aseprite's vector drawing context. Antialiasing is off unless you ask for it.

`draw_text` uses Aseprite's text renderer in live mode, with its bundled fonts or any installed system font. Aseprite loads fonts only when its window is open, so in batch mode the tool falls back to a built-in 5x7 font that scales by whole numbers.

`palette_edit` adds, inserts, removes, moves, sorts, reverses, dedupes and generates ramps. In indexed sprites it remaps every cel and tile so pixels keep their colors.

`view_settings` reads and changes the grid, pixel grid, symmetry, tiled mode, onion skin, overlays and checkerboard. In live mode it also covers zoom, scroll, playback, the timeline and the preview window.

`recent_events` reports what the person at the keyboard did since the last check: edits, undo and redo, switching sprite, layer or frame, commands run and color changes. Changes made by MCP calls are left out by default.

`ask_user` opens a dialog in Aseprite with text, inputs and buttons, waits for an answer and returns it. It gives up after `timeoutSeconds`, 300 by default, and returns `timedOut: true`.

`list_commands` lists every menu command with its parameter names and defaults, taken from Aseprite's C++ source. `api_docs` serves the Lua API reference from the bundled copy of [aseprite/api](https://github.com/aseprite/api). `cli` runs the Aseprite command line for things like `--sheet`, `--split-layers` and `--list-tags`.

## Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `ASEPRITE_PATH` | search, see Requirements | Full path to the Aseprite executable. |
| `ASEPRITE_MCP_PORT` | `41234` | Port the server listens on for the bridge extension. Change it in the extension's MCP Bridge dialog too. |
| `ASEPRITE_MCP_WORKDIR` | the server's working directory | Base directory for relative file paths. |
| `ASEPRITE_MCP_BATCH_TIMEOUT_MS` | `120000` | How long a batch call may run before the process is killed. |
| `ASEPRITE_MCP_LIVE_TIMEOUT_MS` | `55000` | How long a live call waits for Aseprite to answer. |
| `ASEPRITE_USER_DIR` | the platform default | Aseprite's user folder, where `install_extension` puts the extension. |

## Troubleshooting

If `status` reports that Aseprite was not found, set `ASEPRITE_PATH`. With Steam, the executable is in `steamapps/common/Aseprite` inside your Steam library folder.

If live calls time out, look at the Aseprite window for a script security prompt or another modal dialog. Aseprite runs scripts on its UI thread, so an open dialog blocks every call.

If `status` says the bridge is not connected while Aseprite is open, check that the extension is enabled under Edit > Preferences > Extensions and that its port matches `ASEPRITE_MCP_PORT`. Only one server process can own the port. A second server, for example from a second client window, keeps working in batch mode and retries the port every 15 seconds.

Commands that need a timeline range, such as `ReverseFrames`, return `false` in batch mode because a headless process has no timeline. `link_cels` needs live mode for the same reason. Unlinking works in both.

## How it works

Each operation is a handler in [lua/runtime.lua](lua/runtime.lua). The TypeScript server in [src/](src/) validates the tool arguments, resolves paths and sends the call to one of two runners.

For batch mode, [src/batch.ts](src/batch.ts) writes the request to a temp file and runs `aseprite -b --script-param ... --script lua/runner.lua`. The runner loads the runtime, dispatches the call, saves the sprites it changed and writes the response file. Calls run one at a time.

For live mode, [extension/plugin.lua](extension/plugin.lua) opens a WebSocket client inside Aseprite. On connect, the server sends the source of `runtime.lua`, so the extension never needs updating when handlers change. Tool calls and results travel as JSON frames over the same socket. The server pings every 5 seconds, and the extension reconnects after 15 seconds without a message.

During a live call the runtime turns off Aseprite's "format doesn't support layers", overwrite and per-format option alerts, then puts the user's settings back. It also commits any floating pixels left by a paste or a selection transform, before and after the call, so each call sees plain cel contents.

### Aseprite bugs worked around

These are in Aseprite 1.3.18.6 itself.

The gradient tool crashes headless Aseprite with an access violation. It reads dithering settings from the context bar, which does not exist in batch mode. `use_tool` draws linear gradients in Lua in batch mode instead.

The SaveFileCopyAs command object is reused between calls in the GUI and appends `fromFrame` and `toFrame` to the previous call's frame list, so a range export writes extra frames. Those parameters are also 0-based. `export` takes 1-based ranges and exports a trimmed copy of the sprite.

When a WebSocket `onreceive` callback raises a Lua error, Aseprite stops the socket for good and never sends a close event. The bridge wraps every callback in `pcall`.

The `app.range` setters do nothing while the timeline is closed. `link_cels` and `set_active` open the timeline before setting a range.

`ReselectMask` refuses to run from a script, even right after a deselect. `select` keeps the last selection it cleared and restores that.

## Development

```bash
npm install
```

```bash
npm run build
```

`npm run docs` regenerates [docs/tools.md](docs/tools.md) from the schemas the built server registers. Run it after changing any tool.

`npm test` calls all 73 tools through a real MCP client over stdio in batch mode and fails if any tool goes uncalled. Most calls are followed by a check of the result: pixels read back with `get_pixels`, layer and frame structure, palette contents and files on disk. `npm run test:live` does the same against a GUI instance it starts itself, and adds selection editing, cel linking, undo, events, view controls and dialogs. The batch run makes 170 checks and the live run 197. The live run checks `ask_user` through its timeout. Set `ASK_USER=1` and click OK in Aseprite to check the button path too.

`node test/call.mjs <tool> '<json args>'` makes a single call, which helps when debugging a handler.

The data files under [data/](data/) come from Aseprite's source tree. With the source checked out in `aseprite/`:

```bash
python scripts/extract_commands.py aseprite data/api data/commands.json
```

```bash
python scripts/extract_prefs.py aseprite data/preferences.json
```

`scripts/build-aseprite.bat` builds Aseprite from source on Windows with the Visual Studio 2022 Build Tools, using a prebuilt Skia m124 from [aseprite/skia](https://github.com/aseprite/skia/releases) unpacked to `deps/skia`. The server finds a build in `aseprite/build/bin/` without any configuration.

## License

The server, Lua runtime and extension are MIT licensed. See [LICENSE](LICENSE).

The Lua API reference in `data/api` is a copy of [aseprite/api](https://github.com/aseprite/api), MIT licensed by Igara Studio and David Capello, with its license in `data/api/LICENSE.txt`.

Aseprite itself is not included. Its EULA does not allow redistributing the source or binaries, so you need your own copy, bought or built from source for personal use.
