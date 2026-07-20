# Upwind Security ShiftLeft Create Image Scan Event Action

## Overview

The Upwind Security ShiftLeft Create Image Scan Event Action enables seamless integration of Docker image vulnerability scanning into your CI/CD workflows. This action notifies the Upwind Console of a built image, scans it for vulnerabilities, and can optionally block the workflow or post the results back to a pull request.

Under the hood it downloads the `shiftleft` binary from the Upwind release bucket (authenticating with your Upwind credentials) and runs its `image` subcommand against the supplied Docker image.

## Prerequisites
- Supported runner architectures: `linux/amd64` and `linux/arm64`.
- OCI client: Ensure the GitHub runner has access to an OCI client (`docker`, `podman`, or `skopeo`) to pull and inspect images. The selected client must be installed and available on the `PATH`.
- Upwind Credentials: Obtain your Upwind Client ID and Client Secret for authentication.

## Inputs

Define the following inputs in your workflow to configure the action:

| Input                                  | Required | Default         | Description                                                                                                                         |
|----------------------------------------|----------|-----------------|-------------------------------------------------------------------------------------------------------------------------------------|
| `upwind_client_id`                     | Yes      | –               | Your Upwind Client ID.                                                                                                              |
| `upwind_client_secret`                 | Yes      | –               | Your Upwind Client Secret.                                                                                                          |
| `docker_image`                         | Yes      | –               | The already-built Docker image to scan, residing on the same runner or with the full name of the registry                           |
| `docker_user`                          | No       | –               | Username for authenticating to the Docker registry.                                                                                 |
| `docker_password`                      | No       | –               | Password for authenticating to the Docker registry.                                                                                 |
| `pull_image`                           | No       | `true`          | Whether to pull the image. Set to `false` if the image is already available locally.                                                |
| `oci_client`                           | No       | `docker`        | Client used to pull the image. One of `docker`, `podman`, or `skopeo`. The binary must be installed and on the `PATH`.              |
| `additional_registries`                | No       | –               | Comma-separated list of additional registries to associate with the scanned image.                                                  |
| `output_json`                          | No       | `output.json`   | File location to write the JSON scan results to.                                                                                    |
| `commit_sha`                           | No       | `${GITHUB_SHA}` | SHA to associate with the build. Defaults to the `GITHUB_SHA` environment variable.                                                 |
| `upwind_uri`                           | No       | `upwind.io`     | Public Upwind URI domain name.                                                                                                      |
| `use_sudo`                             | No       | `true`          | Whether to invoke the scan with `sudo` so it can connect to the OCI client.                                                         |
| `perform_multiarchitecture_image_scan` | No       | `true`          | Whether to perform a multi-architecture image scan.                                                                                 |
| `block_on`                             | No       | –               | Block the workflow based on the Upwind scan recommendation. One of `do_not_deploy` or `deploy_with_caution`.                        |
| `add_comment`                          | No       | `false`         | Whether to post a summary comment to a pull request when the scan completes. Requires `github_token`, `pr_number`, and `repo_name`. |
| `github_token`                         | No       | –               | GitHub token used to authenticate when posting the PR comment. Required when `add_comment` is `true`.                               |
| `pr_number`                            | No       | –               | Pull request number to comment on. Required when `add_comment` is `true`.                                                           |
| `repo_name`                            | No       | –               | The GitHub repository in `owner/repo` format. Required when `add_comment` is `true`.                                                |
| `main_branch`                          | No       | –               | Base/target branch to diff against (typically `github.event.pull_request.base.ref`). When set, introduced/resolved CVEs are computed against the latest scanned image of this branch instead of the previous scan. Requires that branch to have been scanned. |
| `pr_id`                                | No       | –               | Pull request identifier to associate with the scan.                                                                                 |
| `pr_link`                              | No       | –               | Pull request URL to associate with the scan.                                                                                        |
| `result_wait_seconds`                  | No       | `300`           | Seconds the CLI waits for scan results before giving up (results not ready ⇒ the PR comment is skipped).                            |

Sensitive values such as `upwind_client_id`, `upwind_client_secret`, and `docker_password` should be stored securely using GitHub Secrets.

## Usage

To integrate the ShiftLeft scanning action into your GitHub workflow, include the following step:

