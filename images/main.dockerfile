FROM ghcr.io/thin-edge/tedge-demo-main-systemd

# Copy both ca and client
COPY dist/tedge-pki-smallstep-*.deb /tmp/
RUN apt-get update && apt-get install -y /tmp/*.deb
