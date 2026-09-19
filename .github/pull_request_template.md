Closes #

## What and why
<!-- One issue per PR. What changed, and why this way (link the design/plan section if there is one). -->

## Tests run
<!-- Paste the summary lines, not the whole log. -->
- [ ] `make lint` → `lint: OK`
- [ ] `make test` → all `ok`
- [ ] New/changed behaviour has a test, written first and seen failing: chart behaviour in the chart's helm-unittest suite (`tests/*_test.yaml`), integration/scripts in `hack/tests/test_*.sh`
- [ ] `version` bumped in `Chart.yaml` of every chart whose packaged content this PR changes (not needed for `tests/` only)

## Live lab
- [ ] Does not change what runs on the lab (docs, tests, tooling only)
- [ ] `needs-lab`: verification plan below; run after merge under `hack/lab-lock.sh acquire issue-<n>/<who>`

<!-- needs-lab: which checks prove it (kubectl/argocd/kargo commands and the expected output). After merge, comment
the evidence on the issue: key lines only, never secret material. -->

## Invariants (CLAUDE.md)
- [ ] Cluster name == agent name == cert CN == Argo destination name == OpenChoreo planeID
- [ ] Cluster facts only in `fleet/clusters/<env>/<name>.yaml`; no cluster names hardcoded in ApplicationSets
- [ ] Anything for workers carries `argocd-agent: "true"` (Application and AppProject) and `destination.name`
- [ ] Addons are umbrella charts; the config repo holds no templates
- [ ] Kargo-owned files (`rendered/*`, `repos/apps/*/envs/<env>/values.yaml`) not hand-edited (break-glass: say so)
- [ ] No relative references across `repos/*`
- [ ] CA keys stay on the hub; worker secrets are pulled from OpenBao; no secret material in git, logs or this PR
- [ ] Enable/disable by `.yaml.disabled`, not by commenting out
- [ ] No single push changes an Argo Application's spec and the content it syncs

## Risks / follow-ups
<!-- What could break, how to roll back, what you deliberately left out (open an issue for it). -->
