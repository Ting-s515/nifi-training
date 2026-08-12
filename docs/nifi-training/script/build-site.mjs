import { createHash } from "node:crypto";
import { mkdir, readFile, readdir, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { build } from "esbuild";
import rehypeSlug from "rehype-slug";
import rehypeStringify from "rehype-stringify";
import remarkGfm from "remark-gfm";
import remarkParse from "remark-parse";
import remarkRehype from "remark-rehype";
import { unified } from "unified";

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const webDirectory = path.resolve(scriptDirectory, "..");
const defaultDocsDirectory = webDirectory;
const sourceDirectory = path.join(webDirectory, "src");
const defaultOutputDirectory = webDirectory;
const generatedFileNames = ["index.html", "style.css", "app.mjs"];
const defaultSiteMetadata = {
  name: "NiFi 實作入門課程",
  title: "NiFi 實作入門課程",
  description: "Apache NiFi 2.9.0 本機環境的實作課程與操作文件",
};

const sectionDefinitions = [
  { key: "entry", title: "課程入口" },
  { key: "labs", title: "核心課程" },
  { key: "reference", title: "速查表" },
  { key: "supplement", title: "補充文件" },
];
const sectionOrder = new Map(
  sectionDefinitions.map(({ key }, index) => [key, index]),
);

function visit(node, callback) {
  callback(node);

  if (Array.isArray(node.children)) {
    for (const child of node.children) {
      visit(child, callback);
    }
  }
}

function escapeHtml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll('"', "&quot;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;");
}

function safeDecodeURIComponent(value) {
  try {
    return decodeURIComponent(value);
  } catch {
    return value;
  }
}

export function createDocumentId(fileName) {
  const slug = fileName
    .replace(/\.md$/i, "")
    .normalize("NFKC")
    .toLowerCase()
    .replace(/[^\p{Letter}\p{Number}]+/gu, "-")
    .replace(/^-|-$/g, "");
  // 完整檔名 hash 讓相同 slug 仍保持唯一，同時保留可讀的前半段。
  const suffix = createHash("sha256")
    .update(fileName)
    .digest("hex")
    .slice(0, 8);

  return `doc-${slug || "document"}-${suffix}`;
}

function getSection(fileName) {
  if (fileName === "README.md") {
    return "entry";
  }

  if (fileName === "99-cheatsheet.md") {
    return "reference";
  }

  if (fileName.toLowerCase().startsWith("supplement-")) {
    return "supplement";
  }

  return "labs";
}

