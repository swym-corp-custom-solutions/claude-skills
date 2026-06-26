# ThemeMate — Complete Guide

ThemeMate is a Claude Code skill that turns Claude into a specialized Swym Wishlist implementation assistant. It handles the full workflow of inspecting a merchant storefront, pulling their Shopify theme, implementing Swym UI customizations, testing locally, and opening a PR for review — all from a single conversation.

**Activated by typing `/thememate` in Claude Code.**

No MCP server. No separate app. Runs entirely through Shopify CLI, GitHub CLI, and standard file tools.

---

## Who Can Use ThemeMate

| Role | Primary use |
|------|------------|
| **ACQ** | Set up Swym features on a prospect's store for demo or trial |
| **Success Manager** | Implement post-onboarding customizations a merchant has requested |
| **Support** | Audit a merchant store, diagnose Swym UI issues, answer technical questions |
| **Agency partner** | Implement Swym features on a client's Shopify store |

All roles follow the same workflow. ThemeMate detects your role from context and adjusts — ACQ sessions focus on speed and demo polish; support sessions focus on read-only diagnosis before writing anything.

---

## What ThemeMate Can Do

### Storefront inspection
- Screenshot the live storefront for brand context (homepage, collection, PDP, cart)
- Run a full DOM audit to find every active Swym element on every page type
- Detect Swym version, active features, and which Control Center rendering is in use
- Identify the `.myshopify.com` URL from a custom domain automatically (no need to ask)
- Diagnose broken or missing Swym UI without touching any files

### Theme work
- Pull the merchant's live theme locally via Shopify CLI
- Read and search theme files (layout, templates, sections, snippets, assets)
- Create new CSS/JS asset files
- Patch existing Liquid files with correct injection points
- Test changes locally via `shopify theme dev` without touching the merchant store

### Git and GitHub
- Initialize a private GitHub repo under `swym-corp-custom-solutions`
- Commit the pulled theme as a clean baseline on `main`
- Implement all changes on a feature branch
- Open a PR with a description of what changed and a test checklist
- Stop at PR — merge and merchant store deployment are human steps

### Knowledge and docs
- Answer Swym SDK questions (SwymCallbacks, event hooks, API methods)
- Explain how Swym Control Center rendering works
- Compare Path A (override default styling) vs Path B (replace default UI)
- Advise on correct injection points for different page types

---

## Capabilities by Feature

| Feature | What ThemeMate does |
|---------|-------------------|
| PDP wishlist button — color, size, style | Creates a scoped CSS override file, injects it in the correct layout file |
| Collection card heart icon | Finds the card snippet, adds CSS override or custom button markup |
| Wishlist page tab deep-linking (`?tab=sfl`) | Creates JS asset using `SwymCallbacks`, injects in `theme.liquid` |
| Save for Later button on cart | Locates cart template, implements CSS or custom button |
| Floating launcher / header icon | Layout file JS, targets Swym-injected element |
| Full custom wishlist page | Disables Swym default UI (instructs user to do in App Embeds), builds custom template |
| Store audit / diagnosis | DOM audit, JS inspection, read-only — no files modified |
| Swym knowledge questions | Answers from docs, no store context needed |

---

## Full Workflow: First Session (New Merchant)

This runs when no GitHub repo exists yet for the merchant.

### 1. Storefront Discovery
ThemeMate navigates the live merchant store and runs DOM evaluations to build context:
- Identifies brand tone, primary color, button style from homepage
- Audits every page type (homepage, collection, PDP, cart, wishlist page) for active Swym elements
- Records Swym version, enabled features, and which wishlist rendering is active (Control Center vs legacy)
- Resolves `.myshopify.com` URL from the custom domain without asking

### 2. Theme Pull
Pulls the merchant's live theme locally via Shopify CLI:
```
shopify theme pull --store <merchant>.myshopify.com --theme <live_id> --path ./<merchant-slug>
```
If CLI auth fails, escalates to Partner Portal download. If neither works, blocks and asks for store access — never guesses or uses a generic theme.

### 3. Docs Research
Consults 1-2 Swym documentation references relevant to the specific feature being implemented.

### 4. Explore
Searches the pulled theme files to locate every file to create or modify:
- Finds the correct layout file for the target page type
- Confirms which template is actually serving the target page (`.json` takes priority over `.liquid`)
- Identifies CSS variable names from the theme's actual asset files
- Checks which layout file each template declares (not always `theme.liquid`)

### 5. Plan
Narrates exactly what will change before writing anything:
- New files to create and why
- Existing files to patch and the exact anchor points
- CSS approach using the merchant's actual variable names

Waits for confirmation before writing.

### 6. Validate
Checks before any write:
- All anchor points confirmed from Explore
- No writes targeting a live/published theme
- CSS uses variable names found in the actual theme files

### 7. GitHub Repo Setup
Creates a private repo under `swym-corp-custom-solutions`, commits the clean pulled theme as a baseline on `main`, then immediately branches to `feature/<slug>`:
```
gh repo create swym-corp-custom-solutions/<merchant-slug>-swym-custom --private
git commit -m "chore: baseline pull from <merchant> live theme"
git checkout -b feature/<feature-slug>
```
All implementation happens on the feature branch — `main` stays as the clean baseline until the PR is merged.

