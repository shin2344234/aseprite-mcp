import { existsSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";

export const SERVER_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
export const LUA_DIR = path.join(SERVER_ROOT, "lua");
export const DATA_DIR = path.join(SERVER_ROOT, "data");
export const EXTENSION_DIR = path.join(SERVER_ROOT, "extension");
export const EXTENSION_NAME = "aseprite-mcp-bridge";

export const BRIDGE_PORT = Number(process.env.ASEPRITE_MCP_PORT ?? 41234);
export const BATCH_TIMEOUT_MS = Number(process.env.ASEPRITE_MCP_BATCH_TIMEOUT_MS ?? 120_000);
export const LIVE_TIMEOUT_MS = Number(process.env.ASEPRITE_MCP_LIVE_TIMEOUT_MS ?? 55_000);
export const WORK_DIR = process.env.ASEPRITE_MCP_WORKDIR ?? process.cwd();

function onPath(name: string): string | undefined {
  try {
    const cmd = process.platform === "win32" ? "where" : "which";
    const out = execFileSync(cmd, [name], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] });
    const first = out.split(/\r?\n/).find((l) => l.trim());
    return first?.trim();
  } catch {
    return undefined;
  }
}

/** Finds the Aseprite executable: $ASEPRITE_PATH, a source build in ./aseprite, common installs, then PATH. */
export function findAseprite(): string | undefined {
  const candidates: string[] = [];
  if (process.env.ASEPRITE_PATH) candidates.push(process.env.ASEPRITE_PATH);
  const exe = process.platform === "win32" ? "aseprite.exe" : "aseprite";
  // A source build inside this package (see scripts/build-aseprite.bat).
  candidates.push(path.resolve(SERVER_ROOT, "aseprite", "build", "bin", exe));
  if (process.platform === "win32") {
    candidates.push(
      "C:\\Program Files (x86)\\Steam\\steamapps\\common\\Aseprite\\Aseprite.exe",
      "C:\\Program Files\\Aseprite\\Aseprite.exe",
      path.join(process.env.LOCALAPPDATA ?? path.join(os.homedir(), "AppData", "Local"), "Programs", "Aseprite", "Aseprite.exe"),
    );
  } else if (process.platform === "darwin") {
    candidates.push(
      "/Applications/Aseprite.app/Contents/MacOS/aseprite",
      path.join(os.homedir(), "Library/Application Support/Steam/steamapps/common/Aseprite/Aseprite.app/Contents/MacOS/aseprite"),
    );
  } else {
    candidates.push("/usr/bin/aseprite", path.join(os.homedir(), ".steam/steam/steamapps/common/Aseprite/aseprite"));
  }
  for (const c of candidates) if (existsSync(c)) return c;
  return onPath("aseprite");
}

/** Aseprite's user config folder (where extensions live). */
export function userConfigDir(): string {
  if (process.env.ASEPRITE_USER_DIR) return process.env.ASEPRITE_USER_DIR;
  if (process.platform === "win32") return path.join(process.env.APPDATA ?? path.join(os.homedir(), "AppData", "Roaming"), "Aseprite");
  if (process.platform === "darwin") return path.join(os.homedir(), "Library", "Application Support", "Aseprite");
  return path.join(os.homedir(), ".config", "aseprite");
}
