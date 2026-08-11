export async function copyCodeToClipboard(text, clipboard) {
  if (typeof clipboard?.writeText !== "function") {
    throw new Error("Clipboard API 不可用");
  }

  await clipboard.writeText(text);
}
