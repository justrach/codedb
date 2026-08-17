# subagent sa-027-dfeab3c7

- label: Audit release procedure
- kind: subagent
- status: ok
- elapsed_ms: 211493
- tools: bash,codedb,codedb,bash!,bash,bash,bash,codedb,codedb,codedb,codedb,codedb!,bash,bash!,codedb,codedb,bash,bash,bash,codedb,bash,bash

## task

Inspect the current codedb repository and GitHub release history to determine the exact safe release procedure for v0.2.5829 after PR #674 merges. Focus on tag creation, GitHub Release creation, release-binaries workflow dispatch/event, codedb-notary integration, expected asset names/checksums, npm publication if any, and verification. Do not edit, merge, tag, or publish. Cite files/commands and identify secrets/credentials prerequisites.

## report

# Release assessment for `v0.2.5829`

## Bottom line

Do **not** rely on creating a GitHub Release to start the binary build. The current `release-binaries` workflow is **dispatch-only**, requires an **already-existing tag and GitHub Release**, checks out that tag, and uploads with `--clobber` (`.github/workflows/release-binaries.yml:3-9,46,51-54,140-146`).

More importantly, that workflow currently builds only four Unix assets—no Windows binary—and performs certificate signing only conditionally; it contains **no Apple notarization submission or verification** (`.github/workflows/release-binaries.yml:23-44,73-108`). Running it after a notary process has uploaded assets could overwrite notarized binaries and replace `checksums.sha256` with a four-entry manifest (`.github/workflows/release-binaries.yml:129-146`). Therefore, the exact safe path depends on the unavailable `codedb-notary` procedure. That integration could not be inspected: GitHub returned `404` for `justrach/codedb-notary`, and no reference exists in the codedb repository.

---

## Verified current state

### PR and release commit

At inspection time, PR #674 is open and mergeable, targeting `release/0.2.5829`, not `main`. Its single head commit is:

```text
d4cdd41722676561766e2652777ac3ce6da82bd4
```

