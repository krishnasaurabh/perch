# Contributing to Perch

Thanks for helping. Bug reports, small fixes and focused pull requests are all welcome.

## Reporting a bug

Open an [issue](https://github.com/krishnasaurabh/perch/issues) with:

- the Perch version (Settings, or the DMG name) and your macOS version;
- whether your Mac has a notch, and which display Perch was on;
- what you did, what you expected and what happened instead.

Please do not attach your `planner.json` or screenshots that show personal tasks.
If the bug depends on data, describe the steps that recreate it with sample tasks.

## Setting up

You need:

- **macOS 14 or later with Xcode 26** to build and run the app;
- **or any Linux machine with Swift 6.2 or later** for the domain, MCP and CLI code
  (CI uses Swift 6.2 there).

```sh
git clone https://github.com/krishnasaurabh/perch.git
cd perch
git config core.hooksPath .githooks   # repository checks on commit and push
swift build
```

Run the app from a local build with a throwaway data file so you never touch your real planner:

```sh
PERCH_BUILD_VARIANT=testing scripts/bundle.sh
PERCH_DATA=/tmp/perch-dev.json dist/testing/Perch.app/Contents/MacOS/Perch --demo
```

`--demo` fills an empty planner with sample tasks. `PERCH_DATA` works for `perch-cli` and the
`--mcp` server as well. Diagnostic flags require an explicit absolute `PERCH_DATA` path.

`scripts/bundle.sh` without a variant builds the distribution Release app in `dist/Perch.app`.
It excludes sample scenarios, screenshots and motion drivers, and rejects diagnostic flags.
Debug builds and `PERCH_BUILD_VARIANT=testing` builds include these hooks; do not distribute them.
Swift 6 actor isolation applies to UI state and teardown. Background I/O returns Sendable values;
keep platform objects on their owning actor rather than adding unchecked conformances.

## Where code goes

| Target | Holds | May depend on |
|---|---|---|
| `PlannerCore` | models, parser, repeats, focus, engine, storage | nothing |
| `PerchMCP` | MCP server and tools | `PlannerCore` |
| `PerchUI` | platform-neutral presentation logic | `PlannerCore` |
| `PerchApp` | AppKit/SwiftUI app and Apple services | all of the above |
| `PerchCLI` | `perch-cli` | `PlannerCore`, `PerchMCP` |

Keep logic out of `PerchApp` when it can live in a portable target: portable code is tested on
Linux on every push and is much faster to iterate on. `Tests/ArchitectureTests` enforces these
boundaries, and planner changes go through typed commands rather than direct writes to the file.

## Before you open a pull request

```sh
python3 -m unittest discover -s Tests/ArchitectureTests
swift test
git ls-files -z -- '*.swift' | xargs -0 swift format lint --strict --configuration .swift-format
python3 scripts/check_repository.py --staged
```

CI pins `swift format` 6.4.2. To apply formatting:

```sh
git ls-files -z -- '*.swift' | xargs -0 swift format format --configuration .swift-format --in-place
```

If you change MCP tools, also run the end-to-end check with the official Python SDK:

```sh
swift build -c release --product perch-cli
PERCH_DATA=/tmp/perch-mcp.json uv run --with mcp python scripts/mcp_smoke.py .build/release/perch-cli
```

## Pull requests

- Branch from `main` and keep each pull request to one change.
- Add or update tests for behavior changes. Bug fixes should include a test that fails without the fix.
- UI changes: describe what changed and what you checked by hand. The macOS CI jobs render the
  views and run layout, behavior and motion probes; their screenshots are uploaded as workflow
  artifacts, not committed.
- Add a line under **Unreleased** in [CHANGELOG.md](CHANGELOG.md) for anything a user would notice.
- `main` requires the **Repository hygiene** and **PlannerCore tests (Linux)** checks and a linear
  history. Pull requests are squash-merged.

## What belongs in the repository

Product code, tests, deliberately authored test fixtures and user-facing documentation.
Pictures used by the README live directly in `docs/images/` and must stay under 1 MiB.

Keep these out: logs, test output, generated screenshots, recordings, build products, local
configuration, personal data, credentials and private notes. `.gitignore` covers the common cases,
the commit and push hooks reject the rest, and CI checks the full history of every branch.
Please describe what Perch does rather than comparing it with other products.

## Releases

Maintainers cut a release by bumping `CFBundleShortVersionString` and `CFBundleVersion` in
`Resources/Info.plist`, moving **Unreleased** notes under the new version in `CHANGELOG.md`,
merging that change, and publishing a `vX.Y.Z` GitHub release with the DMG that CI built from
the tagged commit.

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
