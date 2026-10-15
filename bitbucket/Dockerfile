# Upwind image scan pipe for Bitbucket Pipelines.
# The docker CLI talks to the step's shared docker daemon (the customer step
# declares `services: [docker]`); the shiftleft binary itself is downloaded
# at runtime from Upwind's release bucket so scan logic stays current.
FROM docker:27-cli

RUN apk add --no-cache bash curl jq ca-certificates

COPY pipe/pipe.sh /usr/local/bin/pipe.sh
COPY scripts/upwind_bb_comment.sh /usr/local/bin/upwind_bb_comment.sh
RUN chmod +x /usr/local/bin/pipe.sh /usr/local/bin/upwind_bb_comment.sh

ENTRYPOINT ["/usr/local/bin/pipe.sh"]
