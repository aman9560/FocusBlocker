# Contributing to Focus Blocker

Thanks for helping. This is a small personal-use project, so the rules are short. They exist to keep `main` always releasable and the history readable.

## Ground rules

- **`main` is always releasable.** Never commit to it directly and never force-push it. All changes go through a pull request.
- **Be honest in code, commits and docs.** Say what was verified and what was not. Don't claim a platform works if it was only compiled. This project's limits (it is not tamper-proof) are part of its design; don't oversell them.
- **Keep it dependency-free.** The Swift side uses only Apple frameworks and the Windows side only the .NET SDK. Don't add packages without a strong reason.
- **No secrets, no build output.** Never commit signing keys (`signing/extension-key.pem` is git-ignored), tokens, personal blocklists, state files, or generated folders (`.build/`, `dist/`, `bin/`, `obj/`, `out/`).

## Getting set up

```sh
git clone https://github.com/aman9560/FocusBlocker
cd FocusBlocker
```

| To work on | You need | Run the tests |
|---|---|---|
| macOS app, engine, extension | Apple silicon Mac, Xcode Command Line Tools, Node.js | `./build.sh test` |
| Windows app and engine | .NET 10 SDK (the WPF app itself runs only on Windows) | `dotnet run --project Windows/FocusBlocker.Tests -c Release` |

On macOS or Linux add `-p:EnableWindowsTargeting=true` to compile the WPF app. The Windows tests, including the one that runs the real Chrome host, run on any OS.

## Branches

Create a branch from an up-to-date `main`, named `type/short-description` in lower case with hyphens:

| Type | Use for | Example |
|---|---|---|
| `feat/` | a new capability | `feat/mac-snooze` |
| `fix/` | a bug fix | `fix/windows-chrome-grace` |
| `docs/` | documentation only | `docs/readme-overhaul` |
| `test/` | tests only | `test/failsafe-coverage` |
| `refactor/` | behaviour-preserving cleanup | `refactor/process-guard` |
| `ci/` | workflows and release tooling | `ci/release-restore` |
| `chore/` | everything else (version bumps, tidy-ups) | `chore/gitignore-dist` |

Delete the branch after it is merged.

## Commit rules

1. **Subject line:** imperative mood ("Fix", "Add", "Remove"), no trailing full stop, **72 characters or fewer**. It should complete the sentence "If applied, this commit will ...".
   - Good: `Fix Chrome closing during its start-up grace period`
   - Bad: `fixed stuff`, `Updates`, `WIP`
2. **Prefix** the subject with the area when the change only concerns one: `Mac:`, `Windows:`, `Extension:`, `CI:`, `Docs:`, `Installer:`. Leave it off for changes that cut across everything.
3. **Body** (strongly recommended for anything non-trivial): leave a blank line after the subject, wrap at about 72 to 100 characters, and explain **why** the change was needed and what behaviour changes, not just what the diff already shows. Mention how you verified it.
4. **One logical change per commit.** A bug fix, its test, and a doc update for it belong together; an unrelated refactor does not. Don't mix formatting-only changes into a behaviour change.
5. **Every commit builds and passes the tests** for the part you touched, so history can be bisected.
6. **Fix bugs with a test** that fails without the fix. If a test is impossible (for example it needs a real Windows desktop), say so in the commit body.
7. **Reference issues or pull requests** in the body when they exist (`Fixes #12`, `Follow-up to #2`).
8. **AI-assisted work:** if an AI tool wrote or substantially changed the code, keep its `Co-Authored-By:` trailer, and review the change yourself before committing.
9. **Don't rewrite shared history.** Amend or rebase only your own unpushed (or unreviewed) branch; never force-push `main`.

A commit message template is provided; enable it once with:

```sh
git config commit.template .gitmessage
```

Example:

```text
Windows: give a freshly started Chrome time to start the extension

Strict website sessions closed Chrome whenever the last heartbeat was stale,
so a newly launched Chrome was closed before its extension could connect.
Add a 30 second start-up grace, ignore heartbeats that predate this Chrome,
and act only once the Chrome host is registered.

Verified with new ProcessGuard tests and the real host process test.
```

## Code rules

- **Match the surrounding code:** naming, comment density and idiom. Comments explain **why**, not what.
- **Keep the platforms in step.** Rule matching, lock behaviour and strict-mode edit rules exist in both the Swift engine (`Sources/FocusCore`) and the Windows engine (`Windows/FocusBlocker.Core`). A change to one needs the matching change in the other, with tests in both. The shared fixture `Tests/fixtures/url-cases.json` pins website matching for Swift and the extension; add cases there when matching changes.
- **Never force-kill.** Enforcement asks apps to quit and must not force-terminate them.
- **Never send the password to the extension** or let the extension change or end a session. It may only read policy and report heartbeats.
- **Protected apps stay protected.** System processes and Focus Blocker itself must never become blockable.
- **Fail safe.** Unreadable or tampered state must not silently end a session early, and must not block indefinitely (sessions are capped at 12 hours).
- **Swift:** the views use `@LocalState` instead of `@State` so the project builds with only the Command Line Tools. Keep new code compiling that way.
- **C#:** nullable reference types are on; keep warnings at zero.

## Tests

Run everything relevant to your change before pushing.

```sh
./build.sh test                                              # macOS: Swift engine + extension tests
python3 -I Tests/e2e/nmh_e2e.py .build                       # macOS: real Chrome host over pipes
dotnet run --project Windows/FocusBlocker.Tests -c Release   # Windows engine, process rules, real host
```

CI runs the macOS and Windows tests on every push to `main` and every pull request. CI does not run the publish step or the installers, so if you change `build.sh`, `install-mac.sh`, `install-windows.ps1` or the release workflow, reproduce the affected commands yourself and say how in the pull request.

## Pull requests

1. Push your branch and open a pull request against `main`. Fill in the template.
2. Keep it focused and small enough to review. Explain what changed, why, and **what you verified and what you could not**.
3. **CI must be green** (the macOS and Windows jobs) before merging. Address review comments with new commits.
4. **Merge with a merge commit** (not squash or rebase) so the individual commits are kept.
5. Pull requests that change the release workflow must be tested by running the workflow (`workflow_dispatch`) before relying on them.

## Releases

Releases are cut from `main` by pushing a tag `vMAJOR.MINOR.PATCH` (for example `v0.2.6`) or running the **Release** workflow with a version. The workflow builds and publishes the macOS app, Windows app and extension together.

- **Never reuse or move a tag.** If a release is wrong, publish a new patch version.
- Only publish a release after the code is merged to `main` and CI is green.
- The installers download the **latest** release, so a release is what delivers a fix.
- **Never name a workflow-level environment variable `VERSION`** (or another MSBuild property name such as `Configuration`): MSBuild reads environment variables as properties and every `dotnet restore` will fail. The workflow uses `RELEASE_TAG`.

## Security-sensitive changes

The password handling, the state and audit-log integrity code, the installers and the process-closing logic deserve extra care. Describe the threat you are addressing, keep changes minimal, and add tests. If you find a vulnerability, please open an issue that describes the area without publishing exploit details, or contact the maintainer directly.

## Reporting bugs

Open an issue with your OS and version, what you expected, what happened, and (where relevant) the output of `focusctl status`, `focusctl chrome status` or the app's Activity screen. Never paste your accountability password or state files.
