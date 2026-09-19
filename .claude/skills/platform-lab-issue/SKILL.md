---
name: platform-lab-issue
description: Use when picking up, implementing, reviewing or merging a GitHub issue of koorikla/platform-lab (the backlog lives in issues, not CLAUDE.md). Covers claiming an issue, working in a git worktree branch, TDD (helm-unittest in the chart, hack/tests for integration), PR + CI, and verifying on the shared live lab under the lab lock. Use it for every change in this repo when several people or agents work in parallel.
---

# Working a platform-lab issue (parallel-safe)

The backlog is GitHub issues on `koorikla/platform-lab` (labels `status:ready|blocked|in-progress`, `phase:*`,
`area:*`, `needs-lab`). Many workers run at once — humans and agents — against **one shared live lab** (hub context
`mgmt`, workers dev1/dev2…). Git is the coordination point for code; the **lab lock** is the coordination point for
the live environment.

## Roles
- **Worker**: implements one issue on a branch, opens a PR, and (after merge) verifies it live.
- **Coordinator** (a person or the orchestrating agent): picks issues for workers, reviews PRs (spec compliance first,
  then code quality), merges, keeps issue labels/dependencies true. Workers never merge their own PR unless the
  coordinator says so in the issue.

## Worker checklist
1. **Pick**: `gh issue list -R koorikla/platform-lab -l status:ready --search "no:assignee"`. Skip issues whose
   "Blocked by" issues are still open.
2. **Claim**: `gh issue edit <n> --add-assignee @me --add-label status:in-progress --remove-label status:ready` and
   comment "claimed by <who>". One issue per worker.
3. **Context**: read `CLAUDE.md` (invariants — do not break them), the issue, the referenced sections of
   `docs/plans/*` (addenda at the end of the design doc override earlier text), and existing patterns in the files you
   touch. Upstream facts must be verified (chart `helm show values`, CRD `kubectl explain`, upstream source at the
   pinned tag) — never guessed.
4. **Branch in a worktree** (never share a working tree with another worker):
   `git worktree add ../lab-issue-<n> -b issue-<n>-<slug> origin/main`.
5. **TDD**: write the test first, watch it fail, implement, watch it pass. **New chart behaviour → a helm-unittest
   suite inside the chart** (`repos/platform-charts/<chart>/tests/*_test.yaml`, fixtures in `tests/values/`, chart-local
   values only: never `repos/platform-config` or another chart, invariant 6). **`hack/tests/test_*.sh` is only for
   integration and scripts**: a chart with `platform-config` values, cross-chart or chart ↔ config contracts, config-only
   checks, scripts against fakes (see `hack/tests/lib.sh`: `render`, `assert_yq`, `assert_fails`). CONTRIBUTING.md
   "Where a test goes" has the rules and the helm-unittest pitfalls; `hack/tests/unittest.sh <chart dir>` runs one
   chart. `make lint && make test` must be green. Commit small; message ends with a `Co-Authored-By:` trailer when an
   agent co-wrote it.
6. **Charts**: bump `version` in `Chart.yaml` of every chart whose packaged content you change. CI enforces it
   (`hack/check-chart-versions.sh origin/main`; a change only under a chart's `tests/` needs no bump when its
   `.helmignore` lists `tests/`); `charts.yaml` publishes only versions GHCR doesn't have yet. A new chart with tests
   gets a `.helmignore` with `tests/`.
7. **PR**: `gh pr create --fill --body "Closes #<n> …"` with: what changed, how it was tested, what needs live
   verification, risks. Keep PRs to one issue. Rebase on `origin/main` if it moved; resolve conflicts yourself.
8. **Report** to the coordinator (PR link, test output, open questions). Address review findings on the same branch.
9. **After merge, for `needs-lab` issues**: `hack/lab-lock.sh acquire issue-<n>/<who> [minutes]` → wait for Argo CD
   to sync `main` (refresh the app if needed) → run the issue's acceptance checks → comment the evidence on the issue
   (key lines only, **never secret material**) → `hack/lab-lock.sh release issue-<n>/<who>`. If it fails, fix forward
   with a new PR while still holding the lock, or revert.
10. **Close**: the PR's `Closes #n` closes the issue; remove `status:in-progress`; if you unblocked other issues,
    flip them `status:blocked` → `status:ready`.

## Rules for the shared lab
- Read-only `kubectl`/`git fetch` never needs the lock. Anything that mutates the lab does: merging to `main` of a
  change Argo applies, `kubectl apply/patch/delete`, Kargo promotions, `docker` on lab containers, cluster rebirths.
- Never `kind delete cluster` (it lists the CAPD clusters mgmt/dev*); never delete `Cluster/mgmt`.
- Keep ≥25 GB free Docker disk (`docker system df`); DiskPressure evicts pods lab-wide.
- One push must not change an Argo Application's spec *and* the content it syncs (auto-sync can retry the old spec);
  split into two merges.
- Rendered branches `rendered/*` are written only by Kargo (or by a documented, reviewed cleanup).
- Secrets: never print, commit or paste key material; tokens come from OpenBao/ESO, the Kargo deploy key from
  `hack/kargo-deploy-key.sh`.

## Coordinator checklist
- Choose parallel issues that touch disjoint paths; serialize `needs-lab` verification through the lock.
- Review each PR in two passes: (1) spec — does it do exactly what the issue asks (read the code, don't trust the
  report); (2) quality — correctness, security, idempotency, tests, repo conventions. Request changes on the PR.
- Merge with `gh pr merge <pr> --squash --delete-branch` once CI is green and both passes approve; then tell the worker
  to verify live (step 9).
- Keep labels honest: `status:blocked` until every "Blocked by" is closed.
