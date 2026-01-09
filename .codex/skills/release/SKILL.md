# Release Skill

Trigger: release, replace release, update release, rebuild release, new release, push release

## Description

Manages dots releases by replacing the existing release with a new one built from HEAD.

## Steps

1. **Delete existing release and tag**
   ```bash
   gh release delete v0.2.0 --yes --cleanup-tag 2>/dev/null || true
   git push origin :refs/tags/v0.2.0 2>/dev/null || true
   git tag -d v0.2.0 2>/dev/null || true
   ```

2. **Create new tag on HEAD**
   ```bash
   git tag v0.2.0
   git push origin v0.2.0
   ```

3. **Monitor CI workflow**
   ```bash
   gh run list --workflow=release.yml --limit=1
   gh run watch --exit-status
   ```

4. **Verify Homebrew update**
   - Check that joelreymont/homebrew-tap was updated with new SHA256 hashes
   - Verify with: `gh api repos/joelreymont/homebrew-tap/commits --jq '.[0].commit.message'`

5. **Test installation**
   ```bash
   brew update
   brew reinstall joelreymont/tap/dot
   dot --version
   ```

## Notes

- Release workflow builds static binaries with SQLite compiled from source
- Binaries are ~0.9MB, fully static, no dependencies
- Homebrew formula is auto-updated by the release workflow using HOMEBREW_TAP_TOKEN secret
