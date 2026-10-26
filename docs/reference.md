# libnutri

An iPhone nutrition tracker with a shared REST and MCP API. Each account has its own meals, drafts, AI settings, encrypted OpenRouter key and lifetime spending. Text and audio are processed on the server. No iCloud synchronization is required.

The server uses Node.js 24, TypeScript, SQLite and the official MCP SDK. The iOS app uses Swift 6, SwiftUI, SwiftData and native Liquid Glass. Huninn is bundled for the main interface; settings use the system font.

## Layout

| Folder     | Contents                                               |
| ---------- | ------------------------------------------------------ |
| `backend/` | Node.js server: REST API, MCP and tests                |
| `app/`     | iPhone app and the shared Swift package                |
| `landing/` | Static page served by the backend at `/` for browsers  |
| `scripts/` | Repository checks, iPhone build and Swift test helpers |

## Develop and check

```sh
npm ci --prefix backend
cp backend/.env.example backend/.env
# Configure the environment before starting the server.
npm --prefix backend run build
npm --prefix backend start
npm run check
```

`GET /` returns the landing page when the request accepts `text/html` and the JSON service description otherwise. The landing uses a Latin and Cyrillic subset of Huninn (`landing/fonts/huninn-subset.woff2`).

`check` runs server tests, formatting, type checks, gitleaks and, where Swift is installed, the Swift Package tests and formatting checks. Install gitleaks first. Swift test artifacts use a temporary directory outside the repository, including on iCloud-backed checkouts.

The prepared GitHub Actions workflow runs server checks on Linux and Swift tests on macOS after future publication. Deployment remains manual. Do not put production data or credentials in the repository.

## Accounts

OAuth issuer: `https://libauth.avx.so`. API audience: `https://libnutri.avx.so`. MCP audience and endpoint: `https://libnutri.avx.so/mcp`.

Identity comes only from authenticated introspection. Every storage key, worker and long-poll snapshot is scoped to that account. Foreign IDs return not found. Deleting all data removes only the signed-in user's data and provider settings.

The iOS app keeps one active account. Sign-out clears local data and credentials, cancels pending requests and rejects late responses. Server data remains. A different account starts with its own history and settings.

Each user supplies their own OpenRouter key. Analysis defaults to `google/gemini-2.5-flash-lite`; transcription defaults to `openai/whisper-large-v3-turbo`. Explicit nutrient values can be added through MCP without a provider key or paid analysis. Model identifiers remain configurable.

## API and MCP

All `/api/v1/*` routes require an audience-bound bearer token. Read routes require `nutrition:read`; mutations require `nutrition:write`.

| Routes                                                                             | Purpose                                                   |
| ---------------------------------------------------------------------------------- | --------------------------------------------------------- |
| GET `/me`                                                                          | Stable account ID, username and legacy-import eligibility |
| GET `/state`, `/changes?after=...`                                                 | Snapshot and 25-second long polling                       |
| POST `/entries`; GET/PATCH/DELETE `/entries/:id`                                   | Meal creation and versioned editing                       |
| PATCH `/entries/:id/draft`                                                         | Edit the description draft                                |
| POST `/entries/:id/analyze`, `/entries/:id/transcribe`                             | Asynchronous AI processing                                |
| GET `/operations/:id`; POST `/operations/:id/cancel`, `/operations/:id/retry-save` | Progress, cancellation and save-only retry                |
| GET/PATCH `/settings`; GET `/spending`                                             | Per-account configuration and lifetime USD totals         |
| POST `/import`; DELETE `/data`                                                     | Owner-only legacy import and account-local data deletion  |

MCP tools: `get_profile`, `list_meals`, `get_meal`, `daily_totals`, `add_meal`, `update_meal`, `delete_meal`, `reanalyze_meal`, `get_operation`, `cancel_operation`, `retry_saving`, `get_spending`.

Use fresh UUIDs for intentional new meals and reuse them for network retries. Edits require `expectedVersion`. Explicit nutrition avoids AI; reanalysis always calls the model. Previous results remain intact on failure. Nutrients must be finite, nonnegative, and below 3000 kcal / 150 g protein / 150 g fiber before rounding.

## iPhone

Open or generate `app/NutritionTracker.xcodeproj` with XcodeGen. iOS 27 and Xcode 27 are required; no simulator is necessary for CLI device builds.

```sh
(cd app && xcodegen generate)
TEAM_ID=YOUR_TEAM DEVICE_ID=YOUR_IPHONE scripts/build-app.sh
```

The bundle ID stays `so.avx.Nutri` so an update can replace the existing app. The current signing team must be available locally. Before 03:00 the initial selected date is yesterday; midnight changes Today to Yesterday without changing the selected date.

See [migration](migration.md), [deployment](deployment.md) and [security](../SECURITY.md). License: AGPL-3.0-only. Third-party font licenses remain bundled.