The benchmark check succeeded; the base-guard check was skipped. Source: [`gh pr view 674`](https://github.com/justrach/codedb/pull/674).

After merge, the release tag must point to the **actual merged commit on `release/0.2.5829`**, not blindly to the PR head SHA—especially if GitHub creates a merge or squash commit.

Both package metadata locations already declare `0.2.5829`:

- Zig package version: `build.zig.zon:4`
- npm package version: `npm/package.json:2-4`

The release workflow also verifies that the tagged source requires exactly Zig `0.17.0-dev.813+2153f8143` (`.github/workflows/release-binaries.yml:14-15,56-70`; `build.zig.zon:4-5`).

### Release event behavior

The repository copy of the workflow has only:

```yaml
on:
  workflow_dispatch:
```

and requires a `tag` input described as an “Existing tag” (`.github/workflows/release-binaries.yml:3-9`). There is no `release:` trigger. Historical API data shows:

- `v0.2.5824`, `.5825`, and `.5826` had `event=release` runs under an older workflow.
- `v0.2.5823` was successfully run with `event=workflow_dispatch`.
- There are no corresponding `release-binaries` runs for `.5827` or `.5828`.

Source: GitHub Actions API query:

```sh
gh api 'repos/justrach/codedb/actions/workflows/release-binaries.yml/runs?per_page=20'
```

Thus, creating the GitHub Release will **not** launch the current workflow.

### GitHub Release must exist before workflow upload

The publish step invokes:

```sh
gh release upload "$RELEASE_TAG" \
  assets/codedb-* assets/checksums.sha256 \
  --clobber --repo "$GITHUB_REPOSITORY"
```

(`.github/workflows/release-binaries.yml:140-146`).

`gh release upload` needs an existing release associated with the tag. Therefore the operational ordering is:

1. tag exists;
2. GitHub Release exists;
3. binary/notary process uploads assets.

### Tag style in recent releases

Recent tags are annotated tag objects, not lightweight tags. For example, GitHub reports `refs/tags/v0.2.5828` as a tag object whose message is `codedb 0.2.5828`, pointing to commit `54ab9e1…`. Source:

```sh
gh api repos/justrach/codedb/git/ref/tags/v0.2.5828
gh api repos/justrach/codedb/git/tags/6842f832488e2bd6cb3b1f1eb12191e5d091f84a
```

Accordingly, an annotated and preferably signed tag is consistent with release history.

---

# Safe release sequence

These are proposed commands for an authorized operator; none were run.

## 1. Resolve and verify the merged release commit

After PR #674 merges:

```sh
git fetch origin --tags
git log --decorate --oneline origin/release/0.2.5829 -n 10
MERGE_SHA="$(git rev-parse origin/release/0.2.5829)"
git show --stat --oneline "$MERGE_SHA"
```

Confirm that:

- `$MERGE_SHA` contains PR #674;
- `build.zig.zon` says `0.2.5829` and requires the pinned Zig snapshot (`build.zig.zon:4-5`);
- `npm/package.json` says `0.2.5829` (`npm/package.json:2-4`);
- the changelog contains the `0.2.5829` entry and verification results (`CHANGELOG.md:4-9,81-89`);
- the release workflow at that commit contains the pinned Zig hashes and version (`.github/workflows/release-binaries.yml:14-15,25-44,56-70`).

Do not tag the current PR head SHA merely because it was tested; use the post-merge release-branch SHA.

A further policy decision is needed about whether `release/0.2.5829` must first merge to `main`. Recent releases commonly record `target_commitish: main`, but PR #674 currently targets the release branch. The tag itself—not the display value of `target_commitish`—must resolve to the intended release commit.

## 2. Create and push the annotated tag

Only after the commit is frozen and verified:

```sh
git tag -s v0.2.5829 "$MERGE_SHA" -m "codedb 0.2.5829"
git verify-tag v0.2.5829
git show --no-patch --decorate v0.2.5829
git push origin refs/tags/v0.2.5829
```

If project policy does not use GPG/SSH-signed tags, use `git tag -a` instead, but recent release history at least establishes that tags are annotated.

Immediately verify the remote ref:

```sh
gh api repos/justrach/codedb/git/ref/tags/v0.2.5829
git ls-remote origin refs/tags/v0.2.5829
```

The dereferenced tag must lead to `$MERGE_SHA`.

### Credential prerequisite

The operator needs:

- GitHub repository permission to create tags;
- a configured GPG or SSH signing key if using `git tag -s`;
- branch/tag protection authorization, if configured.

## 3. Create the GitHub Release, preferably as a draft

Because the workflow requires an existing release, create it before asset upload. A draft is safer while binaries and notarization are incomplete:

```sh
gh release create v0.2.5829 \
  --repo justrach/codedb \
  --verify-tag \
  --target "$MERGE_SHA" \
  --title "codedb 0.2.5829" \
  --notes-file /path/to/reviewed-v0.2.5829-release-notes.md \
  --draft
```

Draft status should be confirmed:

```sh
gh release view v0.2.5829 \
  --repo justrach/codedb \
  --json tagName,targetCommitish,isDraft,isPrerelease,assets,url
```

Release notes should accurately describe the verified test status from `CHANGELOG.md:81-89`; do not claim notarization until it has independently succeeded.

### Credential prerequisite

`gh` must be authenticated with release/tag administration and Actions permissions, normally via `gh auth login` or an appropriately scoped `GH_TOKEN`.

---

# Binary and notary handling

## 4. Do not blindly dispatch `release-binaries`

The tagged workflow currently builds:

- `codedb-darwin-x86_64`
- `codedb-darwin-arm64`
- `codedb-linux-x86_64`
- `codedb-linux-arm64`

(`.github/workflows/release-binaries.yml:23-44`).

It does **not** build `codedb-windows-x86_64.exe`, although the npm installer expects that exact file (`npm/scripts/postinstall.js:14-20`), and recent releases `.5827` and `.5828` contain it.

The workflow:

- imports an Apple certificate only if secrets are nonempty (`.github/workflows/release-binaries.yml:47-49,73-95`);
- only attempts the `-Dcodesign-identity` path for non-x86_64 macOS, effectively arm64 (`.github/workflows/release-binaries.yml:101-108`);
- contains no `xcrun notarytool`, notarization polling, Gatekeeper check, or equivalent;
- uploads with `--clobber` (`.github/workflows/release-binaries.yml:140-146`).

Consequences:

1. A run can succeed with unsigned macOS binaries if signing secrets are absent.
2. Intel macOS is built without the workflow’s signing branch.
3. It cannot by itself produce the complete five-platform asset set expected by npm.
4. Its generated checksum file covers only files it built (`.github/workflows/release-binaries.yml:129-138`).
5. Running it after an external notary upload can overwrite trusted assets.

Therefore, the **safe release procedure is to use one authoritative publisher**:

- preferably the established `codedb-notary` process, if it builds/signs/notarizes all release assets; or
- dispatch `release-binaries` only as a preliminary four-platform build, then have the notary process replace the macOS artifacts, add Windows, and regenerate/re-upload the final checksum manifest.

Do not publish the release between these stages.

## 5. If explicitly authorized to dispatch the workflow

The workflow version used for dispatch matters. The default branch currently exposes the older Zig `0.16.0` form, while PR #674 changes the release workflow to Zig 0.17. Dispatch against a ref that contains the merged workflow, not accidentally against stale `main`.

A suitable explicit command would be:

```sh
gh workflow run release-binaries.yml \
  --repo justrach/codedb \
  --ref release/0.2.5829 \
  -f tag=v0.2.5829
```

Afterward:

```sh
gh run list \
  --repo justrach/codedb \
  --workflow release-binaries.yml \
  --limit 5

gh run watch RUN_ID \
  --repo justrach/codedb \
  --exit-status
```

The checkout itself is correctly pinned to the release tag (`.github/workflows/release-binaries.yml:46,51-54`), and the workflow checks the tag’s required Zig version before building (`.github/workflows/release-binaries.yml:56-70`).

### Workflow credentials and secrets

The workflow needs:

- repository `GITHUB_TOKEN` with `contents: write`, granted in the workflow at `.github/workflows/release-binaries.yml:11-12,140-146`;
- `APPLE_CERTIFICATE_P12`: base64-encoded signing certificate (`:47,73-87`);
- `APPLE_CERTIFICATE_PASSWORD` (`:48,92`);
- `APPLE_CODESIGN_IDENTITY` (`:49,101-105`).

These Apple secrets are **not marked mandatory** by the workflow. Their absence causes signing to be skipped rather than failing the release, which is unsafe if notarized macOS assets are required.

The external notary system likely also needs Apple notarization credentials—commonly Apple ID/app-specific password/team ID or App Store Connect API issuer/key ID/private key—but this is an inference. No accessible codedb source identifies the exact secret names.

---

# `codedb-notary` integration

## What was verified

- No `codedb-notary` string appears in the codedb repository.
- `gh api repos/justrach/codedb-notary` returned `404`.
- GitHub repository search did not expose a public repository by that name.
- Assets for `v0.2.5828` were all uploaded by `justrach` within approximately one second, while no corresponding `release-binaries` Actions run exists.
- The `v0.2.5828` release notes label arm64 macOS “notarized” and Intel macOS “unsigned.” Source: [`v0.2.5828` release](https://github.com/justrach/codedb/releases/tag/v0.2.5828).

## What is inferred

The recent complete releases were probably assembled by a private/local notary process rather than solely by the public workflow. The simultaneous upload pattern is consistent with a process that stages all finalized assets and uploads them together, but it does not prove the implementation.

Until that process is inspected, it is not possible to state safely:

- its exact dispatch command;
- whether it consumes workflow artifacts or rebuilds;
- which architectures it notarizes;
- whether it generates the final checksum manifest;
- whether it publishes the draft release;
- its exact required secret names.

Because the public workflow uses `--clobber`, the notary process must either run **after** it or be the only asset publisher.

---

# Expected final assets and checksums

Based on npm’s platform map and releases `.5827`/`.5828, the final release should contain exactly:

```text
codedb-darwin-arm64
codedb-darwin-x86_64
codedb-linux-arm64
codedb-linux-x86_64
codedb-windows-x86_64.exe
checksums.sha256
```

Evidence:

- npm mapping: `npm/scripts/postinstall.js:14-20`
- checksum URL and asset URL construction: `npm/scripts/postinstall.js:101-104`
- recent release asset inventory: [`v0.2.5828`](https://github.com/justrach/codedb/releases/tag/v0.2.5828)

`checksums.sha256` must have one 64-hex SHA-256 entry per binary, with filenames matching exactly. The npm installer parses the manifest and refuses installation if the platform asset is absent or mismatched (`npm/scripts/postinstall.js:114-147`).

Generate the **final** manifest only after all signing/notarization changes, because those operations alter binary bytes:

```sh
sha256sum codedb-* | sort > checksums.sha256
sha256sum --check checksums.sha256
```

On macOS, equivalent local verification can use:

```sh
shasum -a 256 codedb-* | sort
```

Also compare every local checksum with GitHub’s release-asset digest:

```sh
gh release view v0.2.5829 \
  --repo justrach/codedb \
  --json assets \
  --jq '.assets[] | [.name,.size,.digest] | @tsv'
```

Do not treat the SHA-256 of `checksums.sha256` itself as a binary entry inside the same file.

---

# npm publication

The npm package is named **`codedeebee`**, not `codedb` (`npm/package.json:2`). The package version is already `0.2.5829` (`npm/package.json:3`).

However, npm registry history shows:

```json
{
  "version": "0.2.5823",
  "dist-tags": { "latest": "0.2.5823" }
}
```

and no `.5828` package exists. Source:

```sh
npm view codedeebee version dist-tags time repository --json
npm view codedeebee@0.2.5828 dist --json
```

There is no npm-publish workflow or publish script in this repository; the only package lifecycle script is `postinstall` (`npm/package.json:23-25`). Thus npm publication is **manual and optional by current precedent**, not part of the GitHub binary workflow.

If `0.2.5829` is to be published, do it only after all six GitHub assets are final and publicly downloadable, since postinstall immediately downloads `v${package.version}` assets and verifies them (`npm/scripts/postinstall.js:101-147`):

```sh
cd npm
npm pack --dry-run
npm publish
```

Then verify:

```sh
npm view codedeebee@0.2.5829 version dist.integrity dist.shasum
npm view codedeebee dist-tags --json
npx --yes codedeebee@0.2.5829 --version
```

### npm credential prerequisite

The operator needs:

- publish rights to the `codedeebee` npm package;
- an npm automation token or interactive npm login;
- npm 2FA/OTP if enforced for publishing.

No `NPM_TOKEN` secret or automated npm publication exists in the inspected workflows.

---

# Final verification before publishing the draft

1. **Tag identity**
   ```sh
   git fetch origin --tags
   git rev-parse 'v0.2.5829^{}'
   git rev-parse origin/release/0.2.5829
   git verify-tag v0.2.5829
   ```
   The first two commit SHAs must match the intended merged release commit.

2. **Release inventory**
   ```sh
   gh release view v0.2.5829 \
     --repo justrach/codedb \
     --json isDraft,isPrerelease,tagName,targetCommitish,assets,url
   ```
   Expect the five binaries plus `checksums.sha256`.

3. **Independent downloads and hashes**
   ```sh
   mkdir -p /tmp/codedb-v0.2.5829-verify
   gh release download v0.2.5829 \
     --repo justrach/codedb \
     --dir /tmp/codedb-v0.2.5829-verify
   cd /tmp/codedb-v0.2.5829-verify
   sha256sum --check checksums.sha256
   ```

4. **Version and platform smoke tests**
   Run each binary on its native platform and confirm `--version` reports `0.2.5829`. At minimum exercise version, index/search, and MCP startup consistent with the changelog’s stated coverage (`CHANGELOG.md:81-89`).

5. **Apple signing/notarization**
   On each claimed signed/notarized macOS binary:
   ```sh
   codesign --verify --deep --strict --verbose=2 ./codedb-darwin-arm64
   codesign -dv --verbose=4 ./codedb-darwin-arm64
   spctl --assess --type execute --verbose=4 ./codedb-darwin-arm64
   ```
   Obtain and retain the notary submission ID/status from the private notary process. Do not claim Intel notarization if it remains unsigned, matching recent release-note precedent.

6. **Windows**
   Test `codedb-windows-x86_64.exe --version` on Windows and ensure its hash is present in `checksums.sha256`.

7. **npm installer, if publishing**
   Test on every npm-supported key:
   - `darwin-arm64`
   - `darwin-x64`
   - `linux-arm64`
   - `linux-x64`
   - `win32-x64`

   These are the only mappings in `npm/scripts/postinstall.js:14-20`.

8. **Publish the draft**
   Only after all checks:
   ```sh
   gh release edit v0.2.5829 \
     --repo justrach/codedb \
     --draft=false
   ```

---

## Three most load-bearing facts

1. **Creating the GitHub Release does not trigger binaries anymore:** the current workflow is `workflow_dispatch` only and requires an existing tag (`.github/workflows/release-binaries.yml:3-9`).
2. **The public workflow is not a complete final publisher:** it builds four assets, omits Windows and notarization, and uploads with `--clobber`, including replacing the checksum manifest (`.github/workflows/release-binaries.yml:23-44,129-146`).
3. **npm `codedeebee@0.2.5829` will depend immediately on the complete GitHub release:** its postinstall downloads exact `v0.2.5829` platform assets and fails on missing or mismatched checksums (`npm/package.json:2-4`; `npm/scripts/postinstall.js:14-20,101-147`).

## Open question

What is the authoritative, access-controlled `codedb-notary` command/workflow, and does it build or consume all five platform binaries, regenerate `checksums.sha256`, and publish the draft? Until that private integration and its credential requirements are inspected, dispatching `release-binaries` or publishing `v0.2.5829` cannot be called fully safe.