### 8. Implement
Creates new asset files and patches existing theme files on the feature branch. Multiple commits for clean PR review — one commit per logical unit (new asset file, injection into layout, etc.).

### 9. Local Testing
Starts the Shopify CLI dev server for live browser validation without touching the merchant store:
```
shopify theme dev --store <merchant>.myshopify.com --path ./<merchant-slug>
```
Local changes hot-reload instantly. The preview URL is printed to the terminal.

### 10. Browser Validation
Validates the feature is working correctly using targeted DOM evaluation — not screenshots:
```js
// Example for tab routing:
({
  tabActive: document.getElementById('tab-tabSavedForLater')?.getAttribute('aria-selected'),
  swymReady: !!window.__SWYM__VERSION__
})
```
If broken: edits the file, hot-reload picks it up, re-evaluates. Maximum 3 iterations before escalating to the user. Screenshots only if a visual/CSS issue genuinely cannot be confirmed via DOM.

### 11. PR
Pushes the feature branch, opens a PR with a description and test checklist, and stops:
```
gh pr create --title "Swym | <Feature> | <Merchant>"
```
ThemeMate shares the PR URL. Merge and post-merge merchant store deployment are done by a human.

### What happens after the PR (human steps)
1. Human reviews and merges PR on GitHub
2. Human runs `shopify theme push --unpublished` to create a copy theme on the merchant store
3. Human connects the copy theme to GitHub main in Shopify Admin > Themes
4. Merchant previews and publishes when ready

---

## Full Workflow: Return Session (Existing Merchant)

When a GitHub repo already exists for the merchant, ThemeMate skips the full setup.

1. **Git Pull** — `git pull origin main` from the existing repo. Reads `METADATA.md` to recover store URL, connected theme ID, and previous session context
2. **Explore** — greps and reads from the cloned files, no CLI pull from merchant store
3. **Plan + Validate** — same as first session
4. **Branch** — creates a new feature branch from current main
5. **Implement** — writes on the feature branch
6. **Local Testing + Browser Validation** — same as first session
7. **PR** — opens PR, stops

After merge, GitHub sync fires automatically and updates the connected copy theme on the merchant store. No additional deployment steps needed in return sessions.

---

## Scenarios

### ACQ — Demo prep for a prospect
> "Set up Swym collection card wishlist buttons matching the brand color for merchantstore1.com. We have a demo tomorrow."

ThemeMate runs full first-session workflow. At the end you get a PR with the implementation. After merge, you create the unpublished copy theme and share the preview URL with the prospect.

### Success Manager — Post-onboarding customization
> "Merchant wants the wishlist heart icon on PDP to be larger and use their pink (#FF6BB3)."

ThemeMate detects the existing repo (return session), pulls main, locates the Swym PDP button in the DOM, creates a scoped CSS override, tests locally, opens PR.

### Support — Diagnosing a broken Swym UI
> "Merchant says the wishlist button isn't showing on collection pages. Can you check?"

ThemeMate runs in read-only inspection mode (Mode B): navigates the live store, runs DOM audits on the collection page, checks JS console for errors, inspects which Swym features are active. Reports findings without writing or pushing anything.

### Support / SM — Quick Swym knowledge question
> "What's the difference between SwymCallbacks and window.SwymEventListeners?"

ThemeMate answers from Swym docs (Mode A). No store context needed. Offers to apply an example on a store if needed.

### Returning to a feature mid-session
> "The tab routing PR is open — can you also add URL sync when the user manually switches tabs?"

ThemeMate detects the existing `deploy_theme_id` in context, reads the current file state, patches without re-pulling. Validates the change, updates the existing PR branch.

---

## What ThemeMate Cannot Do

| Limitation | Why |
|-----------|-----|
| Push to a live/published theme | Safety constraint — always writes to feature branch or local dev only |
| Toggle Swym App Embed settings | Requires Shopify Admin UI — ThemeMate instructs the user to do it manually |
| Configure Swym app backend (plan, pixel, settings) | Swym Dashboard only — out of scope |
| Merge PRs | Human review step — ThemeMate always stops at PR open |
| Create merchant store copy theme | Human-only post-merge step |
| Support non-Shopify storefronts (BigCommerce, WooCommerce) | Delivers code snippets with paste instructions instead |
| Implement features for non-Wishlist Swym products (SBiSA, Watchlist) | Knowledge questions only — theme writes are Wishlist Plus only |

---

## Tips for Support and Success Managers

**Diagnosing issues without touching files:**
Start with "audit" or "diagnose" language — ThemeMate runs in read-only mode and reports what it finds without writing anything. Example: "Can you audit what Swym features are active on merchant.com and check if the wishlist button is rendering correctly on the PDP?"

**Checking Swym version and feature flags:**
ThemeMate runs this automatically during discovery, but you can ask directly: "What Swym version is running on merchant.com and which features are enabled?"

**When you only have a question, not an implementation task:**
Just ask — ThemeMate switches to knowledge mode and answers from Swym docs without pulling any theme files.

**When a merchant reports something broken:**
Share the merchant URL and describe the symptom. ThemeMate will inspect the DOM, check for JS errors, and report what it finds. If a fix is needed, it will propose a plan before writing anything.
