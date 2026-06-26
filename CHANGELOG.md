# Changelog

All notable changes to ThemeMate are documented here.

Format: `[version] YYYY-MM-DD — description`

---

## [1.0.0] 2026-06-26

Initial release.

**Workflow**
- Local-first workflow: pull theme, implement on feature branch, test with `shopify theme dev`, open PR — stop there
- Merchant store copy theme and GitHub connection are human-only post-merge steps; ThemeMate never pushes to merchant store during development

**Browser validation**
- DOM eval-first validation replacing screenshot loop: `browser_evaluate` for functional checks, `browser_snapshot` for structural checks, screenshots only for brand discovery and visual issues that cannot be verified via DOM
- Screenshot discipline: save to session scratchpad, delete after analysis, never leave in project or git-tracked paths

**Swym Control Center support**
- Inject wishlist-page JS in `layout/theme.liquid` with `page.handle contains 'wishlist'` guard, not in page template files (Swym renders via App Embed independent of active template)
- Use `SwymCallbacks` array for post-initialization JS — `setInterval` and `MutationObserver` unreliable because Swym resets UI state during its own init sequence
- Use `e.isTrusted` to distinguish programmatic clicks from user clicks

**EXPLORE phase**
- Active template verification: check for both `.json` and `.liquid` variants; `.json` takes priority and `.liquid` may be dead code
- DOM presence check to confirm which template is actually rendering

**CDP browser setup**
- One-time Chrome remote debugging setup documented in BROWSER WINDOW SETUP section
- Playwright connects to existing authenticated window instead of opening incognito
