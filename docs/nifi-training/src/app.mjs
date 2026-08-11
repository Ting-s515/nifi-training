import mermaid from "mermaid";
import { copyCodeToClipboard } from "./code-copy.mjs";
import { closeDialogOnEscape } from "./dialog-keydown.mjs";

const panels = [...document.querySelectorAll(".document-panel")];
const links = [...document.querySelectorAll(".document-link")];
const defaultPanel = panels[0];
const search = document.querySelector("#document-search");
const currentFile = document.querySelector("#document-current-file");
const previousButton = document.querySelector("#document-previous");
const nextButton = document.querySelector("#document-next");
const dialog = document.querySelector("#diagram-dialog");
const viewport = document.querySelector("#diagram-viewport");
const canvas = document.querySelector("#diagram-canvas");
const zoomLevel = document.querySelector("#diagram-zoom-level");
const zoomInButton = dialog.querySelector('[data-diagram-action="zoom-in"]');
const zoomOutButton = dialog.querySelector('[data-diagram-action="zoom-out"]');
const resetButton = dialog.querySelector('[data-diagram-action="reset"]');
const closeButton = dialog.querySelector('[data-diagram-action="close"]');
const minimumScale = 0.2;
const maximumScale = 5;
const zoomFactor = 1.2;
const copyFeedbackDuration = 1800;
const svgNamespace = "http://www.w3.org/2000/svg";
const copyButtonPresentations = {
  idle: {
    label: "複製此指令或程式碼",
    tooltip: "複製",
  },
  success: {
    label: "已複製",
    tooltip: "已複製",
  },
  error: {
    label: "複製失敗",
    tooltip: "複製失敗",
  },
};
const diagramState = {
  canvasHeight: 0,
  canvasWidth: 0,
  lastPointerX: 0,
  lastPointerY: 0,
  offsetX: 0,
  offsetY: 0,
  opener: null,
  placeholder: null,
  scale: 1,
  svg: null,
  svgStyle: null,
  dragging: false,
};

mermaid.initialize({
  startOnLoad: false,
  securityLevel: "strict",
  theme: "base",
  themeVariables: {
    background: "#fffdf8",
    primaryColor: "#fff7df",
    primaryTextColor: "#342717",
    primaryBorderColor: "#b8924d",
    lineColor: "#72531d",
    secondaryColor: "#f4eddf",
    tertiaryColor: "#faf7ef",
  },
});

function findTarget() {
  const hash = window.location.hash.slice(1);
  let id = hash;

  try {
    id = decodeURIComponent(hash);
  } catch {
    id = hash;
  }

  return id ? document.getElementById(id) : defaultPanel;
}

function filterNavigation() {
  const query = search.value.trim().toLocaleLowerCase("zh-Hant");

  for (const section of document.querySelectorAll(".navigation-section")) {
    let visibleCount = 0;

    for (const link of section.querySelectorAll(".document-link")) {
      const text = link.textContent.toLocaleLowerCase("zh-Hant");
      const visible = !query || text.includes(query);

      link.closest("li").hidden = !visible;
      visibleCount += visible ? 1 : 0;
    }

    section.hidden = visibleCount === 0;
  }
}

function updateDocumentToolbar(activePanel) {
  const currentIndex = panels.indexOf(activePanel);

  currentFile.textContent = activePanel.dataset.documentPath ?? "";
  previousButton.disabled = currentIndex <= 0;
  nextButton.disabled = currentIndex === panels.length - 1;
}

function navigateDocument(offset) {
  const activePanel = findTarget()?.closest(".document-panel") ?? defaultPanel;
  const currentIndex = panels.indexOf(activePanel);
  const targetIndex = currentIndex + offset;

  if (targetIndex < 0 || targetIndex >= panels.length) {
    return;
  }

  window.location.hash = panels[targetIndex].id;
}

function clamp(value, minimum, maximum) {
  return Math.min(Math.max(value, minimum), maximum);
}

function updateDiagramTransform() {
  canvas.style.transform = `translate3d(${diagramState.offsetX}px, ${diagramState.offsetY}px, 0) scale(${diagramState.scale})`;
  zoomLevel.value = `${Math.round(diagramState.scale * 100)}%`;
  zoomLevel.textContent = zoomLevel.value;
}

function readDiagramSize(svg) {
  const viewBox = svg.viewBox?.baseVal;

  if (viewBox?.width > 0 && viewBox?.height > 0) {
    return { height: viewBox.height, width: viewBox.width };
  }

  const bounds = svg.getBoundingClientRect();
  return {
    height: Math.max(bounds.height, 1),
    width: Math.max(bounds.width, 1),
  };
}

