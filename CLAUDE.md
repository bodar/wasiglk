# Project Guidelines

## Getting Started

- **Check README.md** for project structure, architecture, and overview
- **Use `./run`** for all common tasks - it auto-installs required tools (Zig, Bun, wasi-sdk):
  - `./run build` - Build all interpreters
  - `./run test` - Run tests
  - `./run serve` or `./run demo` - Start dev server on port 3000 (check if already running first)
  - `./run typecheck` - Type check TypeScript

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

## Browser Automation

- **Never add wait/sleep calls** when using Chrome or Playwright automation tools
- These introduce flakiness and slow down testing unnecessarily
