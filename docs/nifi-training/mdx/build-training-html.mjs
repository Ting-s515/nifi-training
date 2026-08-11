import { buildSite } from "../script/build-site.mjs";

const result = await buildSite();

console.log(
  `已產生 ${result.documentCount} 份文件：${result.outputDirectory}/index.html`,
);