function fitDiagram() {
  const bounds = viewport.getBoundingClientRect();
  const horizontalPadding = 64;
  const verticalPadding = 64;
  const widthScale = (bounds.width - horizontalPadding) / diagramState.canvasWidth;
  const heightScale = (bounds.height - verticalPadding) / diagramState.canvasHeight;

  diagramState.scale = clamp(
    Math.min(widthScale, heightScale),
    minimumScale,
    maximumScale,
  );
  diagramState.offsetX = 0;
  diagramState.offsetY = 0;
  updateDiagramTransform();
}

function changeZoom(multiplier) {
  diagramState.scale = clamp(
    diagramState.scale * multiplier,
    minimumScale,
    maximumScale,
  );
  updateDiagramTransform();
}

function openDiagram(source, opener) {
  const svg = source.querySelector("svg");

  if (!svg || dialog.open) {
    return;
  }

  const size = readDiagramSize(svg);
  const placeholder = document.createComment("Mermaid diagram placeholder");

  source.insertBefore(placeholder, svg);
  diagramState.canvasHeight = size.height;
  diagramState.canvasWidth = size.width;
  diagramState.opener = opener;
  diagramState.placeholder = placeholder;
  diagramState.svg = svg;
  diagramState.svgStyle = svg.getAttribute("style");

  canvas.style.height = `${size.height}px`;
  canvas.style.width = `${size.width}px`;
  svg.style.height = "100%";
  svg.style.maxWidth = "none";
  svg.style.width = "100%";
  canvas.replaceChildren(svg);

  dialog.showModal();
  requestAnimationFrame(fitDiagram);
}

function restoreDiagram() {
  if (!diagramState.svg || !diagramState.placeholder) {
    return;
  }

  if (diagramState.svgStyle === null) {
    diagramState.svg.removeAttribute("style");
  } else {
    diagramState.svg.setAttribute("style", diagramState.svgStyle);
  }

  diagramState.placeholder.replaceWith(diagramState.svg);
  canvas.replaceChildren();
  canvas.removeAttribute("style");
  diagramState.dragging = false;
  viewport.classList.remove("is-dragging");
  diagramState.opener?.focus();
  diagramState.opener = null;
  diagramState.placeholder = null;
  diagramState.svg = null;
  diagramState.svgStyle = null;
}

function enhanceMermaid(panel) {
  const diagrams = panel.querySelectorAll(
    '.mermaid[data-processed]:not([data-zoom-ready])',
  );

  for (const diagram of diagrams) {
    if (!diagram.querySelector("svg")) {
      continue;
    }

    const frame = document.createElement("div");
    const button = document.createElement("button");

    frame.className = "mermaid-frame";
    button.className = "diagram-zoom-button";
    button.type = "button";
    button.textContent = "🔍 放大";
    button.setAttribute("aria-label", "放大 Mermaid 圖表");
    diagram.before(frame);
    frame.append(button, diagram);
    diagram.dataset.zoomReady = "true";
    diagram.tabIndex = 0;
    diagram.setAttribute("role", "button");
    diagram.setAttribute("aria-label", "點擊開啟 Mermaid 圖表放大檢視");

    button.addEventListener("click", () => openDiagram(diagram, button));
    diagram.addEventListener("click", () => openDiagram(diagram, diagram));
    diagram.addEventListener("keydown", (event) => {
      if (event.key === "Enter" || event.key === " ") {
        event.preventDefault();
        openDiagram(diagram, diagram);
      }
    });
  }
}

// SVG 由 DOM API 建立，避免互動程式引入需要解析的 HTML 字串。
function createSvgElement(name, attributes) {
  const element = document.createElementNS(svgNamespace, name);

  for (const [attribute, value] of Object.entries(attributes)) {
    element.setAttribute(attribute, value);
  }

  return element;
}

// 成功狀態改用 Check icon，讓學員不需閱讀文字也能確認複製結果。
function createCodeCopyIcon(state) {
  const icon = createSvgElement("svg", {
    "aria-hidden": "true",
    class: "code-copy-icon",
    focusable: "false",
    viewBox: "0 0 24 24",
  });

  if (state === "success") {
    icon.append(
      createSvgElement("path", {
        d: "M5 12.5l4 4L19 7",
      }),
    );
    return icon;
  }

  icon.append(
    createSvgElement("rect", {
      height: "11",
      rx: "2",
      width: "11",
      x: "4",
      y: "4",
    }),
    createSvgElement("rect", {
      height: "11",
      rx: "2",
      width: "11",
      x: "9",
      y: "9",
    }),
  );
  return icon;
}

