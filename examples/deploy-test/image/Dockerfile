# Test image for servers/deploy.sh: HEALTHY=no builds an image whose healthcheck always fails.
FROM busybox:1
ARG HEALTHY=yes
ARG VERSION=dev
RUN echo "$VERSION" > /version && if [ "$HEALTHY" = yes ]; then touch /healthy; fi
CMD ["sh", "-c", "trap 'exit 0' TERM; while :; do sleep 1; done"]
