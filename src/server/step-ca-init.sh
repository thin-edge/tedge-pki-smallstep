#!/bin/sh
set -e

usage() {
    cat << EOT
Initialize the step-ca PKI service by creating the root, intermedate certificates
and configuring the provisioner to accept certificate issuing and signing.

USAGE

  $0 [--host <name>] [--domain-suffix <domain>] [--debug] [--help]

FLAGS
  --host <TARGET>               Target host which the device is reachable from child devices.
                                Defaults to the hostname.
  --domain-suffix <SUFFIX>      Domain suffix to add to the given target host. E.g. 'local' to use
                                the local mdns address of the host.
  --debug                       Enable debugging
  --help, -h                    Show this help

EXAMPLES
  $0
  # Initialize and start the step-ca PKI service

  $0 --host maindevice
  # Initialize step-ca and configure thin-edge.io services to use the
  target hostname 'maindevice' to reach the main device

  $0 --domain-suffix local
  # Initialize step-ca and configure thin-edge.io services to the device's
  hostname with the '.local' domain suffix
EOT
}

export STEPPATH="${STEPPATH:-/etc/step-ca}"

DOMAIN_SUFFIX="${DOMAIN_SUFFIX:-}"
TARGET_HOST="${TARGET_HOST:-}"
DEBUG="${DEBUG:-0}"

while [ $# -gt 0 ]; do
    case "$1" in
        --domain-suffix)
            DOMAIN_SUFFIX="$2"
            shift
            ;;
        --host)
            TARGET_HOST="$2"
            shift
            ;;
        --debug)
            DEBUG=1
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        --*|-*)
            echo "Unknown flag: %s" >&2
            exit 1
            ;;
    esac
    shift
done

if [ "${DEBUG:-}" = 1 ]; then
    set -x
fi

# Set the target hostname to be used by thin-edge.io services
if [ -z "$TARGET_HOST" ]; then
    echo "Setting thin-edge.io host target from hostname" >&2
    TARGET_HOST="$(hostname)"
fi
if [ -n "$DOMAIN_SUFFIX" ]; then
    # Only add the domain suffix if it does not already exist
    case "$TARGET_HOST" in
        *."$DOMAIN_SUFFIX")
            echo "Adding domain suffix to host target" >&2
            ;;
        *)
            echo "Adding domain suffix to host target" >&2
            TARGET_HOST="${TARGET_HOST}.${DOMAIN_SUFFIX}"
            ;;
    esac
fi

# The path to the file containing the password to encrypt the keys
export PASSWORD_FILE="$STEPPATH/secrets/password"

# The path to the file containing the password to decrypt the existing root certificate key
export KEY_PASSWORD_FILE="$STEPPATH/secrets/key-password"

# The path to the file containing the password to encrypt the provisioner key
export PROVISION_PASSWORD_FILE="$STEPPATH/secrets/provisioner-password"

mkdir -p "$STEPPATH"
mkdir -p "$(dirname "$PASSWORD_FILE")"

# Use randomized passwords if not already set
if [ ! -f "$PASSWORD_FILE" ]; then
    step crypto rand > "$PASSWORD_FILE"
fi

if [ ! -f "$KEY_PASSWORD_FILE" ]; then
    step crypto rand > "$KEY_PASSWORD_FILE"
fi

if [ ! -f "$PROVISION_PASSWORD_FILE" ]; then
    if [ -n "$PROVISION_PASSWORD" ]; then
        printf -- '%s' "$PROVISION_PASSWORD" > "$PROVISION_PASSWORD_FILE"
    else
        step crypto rand > "$PROVISION_PASSWORD_FILE"
    fi
fi

CURRENT_USER=$(id -u)
if [ "$CURRENT_USER" = 0 ]; then
    chown root:root "$PASSWORD_FILE"
    chmod 600 "$PASSWORD_FILE"
fi

cert_names() {
    prefix="$1"
    shift
    names="127.0.0.1 localhost tedge $(hostname) $(hostname).local $*"

    VALUE=$(
        for i in $names; do
            echo "$prefix=$i"
        done
    )
    echo "$VALUE" | sort | uniq  
}

