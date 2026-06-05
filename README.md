# reposis_workflows

Shared GitHub Actions Workflows for reposis repositories.

## Workflows

### maven-build.yml

Builds and tests a Maven project on pull requests.

| Input          | Required | Default     | Description                        |
|----------------|----------|-------------|------------------------------------|
| `java-version` | Yes      | -           | Java version (e.g. `'17'`, `'21'`) |
| `maven-args`   | No       | `-B verify` | Maven arguments                    |

**Usage:**

```yaml
name: Check PR

on:
  pull_request:

permissions:
  contents: read

jobs:
  build:
    concurrency:
      group: pr-checks-${{ github.repository }}-${{ github.event.pull_request.number }}
      cancel-in-progress: true
    uses: gbv/reposis_workflows/.github/workflows/maven-build.yml@v1
    with:
      java-version: '21'
```

---

### maven-deploy.yml

Deploys a Maven snapshot to a Maven repository.

| Input          | Required | Default                                     | Description                                                         |
|----------------|----------|---------------------------------------------|---------------------------------------------------------------------|
| `java-version` | Yes      | -                                           | Java version (e.g. `'17'`, `'21'`)                                  |
| `version`      | No       | -                                           | Snapshot version (e.g. `'test'`), appends `-SNAPSHOT` automatically |
| `maven-args`   | No       | `--batch-mode deploy -P deploy-to-sonatype` | Maven arguments                                                     |
| `server-id`    | No       | `sonatype-central`                          | Maven server id                                                     |

**Usage (push to main):**

```yaml
name: Snapshot Deploy (main)

on:
  push:
    branches:
      - main
  workflow_dispatch:  # allows re-deploying a snapshot manually

permissions:
  contents: read

jobs:
  deploy-snapshot-on-push:
    concurrency:
      group: snapshot-deploy-main-${{ github.repository }}
      cancel-in-progress: true
    uses: gbv/reposis_workflows/.github/workflows/maven-deploy.yml@v1
    with:
      java-version: '21'
    secrets:
      MAVEN_USERNAME: ${{ secrets.SONATYPE_USERNAME }}
      MAVEN_PASSWORD: ${{ secrets.SONATYPE_PASSWORD }}
```

> Secret names (`SONATYPE_USERNAME` / `SONATYPE_PASSWORD` here) are only an
> example. Use whatever secret names are configured in your repository.

---

### maven-deploy-from-pr.yml

Deploys a Maven snapshot defined by a payload (typically a pull request body).
Checks the triggering actor's permission, verifies that a required label is
present on the pull request, extracts and validates the deploy name from the
payload, then deploys. The workflow extracts `deploy.name` as the snapshot
identifier.

| Input            | Required | Default | Description                                                      |
|------------------|----------|---------|------------------------------------------------------------------|
| `actor`          | Yes      | -       | GitHub login of the user triggering the workflow                 |
| `debug`          | No       | `false` | Enables verbose logging for permission/parse steps               |
| `java-version`   | Yes      | -       | Java version (e.g. `'17'`, `'21'`)                               |
| `labels`         | Yes      | -       | Comma-separated list of labels currently on the pull request     |
| `payload`        | Yes      | -       | Deployment instruction text (e.g. PR body or comment)            |
| `required-label` | Yes      | -       | Label that must be present in `labels` for the deploy to proceed |

**Payload format**, typically placed in the pull request body:

```text
deploy.name: <required>
```

Replace `<required>` with a value made only of letters, digits, `.`, `_` and
`-`. The deployed version will be `<version>-<deploy.name>-SNAPSHOT`.

**Authorization is enforced two ways, both inside this workflow itself:**

1. The triggering actor must have at least `write` permission on the
   repository (job `check-permission`, via `verify-permission.yml`).
2. The pull request must carry the label given in `required-label` (job
   `check-label`). Applying labels normally requires at least `triage`
   permission, so an untrusted pull request cannot trigger a deploy on its
   own. A maintainer has to opt it in first by adding the label.

Both `required-label` and `labels` are **required inputs**. This means the
label gate cannot be silently skipped by a caller that forgets to pass them
or that omits an `if:` condition — the check always runs and always fails
closed if the label is missing.

**Recommended usage:**

```yaml
name: Snapshot Deploy (PR)

on:
  pull_request:
    types: [labeled, synchronize, edited]

permissions:
  contents: read

jobs:
  deploy-pr:
    concurrency:
      group: snapshot-deploy-pr-${{ github.repository }}-${{ github.event.pull_request.number }}
      cancel-in-progress: true
    if: |
      github.event_name == 'pull_request' &&
      contains(github.event.pull_request.labels.*.name, 'snapshot-deploy') &&
      contains(github.event.pull_request.body, 'deploy.name:') &&
      !contains(github.event.pull_request.body, 'deploy.name: <required>')
    uses: gbv/reposis_workflows/.github/workflows/maven-deploy-from-pr.yml@v1
    with:
      actor: ${{ github.actor }}
      java-version: '21'
      payload: ${{ github.event.pull_request.body }}
      required-label: 'snapshot-deploy'
      labels: ${{ join(github.event.pull_request.labels.*.name, ',') }}
    secrets:
      MAVEN_USERNAME: ${{ secrets.SONATYPE_USERNAME }}
      MAVEN_PASSWORD: ${{ secrets.SONATYPE_PASSWORD }}
```

