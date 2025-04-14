# Upwind Security ShiftLeft Create Image Scan Event Action

## Overview

The Upwind Security ShiftLeft ShiftLeft Scan Event Publish Event Action enables seamless integration of Docker image vulnerability scanning into your CI/CD workflows. This action notifies the Upwind Console of a built image, before scanning for vulnerabilities.

## Prerequisites
- Currently supported architectures: `linux/amd64`.
-	Docker Environment: Ensure that the GitHub runner has access to Docker to build and manage images.
-	Upwind Credentials: Obtain your Upwind Client ID and Client Secret for authentication.

## Inputs

Define the following inputs in your workflow to configure the ShiftLeft actions:

-	`upwind_client_id` (required): Your Upwind Client ID.
-	`upwind_client_secret` (required): Your Upwind Client Secret.
- `docker_image` (required): The Docker image to scan, which should reside on the same runner.
-	`docker_user` (optional): Username for authenticating to the Docker registry.
-	`docker_password` (optional): Password for authenticating to the Docker registry.
-	`pull_image` (optional): Boolean flag to determine if the image should be pulled. Set to false if the image is available locally. Default is true.
- `oci_client` (optional): Which client should be used to pull the image. The default `docker` will use the docker daemon. Other options include `podman` and `skopeo`. Note that the binary must be installed and available on the path.
- `output_json` (optional): path to output JSON results to
- `commit_sha` (optional): SHA to be associated with the build. By default this uses the $GITHUB_SHA environmental variable
- `additional_registries` (optional): Comma-separated list of additional registries to associate with the scanned image, passed as a string (String input)

## Usage

To integrate the ShiftLeft scanning action into your GitHub workflow, include the following step:

```
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

Ensure that sensitive information, such as `upwind_client_id`, `upwind_client_secret`, and `docker_password`, are stored securely using GitHub Secrets.

## Versioning
It is recommended that you track the `main` branch rather than a specified tag. This will ensure that you always have the most up to date version of the action.

## Example Workflow

Below is a sample GitHub Actions workflow that builds a Docker image and scans it using the Upwind Security ShiftLeft image scanner:

```
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
        uses: actions/checkout@v2

      - name: Set Up Docker Buildx
        uses: docker/setup-buildx-action@v1

      - name: Build Docker Image
        run: |
          docker build . -t your-docker-image:tag

      - name: Upwind Security ShiftLeft Scan
        uses: upwindsecurity/shiftleft-create-image-scan-event-action@main
        with:
          upwind_client_id: ${{ secrets.UPWIND_CLIENT_ID }}
          upwind_client_secret: ${{ secrets.UPWIND_CLIENT_SECRET }}
          docker_image: 'your-docker-image:${GITHUB_SHA}'
          pull_image: false
      - name: Upwind Security ShiftLeft Image Publish
        uses: upwindsecurity/shiftleft-create-image-publish-event-action@main
        with:
          upwind_client_id: ${{ secrets.UPWIND_CLIENT_ID }}
          upwind_client_secret: ${{ secrets.UPWIND_CLIENT_SECRET }}
          docker_image: 'your-docker-image:your-specified-version'
```

This workflow triggers on pushes to the main branch, builds the Docker image, and then scans it for vulnerabilities using the CloudScanner action. The image does not need to be pulled because it is available locally via the Docker daemon. The

## Troubleshooting
-	Authentication Issues: Verify that your Upwind credentials are correct and have the necessary permissions.
-	Docker Access: Ensure that the GitHub runner has the required permissions to access Docker.