# shellcheck disable=SC2046
step ca init \
    --password-file="$PASSWORD_FILE" \
    --key-password-file="$KEY_PASSWORD_FILE" \
    --provisioner-password-file="$PROVISION_PASSWORD_FILE" \
    --deployment-type=standalone \
    --provisioner=tedge \
    --name=tedge-local \
    $(cert_names --dns "$TARGET_HOST") \
    --address=:8443

# Allow other users to inspect certificates
chmod 755 "$(step path)/certs"
chmod 644 "$(step path)/certs/"*

if [ -d /run/systemd ]; then
    # Stop the ca before configuring it
    systemctl stop step-ca
fi

# TODO: Check why the root certificate needs to be placed in the global store
# for the file transfer service to work, otherwise the following error occurs:
#   config-manager failed uploading configuration snapshot: error sending request for url (https://127.0.0.1:8000/tedge/file-transfer/smallstep-test01/config_snapshot/tedge.toml-c8y-mapper-211213): error trying to connect: invalid peer certificate: UnknownIssuer: error trying to connect: invalid peer certificate: UnknownIssuer: invalid peer certificate: UnknownIssuer
if command -V update-ca-certificates >/dev/null 2>&1; then
    echo "Installing root certificate"
    cp -a "$STEPPATH/certs/root_ca.crt" /usr/local/share/ca-certificates/
    update-ca-certificates
else
    echo "Warning: update-ca-certificates is not installed. Make sure you add '$STEPPATH/certs/root_ca.crt' to your trust store"
fi

# Unencrypt the key as mosquitto needs to access it
step crypto change-pass "$(step path)/secrets/intermediate_ca_key" --password-file="$PASSWORD_FILE" --no-password --insecure --force
chown mosquitto:mosquitto "$(step path)/secrets/intermediate_ca_key"
chmod 600 "$(step path)/secrets/intermediate_ca_key"

# Configure provisioner to control certificate renewal periods
# Duration table:
# 24h = 1 day (min)
# 720h = 30 days (default)
# 8760h = 365 days (max)
step ca provisioner update tedge --x509-min-dur 24h --x509-default-dur 720h --x509-max-dur 4320h

#
# Create certificate for thin-edge.io components (for tedge user)
#
echo "Creating x509 certificates for thin-edge.io" >&2
# shellcheck disable=SC2046
step certificate create \
    --profile=leaf \
    --not-after=8760h \
    --bundle \
    --kty=RSA \
    --ca="$STEPPATH/certs/intermediate_ca.crt" \
    --ca-key="$STEPPATH/secrets/intermediate_ca_key" \
    --no-password \
    --insecure \
    --force \
    $(cert_names --san "$TARGET_HOST") \
    "$(hostname)" /etc/tedge/device-certs/local-tedge.crt /etc/tedge/device-certs/local-tedge.key

chown tedge:tedge /etc/tedge/device-certs/local-tedge.crt
chmod 644 /etc/tedge/device-certs/local-tedge.crt
chown tedge:tedge /etc/tedge/device-certs/local-tedge.key
chmod 600 /etc/tedge/device-certs/local-tedge.key

# Create service to renew the certificate automatically
if command -V systemctl >/dev/null 2>&1; then
    echo "Enabling cert-renewer service for local-tedge" >&2
    systemctl enable cert-renewer@local-tedge.timer
    if [ -d /run/systemd ]; then
        systemctl start cert-renewer@local-tedge.timer
    fi
fi

#
# Create certificate for mosquitto (for mosquitto user)
#
echo "Creating x509 certificates for mosquitto" >&2
# shellcheck disable=SC2046
step certificate create \
    --profile=leaf \
    --not-after=8760h \
    --bundle \
    --kty=RSA \
    --ca="$STEPPATH/certs/intermediate_ca.crt" \
    --ca-key="$STEPPATH/secrets/intermediate_ca_key" \
    --no-password \
    --insecure \
    --force \
    $(cert_names --san "$TARGET_HOST") \
    "$(hostname)" /etc/tedge/device-certs/local-mosquitto.crt /etc/tedge/device-certs/local-mosquitto.key

chown mosquitto:mosquitto /etc/tedge/device-certs/local-mosquitto.crt
chmod 644 /etc/tedge/device-certs/local-mosquitto.crt
chown mosquitto:mosquitto /etc/tedge/device-certs/local-mosquitto.key
chmod 600 /etc/tedge/device-certs/local-mosquitto.key

