# Azure Pipelines image scan task - live e2e runbook

Repeatable end-to-end validation of the `UpwindImageScan@0` task against Upwind's own test
org. Everything here is private test infrastructure; the extension is the private dev build
(`vss-extension.dev.json`). Never publish the prod manifest from this runbook.

Last full run: 2026-10-18, extension `upwindsecurity.upwind-image-scan-dev` v0.0.1, 4/4 scenarios passed.
Last regression run: 2026-10-22, v0.0.4 (review fixes), all scenarios below passed.

The dev extension publishes the task as `UpwindImageScanDev@0` (own GUID, see the release
workflow's rebrand step), so the e2e YAML must reference that name, not `UpwindImageScan@0`.

## Environment

| Item | Value |
|---|---|
| ADO org / project | `upwind-shiftleft-dev` / `shiftleft-test` (project id `92bd487d-84c9-4f7b-a730-a357c6df386b`) |
| Repo | `shiftleft-test`, id `fb257192-26b8-42d8-aec6-d27f7a07b17d`, default branch `aa` (not touched) |
| Branches | `image-scan-e2e-base` (PR target + non-PR baseline), `image-scan-e2e` (PR source) |
| Files on the branches | `azure-image-scan-e2e/Dockerfile`, `azure-image-scan-e2e/azure-pipelines-e2e.yml` |
| Pipeline definition | id `2`, `upwind-image-scan-e2e`, YAML `azure-image-scan-e2e/azure-pipelines-e2e.yml` |
| Pipeline variables | `UPWIND_CLIENT_ID` (secret), `UPWIND_CLIENT_SECRET` (secret), `UPWIND_SHIFTLEFT_PATH` (plain, path to the pre-release binary) |
| Build Validation policy | id `4` on `refs/heads/image-scan-e2e-base` only (blocking, builds definition 2); the policy on `aa` is not involved |
| Agent | self-hosted `spike-mac`, pool `Default` (id 1). The org has no hosted parallelism, so the YAML uses `pool: {name: Default}` |
| Upwind env | `upwindUri: upwind.dev`, dev-org sensor credential (values live only in the secret pipeline variables, never in this repo) |
| PR | #14 `image-scan-e2e` -> `image-scan-e2e-base` (left open, do not merge) |

Auth for all ADO and Marketplace REST calls is an AAD bearer from
`az account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798` (no PATs).

## Setup

1. **Build the VSIX** (not committed, gitignored):
   `cd azure && npx --yes tfx-cli extension create --manifest-globs vss-extension.dev.json --no-prompt`
2. **Publish** (new extension): `POST https://marketplace.visualstudio.com/_apis/gallery/publishers/upwindsecurity/extensions?api-version=7.1-preview.2`, `Content-Type: application/octet-stream`, body = VSIX. Expected 201. For a later version bump use PUT on `.../extensions/upwind-image-scan-dev` and bump BOTH `task.json` and the manifest version.
3. **Share**: `POST https://marketplace.visualstudio.com/_apis/gallery/publisher/upwindsecurity/extension/upwind-image-scan-dev/accountsbyname/upwind-shiftleft-dev?api-version=7.1-preview.1` (singular `publisher`/`extension`). Expected 201.
4. **Wait for validation** (~1-3 min): poll `GET .../gallery/publishers/upwindsecurity/extensions/upwind-image-scan-dev?api-version=7.1-preview.2` until `flags` is `validated`. Installing earlier fails with "doesn't exist".
5. **Install**: `POST https://extmgmt.dev.azure.com/upwind-shiftleft-dev/_apis/extensionmanagement/installedextensionsbyname/upwindsecurity/upwind-image-scan-dev?api-version=7.1-preview.1`. Expected 200 with `extensionName: "Upwind Image Scan (Dev)"`.
6. **Pre-release CLI** (until the stable channel has `--source=AZURE_DEVOPS`): build from the Task 1 shiftleft checkout, `go build -buildvcs=false -o <dir>/shiftleft ./cmd/shiftleft` (darwin/arm64, same machine as the agent) and set `UPWIND_SHIFTLEFT_PATH` to it. The task then skips the OAuth + download step.
7. **Repo grant**: the project build service `shiftleft-test Build Service (upwind-shiftleft-dev)` needs repo-level `Contribute to pull requests` (`PullRequestContribute`) on `shiftleft-test`. It was granted 2026-10-18; without it the comment POST returns 403 TF401027.
8. **Branches and files**: create `image-scan-e2e-base` from `aa` and push the Dockerfile + pipeline YAML (below); create `image-scan-e2e` from it. Pushes go through `POST .../_apis/git/repositories/{repo}/pushes?api-version=7.1`.
9. **Pipeline definition**: `POST .../_apis/build/definitions?api-version=7.1` with `process: {type: 2, yamlFilename: "azure-image-scan-e2e/azure-pipelines-e2e.yml"}`, `repository: {id, type: "TfsGit", defaultBranch: "refs/heads/image-scan-e2e-base"}`, `queue: {id: 1}` and the `variables` map above (secret ones with `isSecret: true`).
10. **Authorize the queue** for the new definition (first use otherwise sits `notStarted`): `PATCH .../_apis/pipelines/pipelinepermissions/queue/1?api-version=7.1-preview.1` with `{"pipelines":[{"id":2,"authorized":true}]}`.
11. **Build Validation policy** (what makes the run a real PR run): `POST .../_apis/policy/configurations?api-version=7.1`, type id `0609b952-1397-4640-95ec-e00a01b2c241`, `settings: {buildDefinitionId: 2, queueOnSourceUpdateOnly: false, manualQueueOnly: false, validDuration: 0, scope: [{refName: "refs/heads/image-scan-e2e-base", matchKind: "Exact", repositoryId: <repo id>}]}`. A manual queue of a `refs/pull/N/merge` ref does NOT populate `System.PullRequest.*`; only the policy-triggered run does, and YAML `pr:` triggers are ignored for Azure Repos.

Pipeline YAML used for scenarios 1, 2 and 4 (`azure-pipelines-e2e.yml`):

```yaml
trigger: none
pr: none
pool:
  name: Default
steps:
  - checkout: self
    clean: true
  - script: docker build -t upwind-e2e:$(Build.SourceVersion) azure-image-scan-e2e
    displayName: Build image
  - task: UpwindImageScanDev@0
    displayName: Upwind image scan
    inputs:
      dockerImage: upwind-e2e:$(Build.SourceVersion)
      upwindClientId: $(UPWIND_CLIENT_ID)
      upwindClientSecret: $(UPWIND_CLIENT_SECRET)
      postComment: true
      upwindUri: upwind.dev
      dockerPull: false
```

Scenario 3 adds `blockOn: do_not_deploy` to the task inputs on the PR branch.
Dockerfiles: base `alpine:3.19` + `apk add curl`; PR commits use `alpine:3.18`, `alpine:3.17`, then `alpine:3.12` (+ curl) for the critical-CVE commit.

## Scenarios and results (run 2026-10-18)

Run link pattern: `https://dev.azure.com/upwind-shiftleft-dev/shiftleft-test/_build/results?buildId=<id>`

| # | Scenario | Run | Expected | Result |
|---|---|---|---|---|
| 4 | Non-PR baseline: manual queue on `image-scan-e2e-base` | [5](https://dev.azure.com/upwind-shiftleft-dev/shiftleft-test/_build/results?buildId=5) | green; comment skipped with the "not a pull-request run" Info line; baseline scan in Console | PASS. Task log has `Info: not a pull-request run; skipping Upwind PR comment`, exit 0, scan reported ("first seen image") with a Console link |
| 1 | PR scan + comment, PR #14 (policy-triggered) | [6](https://dev.azure.com/upwind-shiftleft-dev/shiftleft-test/_build/results?buildId=6) | green; one "Upwind Image Scan Report" thread, status Closed; collapsibles render; Console link resolves; scan row shows Azure Pipelines + pipeline name + run id | PASS. New thread id `54`, author the project build service, status `closed`; `<details>` render collapsed/expanded in the PR UI. Console link opened in the dev Console (logged-in browser): scan details show CI/CD platform `Azure Pipelines`, Pipeline name `upwind-image-scan-e2e`, Run ID `#6`, scan initiator = pipeline requester. Task accepted the inputs with `blockOn` unset (empty-string pickList default compiled and ran) |
| 2 | Sticky update: second commit | [7](https://dev.azure.com/upwind-shiftleft-dev/shiftleft-test/_build/results?buildId=7) | SAME thread updated in place, history shows 2 scans, thread still Closed | PASS. Log: `Updating existing PR thread (54) with new scan + history`; thread 54 now has "Scan history (2 scans)", status `closed`, no second report thread |
| 3 | Block AFTER comment: critical CVEs + `blockOn: do_not_deploy` | [8](https://dev.azure.com/upwind-shiftleft-dev/shiftleft-test/_build/results?buildId=8) | comment posts first, THEN the task fails the job; PR shows failed check | PASS. Log order: CLI prints `Blocking workflow because of 'DO NOT DEPLOY' scan recommendation`, then `Updating existing PR thread (54)` (history now 3 scans), then the task exits 1 (`result: failed`). PR #14 shows "1 required check failed"; policy evaluation `Build: rejected` for build 8 |

Scan ids (Console deep links `https://console.upwind.dev/?redirectToCodeScanId=<id>`): run 5 `40be9b36cfd788fdde6dcb528bb7926572768a717d4daee081fb4c5a82b91781`, run 6 `0e6b8acda395b4ccbed9319a7a2c014e8fb856a237033854bff03b3e924141a7`, run 7 `bbdf7bfc20c78ed03a12610bdfac319bcbfe65db6afdf1f6fe6c7e0f531c9391`, run 8 `1bf0dcb70445530ae0f28a092031c5442ded7fe90670481ae6db2bd4e51c2a1f`.

## Regression run 2026-10-22 (v0.0.4)

| Scenario | Run | Result |
|---|---|---|
| PR scan + sticky update (PR #14, policy-triggered) | [11](https://dev.azure.com/upwind-shiftleft-dev/shiftleft-test/_build/results?buildId=11) | PASS. Task 0.0.4 with the renamed inputs and `postComment: true`; `Updating existing PR thread (54)`, history now 4 scans, thread still `closed`, no duplicate thread. The new history entry records the PR head commit `7bf35fe9` (not the merge commit `97e3a660` the build checked out); diff label reads "vs `image-scan-e2e-base`" |
| Non-PR run: manual queue on `image-scan-e2e` | [13](https://dev.azure.com/upwind-shiftleft-dev/shiftleft-test/_build/results?buildId=13) | PASS. `Info: not a pull-request run; skipping Upwind PR comment`, exit 0, scan reported |

| Block after comment: `blockOn: do_not_deploy`, Dockerfile `alpine:3.9` (new CVEs) | [15](https://dev.azure.com/upwind-shiftleft-dev/shiftleft-test/_build/results?buildId=15) | PASS. `Blocking workflow ... DO NOT DEPLOY`, then `Updating existing PR thread (54)`, then the task fails. The first attempt ([14](https://dev.azure.com/upwind-shiftleft-dev/shiftleft-test/_build/results?buildId=14)) did not block because the image matched the previous scan (0 new CVEs, CLI says proceed); the image must introduce new CVEs |
| `postComment` unset (default off) | [16](https://dev.azure.com/upwind-shiftleft-dev/shiftleft-test/_build/results?buildId=16) | PASS. `Info: postComment is not enabled; skipping Upwind PR comment`; thread 54 unchanged |
| `mainBranch: image-scan-e2e` override | [17](https://dev.azure.com/upwind-shiftleft-dev/shiftleft-test/_build/results?buildId=17) | PASS. Comment reads "vs `image-scan-e2e`" and the CLI diffs against that branch (0 new, vs 225 new against the PR target) |
| No result: nonexistent image, `dockerPull: true` | [18](https://dev.azure.com/upwind-shiftleft-dev/shiftleft-test/_build/results?buildId=18) | PASS. "produced no result" surfaces as a `##[warning]` issue on the run summary; step green |
| No result + `failOnScanError: true` | [19](https://dev.azure.com/upwind-shiftleft-dev/shiftleft-test/_build/results?buildId=19) | PASS. Same message as a `##[error]` issue; task fails |
| Job name | RDB | PASS. Dev org `org_8xFvjw2CxGPfGjwr` (host `aurora01-development-ro.dev.internal`), `shift_left_events.repositoryScanDetails`: every 0.0.4 run has `jobName = "Job"` (the implicit job's `System.JobDisplayName`) and run 17 has `mainBranchName = image-scan-e2e`; runs on 0.0.1/0.0.3 have `jobName` NULL |

Final state: PR branch back on the green setup ([20](https://dev.azure.com/upwind-shiftleft-dev/shiftleft-test/_build/results?buildId=20)): `postComment: true`, Dockerfile `alpine:3.9`, thread 54 with 8 scans. Not exercised live: private-registry inputs (`dockerUser`, `dockerPassword`, `additionalRegistries`, `ociClient` other than docker) and `enforceBlockPolicy`.

`image-scan-e2e-base` now rejects direct pushes (TF402455) because of the Build Validation
policy, so its YAML still references the old task. Run the non-PR scenario against
`image-scan-e2e` instead.

### Deviations from the original plan

- Scenario 4 does not merge the PR. A manual (non-PR) queue of the baseline branch `image-scan-e2e-base` exercises the same comment-skip + baseline path without merging anything, and the default branch `aa` is never touched.
- The PR targets `image-scan-e2e-base` instead of `aa` so that the Build Validation policy (needed for a real PR run) does not alter the shared policies on `aa`.
- Scenario 3 uses `blockOn: do_not_deploy` rather than `enforceBlockPolicy: true`, so it does not depend on the dev org's PR-block policy. `enforceBlockPolicy` was not exercised live.

### Notes and gotchas

- In the dev org, even a plain `alpine:3.19` + curl image scans as `do_not_deploy` (it introduces critical CVEs vs the previous tag), so `blockOn: do_not_deploy` blocks almost any image there. Keep `blockOn` unset for the green scenarios. `proceed_with_deployment` can never block.
- Other threads on PR #14 by `Upwind Code (Dev)` and the "reference was updated" system threads come from the Upwind SCM integration and ADO itself, not from the task.
- The task process runs `scan.sh` with the agent's working directory; `upwind-shift-left.json` lands in the agent workspace (`checkout: self, clean: true` resets it per run).

## Re-running

- Re-run scenario 1/2: push a commit to `image-scan-e2e` (the policy queues a build) or click Re-queue on the PR check.
- Re-run scenario 4: `POST .../_apis/pipelines/2/runs?api-version=7.1` with `{"resources":{"repositories":{"self":{"refName":"refs/heads/image-scan-e2e-base"}}}}`.
- New task version: bump `task.json` and `vss-extension.dev.json` versions, rebuild the VSIX, `PUT` the extension; installed orgs auto-update.

## Cleanup (when the task ships)

Delete the PR, both branches, pipeline definition 2 and policy 4 in `shiftleft-test`; uninstall and unpublish `upwind-image-scan-dev`. Nothing in this runbook modifies pre-existing org state.
