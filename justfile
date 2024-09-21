set dotenv-load

package_dir := "dist"

# Build packages
build:
    mkdir -p dist
    nfpm package --config src/client/nfpm.yaml -p apk -t "{{package_dir}}/"
    nfpm package --config src/client/nfpm.yaml -p rpm -t "{{package_dir}}/"
    nfpm package --config src/client/nfpm.yaml -p deb -t "{{package_dir}}/"

    nfpm package --config src/server/nfpm.yaml -p apk -t "{{package_dir}}/"
    nfpm package --config src/server/nfpm.yaml -p rpm -t "{{package_dir}}/"
    nfpm package --config src/server/nfpm.yaml -p deb -t "{{package_dir}}/"

publish-smallstep-packages *ARGS="":
    ./ci/publish-smallstep-packages.sh "{{package_dir}}" {{ARGS}}

# Publish packages
publish *ARGS="":
    ./ci/publish.sh --path "{{package_dir}}" {{ARGS}}

# Start test
test *ARGS: build
    #!/usr/bin/env bash
    docker compose -f docker-compose.yaml up --build {{ARGS}} -d
    # docker compose exec tedge bash
    docker compose exec tedge step-ca-init.sh
    ENROL_COMMAND=$(docker compose exec tedge step-ca-admin.sh token child01)

    docker compose exec child01 bash -c "$ENROL_COMMAND"
