## What and why

<!-- What does this change, and why is it needed? Link issues (Fixes #123). -->

## Platforms affected

- [ ] macOS
- [ ] Windows
- [ ] Chrome extension
- [ ] Installers / release workflow / docs only

## Checklist

- [ ] Branch is named `type/short-description` and commits follow [CONTRIBUTING.md](../CONTRIBUTING.md)
- [ ] Tests pass locally for what I touched (`./build.sh test` and/or `dotnet run --project Windows/FocusBlocker.Tests -c Release`)
- [ ] Bug fixes include a test that fails without the fix
- [ ] If I changed rule matching, locks or strict-mode behaviour, I changed **both** engines (and `Tests/fixtures/url-cases.json` if needed)
- [ ] No secrets, signing keys, state files or build output are committed
- [ ] If I changed an installer or the release workflow, I ran the affected commands (explain below)

## Verified / not verified

<!-- Be specific: what did you run, on which OS, and what could you not check? -->
