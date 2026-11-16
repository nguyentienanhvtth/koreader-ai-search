// Local test server: node dev.mjs  ->  http://<LAN-IP>:8787/api/explain
// Reads secrets from .env.local (never committed).
import { createServer } from "node:http";
import { readFileSync, existsSync } from "node:fs";
import { networkInterfaces } from "node:os";
import handler from "./api/explain.js";

if (existsSync(".env.local")) {
  for (const line of readFileSync(".env.local", "utf8").split("\n")) {
    const m = line.match(/^\s*([A-Z_]+)\s*=\s*(.*)\s*$/);
    if (m && m[2] && !process.env[m[1]]) process.env[m[1]] = m[2].replace(/^["']|["']$/g, "");
  }
}
const port = Number(process.env.PORT || 8787);
createServer(async (req, res) => {
  const t = Date.now();
  if (req.url !== "/api/explain") { res.statusCode = 404; return res.end("Not found"); }
  await handler(req, res);
  console.log(`${req.method} ${req.url} ${res.statusCode} ${Date.now() - t}ms`);
}).listen(port, () => {
  const ip = Object.values(networkInterfaces()).flat()
    .find((i) => i && i.family === "IPv4" && !i.internal && i.address.startsWith("192.168."))?.address || "localhost";
  console.log(`Local API: http://${ip}:${port}/api/explain`);
});
