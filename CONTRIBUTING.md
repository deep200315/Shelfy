# Contributing to Shelfy

## Branches and environments

```
feature/* ──PR + CI──▶ develop ──auto──▶ DEV build   (GitHub pre-release "dev", rolling)
fix/*     ──PR + CI──▶ develop
                         │
              "Start release" workflow → release/vX.Y.Z ──PR + CI──▶ main ──auto──▶ PROD release vX.Y.Z
hotfix/*  ──PR + CI──────────────────────────────────────────────────▶ main ──auto──▶ PROD vX.Y.(Z+1)
main ──auto back-merge PR──▶ develop   (after every production release)
```

| Branch | Purpose | Deploys to |
|---|---|---|
| `feature/<name>`, `fix/<name>`, `chore/<name>` | One change each; short-lived (1–3 days); PR into `develop` | none |
| `develop` | Integration branch; always builds | **DEV**: `Deploy DEV` publishes the rolling `dev` pre-release |
| `release/vX.Y.Z` | Created by the **Start release** workflow; version bump + changelog | none (PR into `main`) |
| `main` | Production; only release and hotfix PRs merge here | **PROD**: `Deploy PROD` tags `vX.Y.Z` and publishes the release |
| `hotfix/<name>` | Urgent production fix from `main`; bump the patch version in the PR | PROD on merge, then back-merged |

## Pipelines

- **CI** (`ci.yml`): every PR into `develop` or `main` must pass, in order: strict lint → build with warnings as errors → `swift test` → universal package → DMG + zip artifact (downloadable from the run).
- **Deploy DEV** (`cd-dev.yml`): on every push to `develop`, runs CI, then replaces the `dev` pre-release (version `X.Y.Z-dev.<build>`).
- **Start release** (`release.yml`, manual): input `X.Y.Z` → cuts `release/vX.Y.Z` from `develop`, sets `version.env`, moves CHANGELOG "Unreleased" under the version, opens the release PR and runs CI on it.
- **Deploy PROD** (`cd-prod.yml`): on push to `main`; if `version.env` has no tag yet and CHANGELOG has its section, runs CI, publishes `vX.Y.Z` as **Latest** with notes from CHANGELOG, and opens a `main → develop` sync PR.
- **Rollback PROD** (`rollback.yml`, manual): marks a previous version Latest again and demotes the bad one; then ship a `hotfix/*`.

## Day-to-day

```bash
git switch develop && git pull
git switch -c feature/my-change
# TDD: write a failing test, make it pass, commit each slice
swift format format -i -r Sources Tests
swift build -Xswiftc -warnings-as-errors && swift test
# add a user-facing line under "## [Unreleased]" in CHANGELOG.md
gh pr create --base develop
```

Commits use `type: summary` (`feat`, `fix`, `refactor`, `test`, `docs`, `chore`, `ci`, `build`, `style`), one logical change each. Keep formatting changes in their own commit.

## Versioning

[Semantic Versioning](https://semver.org): breaking → major, new features → minor, fixes → patch. The git tag is the source of truth; `version.env` holds the version being prepared.

## Releases are free and ad-hoc signed

Shelfy has no paid Apple Developer ID, so builds are ad-hoc signed: on first launch, right-click **Shelfy.app → Open**. `scripts/package_app.sh` signs with `APP_IDENTITY` if one is ever provided.
