# Upwind Image Scan

Scan container images for vulnerabilities, secrets, and malware with
[Upwind](https://www.upwind.io) directly from your Azure Pipelines build.

- Scans the image you just built and reports the results to your Upwind
  organization, where they appear in the Upwind Console.
- On pull requests, posts an **Upwind Image Scan Report** comment thread with
  introduced, resolved, and existing CVEs plus a per-PR scan history, and
  updates the same thread on every push.
- Fails the build on the scan recommendation or on your organization's Upwind
  PR-block policy, so a Build Validation branch policy can block the merge.

## Quick start

1. Install this extension in your Azure DevOps organization (Project
   Collection Administrator, once per organization).
2. Add your Upwind sensor credentials as secret pipeline variables
   `UPWIND_CLIENT_ID` and `UPWIND_CLIENT_SECRET`.
3. Add the task after the image is built:

```yaml
steps:
  - script: docker build -t myapp:$(Build.SourceVersion) .
    displayName: Build image
  - task: UpwindImageScan@1
    inputs:
      dockerImage: myapp:$(Build.SourceVersion)
      upwindClientId: $(UPWIND_CLIENT_ID)
      upwindClientSecret: $(UPWIND_CLIENT_SECRET)
      dockerPull: false
      postComment: true
```

To post the pull request comment, grant the project build service identity
**Contribute to pull requests** on the repository once (Project settings >
Repositories > Security). Accounts with data residency in the EU, ME, or AP
region set `upwindUri` to `eu.upwind.io`, `me.upwind.io`, or `ap.upwind.io`.

## Requirements

- An agent with `bash`, `curl`, `jq`, and `docker` (Microsoft-hosted Ubuntu
  images include all four), agent version 3.232.0 or later.
- An Upwind account with sensor credentials.

## Support

Contact [support@upwind.io](mailto:support@upwind.io).
