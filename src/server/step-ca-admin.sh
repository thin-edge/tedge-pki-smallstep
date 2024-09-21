#!/bin/sh
set -e

export STEPPATH="${STEPPATH:-/etc/step-ca}"
PROVISION_PASSWORD_FILE="$STEPPATH/secrets/provisioner-password"

ACTION="$1"
shift

case "$ACTION" in
    token)
        CN="$1"
        TOKEN=$(step ca token "$CN" --provisioner-password-file="$PROVISION_PASSWORD_FILE")
        FINGERPRINT=$(step ca root | step certificate fingerprint)

        cat <<EOT
Enroll a child device using the following command:

    $0 enrol "$CN" "https://$(hostname):8443" "$TOKEN" "$FINGERPRINT"

EOT
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
    
    enrol|enroll)
        CN="$1"
        PKI_URL="$2"
        TOKEN="$3"
        FINGERPRINT="$4"

        echo "Installing PKI root certificate"
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

        if tedge mqtt pub 'test-tls-client' 'test'; then
            echo "MQTT Broker (TLS):             PASS" >&2
        else
            echo "MQTT Broker (TLS):             FAIL" >&2
            exit 2
        fi

        # Enable services
        if command -V systemctl >/dev/null 2>&1; then
            echo "Starting/enabling tedge-agent"
            systemctl enable tedge-agent

            if [ -d /run/systemd ]; then
                systemctl restart tedge-agent
            fi
        fi
        ;;
    *)
        echo "Unknown command: $ACTION" >&2
        exit 1
        ;;
esac
