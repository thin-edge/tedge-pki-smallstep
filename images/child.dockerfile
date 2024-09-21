FROM ghcr.io/thin-edge/tedge-demo-main-systemd

COPY dist/tedge-pki-smallstep-client*.deb /tmp/
RUN apt-get update && apt-get install -y /tmp/*.deb
