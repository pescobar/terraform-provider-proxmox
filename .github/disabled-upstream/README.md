# Upstream automation, parked

These are the GitHub Actions workflows and the Dependabot config inherited from
[Telmate/terraform-provider-proxmox](https://github.com/telmate/terraform-provider-proxmox).

They are **not active**: GitHub only runs workflows that sit directly in
`.github/workflows/`, and only reads Dependabot config at `.github/dependabot.yml`.
Parking them here disables them while keeping them readable, so each one can be
adopted later on its own merits.

| File                  | What it did upstream                                            | Why it is parked |
| --------------------- | --------------------------------------------------------------- | ---------------- |
| `go.yml`              | build, vet, staticcheck and unit tests on push/PR to `master`    | Worth adopting once the fork's branch names are settled; it is the only one with real value. |
| `release.yml`         | GoReleaser on every `v*` tag, signs artifacts with a GPG key     | Would fire ~51 times if upstream tags are ever pushed, and fails without `GPG_PRIVATE_KEY` / `PASSPHRASE` secrets. Needs rewriting for the fork's own release process anyway. |
| `manage_issues.yml`   | daily cron closing inactive issues                                | Upstream housekeeping for a busy public tracker. Irrelevant here. |
| `dependabot.yml`      | weekly Go module update PRs                                       | The point of the fork is controlling when dependencies move. Chasing upstream bumps is the opposite of that. |

To re-enable one:

```bash
git mv .github/disabled-upstream/go.yml .github/workflows/go.yml
```

(`dependabot.yml` goes back to `.github/dependabot.yml`, not to `workflows/`.)