ln -sf /etc/tedge/device-certs/local-mosquitto.crt /etc/mosquitto/certs/local-mosquitto.crt
ln -sf /etc/tedge/device-certs/local-mosquitto.key /etc/mosquitto/certs/local-mosquitto.key

# Create service to renew the certificate automatically
if command -V systemctl >/dev/null 2>&1; then
    echo "Enable cert-renewer" >&2
    systemctl enable cert-renewer@local-mosquitto.timer
    if [ -d /run/systemd ]; then
        systemctl start cert-renewer@local-mosquitto.timer
    fi
fi

# FIXME: These files aren't used to generate an external listener
# => Workaround: create the mosquitto tls configuration manually
# tedge config set mqtt.external.ca_path "$(step path)/certs/root_ca.crt"
# tedge config set mqtt.external.cert_file "$(step path)/certs/intermediate_ca.crt"
# tedge config set mqtt.external.key_file "$(step path)/secrets/intermediate_ca_key"

# FIXME: should thin-edge.io support the external listener insteaf of having to edit the mosquitto configure directly
# TODO: Where can the tls listener be added to, conf.d, or /etc/tedge/mosquitto-conf/?
cat << EOF > "/etc/mosquitto/conf.d/tls-listener.conf"
listener 8883 0.0.0.0
allow_anonymous false
require_certificate true
use_identity_as_username true
use_username_as_clientid false
cafile $(step path)/certs/root_ca.crt
certfile /etc/mosquitto/certs/local-mosquitto.crt
keyfile /etc/mosquitto/certs/local-mosquitto.key
EOF

#
# Set thin-edge settings
#

echo "Configuring thin-edge.io to use host target: $TARGET_HOST" >&2

# thin-edge.io File Transfer Service
tedge config set http.client.host "$TARGET_HOST"
tedge config set http.client.port 8000
tedge config set http.key_path /etc/tedge/device-certs/local-tedge.key
tedge config set http.cert_path /etc/tedge/device-certs/local-tedge.crt
# FIXME: Support reading a file instead of a path
# tedge config set http.ca_path "$(step path)/certs/root_ca.crt"
tedge config set http.ca_path "$(step path)/certs"
tedge config set http.client.auth.key_file /etc/tedge/device-certs/local-tedge.key
tedge config set http.client.auth.cert_file /etc/tedge/device-certs/local-tedge.crt

# thin-edge.io mqtt client settings
tedge config set http.bind.address 0.0.0.0
tedge config set mqtt.client.host 127.0.0.1
tedge config set mqtt.client.port 8883
tedge config set mqtt.client.auth.ca_file "$(step path)/certs/root_ca.crt"
tedge config set mqtt.client.auth.cert_file /etc/tedge/device-certs/local-tedge.crt
tedge config set mqtt.client.auth.key_file /etc/tedge/device-certs/local-tedge.key

# thin-edge.io c8y proxy client settings
tedge config set c8y.proxy.bind.address 0.0.0.0
tedge config set c8y.proxy.client.host "$TARGET_HOST"
tedge config set c8y.proxy.client.port 8001
tedge config set c8y.proxy.ca_path "$(step path)/certs"
tedge config set c8y.proxy.cert_path /etc/tedge/device-certs/local-tedge.crt
tedge config set c8y.proxy.key_path /etc/tedge/device-certs/local-tedge.key


# Start/restart services
if [ -d /run/systemd ]; then
    systemctl restart mosquitto
    systemctl restart tedge-agent.service

    if systemctl --quiet is-active tedge-mapper-collectd.service; then
        systemctl restart tedge-mapper-collectd.service
    fi

    # Only restart configured mappers
    if tedge config get c8y.url >/dev/null 2>&1; then
        systemctl restart tedge-mapper-c8y.service
    fi
    if tedge config get aws.url >/dev/null 2>&1; then
        systemctl restart tedge-mapper-aws.service
    fi
    if tedge config get az.url >/dev/null 2>&1; then
        systemctl restart tedge-mapper-az.service
    fi

    systemctl enable step-ca
    systemctl restart step-ca
fi

step-ca-admin.sh verify
