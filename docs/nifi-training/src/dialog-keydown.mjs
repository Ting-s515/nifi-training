// 部分 WebView 不會可靠執行原生 dialog 的 Esc 預設行為，因此集中為可測的明確處理。
export function closeDialogOnEscape(event, dialog) {
  if (event.key !== "Escape") {
    return false;
  }

  event.preventDefault();
  dialog.close();
  return true;
}