> Secret names are only an example. Use whatever secret names are
> configured in your repository.

> Note: the `if:` above only pre-filters on the presence of `deploy.name` in
> the PR body, to avoid unnecessary runs. It intentionally does **not**
> check for the label — that check is enforced inside the workflow itself
> (job `check-label`), so it cannot be forgotten by the caller.

**Why a label, not just the PR body:** the PR body is fully controlled by
the pull request author and can be edited at any time, including on forks.
Gating on a label means a maintainer must actively opt a specific PR in
before any deploy is possible. The body only supplies *what* to deploy
(the `deploy.name` value), never *whether* a deploy is allowed at all.

**Note on repeated triggers:** GitHub does not automatically remove a label
when new commits are pushed to a pull request. If your workflow triggers on
`synchronize`, a label added once will keep authorizing subsequent pushes to
the same pull request until it is manually removed. If you need every new
commit to require fresh maintainer approval, remove the label again after
each `synchronize` event (e.g. via a separate, small workflow with
`pull-requests: write` permission).

**Security note:**

If this workflow is invoked from a `pull_request` event on the base
repository (the setup shown above), the pull request body is only readable,
not directly executed. `deploy.name` is extracted with a strict allow-list
regex (`^[a-zA-Z0-9._-]+$`) before it is used anywhere, so it cannot inject
shell commands or extra Maven arguments.

If this workflow is ever invoked from `pull_request_target` instead (e.g. to
access PR data from forks in contexts where secrets aren't otherwise
available), be aware that it then runs in the **trusted repository
context** while still consuming **untrusted PR data**:

- Secrets become accessible to code checked out from the PR head.
- The PR body and any code in the PR remain untrusted.

Rule: never execute PR-controlled input directly, only validate and parse
it. Security relies on all three checks: actor permission
(`verify-permission.yml`), the required label check (`check-label`), and
strict input validation (`parse-deploy-directives`). Treat the required
label as the actual authorization gate, not the body content itself.

---

### maven-release.yml

Deploys a Maven release to a Maven repository. Sets the version to the
GitHub release tag.

| Input          | Required | Default               | Description                        |
|----------------|----------|-----------------------|------------------------------------|
| `java-version` | Yes      | -                     | Java version (e.g. `'17'`, `'21'`) |
| `maven-args`   | No       | `--batch-mode deploy` | Maven arguments                    |
| `server-id`    | No       | `sonatype-central`    | Maven server id                    |

**Usage:**

```yaml
name: Release Deploy

on:
  release:
    types: [created]

permissions:
  contents: read

jobs:
  deploy:
    concurrency:
      group: release-deploy-${{ github.repository }}-${{ github.ref_name }}
    uses: gbv/reposis_workflows/.github/workflows/maven-release.yml@v1
    with:
      java-version: '21'
    secrets:
      MAVEN_USERNAME: ${{ secrets.SONATYPE_USERNAME }}
      MAVEN_PASSWORD: ${{ secrets.SONATYPE_PASSWORD }}
```

> Secret names are only an example. Use whatever secret names are
> configured in your repository.

> Note: no `cancel-in-progress` is set here on purpose. Two different
> release tags (e.g. `v1.2.0` and a hotfix `v1.2.1`) are independent and
> both should be allowed to complete; the concurrency group only prevents
> the same tag from being deployed twice in parallel.

---

### forward-merge.yml

Creates or updates a pull request that forwards changes from a release branch
to the next release branch. If no newer release branch exists, the changes are
forwarded to the default branch (usually `main`).  
The workflow automatically determines the next target branch by sorting release
branches matching the configured version pattern.

| Input            | Required | Default                 | Description                                     |
|------------------|----------|-------------------------|-------------------------------------------------|
| `default-branch` | No       | `main`                  | Branch used when no newer release branch exists |
| `branch-pattern` | No       | `[0-9]{4}\.[0-9]{2}\.x` | Regex for release branches                      |

**Usage:**


```yaml
name: Forward Merge

on:
  push:
    branches:
      - '[0-9][0-9][0-9][0-9].[0-9][0-9].x'

permissions:
  contents: read
  pull-requests: write

jobs:
  forward-merge:
    concurrency:
      group: forward-merge-${{ github.repository }}-${{ github.ref_name }}
      cancel-in-progress: true
    uses: gbv/reposis_workflows/.github/workflows/forward-merge.yml@v1
```

---
