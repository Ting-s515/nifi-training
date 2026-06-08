import { readdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const currentFile = fileURLToPath(import.meta.url);
const templateDir = path.dirname(currentFile);
const trainingDir = path.resolve(templateDir, "..");
const outputFile = path.join(trainingDir, "index.html");
const templateFile = path.join(templateDir, "training-layout.mdx");

const markdownExtensions = new Set([".md", ".mdx"]);

const slugCounts = new Map();

function escapeHtml(value) {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function slugify(value) {
  const normalized = value
    .trim()
    .toLowerCase()
    .replace(/[^\p{L}\p{N}]+/gu, "-")
    .replace(/^-+|-+$/g, "");

  return normalized || "section";
}

function uniqueSlug(value) {
  const base = slugify(value);
  const count = slugCounts.get(base) || 0;
  slugCounts.set(base, count + 1);
  return count === 0 ? base : `${base}-${count + 1}`;
}

function splitTableRow(line) {
  return line
    .trim()
    .replace(/^\|/, "")
    .replace(/\|$/, "")
    .split("|")
    .map((cell) => cell.trim());
}

function isTableDivider(line) {
  return /^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?\s*$/.test(line);
}

function isUnorderedList(line) {
  return /^\s*[-*+]\s+/.test(line);
}

function isOrderedList(line) {
  return /^\s*\d+\.\s+/.test(line);
}

function getListText(line) {
  return line.replace(/^\s*(?:[-*+]|\d+\.)\s+/, "");
}

function resolveDocumentLink(href) {
  if (!/\.mdx?(#.*)?$/i.test(href)) {
    return href;
  }

  const [fileName, hash = ""] = href.split("#");
  const slug = slugify(path.basename(fileName).replace(/\.mdx?$/i, ""));
  return hash ? `#${slug}-${slugify(hash)}` : `#${slug}`;
}

// 這裡只實作課程文件會用到的 Markdown 子集，避免閱讀器需要 npm 相依套件。
function renderInline(value) {
  const tokens = [];
  let text = value.replace(/`([^`]+)`/g, (_, code) => {
    const token = `@@CODE_${tokens.length}@@`;
    tokens.push(`<code>${escapeHtml(code)}</code>`);
    return token;
  });

  text = text.replace(/!\[([^\]]*)\]\(([^)]+)\)/g, (_, alt, src) => {
    const token = `@@CODE_${tokens.length}@@`;
    tokens.push(`<img src="${escapeHtml(src)}" alt="${escapeHtml(alt)}" />`);
    return token;
  });

  text = text.replace(/\[([^\]]+)\]\(([^)]+)\)/g, (_, label, href) => {
    const token = `@@CODE_${tokens.length}@@`;
    const resolvedHref = resolveDocumentLink(href);
    tokens.push(`<a href="${escapeHtml(resolvedHref)}">${renderInline(label)}</a>`);
    return token;
  });

  text = escapeHtml(text);
  text = text
    .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>")
    .replace(/\*([^*]+)\*/g, "<em>$1</em>");

  for (const [index, html] of tokens.entries()) {
    text = text.replaceAll(`@@CODE_${index}@@`, html);
  }

  return text;
}

function renderParagraph(lines) {
  return `<p>${renderInline(lines.join(" "))}</p>`;
}

function renderList(lines, ordered) {
  const tag = ordered ? "ol" : "ul";
  const items = lines.map((line) => `<li>${renderInline(getListText(line))}</li>`).join("\n");
  return `<${tag}>\n${items}\n</${tag}>`;
}

function renderTable(lines) {
  const header = splitTableRow(lines[0]);
  const bodyRows = lines.slice(2).map(splitTableRow);
  const head = header.map((cell) => `<th>${renderInline(cell)}</th>`).join("");
  const body = bodyRows
    .map((row) => `<tr>${row.map((cell) => `<td>${renderInline(cell)}</td>`).join("")}</tr>`)
    .join("\n");

  return `<table>\n<thead><tr>${head}</tr></thead>\n<tbody>\n${body}\n</tbody>\n</table>`;
}

function renderBlockquote(lines) {
  const content = lines.map((line) => line.replace(/^\s*>\s?/, "")).join("\n");
  return `<blockquote>\n${markdownToHtml(content)}\n</blockquote>`;
}

// 產生靜態 HTML 可讓課程離線閱讀，並保留原始 Markdown 作為主要編輯來源。
function markdownToHtml(markdown) {
  const lines = markdown.replace(/^\uFEFF/, "").replace(/\r\n/g, "\n").split("\n");
  const blocks = [];
  let index = 0;

  while (index < lines.length) {
    const line = lines[index];

    if (!line.trim()) {
      index += 1;
      continue;
    }

    const fenceMatch = line.match(/^\s*(```|~~~)\s*([\w-]*)\s*$/);
    if (fenceMatch) {
      const fence = fenceMatch[1];
      const language = fenceMatch[2];
      const codeLines = [];
      index += 1;

      while (index < lines.length && !lines[index].startsWith(fence)) {
        codeLines.push(lines[index]);
        index += 1;
      }

      index += 1;
      blocks.push(
        `<pre><code class="language-${escapeHtml(language)}">${escapeHtml(codeLines.join("\n"))}</code></pre>`,
      );
      continue;
    }

    const headingMatch = line.match(/^(#{1,6})\s+(.+)$/);
    if (headingMatch) {
      const level = headingMatch[1].length;
      const text = headingMatch[2].trim();
      const id = uniqueSlug(text);
      blocks.push(`<h${level} id="${id}">${renderInline(text)}</h${level}>`);
      index += 1;
      continue;
    }

    if (/^\s*---+\s*$/.test(line)) {
      blocks.push("<hr />");
      index += 1;
      continue;
    }

    if (/^\s*>/.test(line)) {
      const quoteLines = [];
      while (index < lines.length && /^\s*>/.test(lines[index])) {
        quoteLines.push(lines[index]);
        index += 1;
      }
      blocks.push(renderBlockquote(quoteLines));
      continue;
    }

    if (line.includes("|") && index + 1 < lines.length && isTableDivider(lines[index + 1])) {
      const tableLines = [line, lines[index + 1]];
      index += 2;
      while (index < lines.length && lines[index].includes("|") && lines[index].trim()) {
        tableLines.push(lines[index]);
        index += 1;
      }
      blocks.push(renderTable(tableLines));
      continue;
    }

    if (isUnorderedList(line) || isOrderedList(line)) {
      const ordered = isOrderedList(line);
      const listLines = [];
      while (
        index < lines.length &&
        lines[index].trim() &&
        (ordered ? isOrderedList(lines[index]) : isUnorderedList(lines[index]))
      ) {
        listLines.push(lines[index]);
        index += 1;
      }
      blocks.push(renderList(listLines, ordered));
      continue;
    }

    const paragraphLines = [line.trim()];
    index += 1;
    while (
      index < lines.length &&
      lines[index].trim() &&
      !lines[index].match(/^(#{1,6})\s+(.+)$/) &&
      !lines[index].match(/^\s*(```|~~~)/) &&
      !lines[index].match(/^\s*>/) &&
      !(lines[index].includes("|") && index + 1 < lines.length && isTableDivider(lines[index + 1])) &&
      !isUnorderedList(lines[index]) &&
      !isOrderedList(lines[index])
    ) {
      paragraphLines.push(lines[index].trim());
      index += 1;
    }
    blocks.push(renderParagraph(paragraphLines));
  }

  return blocks.join("\n");
}

function extractTitle(markdown, fallback) {
  const heading = markdown.match(/^#\s+(.+)$/m);
  return heading ? heading[1].trim() : fallback;
}

async function getSourceFiles() {
  const entries = await readdir(trainingDir, { withFileTypes: true });

  return entries
    .filter((entry) => entry.isFile())
    .map((entry) => entry.name)
    .filter((fileName) => markdownExtensions.has(path.extname(fileName).toLowerCase()))
    .sort((left, right) => left.localeCompare(right, "zh-Hant"));
}

async function build() {
  const [template, sourceFiles] = await Promise.all([readFile(templateFile, "utf8"), getSourceFiles()]);
  const documents = [];

  for (const fileName of sourceFiles) {
    slugCounts.clear();
    const source = await readFile(path.join(trainingDir, fileName), "utf8");
    const id = slugify(fileName.replace(/\.mdx?$/i, ""));
    documents.push({
      id,
      file: fileName,
      title: extractTitle(source, fileName),
      html: markdownToHtml(source),
    });
  }

  const generatedAt = new Intl.DateTimeFormat("zh-TW", {
      dateStyle: "medium",
      timeStyle: "short",
    }).format(new Date());
  const documentData = JSON.stringify(documents, null, 2).replaceAll("</script", "<\\/script");

  const html = template
    .replace("{{DOCUMENT_COUNT}}", () => String(documents.length))
    .replace("{{GENERATED_AT}}", () => generatedAt)
    .replace("{{DOCUMENT_DATA}}", () => documentData);

  await writeFile(outputFile, html, "utf8");
  console.log(`Generated ${path.relative(process.cwd(), outputFile)} from ${documents.length} files.`);
}

await build();
