# Upwind image scan task for Azure Pipelines

Scan container images for vulnerabilities with [Upwind](https://www.upwind.io)
ShiftLeft directly from your Azure Pipelines build, and get a sticky
"Upwind Image Scan Report" comment on your pull requests showing introduced,
resolved, and existing CVEs plus a per-PR scan history.

The task downloads the `shiftleft` binary, scans the image you just built,
reports the results to your Upwind organization (they appear in the Console
under Vulnerabilities > CI scans), and - on pull-request builds - posts or
updates one comment thread per PR.

## Quick start

1. **Install the extension (one time, per Azure DevOps organization).** A
   Project Collection Administrator installs **Upwind Image Scan** (publisher
   `upwindsecurity`) from the Visual Studio Marketplace into your
   organization.

2. **Add your Upwind credentials as secret pipeline variables** (Pipelines >
   your pipeline > Edit > Variables, tick "Keep this value secret"):
   `UPWIND_CLIENT_ID` and `UPWIND_CLIENT_SECRET` (an Upwind sensor
   credential).

3. **Add the task to your `azure-pipelines.yml` after the image is built:**

   ```yaml
   steps:
     - script: docker build -t myapp:$(Build.SourceVersion) .
       displayName: Build image
     - task: UpwindImageScan@0
       inputs:
         image: myapp:$(Build.SourceVersion)
         clientId: $(UPWIND_CLIENT_ID)
         clientSecret: $(UPWIND_CLIENT_SECRET)
         dockerPull: false
   ```

   `dockerPull: false` tells the task the image already exists on the agent
   (built in an earlier step). For an image that lives in a registry, leave
   `dockerPull` at its default (`true`) and set `image` to the registry path;
   the agent must be logged in to that registry.

   Choose the agent pool as you normally would (for example
   `pool: {vmImage: ubuntu-latest}`). The agent needs `bash`, `curl`, `jq`
   and `docker`; Microsoft-hosted Ubuntu images include all four.

4. **Grant the build service permission to comment on pull requests (one
   time per repository).** See
   [Allow the task to comment on pull requests](#allow-the-task-to-comment-on-pull-requests).
   Without it the scan still runs and reports to the Console; only the PR
   comment is skipped.

5. **Make the pipeline run on pull requests** with a Build Validation branch
   policy (see [Blocking merges](#blocking-merges)). Azure Repos ignores the
   YAML `pr:` trigger, so the policy is also what makes a run a "pull-request
   run" that can post a comment.

The `@0` in `UpwindImageScan@0` floats on the latest `0.x.y` release of the
task, so fixes arrive without pipeline changes. Scan logic itself ships in
the `shiftleft` binary, which the task always fetches from your configured
release channel.

## Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `image` | yes | | The image to scan, e.g. `myapp:$(Build.SourceVersion)` |
| `clientId` | yes | | Upwind sensor credential id |
| `clientSecret` | yes | | Upwind sensor credential secret; pass a secret pipeline variable such as `$(UPWIND_CLIENT_SECRET)` |
| `upwindUri` | no | `upwind.io` | Upwind domain: `upwind.io` or `upwind.dev` |
| `blockOn` | no | never block | Fail the task on scan recommendation: `do_not_deploy` or `deploy_with_caution` |
| `enforceBlockPolicy` | no | `false` | `true` to fail the task when the scan violates your organization's Upwind PR-block policy |
| `dockerPull` | no | `true` | `false` when the image was built earlier in the same pipeline (default: pull from the registry) |
| `agentChannel` | no | `stable` | Release channel of the `shiftleft` binary |
| `postComment` | no | `true` | `false` to never post the PR comment |

## Allow the task to comment on pull requests

The task posts the report using the pipeline's own job access token, so no
extra secret or token variable is needed. The identity behind that token is
the project build service, and by default it is not allowed to write to pull
requests. Grant it once per repository:

1. Project settings > Repositories > select the repository (or "All
   repositories") > Security.
2. Find the build service identity: **`<Project name> Build Service
   (<Organization name>)`**. If your organization turned off "Limit job
   authorization scope to current project", the identity is **`Project
   Collection Build Service (<Organization name>)`** instead.
3. Set **Contribute to pull requests** to **Allow**.

Until this is granted, the comment step fails with HTTP 403 and Azure DevOps
answers with:

```
TF401027: You need the Git 'PullRequestContribute' permission to perform this action. Details: identity 'Build\<project-id>', scope 'repository'.
```

In the task log this shows as `Warning: failed to post Upwind PR comment`
(usually preceded by a curl 403 line). The scan result is unaffected and the
build is not failed because of the comment.

The report is posted as a thread with status **Closed**, so it never trips a
"Comment requirements" branch policy.

## Blocking merges

The task fails (nonzero exit) when `blockOn` matches the scan recommendation,
or when `enforceBlockPolicy: true` and your Upwind organization's PR-block
policy is violated. The report comment is still posted before the task
exits.

```yaml
- task: UpwindImageScan@0
  inputs:
    image: myapp:$(Build.SourceVersion)
    clientId: $(UPWIND_CLIENT_ID)
    clientSecret: $(UPWIND_CLIENT_SECRET)
    dockerPull: false
    blockOn: do_not_deploy
```

A failed build only blocks the merge when the pipeline is wired in as a
required check. In Project settings > Repositories > the repository >
Policies > Branch Policies > your target branch (for example `main`) >
**Build Validation** > Add build policy: pick this pipeline and set Policy
requirement to **Required**. Pull requests targeting that branch then queue
the pipeline automatically, show the result as a PR check, and cannot
complete while it is failed. The same policy is what makes the run a
pull-request run, so the comment is posted.

## Troubleshooting

- **`Info: not a pull-request run; skipping Upwind PR comment`** - comments
  only post on runs queued by a Build Validation policy. Manual and
  CI-trigger runs scan and report to the Console only (and establish the
  baseline for "introduced vs" diffs).
- **`Warning: failed to post Upwind PR comment` with a 403 /
  `TF401027`** - the build service identity lacks **Contribute to pull
  requests**; see
  [Allow the task to comment on pull requests](#allow-the-task-to-comment-on-pull-requests).
- **`No job access token available; the Upwind PR comment will be skipped`**
  - the pipeline has no job access token. This happens when the organization
  or project restricts job authorization, or the build identity is scoped
  out of the repository. Fix the repository grant above and check Project
  settings > Pipelines > Settings.
- **`docker: command not found` / cannot connect to the docker daemon** -
  the agent has no docker. Use a Microsoft-hosted Ubuntu image, or install
  docker on your self-hosted agent and make sure the agent user can run it.
- **The task is rejected or the pipeline cannot find `UpwindImageScan@0`** -
  the extension is not installed in this organization, or the organization
  has a task restrictions policy. If the organization restricts which tasks
  may use commands or set variables, the Upwind task declares restricted
  command mode and sets no variables, so it should pass; if your policy only
  allows an explicit task list, ask a Project Collection Administrator to add
  it.
- **The scan shows the repository as a raw URL in the Console** - the
  repository name is resolved from your Upwind Code integration. Until the
  Azure DevOps repository is onboarded in Upwind (Integrations > Code), the
  scan is shown with the repository's full URL instead of its name. The scan
  itself is unaffected.
- **Scan shows "Reported via API" in the Console / `invalid value
  "AZURE_DEVOPS"` from the CLI** - the `shiftleft` binary on your release
  channel predates Azure DevOps support; it works once your channel picks up
  the release that includes it. Set `agentChannel` to a release that includes
  Azure DevOps support.
- **The pipeline sits in "Queued/Not started" the first time** - Azure
  Pipelines needs a one-time authorization of the agent pool for a new
  pipeline, and Microsoft-hosted agents need parallelism in the organization.
  Neither is related to the task.

## Repository layout

- `azure/task/` - the task: `task.json` (inputs), `index.js` (launcher),
  `scan.sh` (scan orchestration), `upwind_ado_comment.sh` (PR comment)
- `azure/vss-extension.json` - the Marketplace extension manifest published
  by the repo's Azure release workflow; `azure/vss-extension.dev.json` is the
  private dev build used by the e2e runbook in `azure/e2e/README.md`
- `azure/tests/` - offline test suites (`run_task_tests.sh`,
  `run_launcher_tests.sh`, `run_comment_tests.sh`)
