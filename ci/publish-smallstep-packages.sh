#!/usr/bin/env bash
set -ex

mkdir -p dist
cd dist

SOURCE_PATH="${SOURCE_PATH:-.}"

while [ $# -gt 0 ]; do
    case "$1" in
        --path)
            SOURCE_PATH="$2"
            shift
            ;;
        --*|-*)
            echo "Unknown flag. $1" >&2
            exit 1
            ;;
        *)
            ;;
    esac
    shift
done

rm -f step*.deb

download_smallstep() {
    ext="$1"
    echo "Downloading $ext packages"

    wget "https://dl.smallstep.com/cli/docs-ca-install/latest/step-cli_armv5.${ext}"
    wget "https://dl.smallstep.com/cli/docs-ca-install/latest/step-cli_armv6.${ext}"
    wget "https://dl.smallstep.com/cli/docs-ca-install/latest/step-cli_arm64.${ext}"
    wget "https://dl.smallstep.com/cli/docs-ca-install/latest/step-cli_amd64.${ext}"
    wget "https://dl.smallstep.com/cli/docs-ca-install/latest/step-cli_386.${ext}"

    wget "https://dl.smallstep.com/certificates/docs-ca-install/latest/step-ca_armv5.${ext}"
    wget "https://dl.smallstep.com/certificates/docs-ca-install/latest/step-ca_armv6.${ext}"
    wget "https://dl.smallstep.com/certificates/docs-ca-install/latest/step-ca_arm64.${ext}"
    wget "https://dl.smallstep.com/certificates/docs-ca-install/latest/step-ca_amd64.${ext}"
    wget "https://dl.smallstep.com/certificates/docs-ca-install/latest/step-ca_386.${ext}"
}

publish_linux() {
    local sourcedir="$1"
    local pattern="$2"
    local package_type="$3"
    local sub_path="$4"

    local upload_path="${PUBLISH_OWNER}/${PUBLISH_REPO}"
    if [ -n "$sub_path" ]; then
        upload_path="$upload_path/$sub_path"
    fi

    # Notes: Currently Cloudsmith does not support the following (this might change in the future)
    #  * distribution and distribution_version must be selected from values in the list. use `cloudsmith list distros` to get the list
    #  * The component can not be set and is currently fixed to 'main'
    find "$sourcedir" -name "$pattern" -print0 | while read -r -d $'\0' file
    do
        cloudsmith upload "$package_type" "$upload_path" "$file" \
            --no-wait-for-sync \
            --api-key "${PUBLISH_TOKEN}"
    done
}

# Note: alpine already has step-ca and step-cli packages in the community repository

download_smallstep deb
download_smallstep rpm

publish_linux "$SOURCE_PATH" "step*.deb" deb "any-distro/any-version"
publish_linux "$SOURCE_PATH" "step*.rpm" rpm "any-distro/any-version"
