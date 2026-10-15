# Upwind image scan pipe for Bitbucket Pipelines

Scan container images for vulnerabilities with [Upwind](https://www.upwind.io)
ShiftLeft directly from your Bitbucket Pipelines build, and get a sticky
"Upwind Image Scan Report" comment on your pull requests showing introduced,
resolved, and existing CVEs plus a per-PR scan history.

The pipe downloads the `shiftleft` binary, scans the image you just built,
reports the results to your Upwind organization (they appear in the Console
under Vulnerabilities > CI scans), and - on pull-request pipelines - posts or
updates one comment per PR.

## Quick start

1. Define secured repository variables (Repository settings > Pipelines >
   Repository variables): `UPWIND_CLIENT_ID` and `UPWIND_CLIENT_SECRET`
   (an Upwind sensor credential), and optionally `UPWIND_COMMENT_TOKEN`
   (see [Creating the comment token](#creating-the-comment-token)).

2. Add the pipe to your `bitbucket-pipelines.yml` after the image is built.
   A minimal pull-request pipeline:

   ```yaml
   pipelines:
     pull-requests:
       '**':
         - step:
             name: Build + Upwind image scan
             services: [docker]
             script:
               - docker build -t myapp:$BITBUCKET_COMMIT .
               - pipe: docker://ghcr.io/upwindsecurity/code-image-scan-bitbucket:v0
                 variables:
                   UPWIND_CLIENT_ID: $UPWIND_CLIENT_ID
                   UPWIND_CLIENT_SECRET: $UPWIND_CLIENT_SECRET
                   UPWIND_COMMENT_TOKEN: $UPWIND_COMMENT_TOKEN
                   UPWIND_DOCKER_IMAGE: myapp:$BITBUCKET_COMMIT
                   UPWIND_DOCKER_PULL: 'false'
             artifacts: [upwind-shift-left.json]
   ```

   The pipe shares the step's docker daemon, so an image built earlier in
   the same step needs no tar handoff - just set `UPWIND_DOCKER_PULL=false`.
   Images already in a registry need neither: set `UPWIND_DOCKER_IMAGE` to
   the registry path and leave `UPWIND_DOCKER_PULL` on its default (`true`).

3. Open a pull request. The scan runs, the results land in the Upwind
   Console, and (with `UPWIND_COMMENT_TOKEN` set) the report comment appears
   on the PR and is updated in place on every push.

The `:v0` tag floats on the latest `v0.x.y` release, so fixes arrive without
pipeline changes; pin the full version (e.g. `:v0.2.0`) if you prefer
immutable builds. Scan logic itself ships in the `shiftleft` binary, which
the pipe always fetches from your configured release channel.

## Variables

| Variable | Required | Description |
|---|---|---|
| `UPWIND_CLIENT_ID` | yes | Upwind sensor credential id |
| `UPWIND_CLIENT_SECRET` | yes | Upwind sensor credential secret |
| `UPWIND_DOCKER_IMAGE` | yes | The image to scan, e.g. `myapp:$BITBUCKET_COMMIT` |
| `UPWIND_COMMENT_TOKEN` | no | Repository access token with the `pullrequest:write` scope; enables the PR comment |
| `UPWIND_URI` | no | `upwind.io` (default) or `upwind.dev` |
| `UPWIND_BLOCK_ON` | no | Fail the step on scan recommendation: `do_not_deploy` or `deploy_with_caution` |
| `UPWIND_ENFORCE_BLOCK_POLICY` | no | `true` to fail the step when the scan violates your org's PR-block policy |
| `UPWIND_DOCKER_PULL` | no | `false` when the image is built in the same pipeline (default `true`: pull from registry) |
| `UPWIND_AGENT_CHANNEL` | no | Release channel of the `shiftleft` binary (default `stable`) |

Pipes only see the variables you pass in the `variables:` block (plus
Bitbucket's own `BITBUCKET_*` variables), so each one must be forwarded
explicitly as in the quick start.

## Creating the comment token

Repository settings > Security > Access tokens > Create repository access
token. Scopes: **Pull requests: Read and Write**. Store it as the secured
repository variable `UPWIND_COMMENT_TOKEN`. Without it the scan still runs
and reports to the Console; only the PR comment is skipped.

The token is also used to show a human-readable "initiated by" name in the
Console (the PR author); without it, scans are attributed to the pipeline
triggerer's UUID.

## Blocking merges

The pipe fails (nonzero exit) when `UPWIND_BLOCK_ON` matches the scan
recommendation or when `UPWIND_ENFORCE_BLOCK_POLICY=true` and your Upwind
organization's PR-block policy is violated. The red build shows on the PR;
workspaces on Bitbucket Premium can make it binding with a merge check that
requires passing builds. The report comment is still posted before the pipe
exits.

## Troubleshooting

- **"Info: UPWIND_COMMENT_TOKEN not set"** - the comment is opt-in; create
  the token above.
- **"Info: not a pull-request pipeline"** - comments only post on
  `pull-requests:` pipelines; branch pipelines scan and report to the
  Console only (and establish the baseline for "introduced vs" diffs).
- **"Warning: failed to post/update Upwind PR comment"** - the token is
  invalid, expired, or missing the `pullrequest:write` scope. The build
  result is unaffected.
- **Scan shows "Reported via API" in the Console** - the `shiftleft` binary
  predates `--source=BITBUCKET`; it will appear once your channel picks up
  the release that includes it.
- **`invalid value "BITBUCKET"` from the CLI** - same cause as above; set
  `UPWIND_AGENT_CHANNEL` to a release that includes Bitbucket support.
- **`docker: command not found` / cannot connect to docker daemon** - the
  step running the pipe must declare `services: [docker]`.

## Repository layout

- `pipe/pipe.sh` - the pipe entrypoint (scan + comment orchestration)
- `Dockerfile` - the pipe image, published to
  `ghcr.io/upwindsecurity/code-image-scan-bitbucket` by the repo's
  `bitbucket-release.yml` workflow on every `bitbucket-vX.Y.Z` tag (docker
  tags: exact version, floating major, `latest`; the pipe versions
  independently of the GitHub action's `vX.Y.Z` tags)
- `scripts/upwind_bb_comment.sh` - the PR comment script, baked into the
  image
- `tests/run_tests.sh`, `tests/run_pipe_tests.sh` - offline test suites
  (dry-run + stub API server)
