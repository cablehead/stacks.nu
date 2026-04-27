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
