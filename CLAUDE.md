## Git Commit Style Preferences

**NEVER commit unless explicitly asked by the user.**

When committing: review `git diff`

- Use conventional commit format: `type: subject line`
- Keep subject line concise and descriptive
- **NEVER include marketing language, promotional text, or AI attribution**
- **NEVER add "Generated with Claude Code", "Co-Authored-By: Claude", or similar
  spam**
- Follow existing project patterns from git log
- Prefer just a subject and no body, unless the change is particularly complex

Example good commit messages from this project:

- `feat: 3-pane datastar ui for stacks on xs event store`
- `feat: clip.add bumps selection to the new clip in auto stacks`
- `refactor: move site into www/ so -w doesn't watch ./store`
- `fix: drop unnecessary -p 5000 pulse from .cat -f`
- `fix: compose submit posts textarea body; drop signals`

## Tone and Communication

- ASCII only. No em dashes, smart quotes, or other unicode punctuation. Use "--"
  only in code contexts, not as prose punctuation.
- No wasted words. No fluff. Each word should add value to the reader.
- Human readable and clear.
- Calm, matter-of-fact technical tone.

## Code Quality

Run `http-nu eval --store /tmp/test ./www/test.nu` before committing. Use ASCII
characters only in code, comments, and documentation.

## Markup and CSS

### Markup

- The static page shell is built with **http-nu's HTML DSL** in Nushell, so
  helpers like `SCRIPT-ICONIFY` come for free and we stay inside the
  convention layer.
- Anything that morphs per state is a **minijinja2 template** rendered
  server-side and sent over SSE as a `datastar-patch-elements` patch.
- Tags are **semantic**: `<main>`, `<aside>`, `<section>`, `<article>`,
  `<nav>`, `<footer>`, `<figure>` / `<figcaption>`, `<button>`, `<kbd>`,
  with `aria-label` on landmarks. Per-element `class` only when state
  variants are needed.
- One source of truth per concern. The keymap lives in **one**
  `data-keymap='...'` JSON on `<main>`; the keyboard listener and the
  clickable status-bar bindings both read from it.

### CSS

- **Stellar** (`http://localhost:7331/assets/css/stellar`) supplies the
  variables: `--neutral-N`, `--primary-N`, `--font-size-N`,
  `--font-line-height-N`, `--border-radius-N`, `--font-mono` / `--font-sans`.
  Pull from those rather than typing literals.
- `www/static/base.css` is a thin **element skin** that wires bare semantic
  tags to those tokens (`body`, `button`, `kbd`, `a`, `pre`, `::selection`).
  It also holds the few class rules we own (`.binding`, `.binding:hover`).
- **Inline `style="..."`** for layout that's unique to one element (a
  one-off grid template, padding, flex direction). Tokens still drive the
  values: `style="padding: var(--font-line-height--1) var(--font-size--1);"`.
- **Classes** when we need `:hover` / `:focus` variants, or to toggle a
  state from JS (`.is-hover` on a binding for screenshot poses).
- No bundler, no CSS-in-JS, no Tailwind. Tokens + a small skin + per-element
  inline styles.

### Style minutiae

- ASCII only. Apple symbol keys (`cmd`, `shift`, `return`) are unicode
  characters, NOT SVGs -- they need to scale with the font, line up
  baseline-wise, and be selectable.
- Reach for **iconify** (`<iconify-icon icon="lucide:...">`) only for action
  icons (sort toggle), never for keyboard hints.
- `<kbd>` is a square 1.5em tile; widens for multi-char keys (`ESC`).
