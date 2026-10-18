# Changelog

## 0.1.0, 17 October 2026

First release.

73 tools covering sprites, layers, frames, cels, drawing, selections, the clipboard, palettes, tags, slices, custom properties, tilesets, tilemaps, filters, preferences, view settings, rendering and export. `run_command` and `run_lua` reach anything else in Aseprite.

Two backends. Batch mode runs a headless `aseprite -b` process per call. Live mode drives an open Aseprite window through the bundled bridge extension over a local WebSocket, with `recent_events` and `ask_user` available only there.

Tested against Aseprite 1.3.18.6 on Windows: 170 checks in batch mode and 197 in live mode.
