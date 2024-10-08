#!/bin/sh
set -e

command_usage() {
    cat <<EOT
thin-edge.io step-ca administration tasks to enroll and verify devices
using certificates to enable secure communication using mtls

USAGE

    $0 <SUBCOMMANDS>

Note: Use --help or -h to view the help for each subcommand, for example

    $0 token --help

    or

    $0 enroll --help

SUBCOMMANDS

    token           Generate a one-time token to enroll a child device. This should be run on the main device
    enroll          Enroll a child device using the one-time token generated via the 'token' command.
                    This should be run on the child device
    verify          Verify thin-edge.io services with mTLS

EXAMPLES
    $0 token child01        
    # On main device, generate a token for 'child01', then copy/paste the command and execute on the child device
EOT
}

ACTION=

# Enable help and debugging early on without doing formal argument parsing
for arg in "$@"; do
    case "$arg" in
        --debug)
            DEBUG=1;
            ;;
        --help|-h)
            command_usage
            exit 0
            ;;
        --*|-*)
            # ignore
            ;;
        *)
            ACTION="$arg"
            shift
            # stop parsing as sub commands should handle their own help
            break
            ;;
    esac
done
if [ "${DEBUG:-0}" = 1 ]; then
    set -x
fi

export STEPPATH="${STEPPATH:-/etc/step-ca}"
PROVISION_PASSWORD_FILE=${PROVISION_PASSWORD_FILE:-"$STEPPATH/secrets/provisioner-password"}

# Allow downloading the root ca from an untrusted root ca. Only turn on this if you are 100%
# sure you can trust it (e.g. you are running in a controlled network)
ALLOW_UNTRUSTED_ROOT_CA=${ALLOW_UNTRUSTED_ROOT_CA:-0}

# Maximum time before giving up in the curl connection tests (in seconds)
CONNECTION_TEST_TIMEOUT=${CONNECTION_TEST_TIMEOUT:-15}

# ACTION="$1"
# shift

convert_to_local_domain() {
    url="$1"
    case "$url" in
        http://*:*|https://*:*)
            url=$(echo "$url" | sed 's/:\([0-9]*\)$/.local:\1/')
            ;;
        *)
            url="${url}.local"
            ;;
    esac
    echo "$url"
}

fetch_untrusted_root() {
    output_file="$1"
    shift

    for url in "$@"; do
        if curl -k -s "$url/roots.pem" > "$output_file"; then
            return 0
        fi
    done

    echo "Failed to download root ca from PKI server" >&2
    return 1
}

verify_pki_url() {
    fingerprint="$1"
    shift

    for url in "$@"; do
        if ! step ca root --ca-url "$url" --fingerprint "$fingerprint" >/dev/null 2>&1; then
            echo "Failed to reach PKI using 'step ca root'. url=$url" >&2
            continue
        fi
        if ! curl -k -s "$url" >/dev/null 2>&1; then
            echo "Failed to reach PKI using curl. url=$url" >&2
            continue
        fi
        echo "Successfully reached PKI. url=$url" >&2
        echo "$url"
        return 0
    done

    echo "Failed resolve PKI url" >&2
    return 1
}

