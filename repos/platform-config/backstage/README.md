# Backstage (OpenChoreo) software templates

| Template | What it creates |
|---|---|
| [`templates/helm-chart-repo`](templates/helm-chart-repo/template.yaml) | A Helm chart repository (plain or umbrella chart) with pre-commit, conventional-commit semver releases (commitizen) and GitLab CI publishing to Artifactory |

Nothing here is applied by Argo CD: Backstage reads the templates straight from git once they are registered.
`hack/tests/test_backstage_template.sh` renders each skeleton offline (nunjucks, like the scaffolder) and lints the
result; `BACKSTAGE_TEMPLATE_PRECOMMIT=1` also runs the generated repo's `pre-commit run --all-files`.

## What OpenChoreo 1.2.5's Backstage can run

Checked against `openchoreo/backstage-plugins` v1.2.5 (`packages/backend`, `yarn.lock`): Backstage 1.51,
`scaffolder-backend` 4.0.0 with only `scaffolder-backend-module-github` 0.9.9 (plus OpenChoreo's own actions).

| Action | In the image |
|---|---|
| `fetch:template`, `catalog:register` | yes (built in) |
| `publish:github` | yes |
| `publish:gitlab` | **no** (`@backstage/plugin-scaffolder-backend-module-gitlab` is not a dependency) |

So `helm-chart-repo` offers two targets. **GitLab** is the intended one and needs either an image with the GitLab
module (two lines in `packages/backend`: the dependency `@backstage/plugin-scaffolder-backend-module-gitlab`, 0.11.x
for Backstage 1.51, and `backend.add(import('@backstage/plugin-scaffolder-backend-module-gitlab'))`) or a later
OpenChoreo release that bundles it. **GitHub** works with the stock image and proves the template end to end
(the generated repository still carries the GitLab pipeline).

## Registering (issue #12)

`backstage.appConfig` of the `openchoreo-control-plane` chart becomes an extra app-config file. Two traps:

- The image sets no global `catalog.rules`, so Backstage's default (`Component`, `API`, `Location`) applies:
  a template location needs its own `rules: [allow: [Template]]`.
- Backstage **replaces arrays** from lower-priority config files instead of merging them: setting
  `catalog.locations` drops OpenChoreo's built-in template locations unless they are listed again.
  The list below is `app-config.production.yaml` of backstage-plugins v1.2.5: re-check it when upgrading.

```yaml
# repos/platform-config/addons/management/openchoreo-control-plane/values.yaml
openchoreo-control-plane:
  backstage:
    appConfig:
      catalog:
        locations:
          # OpenChoreo 1.2.5 built-ins (restated because arrays replace, see above)
          - { type: file, target: /app/catalog-entities/org.yaml, rules: [{ allow: [Group] }] }
          - { type: file, target: /app/templates/create-openchoreo-componenttype/template.yaml, rules: [{ allow: [Template] }] }
          - { type: file, target: /app/templates/create-openchoreo-resourcetype/template.yaml, rules: [{ allow: [Template] }] }
          - { type: file, target: /app/templates/create-openchoreo-projecttype/template.yaml, rules: [{ allow: [Template] }] }
          - { type: file, target: /app/templates/create-openchoreo-trait/template.yaml, rules: [{ allow: [Template] }] }
          - { type: file, target: /app/templates/create-openchoreo-workflow/template.yaml, rules: [{ allow: [Template] }] }
          - { type: file, target: /app/templates/create-openchoreo-environment/template.yaml, rules: [{ allow: [Template] }] }
          - { type: file, target: /app/templates/create-openchoreo-namespace/template.yaml, rules: [{ allow: [Template] }] }
          - { type: file, target: /app/templates/create-openchoreo-deploymentpipeline/template.yaml, rules: [{ allow: [Template] }] }
          - { type: file, target: /app/templates/create-openchoreo-clustercomponenttype/template.yaml, rules: [{ allow: [Template] }] }
          - { type: file, target: /app/templates/create-openchoreo-clusterresourcetype/template.yaml, rules: [{ allow: [Template] }] }
          - { type: file, target: /app/templates/create-openchoreo-clusterprojecttype/template.yaml, rules: [{ allow: [Template] }] }
          - { type: file, target: /app/templates/create-openchoreo-clustertrait/template.yaml, rules: [{ allow: [Template] }] }
          - { type: file, target: /app/templates/create-openchoreo-clusterworkflow/template.yaml, rules: [{ allow: [Template] }] }
          - { type: file, target: /app/templates/create-openchoreo-notification-channel/template.yaml, rules: [{ allow: [Template] }] }
          # this repo's templates (fetch:template resolves ./skeleton relative to this URL)
          - type: url
            target: https://github.com/koorikla/platform-lab/blob/main/repos/platform-config/backstage/templates/helm-chart-repo/template.yaml
            rules: [{ allow: [Template] }]
      integrations:
        # reading the template + publish:github/catalog:register for the GitHub target; the base config's
        # github.com entry is not loaded by the image (it ships app-config.production.yaml only)
        github:
          - host: github.com
            token: ${GITHUB_TOKEN}
        # the GitLab target (needs the GitLab scaffolder module, see above)
        # gitlab:
        #   - host: gitlab.example.com
        #     token: ${GITLAB_TOKEN}
    extraEnv:
      # tokens come from the backstage-secrets ExternalSecret (OpenBao), never from values
      - name: GITHUB_TOKEN
        valueFrom: { secretKeyRef: { name: backstage-secrets, key: github-token } }
```

Token scopes: GitHub fine-grained token with *Contents* and *Administration* (create repositories) write on the
target owner; GitLab token with `api` on the target group (creating projects and the `ARTIFACTORY_URL` variable).
Artifactory credentials and the release token are **not** Backstage's business: they are group-level CI/CD variables
(see the generated repository's README).
