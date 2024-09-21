#!/bin/sh
set -e

export STEPPATH="${STEPPATH:-/etc/step-ca}"
PROVISION_PASSWORD_FILE="$STEPPATH/secrets/provisioner-password"

ACTION="$1"
shift

check_services_using_tls() {
    echo
    echo "Checking service status (with mTLS)"
    echo

    OK_COUNT=0
    if timeout 5 tedge mqtt pub "tls-client-test" "test" >/dev/null 2>&1; then
        echo "    MQTT Broker:          PASS" >&2
        OK_COUNT=$((OK_COUNT + 1))
    else
        echo "    MQTT Broker:          FAIL" >&2
        exit 2
    fi

    if curl "https://$(tedge config get http.client.host):$(tedge config get http.client.port)/" --capath "$(tedge config get http.ca_path)" --key "$(tedge config get http.client.auth.key_file)" --cert "$(tedge config get http.client.auth.cert_file)"; then
        echo "    FileTransferService:  PASS" >&2
        OK_COUNT=$((OK_COUNT + 1))
    else
        echo "    FileTransferService:  FAIL" >&2
        exit 2
    fi

    # TODO: Check if the mapper is connected or not
    if curl "https://$(tedge config get c8y.proxy.client.host):$(tedge config get c8y.proxy.client.port)/c8y/tenant/currentTenant" --capth "$(tedge config get c8y.proxy.ca_path)" --key "$(tedge config get c8y.proxy.key_path)" --cert "$(tedge config get c8y.proxy.cert_path)" >/dev/null 2>&1; then
        echo "    Cumulocity IoT Proxy: PASS" >&2
        OK_COUNT=$((OK_COUNT + 1))
    else
        echo "    Cumulocity IoT Proxy: FAIL" >&2
    fi

    printf "\nSummary\n\n"

    if [ "$OK_COUNT" -ge 2 ]; then
        printf '    OK - %s of 3 services are working\n\n' "$OK_COUNT"
        return 0
    else
        printf '    FAIL - Only %s of 3 services are working\n\n' "$OK_COUNT"
        return 1
    fi
}

case "$ACTION" in
    token)
        CN="$1"
        TOKEN=$(step ca token "$CN" --provisioner-password-file="$PROVISION_PASSWORD_FILE")
        FINGERPRINT=$(step ca root | step certificate fingerprint)

        ENROLL_COMMAND="$0 enrol '$CN' https://$(hostname):8443 $TOKEN $FINGERPRINT"

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
        check_services_using_tls
        ;;
    
    enrol|enroll)
        CN="$1"
        PKI_URL="$2"
        TOKEN="$3"
        FINGERPRINT="$4"

        step ca bootstrap --ca-url "$PKI_URL" --fingerprint "$FINGERPRINT" --install

        # Note: Only use the device.key_path and cert_path for storage of a common place for mtls cert and key
        tedge config set device.key_path /etc/tedge/device-certs/tedge-agent.key
        tedge config set device.cert_path /etc/tedge/device-certs/tedge-agent.crt

        echo "Creating child certificate"
        step ca certificate --kty=RSA --ca-url "$PKI_URL" --token "$TOKEN" "$CN" "svc.crt" "svc.key"

        # Set permissions (before moving them)
        chown tedge:tedge svc.crt
        chmod 644 svc.crt
        chown tedge:tedge svc.key
        chmod 600 svc.key

        mv svc.crt "$(tedge config get device.cert_path)"
        mv svc.key "$(tedge config get device.key_path)"

        echo "Configuring tedge-agent as a child device"
        TARGET=$(echo "$PKI_URL" | sed 's|.*://||g' | sed 's/:.*//g')

        tedge config set mqtt.device_topic_id "device/$TARGET//"

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
            echo "Starting/enabling tedge-agent"
            systemctl enable tedge-agent

            if [ -d /run/systemd ]; then
                systemctl restart tedge-agent
            fi
        fi

        echo "The child device has been successfully enrolled"
        ;;
    *)
        echo "Unknown command: $ACTION" >&2
        exit 1
        ;;
esac