check_services_using_tls() {
    echo
    echo "Checking service status (with mTLS)" >&2
    echo

    OK_COUNT=0
    if timeout 5 tedge mqtt pub "tls-client-test" "test" >/dev/null 2>&1; then
        echo "    MQTT Broker:          PASS" >&2
        OK_COUNT=$((OK_COUNT + 1))
    else
        echo "    MQTT Broker:          FAIL" >&2
    fi

    if curl -s -4 --max-time "$CONNECTION_TEST_TIMEOUT" "https://$(tedge config get http.client.host):$(tedge config get http.client.port)/" --capath "$(tedge config get http.ca_path)" --key "$(tedge config get http.client.auth.key_file)" --cert "$(tedge config get http.client.auth.cert_file)"; then
        echo "    FileTransferService:  PASS" >&2
        OK_COUNT=$((OK_COUNT + 1))
    else
        echo "    FileTransferService:  FAIL" >&2
    fi

    # TODO: Check if the mapper is connected or not
    if curl -s -4 --max-time "$CONNECTION_TEST_TIMEOUT" "https://$(tedge config get c8y.proxy.client.host):$(tedge config get c8y.proxy.client.port)/c8y/tenant/currentTenant" --capath "$(tedge config get c8y.proxy.ca_path)" --key "$(tedge config get c8y.proxy.key_path)" --cert "$(tedge config get c8y.proxy.cert_path)" >/dev/null 2>&1; then
        echo "    Cumulocity IoT Proxy: PASS" >&2
        OK_COUNT=$((OK_COUNT + 1))
    else
        echo "    Cumulocity IoT Proxy: FAIL" >&2
    fi

    printf "\nSummary\n\n" >&2

    if [ "$OK_COUNT" -ge 2 ]; then
        printf '    OK - %s of 3 services are working\n\n' "$OK_COUNT" >&2
        return 0
    else
        printf '    FAIL - Only %s of 3 services are working\n\n' "$OK_COUNT" >&2
        return 1
    fi
}

case "$ACTION" in
    token)
        CN=${CN:-}
        HOST_NAME=${HOST_NAME:-}

        command_token_usage() {
            cat <<EOT
Generate an enrollment command for a given child device name (which is used as the Common Name).
A one-liner will be returned which can be used to enroll a child device which is running the
tedge-agent service.

USAGE

    $0 token <COMMON_NAME> [--host alternative-name]

POSITIONAL ARGUMENTS
    COMMON_NAME                     Common name of the child device

FLAGS
    --host <STRING>          Explicit public name which the device is reachable for other devices.
                             For example, if you are using Azure then this might be the public IP address of the main device
    --debug                  Enable debugging
    --help, -h               Show this help

EXAMPLES

    $0 token mychild01
    # Create an enrollment command (including a one-time token)

    $0 token mychild01 --host some.public.name
    # Create an enrollment command (including a one-time token) but using an explicit public address
EOT
        }

        while [ $# -gt 0 ]; do
            case "$1" in
                --host)
                    HOST_NAME="$2"
                    shift
                    ;;
                --help|-h)
                    command_token_usage
                    exit 0
                    ;;
                --debug)
                    # ignore as it is already handled at the top of the script
                    ;;
                --*|-*)
                    echo "Unknown flag: $1" >&2
                    command_token_usage
                    exit 1
                    ;;
                *)
                    CN="$1"
                    ;;
            esac
            shift
        done

        if [ -z "$HOST_NAME" ]; then
            if command -V hostname >/dev/null 2>&1; then
                HOST_NAME="$(hostname)"
            elif [ -n "$HOST" ]; then
                HOST_NAME="$HOST"
            fi
        fi

        TOKEN=$(step ca token "$CN" --provisioner-password-file="$PROVISION_PASSWORD_FILE")
        FINGERPRINT=$(step ca root | step certificate fingerprint)

        ENROLL_COMMAND="$0 enroll '$CN' --ca-url https://${HOST_NAME}:8443 --fingerprint $FINGERPRINT --token $TOKEN"

        if [ -t 1 ]; then
            cat <<EOT >&2

Enroll a child device using the following command (using a one-time token):

    $ENROLL_COMMAND

