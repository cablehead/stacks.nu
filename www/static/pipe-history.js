// History recall for the pipe-clip input. Up/Down cycle through prior
// pipelines; the list is shipped server-side as `data-history` (JSON, newest
// first). Cursor state lives on the element (it survives re-renders only as
// long as datastar's idiomorph preserves the same node, which is what we
// want -- Esc closes the dialog and the next open starts fresh).
//
// Mounted via:
//   data-init="window.pipeHistory.attach(el)"
//
// keys.js's document-level keydown handler doesn't bind ArrowUp/ArrowDown,
// so we don't need to fight it -- our input listener fires first via bubble
// and that's enough.

(function () {
  function attach(input) {
    if (!input || input.dataset.historyAttached === "1") return;
    input.dataset.historyAttached = "1";
    let history = [];
    try { history = JSON.parse(input.dataset.history || "[]"); } catch (_) {}
    let cursor = -1;        // -1 = the user's typed input; 0..n-1 = past entries
    let staged = "";        // the user's typed input, stashed when they hit ArrowUp

    input.addEventListener("keydown", function (e) {
      if (e.key === "ArrowUp") {
        if (cursor < history.length - 1) {
          if (cursor === -1) staged = input.value;
          cursor++;
          input.value = history[cursor];
          input.setSelectionRange(input.value.length, input.value.length);
        }
        e.preventDefault();
        e.stopPropagation();
      } else if (e.key === "ArrowDown") {
        if (cursor >= 0) {
          cursor--;
          input.value = cursor === -1 ? staged : history[cursor];
          input.setSelectionRange(input.value.length, input.value.length);
        }
        e.preventDefault();
        e.stopPropagation();
      }
    });
  }

  window.pipeHistory = { attach: attach };
})();
