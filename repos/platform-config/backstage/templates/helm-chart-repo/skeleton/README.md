# ${{ values.name }}

${{ values.description }}

{% if values.chartType == 'umbrella' -%}
Umbrella chart around [`${{ values.upstreamChart }}`](${{ values.upstreamRepository }}) `${{ values.upstreamVersion }}`:
the upstream chart is the only dependency (`Chart.yaml`), its settings live under `${{ values.upstreamChart }}:` in
`values.yaml`, and anything the platform adds (policies, secrets, dashboards) goes into `templates/`.
{%- else -%}
Plain chart: the Kubernetes objects are in `templates/`, their knobs in `values.yaml`.
{%- endif %}

Created from the Backstage template `helm-chart-repo`; owned by `${{ values.owner }}`.

## Develop

Tools: `helm` 4, `pre-commit`, and (for releases by hand) `commitizen`.

```sh
pre-commit install                # pre-commit + commit-msg hooks
helm dependency build .           # umbrella charts: fetch the dependency, then commit Chart.lock
helm lint --strict . && helm template ci .
pre-commit run --all-files        # exactly what the CI lint stage runs
```

Add a `ci/<case>-values.yaml` for every configuration worth guarding: the CI test stage renders each one and checks
it with kubeconform.

## Commit messages and releases

Commits follow [Conventional Commits](https://www.conventionalcommits.org/) (the commit-msg hook rejects anything
else). They decide the next version:

| Commit | Release |
|---|---|
| `fix: …` | patch (0.1.0 → 0.1.1) |
| `feat: …` | minor (0.1.0 → 0.2.0) |
| `feat!: …` or a `BREAKING CHANGE:` footer | major; minor while the version is 0.x (`major_version_zero` in `.cz.toml`) |
| `chore:`, `docs:`, `ci:`, `test:`, … | no release |

Never edit `version` in `Chart.yaml` by hand. On every merge to `main` the **release** job runs `cz bump`: it computes
the version from the commits since the last tag, writes it to `Chart.yaml` and `.cz.toml`, updates `CHANGELOG.md`,
commits `bump: release X.Y.Z` (pushed with `ci.skip`) and pushes the tag `vX.Y.Z`. The tag pipeline's **publish** job
packages the chart and pushes it to Artifactory. `cz bump --dry-run` shows locally what the next release would be.

To release 1.0.0, set `major_version_zero = false` in `.cz.toml` and merge a `feat!:` commit.

## Pipeline

| Stage | When | What |
|---|---|---|
| lint | every pipeline | `pre-commit run --all-files` (helm lint/template, yamllint, whitespace) |
| test | every pipeline | `helm template` with `values.yaml` and each `ci/*-values.yaml`, validated by kubeconform |
| release | `main` | `cz bump` → release commit + tag `vX.Y.Z` |
| publish | tag `vX.Y.Z` | `helm package`; `helm push` to `oci://…` or HTTP upload to `https://…/artifactory/<repo>` |

CI/CD variables (Settings → CI/CD → Variables, usually inherited from the group; never committed):

| Variable | Set by | Notes |
|---|---|---|
| `ARTIFACTORY_URL` | the Backstage template | `oci://<host>/<repo>` for an OCI Helm repository, `https://<host>/artifactory/<repo>` for a classic one |
| `ARTIFACTORY_USER` | an admin | masked, protected |
| `ARTIFACTORY_TOKEN` | an admin | masked, protected; access/identity token with deploy permission on the repository |
| `RELEASE_TOKEN` | an admin | masked, protected; project access token, role Maintainer, scope `write_repository` |

Protected variables are only visible to protected refs: protect `main` and the tag pattern `v*`, and allow the
`RELEASE_TOKEN` bot to push to `main`.

## Install

```sh
helm install my-release oci://<artifactory-host>/<repo>/${{ values.name }} --version X.Y.Z       # OCI
helm repo add charts https://<artifactory-host>/artifactory/<repo> && helm install my-release charts/${{ values.name }}  # classic
```