function getTitle(markdown, fileName) {
  const heading = markdown.match(/^#\s+(.+)$/m)?.[1]?.trim();
  return heading ?? fileName.replace(/\.md$/i, "");
}

function isExternalLink(href) {
  return /^(?:[a-z][a-z0-9+.-]*:|\/\/)/i.test(href);
}

function resolveDocumentLink(href, currentFile, documentIds) {
  if (href.startsWith("#")) {
    return `#${documentIds.get(currentFile)}--${safeDecodeURIComponent(href.slice(1))}`;
  }

  if (isExternalLink(href)) {
    return href;
  }

  const [linkedPath, fragment] = href.split("#", 2);
  const decodedPath = safeDecodeURIComponent(linkedPath).replaceAll("\\", "/");

  if (!decodedPath.toLowerCase().endsWith(".md")) {
    return href;
  }

  const targetFile = path.posix.normalize(
    path.posix.join(path.posix.dirname(currentFile), decodedPath),
  );
  const targetId = documentIds.get(targetFile);

  if (!targetId) {
    return href;
  }

  return fragment
    ? `#${targetId}--${safeDecodeURIComponent(fragment)}`
    : `#${targetId}`;
}

function rehypePrepareStaticDocument(options) {
  const { currentFile, documentIds } = options;
  const currentId = documentIds.get(currentFile);

  return (tree) => {
    visit(tree, (node) => {
      if (node.type !== "element") {
        return;
      }

      node.properties ??= {};

      if (node.properties.id) {
        node.properties.id = `${currentId}--${node.properties.id}`;
      }

      if (node.tagName === "a" && typeof node.properties.href === "string") {
        const href = node.properties.href;
        node.properties.href = resolveDocumentLink(
          href,
          currentFile,
          documentIds,
        );

        if (isExternalLink(href)) {
          node.properties.target = "_blank";
          node.properties.rel = ["noreferrer", "noopener"];
        }
      }

      if (
        node.tagName === "pre" &&
        node.children?.length === 1 &&
        node.children[0].tagName === "code" &&
        node.children[0].properties?.className?.includes("language-mermaid")
      ) {
        const source = node.children[0].children
          .filter((child) => child.type === "text")
          .map((child) => child.value)
          .join("");

        node.tagName = "div";
        node.properties = { className: ["mermaid"] };
        node.children = [{ type: "text", value: source }];
      }
    });
  };
}

async function renderMarkdown(markdown, currentFile, documentIds) {
  const rendered = await unified()
    .use(remarkParse)
    .use(remarkGfm)
    .use(remarkRehype, {
      footnoteLabel: "註腳",
      footnoteBackLabel: "返回內容",
    })
    .use(rehypeSlug)
    .use(rehypePrepareStaticDocument, { currentFile, documentIds })
    .use(rehypeStringify)
    .process(markdown);

  return String(rendered);
}

async function readDocuments(docsDirectory) {
  const fileNames = (await readdir(docsDirectory))
    .filter((fileName) => fileName.toLowerCase().endsWith(".md"))
    .sort((left, right) => {
      const sectionDifference =
        sectionOrder.get(getSection(left)) - sectionOrder.get(getSection(right));

      return sectionDifference || left.localeCompare(right, "zh-Hant");
    });
  const documentIds = new Map(
    fileNames.map((fileName) => [fileName, createDocumentId(fileName)]),
  );

  return Promise.all(
    fileNames.map(async (fileName) => {
      const markdown = await readFile(path.join(docsDirectory, fileName), "utf8");

      return {
        fileName,
        id: documentIds.get(fileName),
        section: getSection(fileName),
        title: getTitle(markdown, fileName),
        html: await renderMarkdown(markdown, fileName, documentIds),
      };
    }),
  );
}

function renderNavigation(documents) {
  const firstDocumentId = documents[0]?.id;

  return sectionDefinitions
    .map(({ key, title }) => {
      const links = documents
        .filter((document) => document.section === key)
        .map(
          (document) => `
            <li>
              <a class="document-link${document.id === firstDocumentId ? " is-active" : ""}" href="#${document.id}"${document.id === firstDocumentId ? ' aria-current="page"' : ""}>
                <span class="document-title">${escapeHtml(document.title)}</span>
                <span class="document-file">${escapeHtml(document.fileName)}</span>
              </a>
            </li>`,
        )
        .join("");

      return `
        <section class="navigation-section">
          <h2>${title}</h2>
          <ul>${links}
          </ul>
        </section>`;
    })
    .join("");
}

function renderContent(documents) {
  return documents
    .map((document, index) => {
      const hiddenAttribute = index === 0 ? "" : "\n          hidden";

      return `
        <article
          class="document-panel markdown-body"
          id="${document.id}"
          data-document-path="${escapeHtml(document.fileName)}"
          aria-label="${escapeHtml(document.title)}"${hiddenAttribute}
        >
${document.html}
        </article>`;
    })
    .join("");
}

async function cleanOutputDirectory(outputDirectory) {
  const resolvedOutputDirectory = path.resolve(outputDirectory);

  if (resolvedOutputDirectory === path.resolve(webDirectory)) {
    // 根目錄同時保存 Markdown 來源，因此只能清理本次產生的三個檔案。
    await Promise.all(
      generatedFileNames.map((fileName) =>
        rm(path.join(resolvedOutputDirectory, fileName), { force: true }),
      ),
    );
    return;
  }

  await rm(resolvedOutputDirectory, { recursive: true, force: true });
}

export async function buildSite({
  docsDirectory = defaultDocsDirectory,
  outputDirectory = defaultOutputDirectory,
  siteMetadata = {},
} = {}) {
  const documents = await readDocuments(docsDirectory);
  const resolvedSiteMetadata = { ...defaultSiteMetadata, ...siteMetadata };
  const template = await readFile(path.join(sourceDirectory, "index.html"), "utf8");
  const html = template
    .replaceAll("{{SITE_NAME}}", () => escapeHtml(resolvedSiteMetadata.name))
    .replaceAll("{{SITE_TITLE}}", () => escapeHtml(resolvedSiteMetadata.title))
    .replaceAll("{{SITE_DESCRIPTION}}", () => escapeHtml(resolvedSiteMetadata.description))
    .replace("{{DOCUMENT_COUNT}}", () => String(documents.length))
    .replace("<!-- DOCUMENT_NAVIGATION -->", () => renderNavigation(documents))
    .replace("<!-- DOCUMENT_CONTENT -->", () => renderContent(documents));

  await cleanOutputDirectory(outputDirectory);
  await mkdir(outputDirectory, { recursive: true });
  await Promise.all([
    writeFile(path.join(outputDirectory, "index.html"), html, "utf8"),
    readFile(path.join(sourceDirectory, "style.css"), "utf8").then((css) =>
      writeFile(path.join(outputDirectory, "style.css"), css, "utf8"),
    ),
    build({
      entryPoints: [path.join(sourceDirectory, "app.mjs")],
      bundle: true,
      format: "esm",
      target: "es2022",
      minify: true,
      outfile: path.join(outputDirectory, "app.mjs"),
      logLevel: "silent",
    }),
  ]);

  const appFile = path.join(outputDirectory, "app.mjs");
  const appSource = await readFile(appFile, "utf8");
  // Mermaid bundle 會保留語法片段的行尾空白，清理後才能通過 repository whitespace 檢查。
  await writeFile(appFile, appSource.replace(/[ \t]+$/gm, ""), "utf8");

  return { documentCount: documents.length, outputDirectory };
}

const invokedFile = process.argv[1] ? pathToFileURL(path.resolve(process.argv[1])).href : "";

if (import.meta.url === invokedFile) {
  const result = await buildSite();
  console.log(
    `已產生 ${result.documentCount} 份文件：${path.join(result.outputDirectory, "index.html")}`,
  );
}
