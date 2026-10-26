<img src="https://github.com/user-attachments/assets/3175ff96-4d7a-4f8b-8699-5ec38a11612e" width="200" alt="libnutri" />

![vibecoded](https://img.shields.io/badge/vibecoded-545454)
[![open-source](https://img.shields.io/badge/open--source-545454)](LICENSE)
[![release](https://img.shields.io/badge/release-tag--v0.0.1-367d55)](https://github.com/hikariatama/libnutri/releases/tag/v0.0.1)
[![CI](https://github.com/hikariatama/libnutri/actions/workflows/ci.yml/badge.svg)](https://github.com/hikariatama/libnutri/actions/workflows/ci.yml)
[![AGPL-3.0](https://img.shields.io/badge/license-AGPL--3.0-545454)](LICENSE)

> An iPhone nutrition tracker with text, voice and ChatGPT integration. Meals sync through a shared REST and MCP API.

<img src="https://github.com/user-attachments/assets/0582cb9c-76a3-464c-9a78-09f84c3efec9" width="100%" alt="libnutri screenshot" />

## Download

<table>
  <thead><tr><th>Platform</th><th>Download</th></tr></thead>
  <tbody>
    <tr><td>iPhone</td><td><a href="https://github.com/hikariatama/libnutri/releases/download/v0.0.1/libnutri-iphone-unsigned.ipa"><img alt="IPA Unsigned" src="https://img.shields.io/badge/IPA-Unsigned-367d55" /></a></td></tr>
    <tr><td>Server</td><td><a href="https://github.com/hikariatama/libnutri/releases/download/v0.0.1/libnutri-backend.tar.gz"><img alt="TAR.GZ Node 24" src="https://img.shields.io/badge/TAR.GZ-Node%2024-545454" /></a></td></tr>
  </tbody>
</table>

CI replaces the draft for this version on rebuild. Before publication, maintainers can download it from [Releases](https://github.com/hikariatama/libnutri/releases). Checksums: `SHA256SUMS.txt`.

The IPA requires signing with your Apple account before installation.

## Prerequisites

- Node.js 24 and gitleaks.
- Xcode 27 and XcodeGen for the iOS 27 app.

## Development

```sh
npm ci --prefix backend
cp backend/.env.example backend/.env
# Configure backend/.env before starting the server.
npm --prefix backend run build
npm --prefix backend start
```

Open `app/NutritionTracker.xcodeproj` for the iPhone app. Set your signing team locally.

## Checks

```sh
npm run check
```

MCP endpoint: `https://libnutri.avx.so/mcp`. OAuth issuer: `https://libauth.avx.so`.
Each account uses its own OpenRouter key; analysis and transcription happen on the server.

See [development and API reference](docs/reference.md), [deployment](docs/deployment.md), [migration](docs/migration.md) and [third-party licenses](THIRD_PARTY.md).
