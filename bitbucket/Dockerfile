# Upwind image scan pipe for Bitbucket Pipelines.
# Build with the REPO ROOT as context (docker build -f bitbucket/Dockerfile .):
# the scan-output guard is shared with the GitHub action from scripts/.
# The docker CLI talks to the step's shared docker daemon (the customer step
# declares `services: [docker]`); the shiftleft binary itself is downloaded
# at runtime from Upwind's release bucket so scan logic stays current.
FROM docker:27-cli

RUN apk add --no-cache bash curl jq ca-certificates

COPY bitbucket/pipe/pipe.sh /usr/local/bin/pipe.sh
COPY bitbucket/scripts/upwind_bb_comment.sh /usr/local/bin/upwind_bb_comment.sh
COPY scripts/check_scan_output.sh /usr/local/bin/check_scan_output.sh
RUN chmod +x /usr/local/bin/pipe.sh /usr/local/bin/upwind_bb_comment.sh /usr/local/bin/check_scan_output.sh

ENTRYPOINT ["/usr/local/bin/pipe.sh"]