```yaml
- name: Upwind Security ShiftLeft Scanning
  uses: upwindsecurity/shiftleft-create-image-scan-event-action@main
  with:
    upwind_client_id: ${{ secrets.UPWIND_CLIENT_ID }}
    upwind_client_secret: ${{ secrets.UPWIND_CLIENT_SECRET }}
    docker_image: 'your-docker-image:tag'
    docker_user: ${{ secrets.DOCKER_USER }}
    docker_password: ${{ secrets.DOCKER_PASSWORD }}
    pull_image: false
```

### Commenting on a pull request

Set `add_comment: true` to have the action post a Markdown summary of the scan (image, per-architecture status, and introduced CVEs grouped by severity) as a comment on a pull request. When `add_comment` is enabled, `github_token`, `pr_number`, and `repo_name` are all required — the action validates this up front and fails if any are missing.

```yaml
- name: Upwind Security ShiftLeft Scanning
  uses: upwindsecurity/shiftleft-create-image-scan-event-action@main
  with:
    upwind_client_id: ${{ secrets.UPWIND_CLIENT_ID }}
    upwind_client_secret: ${{ secrets.UPWIND_CLIENT_SECRET }}
    docker_image: 'your-docker-image:tag'
    pull_image: false
    add_comment: true
    github_token: ${{ secrets.GITHUB_TOKEN }}
    pr_number: ${{ github.event.pull_request.number }}
    repo_name: ${{ github.repository }}
```

The job needs `pull-requests: write` permission for the token to post the comment.

### Diffing against the base branch

By default the comment compares the scan against the image's previous scan. Set `main_branch` to the pull request's base branch to instead compute introduced/resolved CVEs relative to the latest scanned image of that branch. Pass `pr_id` and `pr_link` to associate the scan with the originating pull request. These values are typically sourced from the `github.event.pull_request.*` context:

```yaml
- name: Upwind Security ShiftLeft Scanning
  uses: upwindsecurity/shiftleft-create-image-scan-event-action@main
  with:
    upwind_client_id: ${{ secrets.UPWIND_CLIENT_ID }}
    upwind_client_secret: ${{ secrets.UPWIND_CLIENT_SECRET }}
    docker_image: 'your-docker-image:tag'
    pull_image: false
    add_comment: true
    github_token: ${{ secrets.GITHUB_TOKEN }}
    pr_number: ${{ github.event.pull_request.number }}
    repo_name: ${{ github.repository }}
    main_branch: ${{ github.event.pull_request.base.ref }}
    pr_id: ${{ github.event.pull_request.number }}
    pr_link: ${{ github.event.pull_request.html_url }}
```

The base branch must already have been scanned for the diff to be meaningful; otherwise all CVEs will appear as newly introduced.

## Versioning
It is recommended that you track the `main` branch rather than a specified tag. This will ensure that you always have the most up to date version of the action.

## Example Workflow

Below is a sample GitHub Actions workflow that builds a Docker image and scans it using the Upwind Security ShiftLeft image scanner:

```yaml
name: Docker Image Build and Scan

on:
  push:
    branches:
      - main

jobs:
  build-and-scan:
    runs-on: ubuntu-latest

    steps:
      - name: Checkout Code
        uses: actions/checkout@v6

      - name: Set Up Docker Buildx
        uses: docker/setup-buildx-action@v1

      - name: Build Docker Image
        run: |
          docker build . -t your-docker-image:${GITHUB_SHA}

      - name: Upwind Security ShiftLeft Scan
        uses: upwindsecurity/shiftleft-create-image-scan-event-action@main
        with:
          upwind_client_id: ${{ secrets.UPWIND_CLIENT_ID }}
          upwind_client_secret: ${{ secrets.UPWIND_CLIENT_SECRET }}
          docker_image: 'your-docker-image:${GITHUB_SHA}'
          pull_image: false
```

This workflow triggers on pushes to the `main` branch, builds the Docker image, and then scans it for vulnerabilities. The image does not need to be pulled because it is available locally via the Docker daemon.

## Troubleshooting
- Authentication Issues: Verify that your Upwind credentials are correct and have the necessary permissions.
- OCI Client Access: Ensure that the GitHub runner has the required permissions to access the selected OCI client (`docker`, `podman`, or `skopeo`). If the scan cannot reach the client, confirm whether `use_sudo` should be enabled for your runner.
- PR Comment Failures: When using `add_comment: true`, ensure `github_token`, `pr_number`, and `repo_name` are all provided and that the token has `pull-requests: write` permission.
