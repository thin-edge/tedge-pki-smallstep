# thin-edge.io Smallstep (local) PKI integration

The project provides a community plugin for thin-edge.io which provides a local PKI to make it easier to setup TLS communication for mutual TLS authentication for all thin-edge.io components and child devices.

## Installation

### Main device

The pki should be installed on the main device so that the child devices can request an initial x509 certificate, and also setup periodic renewal.

It is assumed that you have already installed thin-edge.io no the main device. If you haven't please follow the [official installation instructions](https://thin-edge.github.io/thin-edge.io/install/).

1. Install the tedge pki integration (which includes the installation of smallstep)

    ```sh
    apt-get install -y tedge-pki-smallstep-ca
    ```

2. Configure and start the smallstep ca server

    ```sh
    step-ca-init.sh
    ```

### Child device

1. Install the thin-edge.io and the pki client integration

    **Debian/Ubuntu**

    ```sh
    apt-get install -y tedge tedge-agent tedge-pki-smallstep-client
    ```

2. Open a shell on the main device and get an enrollment token

    ```sh
    step-ca-admin.sh token <child_name>
    ```

    Follow the instructions printed to the console, and then execute the command on the child device

## Managing certificate renewals

To ensure the certificates are automatically renewed, as service is configure which periodically checks if the certificate will expire soon, and will renew it (using the existing certificate for authentication) before it expires (within 25% of the certificate validity period).

The following service timers are used to trigger the certificate renewals.

**Main device**

* cert-renewer@local-tedge.timer - Used by tedge-mapper-c8y and tedge-agent
* cert-renewer@local-mosquitto.timer - Used for mosquitto authentication

**Child device**

* cert-renewer@tedge-agent.timer - Used by tedge-agent

## Renewing Root and intermediate certificates

The root and intermediate certificates have a default expiration of 10 years, so they need less maintaince.

**Renew intermiate certificate**

TODO - The following instructions don't work as it also recreates the private key (which is not desired).

```sh
export STEPPATH="/etc/step-ca"
sudo step certificate create --csr "Intermediate CA" "$STEPPATH/certs/intermediate_ca.csr" "$STEPPATH/secrets/intermediate_ca_key"
sudo step ca sign "$STEPPATH/certs/intermediate_ca.csr" "$STEPPATH/certs/intermediate_ca.crt"
sudo rm -f "$STEPPATH/certs/intermediate_ca.csr"
```

**Renew root certificate**

TODO