// Tooltip 與 aria-label 同步狀態，讓滑鼠和輔助科技取得一致回饋。
function setCodeCopyButtonState(button, state) {
  const presentation = copyButtonPresentations[state];

  button.replaceChildren(createCodeCopyIcon(state));
  button.dataset.copyState = state;
  button.dataset.tooltip = presentation.tooltip;
  button.setAttribute("aria-label", presentation.label);
}

function enhanceCodeBlocks(panel) {
  const blocks = panel.querySelectorAll("pre:not([data-copy-ready])");

  for (const block of blocks) {
    const code = block.querySelector(":scope > code");

    if (!code) {
      continue;
    }

    const frame = document.createElement("div");
    const button = document.createElement("button");
    let resetTimer;

    frame.className = "code-block-frame";
    button.className = "code-copy-button";
    button.type = "button";
    button.setAttribute("aria-live", "polite");
    setCodeCopyButtonState(button, "idle");
    block.before(frame);
    frame.append(block, button);
    block.dataset.copyReady = "true";

    button.addEventListener("click", async () => {
      window.clearTimeout(resetTimer);
      button.disabled = true;

      try {
        await copyCodeToClipboard(code.textContent ?? "", navigator.clipboard);
        setCodeCopyButtonState(button, "success");
      } catch {
        setCodeCopyButtonState(button, "error");
      } finally {
        button.disabled = false;
        resetTimer = window.setTimeout(() => {
          setCodeCopyButtonState(button, "idle");
        }, copyFeedbackDuration);
      }
    });
  }
}

async function renderMermaid(panel) {
  const nodes = panel.querySelectorAll(".mermaid:not([data-processed])");

  if (nodes.length === 0) {
    enhanceMermaid(panel);
    return;
  }

  try {
    await mermaid.run({ nodes });
    enhanceMermaid(panel);
  } catch (error) {
    console.error("Mermaid 圖表渲染失敗", error);
  }
}

async function showDocument() {
  const target = findTarget();
  const activePanel = target?.closest(".document-panel") ?? defaultPanel;

  for (const panel of panels) {
    panel.hidden = panel !== activePanel;
  }

  for (const link of links) {
    const isActive = link.hash === `#${activePanel.id}`;
    link.classList.toggle("is-active", isActive);

    if (isActive) {
      link.setAttribute("aria-current", "page");
    } else {
      link.removeAttribute("aria-current");
    }
  }

  updateDocumentToolbar(activePanel);
  enhanceCodeBlocks(activePanel);
  await renderMermaid(activePanel);

  if (target && target !== activePanel) {
    requestAnimationFrame(() => target.scrollIntoView());
  } else {
    window.scrollTo({ top: 0 });
  }
}

search.addEventListener("input", filterNavigation);
previousButton.addEventListener("click", () => navigateDocument(-1));
nextButton.addEventListener("click", () => navigateDocument(1));
window.addEventListener("hashchange", showDocument);
zoomInButton.addEventListener("click", () => changeZoom(zoomFactor));
zoomOutButton.addEventListener("click", () => changeZoom(1 / zoomFactor));
resetButton.addEventListener("click", fitDiagram);
closeButton.addEventListener("click", () => dialog.close());
dialog.addEventListener("close", restoreDiagram);
dialog.addEventListener("keydown", (event) => closeDialogOnEscape(event, dialog));
dialog.addEventListener("click", (event) => {
  if (event.target === dialog) {
    dialog.close();
  }
});
viewport.addEventListener(
  "wheel",
  (event) => {
    event.preventDefault();
    changeZoom(event.deltaY < 0 ? zoomFactor : 1 / zoomFactor);
  },
  { passive: false },
);
viewport.addEventListener("pointerdown", (event) => {
  if (event.button !== 0) {
    return;
  }

  event.preventDefault();
  diagramState.dragging = true;
  diagramState.lastPointerX = event.clientX;
  diagramState.lastPointerY = event.clientY;
  viewport.classList.add("is-dragging");
  viewport.setPointerCapture(event.pointerId);
});
viewport.addEventListener("pointermove", (event) => {
  if (!diagramState.dragging) {
    return;
  }

  diagramState.offsetX += event.clientX - diagramState.lastPointerX;
  diagramState.offsetY += event.clientY - diagramState.lastPointerY;
  diagramState.lastPointerX = event.clientX;
  diagramState.lastPointerY = event.clientY;
  updateDiagramTransform();
});

function stopDragging(event) {
  diagramState.dragging = false;
  viewport.classList.remove("is-dragging");

  if (viewport.hasPointerCapture(event.pointerId)) {
    viewport.releasePointerCapture(event.pointerId);
  }
}

viewport.addEventListener("pointerup", stopDragging);
viewport.addEventListener("pointercancel", stopDragging);
window.addEventListener("resize", () => {
  if (dialog.open) {
    fitDiagram();
  }
});
filterNavigation();
void showDocument();
