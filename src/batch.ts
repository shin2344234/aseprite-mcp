import { spawn } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { BATCH_TIMEOUT_MS, LUA_DIR, WORK_DIR, findAseprite } from "./config.js";

export interface RuntimeResponse {
  ok: boolean;
  result?: unknown;
  error?: string;
  traceback?: string;
  output?: string[];
  saved?: string[];
  warning?: string;
}

export interface ProcessResult {
  code: number | null;
  stdout: string;
  stderr: string;
  timedOut: boolean;
}

// One Aseprite process at a time, so two calls never edit the same file at once.
let queue: Promise<unknown> = Promise.resolve();
function serialize<T>(fn: () => Promise<T>): Promise<T> {
  const next = queue.then(fn, fn);
  queue = next.catch(() => undefined);
  return next;
}

export function requireAseprite(): string {
  const exe = findAseprite();
  if (!exe) {
    throw new Error(
      "Aseprite executable not found. Set ASEPRITE_PATH to the full path of the Aseprite executable.",
    );
  }
  return exe;
}

export function runProcess(args: string[], timeoutMs = BATCH_TIMEOUT_MS): Promise<ProcessResult> {
  const exe = requireAseprite();
  return new Promise((resolve, reject) => {
    const child = spawn(exe, args, { cwd: WORK_DIR, windowsHide: true });
    let stdout = "";
    let stderr = "";
    let timedOut = false;
    const timer = setTimeout(() => {
      timedOut = true;
      child.kill();
    }, timeoutMs);
    child.stdout.on("data", (d) => (stdout += d.toString()));
    child.stderr.on("data", (d) => (stderr += d.toString()));
    child.on("error", (e) => {
      clearTimeout(timer);
      reject(e);
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      resolve({ code, stdout, stderr, timedOut });
    });
  });
}

/** Runs one runtime handler in a fresh `aseprite -b` process. */
export function callBatch(tool: string, args: Record<string, unknown>): Promise<RuntimeResponse> {
  return serialize(async () => {
    const dir = await mkdtemp(path.join(os.tmpdir(), "aseprite-mcp-"));
    try {
      const req = path.join(dir, "request.json");
      const resp = path.join(dir, "response.json");
      await writeFile(req, JSON.stringify({ tool, args }), "utf8");
      const proc = await runProcess([
        "-b",
        "--script-param", `runtime=${path.join(LUA_DIR, "runtime.lua")}`,
        "--script-param", `request=${req}`,
        "--script-param", `response=${resp}`,
        "--script", path.join(LUA_DIR, "runner.lua"),
      ]);
      let text: string;
      try {
        text = await readFile(resp, "utf8");
      } catch {
        const why = proc.timedOut ? `timed out after ${BATCH_TIMEOUT_MS} ms` : `exited with code ${proc.code}`;
        const log = (proc.stderr + proc.stdout).trim().split(/\r?\n/).slice(-15).join("\n");
        return { ok: false, error: `Aseprite ${why} without a response.\n${log}` };
      }
      return JSON.parse(text) as RuntimeResponse;
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });
}

export function runCli(args: string[], timeoutMs?: number): Promise<ProcessResult> {
  return serialize(() => runProcess(args, timeoutMs));
}