EOT
        else
            # Only print out the one-liner
            echo "$ENROLL_COMMAND"
        fi
        ;;

    renew)
        #
        # Force renewing of the tedge-agent certificate
        #
        if [ $# -ge 2 ]; then
            CERT_LOCATION="$1"
            KEY_LOCATION="$2"
        else
            CERT_LOCATION="$(tedge config get device.cert_path)"
            KEY_LOCATION="$(tedge config get device.key_path)"
        fi

        # TODO: Should the certs be renewed atomically to avoid corruption?
        /usr/bin/step ca renew --force "${CERT_LOCATION}" "${KEY_LOCATION}"

        # Set the permissions
        chown tedge:tedge "${CERT_LOCATION}"
        chmod 644 "${CERT_LOCATION}"
        chown tedge:tedge "${KEY_LOCATION}"
        chmod 600 "${KEY_LOCATION}"

        if command -V systemctl >/dev/null 2>&1; then
            if systemctl --quiet is-active tedge-agent.service; then
                systemctl try-reload-or-restart tedge-agent
            fi
        fi
        ;;

    verify)
        if ! check_services_using_tls; then
            exit 2
        fi
        ;;

    enrol|enroll)
        CN=${CN:-}
        PKI_URL=${PKI_URL:-"https://tedge:8443"}
        CA_ROOT=${CA_ROOT:-"$STEPPATH/certs/root_ca.crt"}
        TOKEN=${TOKEN:-}
        FINGERPRINT=${FINGERPRINT:-}
        TARGET="${TARGET:-}"
        TOPIC_ID="${TOPIC_ID:-}"

        command_enroll_usage() {
            cat <<EOT
Enroll a child device using the given PKI to generate the TLS certificates for secure communication.

Tip: On the main device, run '$0 token <COMMON_NAME>' to generate a one-liner command that you can
run on the child device to create the child device certificates.

USAGE

    $0 enroll <COMMON_NAME> --ca-url <STEP_CA_URL> --fingerprint "CA_FINGERPRINT" --token "<ENROLLMENT_TOKEN>"

POSITIONAL ARGUMENTS
    COMMON_NAME                     Common name of the child device

FLAGS
    --ca-url <STEP_CA_URL>                step-ca server endpoint
    --fingerprint <FINGERPRINT>           Fingerprint of the root CA from the step-ca server
    --token <TOKEN>                       One time token used to authenticate against the server. The token is
                                          only valid for a given common name (set when creating the token)
    --root <path>                         Path to the root certificate
    --provisioner-password-file <path>    Provisioner password file to use for authentication instead of a token
    --allow-insecure-root                Allow downloading from a potentially untrusted root ca. ENV ALLOW_UNTRUSTED_ROOT_CA=1
    --main-device <DNS|IP_ADDR>           DNS entry or IP address of the main device in case if it differs from
                                          the ca-url, otherwise the main-device value will be derived from the ca-url
    --topic-id <TOPIC_ID>                 4 part MQTT Topic ID used to address the default, e.g. device/child01//.
                                          Defaults to "device/<COMMON_NAME>//"
    --debug                               Enable debugging
    --help, -h                            Show this help

EXAMPLES

    $0 enroll mychild01 --ca-url https://tedge:8443 --fingerprint abcdef --token "asfdasdfasdfasdfasdf"
    # Enroll a device called mychild01

    $0 enroll mychild01 --ca-url https://tedge:8443 --fingerprint abcdef --token "asfdasdfasdfasdfasdf" --main-device other-address
    # Enroll a device called mychild01 but use another alias for the device

    $0 enroll mychild01 --ca-url https://tedge:8443 --fingerprint abcdef
    # Enrol a device and prompt for the provisioner password

    $0 enroll mychild01 --ca-url https://tedge:8443 --root root_ca.pem
    # Enrol a device and prompt for the provisioner password and use a root ca instead of the fingerprint

    $0 enroll mychild01 --ca-url https://tedge:8443 --root root_ca.pem --provisioner-password-file /run/password
    # Enrol a device using the provisioner password

    $0 enroll mychild01 --ca-url https://tedge:8443 --allow-insecure-root
    # Enrol a device and allow downloading the root certs from a potentiall untrusted root ca (not recommended in most scenarios)
EOT
        }

        while [ $# -gt 0 ]; do
            case "$1" in
                --main-device)
                    TARGET="$2"
                    shift
                    ;;
                --ca-url)
                    PKI_URL="$2"
                    shift
                    ;;
                --root)
                    CA_ROOT="$2"
                    shift
                    ;;
                --provisioner-password-file)
                    PROVISION_PASSWORD_FILE="$2"
                    shift
                    ;;
                --token)
                    TOKEN="$2"
                    shift
                    ;;
                --fingerprint)
                    FINGERPRINT="$2"
                    shift
                    ;;
                --allow-insecure-root)
                    ALLOW_UNTRUSTED_ROOT_CA=1
                    ;;
                --topic-id)
                    TOPIC_ID="$2"
                    shift
                    ;;
                --debug)
                    # ignore as it is already handled at the top of the script
                    ;;
                --help|-h)
                    command_enroll_usage
                    exit 0
                    ;;
                --*|-*)
                    echo "Unknown flag: $1" >&2
                    command_enroll_usage
                    exit 1
                    ;;
                *)
                    # Positional argument
                    CN="$1"
                    ;;
            esac
            shift
        done

        if [ -z "$CN" ]; then
            echo "Using hostname as the certificate Common Name" >&2
            CN=$(hostname)
        fi

        # Check if the url is resolvable, and if not, fallback to the .local address
        # Check with both step and curl as curl can have slightly different results
        # Note: curl insecure mode is only used to check if the address is reachable nothing more!
        if [ -z "$FINGERPRINT" ]; then
            if [ ! -f "$CA_ROOT" ]; then
                if [ "$ALLOW_UNTRUSTED_ROOT_CA" = 1 ]; then
                    echo "WARNING!!! Fetching root certificate from untrusted url" >&2
                    CA_ROOT=root.pem
                    fetch_untrusted_root "$CA_ROOT" "$PKI_URL" "$(convert_to_local_domain "$PKI_URL")"
                fi
            fi
            # Use a given CA root file to lookup the fingerprint, the presence of the root certificate establishes trust with the server
            FINGERPRINT=$(step certificate fingerprint "$CA_ROOT")
        fi

        # Try multiple urls to find the one that is reachable from the client (e.g. given url then try the .local url)
        RESOLVED_PKI_URL=$(verify_pki_url "$FINGERPRINT" "$PKI_URL" "$(convert_to_local_domain "$PKI_URL")" ||:)
        if [ -z "$RESOLVED_PKI_URL" ]; then
            echo "Resolving host failed. Could not resolve PKI server: $PKI_URL" >&2
            exit 1
        fi
        PKI_URL="$RESOLVED_PKI_URL"

        if [ -z "$FINGERPRINT" ]; then
            echo "step-ca root certificate fingerprint was not provided or the was an error retrieving it from the step-ca server" >&2
            exit 1
        fi

        step ca bootstrap --force --ca-url "$PKI_URL" --fingerprint "$FINGERPRINT" --install

        # Note: Only use the device.key_path and cert_path for storage of a common place for mtls cert and key
        tedge config set device.key_path /etc/tedge/device-certs/tedge-agent.key
        tedge config set device.cert_path /etc/tedge/device-certs/tedge-agent.crt

        echo "Requesting child certificate" >&2
        # Note: requesting a certificate requires either --token or --root flags!
        if [ -n "$TOKEN" ]; then
            step ca certificate --force --kty=RSA --ca-url "$PKI_URL" --token "$TOKEN" "$CN" "$(tedge config get device.cert_path)" "$(tedge config get device.key_path)"
        elif [ -f "$PROVISION_PASSWORD_FILE" ]; then
            step ca certificate --force --kty=RSA --ca-url "$PKI_URL" --root "$CA_ROOT" --provisioner-password-file "$PROVISION_PASSWORD_FILE" "$CN" "$(tedge config get device.cert_path)" "$(tedge config get device.key_path)"
        else
            # User will be prompted for the provisioner password
            step ca certificate --force --kty=RSA --ca-url "$PKI_URL" --root "$CA_ROOT" "$CN" "$(tedge config get device.cert_path)" "$(tedge config get device.key_path)"
        fi

        # Set permissions (before moving them)
        chown tedge:tedge "$(tedge config get device.cert_path)"
        chmod 644 "$(tedge config get device.cert_path)"
        chown tedge:tedge "$(tedge config get device.key_path)"
        chmod 600 "$(tedge config get device.key_path)"

        if [ -z "$TARGET" ]; then
            TARGET=$(echo "$PKI_URL" | sed 's|.*://||g' | sed 's/:.*//g')
        fi

        if [ -z "$TOPIC_ID" ]; then
            TOPIC_ID="device/$CN//"
        fi

        echo "Configuring tedge-agent as a child device connecting to $TOPIC_ID" >&2
        tedge config set mqtt.device_topic_id "$TOPIC_ID"

        # thin-edge.io File Transfer Service
        tedge config set http.client.host "$TARGET"
        tedge config set http.client.port 8000
        tedge config set http.ca_path "/etc/ssl/certs"
        tedge config set http.client.auth.key_file "$(tedge config get device.key_path)"
        tedge config set http.client.auth.cert_file "$(tedge config get device.cert_path)"

        # thin-edge.io mqtt client settings
        tedge config set mqtt.client.host "$TARGET"
        tedge config set mqtt.client.port 8883
        tedge config set mqtt.client.auth.ca_dir "/etc/ssl/certs"
        tedge config set mqtt.client.auth.cert_file "$(tedge config get device.cert_path)"
        tedge config set mqtt.client.auth.key_file "$(tedge config get device.key_path)"

        # thin-edge.io c8y proxy client settings
        tedge config set c8y.proxy.client.host "$TARGET"
        tedge config set c8y.proxy.client.port 8001
        tedge config set c8y.proxy.ca_path "/etc/ssl/certs"
        tedge config set c8y.proxy.cert_path "$(tedge config get device.cert_path)"
        tedge config set c8y.proxy.key_path "$(tedge config get device.key_path)"

        check_services_using_tls

        # Enable services
        if command -V systemctl >/dev/null 2>&1; then
            echo "Starting/enabling tedge-agent" >&2
            systemctl enable tedge-agent

            # Disable services that don't work on child devices
            systemctl disable tedge-mapper-collectd >/dev/null 2>&1 ||:
            systemctl disable collectd >/dev/null 2>&1 ||:

            if [ -d /run/systemd ]; then
                systemctl restart tedge-agent

                if systemctl is-enabled tedge-container-monitor.service >/dev/null 2>&1; then
                    systemctl restart tedge-container-monitor.service
                fi

                systemctl stop tedge-mapper-collectd >/dev/null 2>&1 ||:
                systemctl stop collectd >/dev/null 2>&1 ||:
            fi

            systemctl mask tedge-mapper-collectd >/dev/null 2>&1 ||:
            systemctl mask collectd >/dev/null 2>&1 ||:
        fi

        echo "The child device has been successfully enrolled" >&2
        ;;
    delete-ca)
        #
        # Delete all of the existing step-ca configuration and root certificate
        #
        echo "Deleting the existing step-ca configuration (this will invalidate all existing certificates!)" >&2
        rm -rf "$STEPPATH"
        rm -f \
            /usr/local/share/ca-certificates/root_ca.crt \
            /etc/ssl/certs/root_ca.pem

        if [ -d /run/systemd ]; then
            systemctl stop step-ca
        fi
        update-ca-certificates -f
        ;;

    restart_service)
        SERVICE_NAME="$1"
        CMD_TOPIC="$(tedge config get mqtt.topic_root)/$(tedge config get mqtt.device_topic_id)/cmd/restart_service/local-$(date +%s)"
        tedge mqtt pub -r -q 1 \
            "$CMD_TOPIC" \
            "{\"status\":\"init\",\"name\":\"$SERVICE_NAME\"}"
        
        # Wait for command to finish
        echo "Waiting for service to restart (TODO: wait and subscribe for updates)" >&2
        tedge mqtt pub -r -q 1 "$CMD_TOPIC" ""
        sleep 90

        echo "Clearing request" >&2
        tedge mqtt pub -r -q 1 "$CMD_TOPIC" ""
        ;;

    *)
        echo "Unknown command: $ACTION" >&2
        exit 1
        ;;
esac
