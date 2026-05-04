// History recall for the pipe-clip input. Up/Down cycle through prior
// pipelines; the list is shipped server-side as `data-history` (JSON, newest
// first). Cursor state lives on the closure -- a fresh open starts at the
// input (cursor = -1) with no row highlighted.
//
// Mounted via:
//   data-init="window.pipeHistory.attach(el)"
//
// keys.js's document-level keydown handler doesn't bind ArrowUp/ArrowDown,
// so we don't need to fight it -- our input listener fires first via bubble
// and that's enough.
//
// Each history row in the DOM carries data-history-index = its position in
// the newest-first list. We toggle `.is-selected` on the row matching the
// current cursor.

(function () {
  let active = null;  // {input, history, cursor, staged}

  function highlight() {
    if (!active) return;
    document.querySelectorAll(".pipe-history-row").forEach(function (btn) {
      const idx = parseInt(btn.dataset.historyIndex, 10);
      btn.classList.toggle("is-selected", idx === active.cursor);
    });
  }

  function attach(input) {
    if (!input || input.dataset.historyAttached === "1") return;
    input.dataset.historyAttached = "1";

    let history = [];
    try { history = JSON.parse(input.dataset.history || "[]"); } catch (_) {}

    active = { input: input, history: history, cursor: -1, staged: "" };

    input.addEventListener("keydown", function (e) {
      if (e.key === "ArrowUp") {
        if (active.cursor < active.history.length - 1) {
          if (active.cursor === -1) active.staged = input.value;
          active.cursor++;
          input.value = active.history[active.cursor];
          input.setSelectionRange(input.value.length, input.value.length);
          highlight();
        }
        e.preventDefault();
        e.stopPropagation();
      } else if (e.key === "ArrowDown") {
        if (active.cursor >= 0) {
          active.cursor--;
          input.value = active.cursor === -1 ? active.staged : active.history[active.cursor];
          input.setSelectionRange(input.value.length, input.value.length);
          highlight();
        }
        e.preventDefault();
        e.stopPropagation();
      } else if (e.key.length === 1) {
        // Typing exits history-recall mode -- once the user starts editing,
        // the highlight stops tracking a row.
        if (active.cursor !== -1) {
          active.cursor = -1;
          highlight();
        }
      }
    });
  }

  // Click-to-load also goes through this to keep the highlighted row in sync.
  function refresh() {
    if (active) {
      active.cursor = -1;
      highlight();
    }
  }

  window.pipeHistory = { attach: attach, refresh: refresh };
})();
