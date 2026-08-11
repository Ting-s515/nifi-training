import { createReadStream } from "node:fs";
import { access } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createServer } from "node:http";

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const outputDirectory = path.resolve(scriptDirectory, "..");
const port = 18100;
const host = "127.0.0.1";
const files = new Map([
  ["/", { name: "index.html", type: "text/html; charset=utf-8" }],
  ["/index.html", { name: "index.html", type: "text/html; charset=utf-8" }],
  ["/style.css", { name: "style.css", type: "text/css; charset=utf-8" }],
  ["/app.mjs", { name: "app.mjs", type: "text/javascript; charset=utf-8" }],
]);

await access(path.join(outputDirectory, "index.html"));

const server = createServer((request, response) => {
  const pathname = new URL(request.url ?? "/", "http://localhost").pathname;
  const file = files.get(pathname);

  if (!file) {
    response.writeHead(404, { "content-type": "text/plain; charset=utf-8" });
    response.end("找不到頁面");
    return;
  }

  response.writeHead(200, {
    "cache-control": "no-cache",
    "content-type": file.type,
  });
  createReadStream(path.join(outputDirectory, file.name)).pipe(response);
});

server.on("error", (error) => {
  if (error.code === "EADDRINUSE") {
    console.error(`Port ${port} 已被占用，請先關閉原有的文件網站程序。`);
    process.exitCode = 1;
    return;
  }

  throw error;
});

server.listen(port, host, () => {
  console.log(`文件網站：http://${host}:${port}`);
});
