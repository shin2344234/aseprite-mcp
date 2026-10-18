import { readFile } from "node:fs/promises";
import path from "node:path";
import { WebSocketServer, type WebSocket } from "ws";
import { BRIDGE_PORT, LIVE_TIMEOUT_MS, LUA_DIR } from "./config.js";
import type { RuntimeResponse } from "./batch.js";

interface Pending {
  resolve: (r: RuntimeResponse) => void;
  reject: (e: Error) => void;
  timer: NodeJS.Timeout;
}

/**
 * WebSocket server that the Aseprite bridge extension connects to.
 * Only the most recent Aseprite connection is used.
 */
export class Bridge {
  private wss?: WebSocketServer;
  private client?: WebSocket;
  private ready = false;
  private nextId = 1;
  private pending = new Map<string, Pending>();
  private readyWaiters: Array<() => void> = [];
  private queue: Promise<unknown> = Promise.resolve();
  info: Record<string, unknown> | undefined;
  listenError: string | undefined;

  constructor(readonly port = BRIDGE_PORT) {}

  start(): void {
    const wss = new WebSocketServer({ host: "127.0.0.1", port: this.port });
    wss.on("listening", () => {
      this.listenError = undefined;
      this.wss = wss;
    });
    wss.on("error", (err: NodeJS.ErrnoException) => {
      this.listenError =
        err.code === "EADDRINUSE"
          ? `Port ${this.port} is in use (another aseprite-mcp instance?). Live mode is off; retrying every 15 s.`
          : String(err);
      wss.close();
      setTimeout(() => this.start(), 15_000).unref();
    });
    wss.on("connection", (ws) => this.onConnection(ws));
  }

  get connected(): boolean {
    return this.ready && this.client !== undefined;
  }

  status() {
    return {
      port: this.port,
      listening: this.wss !== undefined && !this.listenError,
      connected: this.connected,
      aseprite: this.info,
      error: this.listenError,
    };
  }

  /** Resolves once Aseprite connects and loads the runtime, or false on timeout. */
  waitForConnection(timeoutMs: number): Promise<boolean> {
    if (this.connected) return Promise.resolve(true);
    return new Promise((resolve) => {
      const timer = setTimeout(() => resolve(false), timeoutMs);
      this.readyWaiters.push(() => {
        clearTimeout(timer);
        resolve(true);
      });
    });
  }

  private onConnection(ws: WebSocket) {
    if (this.client && this.client !== ws) this.client.close();
    this.client = ws;
    this.ready = false;
    // Heartbeat: the extension treats 15 s of silence as a dead link and reconnects.
    const ping = setInterval(() => {
      if (ws.readyState === ws.OPEN) ws.send("PING");
    }, 5_000);
    ping.unref();
    ws.on("close", () => clearInterval(ping));
    ws.on("message", (raw) => this.onMessage(ws, raw.toString()));
    ws.on("close", () => {
      if (this.client !== ws) return;
      this.client = undefined;
      this.ready = false;
      for (const [id, p] of this.pending) {
        clearTimeout(p.timer);
        p.reject(new Error("Aseprite disconnected before answering"));
        this.pending.delete(id);
      }
    });
  }

  private async onMessage(ws: WebSocket, data: string) {
    const nl = data.indexOf("\n");
    const head = nl >= 0 ? data.slice(0, nl) : data;
    const body = nl >= 0 ? data.slice(nl + 1) : "";
    if (head === "HELLO") {
      const runtime = await readFile(path.join(LUA_DIR, "runtime.lua"), "utf8");
      ws.send("RUNTIME\n" + runtime);
    } else if (head === "READY") {
      try {
        const r = JSON.parse(body) as RuntimeResponse;
        if (!r.ok) {
          this.info = { error: r.error };
          return;
        }
        this.info = r.result as Record<string, unknown>;
      } catch {
        this.info = { raw: body };
      }
      this.ready = true;
      for (const w of this.readyWaiters.splice(0)) w();
    } else if (head.startsWith("RESULT ")) {
      const id = head.slice(7);
      const p = this.pending.get(id);
      if (!p) return;
      this.pending.delete(id);
      clearTimeout(p.timer);
      try {
        p.resolve(JSON.parse(body) as RuntimeResponse);
      } catch (e) {
        p.reject(new Error(`Bad response from Aseprite: ${String(e)}`));
      }
    }
  }

  /** Sends one handler call to the live Aseprite. Calls run one at a time. */
  call(tool: string, args: Record<string, unknown>, timeoutMs = LIVE_TIMEOUT_MS): Promise<RuntimeResponse> {
    const run = () =>
      new Promise<RuntimeResponse>((resolve, reject) => {
        const ws = this.client;
        if (!ws || !this.ready) {
          reject(new Error("Aseprite is not connected"));
          return;
        }
        const id = String(this.nextId++);
        const timer = setTimeout(() => {
          this.pending.delete(id);
          reject(
            new Error(
              `Aseprite did not answer within ${timeoutMs} ms. A modal dialog (e.g. a script permission prompt) may be waiting in the Aseprite window.`,
            ),
          );
        }, timeoutMs);
        this.pending.set(id, { resolve, reject, timer });
        ws.send(`CALL ${id}\n` + JSON.stringify({ tool, args }));
      });
    const next = this.queue.then(run, run);
    this.queue = next.catch(() => undefined);
    return next;
  }
}
