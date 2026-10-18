// One-off tool call through the MCP server, for debugging.
// Usage: node test/call.mjs <tool> '<json args>' [<tool> '<json args>' ...]
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const client = new Client({ name: "call", version: "0" });
await client.connect(new StdioClientTransport({ command: process.execPath, args: [path.join(root, "dist", "index.js")], stderr: "inherit" }));
const argv = process.argv.slice(2);
if (argv.some((a) => a.includes('"backend":"live"'))) {
  // Give the bridge a moment to reconnect to this new server process.
  for (let i = 0; i < 30; i++) {
    const s = await client.callTool({ name: "status", arguments: {} });
    if (s.content[0].text.includes('"connected":true')) break;
    await new Promise((r) => setTimeout(r, 500));
  }
}
for (let i = 0; i < argv.length; i += 2) {
  const r = await client.callTool({ name: argv[i], arguments: JSON.parse(argv[i + 1] ?? "{}") });
  console.log(`${r.isError ? "ERROR " : ""}${argv[i]}: ${r.content.filter((c) => c.type === "text").map((c) => c.text).join("\n")}`);
}
await client.close();
