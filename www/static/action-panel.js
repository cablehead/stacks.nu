// Wires up the actions panel when it mounts. Datastar's data-init on the
// dialog element calls window.actionPanel.mount(el) -- listeners attach
// scoped to that subtree, and they go away with the node when the panel
// is morphed out (mode -> main).
//
// Why mount() and not a global handler: the panel only exists in actions
// mode. A scoped mount is one-line per render and self-cleaning.

(function () {
  function $(el, sel) { return el.querySelector(sel); }
  function $$(el, sel) { return Array.from(el.querySelectorAll(sel)); }

  function visibleRows(panel) {
    return $$(panel, ".action-row").filter(r => r.style.display !== "none");
  }
  function selectedIndex(panel) {
    const rows = visibleRows(panel);
    return rows.findIndex(r => r.classList.contains("is-selected"));
  }
  function setSelected(panel, idx) {
    const rows = visibleRows(panel);
    if (rows.length === 0) return;
    const wrapped = ((idx % rows.length) + rows.length) % rows.length;
    $$(panel, ".action-row").forEach(r => r.classList.remove("is-selected"));
    rows[wrapped].classList.add("is-selected");
    rows[wrapped].scrollIntoView({ block: "nearest" });
  }
  function applyFilter(panel, term) {
    const lower = term.trim().toLowerCase();
    $$(panel, ".action-row").forEach(r => {
      const label = (r.querySelector("span")?.textContent || "").toLowerCase();
      r.style.display = (!lower || label.includes(lower)) ? "" : "none";
    });
    setSelected(panel, 0);
  }
  // Cancel first, then invoke -- so the actions.close frame is appended
  // before any frame the action itself emits (e.g. compose.open from
  // clip.new). Server-side projection sees them in that order.
  function fire(id) {
    fetch("/actions/cancel", { method: "POST" }).finally(() => {
      window.actions.invoke(id);
    });
  }

  window.actionPanel = {
    mount: function (panel) {
      const input = $(panel, "#actions-filter");
      if (input) {
        input.addEventListener("input", () => applyFilter(panel, input.value));
        input.addEventListener("keydown", (e) => {
          if (e.key === "ArrowDown" || (e.ctrlKey && e.key === "n")) {
            e.preventDefault(); e.stopPropagation();
            setSelected(panel, selectedIndex(panel) + 1);
          } else if (e.key === "ArrowUp" || (e.ctrlKey && e.key === "p")) {
            e.preventDefault(); e.stopPropagation();
            setSelected(panel, selectedIndex(panel) - 1);
          } else if (e.key === "Enter") {
            e.preventDefault(); e.stopPropagation();
            const rows = visibleRows(panel);
            const idx = selectedIndex(panel);
            if (idx >= 0) fire(rows[idx].dataset.action);
          }
        });
      }
      panel.addEventListener("mousedown", (e) => {
        const row = e.target.closest(".action-row");
        if (!row || !row.dataset.action) return;
        e.preventDefault();
        fire(row.dataset.action);
      });
      // Close on click outside the panel's inner box. Document-level so
      // clicks on the status bar and other UI also dismiss. Self-cleans
      // when the panel is morphed out of the DOM.
      const inner = panel.firstElementChild;
      const docHandler = (e) => {
        if (!document.body.contains(panel)) {
          document.removeEventListener("mousedown", docHandler);
          return;
        }
        if (inner.contains(e.target)) return;
        document.removeEventListener("mousedown", docHandler);
        fetch("/actions/cancel", { method: "POST" });
      };
      document.addEventListener("mousedown", docHandler);
    },
  };
})();
