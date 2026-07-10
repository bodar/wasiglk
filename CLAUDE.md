# Project Guidelines

## Getting Started

- **Check README.md** for project structure, architecture, and overview
- **Use `./run`** for all common tasks - it auto-installs required tools (Zig, Bun, wasi-sdk):
  - `./run build` - Build all interpreters
  - `./run test` - Run tests
  - `./run serve` or `./run demo` - Start dev server on port 3000 (check if already running first)
  - `./run check` - Type check TypeScript

## Submodules

- **Never modify submodule source code** unless it's temporary for testing purposes
- If temporary changes are made to a submodule, **revert them before committing**
- References to "emglken" in submodules should be left as-is

## Licensing

- Only reference or build against code with **permissive licenses** (MIT, BSD, or similar)
- Code must be usable in commercial projects
- Submodules may contain non-permissively licensed code, but we cannot build against those parts

## Language Preferences

- **System-level code**: Write in Zig, not C
- **TypeScript/JavaScript**: Use Bun in preference over Node
  - Always try Bun first
  - Fall back to Node only if something doesn't work in Bun

## Testing

- **Zig and C code should have inline unit tests** where reasonably possible (pure logic, mappings, conversions)
- Run Zig tests with `./run testZig`; they also run as part of `./run test` and `./run ci`

## Documentation

- **Research and plan markdown lives in `docs/`** — not the repo root. (Only
  `README.md` and `CLAUDE.md` stay at the root; vendored/submodule/package
  READMEs stay where they are.)
- **Filename**: `YYYY-MM-DD-slug-<type>.md`, date-prefixed, kebab-case, where
  `<type>` is `plan` or `research` (e.g. `2026-07-09-graphics-and-blorb-handling-plan.md`).
  The date is when the document was first written.
- **Frontmatter** (YAML) on every such file, matching the talebrary docs format:
  ```yaml
  ---
  title: "Human-readable title"
  date: YYYY-MM-DD
  author: Daniel Bodart
  type: plan | research
  status: in-progress | complete | superseded | blocked
  tags: [kebab, topic, tags]
  ---
  ```
- Keep `status` current as work lands (`in-progress` → `complete`, etc.).

## Browser Automation

- **Never add wait/sleep calls** when using Chrome or Playwright automation tools
- These introduce flakiness and slow down testing unnecessarily
