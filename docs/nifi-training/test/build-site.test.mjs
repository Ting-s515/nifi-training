import assert from "node:assert/strict";
import { mkdir, mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { after, before, test } from "node:test";
import { buildSite, createDocumentId } from "../script/build-site.mjs";
import { copyCodeToClipboard } from "../src/code-copy.mjs";
import { closeDialogOnEscape } from "../src/dialog-keydown.mjs";

let fixtureDirectory;
let outputDirectory;
let html;
const fixtureDocuments = new Map([
  [
    "入門.md",
    "# 入門指南\n\n入門文件內容唯一標記。\n\n```bash\nkubectl get pods --all-namespaces\n```\n\n請閱讀 [進階參考](進階.MD#操作流程)。\n",
  ],
  [
    "PowerShell.md",
    "# PowerShell replacement\n\nPowerShell 文件內容唯一標記。\n\n```powershell\nif ($_ -match '^\\s*([^#=]+)=(.*)$') {\n  Write-Host 'ok'\n}\n```\n",
  ],
  ["進階.MD", "# 進階參考\n\n## 操作流程\n\n進階文件內容唯一標記。\n"],
  ["A+B.md", "# 加號文件\n\n加號檔名內容。\n"],
  ["A B.md", "# 空白文件\n\n空白檔名內容。\n"],
  ["unicode-composed.md", "# Composed Unicode\n\nComposed 內容。\n"],
  ["unicode-decomposed.md", "# Decomposed Unicode\n\nDecomposed 內容。\n"],
]);
const composedFileName = "é.md";
const decomposedFileName = "e\u0301.md";

function escapeHtmlAttribute(value) {
  // 測試依實際檔名驗證輸出，因此需套用與 HTML attribute 相同的 escaping。
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll('"', "&quot;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;");
}

before(async () => {
  fixtureDirectory = await mkdtemp(path.join(os.tmpdir(), "static-docs-web-"));
  const docsDirectory = path.join(fixtureDirectory, "docs");
  outputDirectory = path.join(fixtureDirectory, "dist");
  await mkdir(docsDirectory);
  await Promise.all(
    [...fixtureDocuments].map(([fileName, markdown]) =>
      writeFile(path.join(docsDirectory, fileName), markdown, "utf8"),
    ),
  );

  const result = await buildSite({
    docsDirectory,
    outputDirectory,
    siteMetadata: {
      name: "示例專案",
      title: "示例專案文件",
      description: "示例專案的測試文件網站",
    },
  });
  html = await readFile(path.join(outputDirectory, "index.html"), "utf8");

  assert.equal(result.documentCount, fixtureDocuments.size);
});

after(async () => {
  await rm(fixtureDirectory, { recursive: true, force: true });
});

test("將全部文件預先寫入單一靜態 HTML", () => {
  const panels = html.match(/class="document-panel markdown-body"/g) ?? [];

  assert.equal(panels.length, fixtureDocuments.size);
  for (const [fileName, markdown] of fixtureDocuments) {
    assert.ok(html.includes(`data-document-path="${escapeHtmlAttribute(fileName)}"`));
    const contentMarker = markdown.match(/[^#\s][^\n]*內容[^\n]*/)?.[0];
    assert.ok(contentMarker && html.includes(contentMarker));
  }
  assert.match(html, /<title>示例專案文件<\/title>/);
  assert.doesNotMatch(html, /{{SITE_(?:NAME|TITLE|DESCRIPTION)}}/);
  assert.doesNotMatch(html, /\?doc=/);
});

test("將文件間的 Markdown 連結改為同頁 hash", () => {
  const targetId = createDocumentId("進階.MD");

  assert.ok(html.includes(`href="#${targetId}--操作流程"`));
  assert.doesNotMatch(html, /href="[^"]+\.md(?:#|\")/i);
});

test("為相似與非 ASCII 檔名建立唯一文件 ID", () => {
  const articleIds = [...html.matchAll(/<article[\s\S]*?\bid="([^"]+)"/g)].map(
    (match) => match[1],
  );
  const activeLinks = html.match(/class="document-link is-active"/g) ?? [];
  const currentPages = html.match(/aria-current="page"/g) ?? [];

  assert.equal(articleIds.length, fixtureDocuments.size);
  assert.equal(new Set(articleIds).size, fixtureDocuments.size);
  assert.notEqual(createDocumentId("A+B.md"), createDocumentId("A B.md"));
  assert.notEqual(createDocumentId("入門.md"), createDocumentId("進階.MD"));
  assert.equal(
    composedFileName.normalize("NFC"),
    decomposedFileName.normalize("NFC"),
  );
  assert.notEqual(
    createDocumentId(composedFileName),
    createDocumentId(decomposedFileName),
  );
  assert.equal(activeLinks.length, 1);
  assert.equal(currentPages.length, 1);
});

test("輸出瀏覽器所需的靜態資產", async () => {
  const app = await stat(path.join(outputDirectory, "app.mjs"));
  const style = await stat(path.join(outputDirectory, "style.css"));

  assert.ok(app.size > 0);
  assert.ok(style.size > 0);
  assert.doesNotMatch(html, /\/src\//);
});

test("切換文件時只操作既有 DOM，不重新取得 Markdown", async () => {
  const source = await readFile(new URL("../src/app.mjs", import.meta.url), "utf8");

  assert.match(source, /window\.addEventListener\("hashchange"/);
  assert.match(source, /panel\.hidden = panel !== activePanel/);
  assert.doesNotMatch(source, /\bfetch\s*\(/);
});

test("保留文件內容中的 JavaScript replacement pattern", () => {
  const powershellLine = "if ($_ -match '^\\s*([^#=]+)=(.*)$') {";

  assert.ok(html.includes(powershellLine));
  assert.equal((html.match(/<\/main>/g) ?? []).length, 1);
});

test("保留文件搜尋與前後頁導覽", async () => {
  const source = await readFile(new URL("../src/app.mjs", import.meta.url), "utf8");

  assert.match(html, /id="document-search"/);
  assert.match(html, /id="document-previous"/);
  assert.match(html, /id="document-next"/);
  assert.match(source, /search\.addEventListener\("input", filterNavigation\)/);
  assert.match(source, /previousButton\.addEventListener\("click"/);
  assert.match(source, /nextButton\.addEventListener\("click"/);
});

test("提供 Mermaid 全螢幕縮放與拖曳閱讀器", async () => {
  const source = await readFile(new URL("../src/app.mjs", import.meta.url), "utf8");
  const style = await readFile(new URL("../src/style.css", import.meta.url), "utf8");

  assert.match(html, /id="diagram-dialog"/);
  assert.match(html, /data-diagram-action="zoom-in"/);
  assert.match(source, /button\.className = "diagram-zoom-button"/);
  assert.match(source, /dialog\.showModal\(\)/);
  assert.match(source, /addEventListener\(\s*"wheel"/);
  assert.match(source, /addEventListener\("pointermove"/);
  assert.match(style, /\.diagram-dialog::backdrop/);
  assert.match(style, /\.mermaid-frame\s*{[^}]*width: 100%;/s);
  assert.doesNotMatch(style, /calc\(100vw - 320px/);
});

test("為 code block 提供右上角複製按鈕與狀態樣式", async () => {
  const source = await readFile(new URL("../src/app.mjs", import.meta.url), "utf8");
  const style = await readFile(new URL("../src/style.css", import.meta.url), "utf8");

  assert.match(html, /<pre><code class="language-bash">kubectl get pods/);
  assert.match(source, /button\.className = "code-copy-button"/);
  assert.match(source, /code\.textContent \?\? ""/);
  assert.match(source, /navigator\.clipboard/);
  assert.match(source, /createSvgElement\("rect"/);
  assert.match(source, /createSvgElement\("path"/);
  assert.match(source, /setCodeCopyButtonState\(button, "success"\)/);
  assert.match(source, /setCodeCopyButtonState\(button, "error"\)/);
  assert.match(source, /tooltip: "複製"/);
  assert.match(source, /button\.dataset\.tooltip = presentation\.tooltip/);
  assert.match(source, /button\.setAttribute\("aria-label", presentation\.label\)/);
  assert.match(source, /button\.setAttribute\("aria-live", "polite"\)/);
  assert.doesNotMatch(source, /button\.textContent = "(?:複製|已複製|複製失敗)"/);
  assert.match(style, /\.code-block-frame\s*{[^}]*display:\s*grid/s);
  assert.match(
    style,
    /\.code-block-frame\s*{[^}]*grid-template-columns:\s*minmax\(0, 1fr\) 3rem/s,
  );
  assert.match(style, /\.code-block-frame pre\s*{[^}]*grid-column:\s*1/s);
  assert.match(style, /\.code-block-frame pre\s*{[^}]*min-width:\s*0/s);
  assert.match(style, /\.code-block-frame pre\s*{[^}]*border:\s*0/s);
  assert.doesNotMatch(style, /\.code-block-frame pre\s*{[^}]*padding-right:\s*3\.5rem/s);
  assert.doesNotMatch(style, /\.code-block-frame pre\s*{[^}]*padding-top:\s*3\.25rem/s);
  assert.match(style, /\.code-copy-button\s*{[^}]*position:\s*relative/s);
  assert.doesNotMatch(style, /\.code-copy-button\s*{[^}]*position:\s*absolute/s);
  assert.match(style, /\.code-copy-button\s*{[^}]*grid-column:\s*2/s);
  assert.match(style, /\.code-copy-button\s*{[^}]*align-self:\s*start/s);
  assert.match(style, /\.code-copy-button\s*{[^}]*justify-self:\s*center/s);
  assert.match(style, /\.code-copy-button\s*{[^}]*width:\s*2rem/s);
  assert.match(style, /\.code-copy-button\s*{[^}]*height:\s*2rem/s);
  assert.match(style, /\.code-copy-button::before\s*{[^}]*content:\s*attr\(data-tooltip\)/s);
  assert.match(
    style,
    /\.code-copy-button::before\s*{[^}]*right:\s*calc\(100% \+ 0\.55rem\)/s,
  );
  assert.match(style, /\.code-copy-button:focus-visible::before/);
  assert.match(style, /\.code-copy-icon\s*{[^}]*width:\s*0\.875rem/s);
  assert.match(style, /\.code-copy-icon\s*{[^}]*height:\s*0\.875rem/s);
  assert.match(
    style,
    /@media print[\s\S]*\.code-block-frame\s*{[^}]*grid-template-columns:\s*minmax\(0, 1fr\)/s,
  );
});

test("GivenCodeText_WhenCopySucceeds_ShouldPreserveExactContent", async () => {
  const writes = [];
  const clipboard = {
    async writeText(value) {
      writes.push(value);
    },
  };
  const command = "kubectl get pods\nkubectl get services\n";

  await copyCodeToClipboard(command, clipboard);

  assert.deepEqual(writes, [command]);
});

test("GivenClipboardUnavailable_WhenCopyCode_ShouldReject", async () => {
  await assert.rejects(
    copyCodeToClipboard("kubectl get pods", undefined),
    /Clipboard API 不可用/,
  );
});

test("GivenMermaidDialogOpen_WhenPressEscape_ShouldPreventDefaultAndClose", () => {
  let prevented = false;
  let closeCount = 0;
  const event = {
    key: "Escape",
    preventDefault() {
      prevented = true;
    },
  };
  const targetDialog = {
    close() {
      closeCount += 1;
    },
  };

  const handled = closeDialogOnEscape(event, targetDialog);

  assert.equal(handled, true);
  assert.equal(prevented, true);
  assert.equal(closeCount, 1);
});

test("GivenMermaidDialogOpen_WhenPressNonEscape_ShouldRemainOpen", () => {
  const event = {
    key: "Enter",
    preventDefault() {
      assert.fail("非 Escape 鍵不應取消預設行為");
    },
  };
  const targetDialog = {
    close() {
      assert.fail("非 Escape 鍵不應關閉 dialog");
    },
  };

  const handled = closeDialogOnEscape(event, targetDialog);

  assert.equal(handled, false);
});
