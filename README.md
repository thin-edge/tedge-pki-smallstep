# thin-edge.io Smallstep (local) PKI integration

The project provides a community plugin for thin-edge.io which provides a local PKI (from [Smallstep](https://smallstep.com/)) to make it easier to setup TLS communication for mutual TLS authentication for all thin-edge.io components and child devices.

## Plugin summary

### What will be deployed to the device?

The following describes the functionality installed

**Server (CA) - tedge-pki-smallstep-ca**

* A service a `step-ca.service` which runs the `step-ca` application which provides the PKI endpoints for local device enrollment
* Certificate renewal service to renew the certificates used by thin-edge.io on the main device
    * `cert-renewer@tedge-agent.timer` (timer) which triggers `cert-renewer@tedge-agent.service`
* The following binaries are installed to interact with the local PKI service
    * `step-ca-init.sh` - Initialize the local PKI service and generate certificates for the thin-edge.io components on the main device

**Note:** The `tedge-pki-smallstep-ca` package will also install the `tedge-pki-smallstep-client` package, as the `step-ca-admin.sh` script can be used to generate an enrollment one-liner based on a one-time password which is only valid for the given child device common name

**Client - tedge-pki-smallstep-client**

* Certificate renewal service to renew the certificates used by thin-edge.io on the child device
    * `cert-renewer@tedge-agent.timer` (timer) which triggers `cert-renewer@tedge-agent.service`

* The following binaries are installed to interact with the local PKI service
    * `step-ca-admin.sh enroll` - Enroll a device by requesting a certificate from the PKI server running on the main device
    * `step-ca-admin.sh enroll` - Enroll a device by requesting a certificate from the PKI server running on the main device


**Technical summary**

The following details the technical aspects of the plugin to get an idea what systems it supports.

|||
|--|--|
|**Languages**|`shell` (posix compatible)|
|**CPU Architectures**|`all/noarch`|
|**Supported init systems**|`systemd`|
|**Required Dependencies**|`step-ca` (server), `step-cli` (client)|

### How to do I get it?

The following linux package formats are provided on the releases page and also in the [tedge-community](https://cloudsmith.io/~thinedge/repos/community/packages/) repository:

**Server (CA)**

|Operating System|Repository link|
|--|--|
|Debian/Raspbian (deb)|[![Latest version of 'tedge-pki-smallstep-ca' @ Cloudsmith](https://api-prd.cloudsmith.io/v1/badges/version/thinedge/community/deb/tedge-pki-smallstep-ca/latest/a=all;d=any-distro%252Fany-version;t=binary/?render=true&show_latest=true)](https://cloudsmith.io/~thinedge/repos/community/packages/detail/deb/tedge-pki-smallstep-ca/latest/a=all;d=any-distro%252Fany-version;t=binary/)|
|Alpine Linux (apk)|[![Latest version of 'tedge-pki-smallstep-ca' @ Cloudsmith](https://api-prd.cloudsmith.io/v1/badges/version/thinedge/community/alpine/tedge-pki-smallstep-ca/latest/a=noarch;d=alpine%252Fany-version/?render=true&show_latest=true)](https://cloudsmith.io/~thinedge/repos/community/packages/detail/alpine/tedge-pki-smallstep-ca/latest/a=noarch;d=alpine%252Fany-version/)|
|RHEL/CentOS/Fedora (rpm)|[![Latest version of 'tedge-pki-smallstep-ca' @ Cloudsmith](https://api-prd.cloudsmith.io/v1/badges/version/thinedge/community/rpm/tedge-pki-smallstep-ca/latest/a=noarch;d=any-distro%252Fany-version;t=binary/?render=true&show_latest=true)](https://cloudsmith.io/~thinedge/repos/community/packages/detail/rpm/tedge-pki-smallstep-ca/latest/a=noarch;d=any-distro%252Fany-version;t=binary/)|

**Client**

|Operating System|Repository link|
|--|--|
|Debian/Raspbian (deb)|[![Latest version of 'tedge-pki-smallstep-client' @ Cloudsmith](https://api-prd.cloudsmith.io/v1/badges/version/thinedge/community/deb/tedge-pki-smallstep-client/latest/a=all;d=any-distro%252Fany-version;t=binary/?render=true&show_latest=true)](https://cloudsmith.io/~thinedge/repos/community/packages/detail/deb/tedge-pki-smallstep-client/latest/a=all;d=any-distro%252Fany-version;t=binary/)|
|Alpine Linux (apk)|[![Latest version of 'tedge-pki-smallstep-client' @ Cloudsmith](https://api-prd.cloudsmith.io/v1/badges/version/thinedge/community/alpine/tedge-pki-smallstep-client/latest/a=noarch;d=alpine%252Fany-version/?render=true&show_latest=true)](https://cloudsmith.io/~thinedge/repos/community/packages/detail/alpine/tedge-pki-smallstep-client/latest/a=noarch;d=alpine%252Fany-version/)|
|RHEL/CentOS/Fedora (rpm)|[![Latest version of 'tedge-pki-smallstep-client' @ Cloudsmith](https://api-prd.cloudsmith.io/v1/badges/version/thinedge/community/rpm/tedge-pki-smallstep-client/latest/a=noarch;d=any-distro%252Fany-version;t=binary/?render=true&show_latest=true)](https://cloudsmith.io/~thinedge/repos/community/packages/detail/rpm/tedge-pki-smallstep-client/latest/a=noarch;d=any-distro%252Fany-version;t=binary/)|

## Features

The following features are supported by the plugin:

* Local PKI service which is installed on the main device
* Child device enrollment via a client
* Automatic certificate renewal services for each certificate (run on the device on which the certificate is located on)

## Installation

### Pre-requisites

If you are using a firewall on the main device (or in your cloud setup), ensure that the following ports are open, otherwise the child device will not be able to connect to the main device.

* Port 8443 (TCP) - INCOMING - step-ca endpoint (local PKI) used to issue certificates for the local network
* Port 8883 (TCP) - INCOMING - mosquitto broker
* Port 8000 (TCP) - INCOMING - thin-edge.io File Transfer Service (HTTP server)
* Port 8001 (TCP) - INCOMING - thin-edge.io Cumulocity Local Proxy

### Main device

The pki should be installed on the main device so that the child devices can request an initial x509 certificate, and also setup periodic renewal.

It is assumed that you have already installed thin-edge.io no the main device. If you haven't please follow the [official installation instructions](https://thin-edge.github.io/thin-edge.io/install/).

1. Install the tedge pki integration (which includes the installation of step-ca from [Smallstep](https://smallstep.com/))

    **Debian/Ubuntu**

    ```sh
    sudo apt-get update
    sudo apt-get install tedge-pki-smallstep-ca
    ```

2. Configure and start the step-ca server

    ```sh
    sudo step-ca-init.sh

    # Or add some additional names to be included in the generated certificates
    sudo step-ca-init.sh --san "other.name" --san "alternative.name"

    # Enforce using .local addresses
    sudo step-ca-init.sh --domain-suffix local
    ```

### Child device

**Important Note** 

For the following instructions to work, device where the step-ca (PKI) service has been installed needs to be reachable by the name given whilst creating the enrollment token. If the step-ca (PKI) service is not reachable, then you may need to manually enter the IP address of the server to the child device's `/etc/hosts` so that name resolution works correctly.

To enroll a child device to a main device, execute the following steps:

1. Install thin-edge.io

    ```sg
    wget -O - thin-edge.io/install.sh | sh -s
    ```

2. Install the pki client thin-edge.io integration package

    **Debian/Ubuntu**

    ```sh
    sudo apt-get update
    sudo apt-get install tedge-pki-smallstep-client
    ```

3. Open a shell on the main device and get an enrollment token

    ```sh
    sudo step-ca-admin.sh token <child_name>
    ```

    You can also specify an explicit `--host <name>` flag if the server is only reachable from a public IP address / DNS entry:

    ```sh
    sudo step-ca-admin.sh token <child_name> --host some.public.name
    ```

    Follow the instructions printed to the console, and then execute the command on the child device.

## Managing certificate renewals

To ensure the certificates are automatically renewed, as service is configure which periodically checks if the certificate will expire soon, and will renew it (using the existing certificate for authentication) before it expires (within 25% of the certificate validity period).

The following service timers are used to trigger the certificate renewals.

**Main device**

* `cert-renewer@local-tedge.timer` - Used by tedge-mapper-c8y and tedge-agent
* `cert-renewer@local-mosquitto.timer` - Used for mosquitto authentication

**Child device**

* `cert-renewer@tedge-agent.timer` - Used by tedge-agent

## Renewing Root and intermediate certificates

The root and intermediate certificates have a default expiration of 10 years, so they need less maintenance.

**Renew intermediate certificate**

TODO - The following instructions don't work as it also recreates the private key (which is not desired).

```sh
export STEPPATH="/etc/step-ca"
sudo step certificate create --csr "Intermediate CA" "$STEPPATH/certs/intermediate_ca.csr" "$STEPPATH/secrets/intermediate_ca_key"
sudo step ca sign "$STEPPATH/certs/intermediate_ca.csr" "$STEPPATH/certs/intermediate_ca.crt"
sudo rm -f "$STEPPATH/certs/intermediate_ca.csr"
```

**Renew root certificate**

TODO
