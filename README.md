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
