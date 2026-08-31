# Upstream automation, parked

These are the GitHub Actions workflows and the Dependabot config inherited from
[Telmate/terraform-provider-proxmox](https://github.com/telmate/terraform-provider-proxmox).

They are **not active**: GitHub only runs workflows that sit directly in
`.github/workflows/`, and only reads Dependabot config at `.github/dependabot.yml`.
Parking them here disables them while keeping them readable, so each one can be
adopted later on its own merits.

`go.yml` and `release.yml` have since been **adopted** and now live in
`.github/workflows/`, rewritten for the fork: `go.yml` targets `main` and adds
`workflow_dispatch`, `release.yml` fires on the fork's own `v*` tags. Only the
two below are still parked.

| File                  | What it did upstream                                            | Why it is parked |
| --------------------- | --------------------------------------------------------------- | ---------------- |
| `manage_issues.yml`   | daily cron closing inactive issues                                | Upstream housekeeping for a busy public tracker. Irrelevant here. |
| `dependabot.yml`      | weekly Go module update PRs                                       | The point of the fork is controlling when dependencies move. Chasing upstream bumps is the opposite of that. |

To re-enable one:

```bash
git mv .github/disabled-upstream/manage_issues.yml .github/workflows/manage_issues.yml
```

(`dependabot.yml` goes back to `.github/dependabot.yml`, not to `workflows/`.)
