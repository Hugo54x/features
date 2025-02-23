#!/usr/bin/env bash
#-------------------------------------------------------------------------------------------------------------
# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the MIT License. See https://go.microsoft.com/fwlink/?linkid=2090316 for license information.
#-------------------------------------------------------------------------------------------------------------
#
# Docs: https://github.com/microsoft/vscode-dev-containers/blob/main/script-library/docs/kubectl-helm.md
# Maintainer: The VS Code and Codespaces Teams

set -e

# Clean up
rm -rf /var/lib/apt/lists/*

KUBECTL_VERSION="${VERSION:-"latest"}"
HELM_VERSION="${HELM:-"latest"}"
MINIKUBE_VERSION="${MINIKUBE:-"none"}" # latest is also valid

KUBECTL_SHA256="${KUBECTL_SHA256:-"automatic"}"
HELM_SHA256="${HELM_SHA256:-"automatic"}"
MINIKUBE_SHA256="${MINIKUBE_SHA256:-"automatic"}"
USERNAME="${USERNAME:-"${_REMOTE_USER:-"automatic"}"}"

HELM_GPG_KEYS_URI="https://raw.githubusercontent.com/helm/helm/main/KEYS"
GPG_KEY_SERVERS="keyserver hkp://keyserver.ubuntu.com
keyserver hkps://keys.openpgp.org
keyserver hkp://keyserver.pgp.com"

if [ "$(id -u)" -ne 0 ]; then
    echo -e 'Script must be run as root. Use sudo, su, or add "USER root" to your Dockerfile before running this script.'
    exit 1
fi

# Determine the appropriate non-root user
if [ "${USERNAME}" = "auto" ] || [ "${USERNAME}" = "automatic" ]; then
    USERNAME=""
    POSSIBLE_USERS=("vscode" "node" "codespace" "$(awk -v val=1000 -F ":" '$3==val{print $1}' /etc/passwd)")
    for CURRENT_USER in "${POSSIBLE_USERS[@]}"; do
        if id -u ${CURRENT_USER} > /dev/null 2>&1; then
            USERNAME=${CURRENT_USER}
            break
        fi
    done
    if [ "${USERNAME}" = "" ]; then
        USERNAME=root
    fi
elif [ "${USERNAME}" = "none" ] || ! id -u ${USERNAME} > /dev/null 2>&1; then
    USERNAME=root
fi

USERHOME="/home/$USERNAME"
if [ "$USERNAME" = "root" ]; then
    USERHOME="/root"
fi

# Figure out correct version of a three part version number is not passed
find_version_from_git_tags() {
    local variable_name=$1
    local requested_version=${!variable_name}
    if [ "${requested_version}" = "none" ]; then return; fi
    local repository=$2
    local prefix=${3:-"tags/v"}
    local separator=${4:-"."}
    local last_part_optional=${5:-"false"}    
    if [ "$(echo "${requested_version}" | grep -o "." | wc -l)" != "2" ]; then
        local escaped_separator=${separator//./\\.}
        local last_part
        if [ "${last_part_optional}" = "true" ]; then
            last_part="(${escaped_separator}[0-9]+)?"
        else
            last_part="${escaped_separator}[0-9]+"
        fi
        local regex="${prefix}\\K[0-9]+${escaped_separator}[0-9]+${last_part}$"
        local version_list="$(git ls-remote --tags ${repository} | grep -oP "${regex}" | tr -d ' ' | tr "${separator}" "." | sort -rV)"
        if [ "${requested_version}" = "latest" ] || [ "${requested_version}" = "current" ] || [ "${requested_version}" = "lts" ]; then
            declare -g ${variable_name}="$(echo "${version_list}" | head -n 1)"
        else
            set +e
            declare -g ${variable_name}="$(echo "${version_list}" | grep -E -m 1 "^${requested_version//./\\.}([\\.\\s]|$)")"
            set -e
        fi
    fi
    if [ -z "${!variable_name}" ] || ! echo "${version_list}" | grep "^${!variable_name//./\\.}$" > /dev/null 2>&1; then
        echo -e "Invalid ${variable_name} value: ${requested_version}\nValid values:\n${version_list}" >&2
        exit 1
    fi
    echo "${variable_name}=${!variable_name}"
}

apt_get_update()
{
    if [ "$(find /var/lib/apt/lists/* | wc -l)" = "0" ]; then
        echo "Running apt-get update..."
        apt-get update -y
    fi
}

# Checks if packages are installed and installs them if not
check_packages() {
    if ! dpkg -s "$@" > /dev/null 2>&1; then
        apt_get_update
        apt-get -y install --no-install-recommends "$@"
    fi
}

# Ensure apt is in non-interactive to avoid prompts
export DEBIAN_FRONTEND=noninteractive

# Install dependencies
check_packages curl ca-certificates coreutils gnupg2 dirmngr bash-completion
if ! type git > /dev/null 2>&1; then
    check_packages git
fi

architecture="$(uname -m)"
case $architecture in
    x86_64) architecture="amd64";;
    aarch64 | armv8*) architecture="arm64";;
    aarch32 | armv7* | armvhf*) architecture="arm";;
    i?86) architecture="386";;
    *) echo "(!) Architecture $architecture unsupported"; exit 1 ;;
esac

# Install the kubectl, verify checksum
echo "Downloading kubectl..."
if [ "${KUBECTL_VERSION}" = "latest" ] || [ "${KUBECTL_VERSION}" = "lts" ] || [ "${KUBECTL_VERSION}" = "current" ] || [ "${KUBECTL_VERSION}" = "stable" ]; then
    KUBECTL_VERSION="$(curl -sSL https://dl.k8s.io/release/stable.txt)"
else
    find_version_from_git_tags KUBECTL_VERSION https://github.com/kubernetes/kubernetes
fi
if [ "${KUBECTL_VERSION::1}" != 'v' ]; then
    KUBECTL_VERSION="v${KUBECTL_VERSION}"
fi
curl -sSL -o /usr/local/bin/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${architecture}/kubectl"
chmod 0755 /usr/local/bin/kubectl
if [ "$KUBECTL_SHA256" = "automatic" ]; then
    KUBECTL_SHA256="$(curl -sSL "https://dl.k8s.io/${KUBECTL_VERSION}/bin/linux/${architecture}/kubectl.sha256")"
fi
([ "${KUBECTL_SHA256}" = "dev-mode" ] || (echo "${KUBECTL_SHA256} */usr/local/bin/kubectl" | sha256sum -c -))
if ! type kubectl > /dev/null 2>&1; then
    echo '(!) kubectl installation failed!'
    exit 1
fi

# kubectl bash completion
kubectl completion bash > /etc/bash_completion.d/kubectl

# kubectl zsh completion
if [ -e "${USERHOME}}/.oh-my-zsh" ]; then
    mkdir -p "${USERHOME}/.oh-my-zsh/completions"
    kubectl completion zsh > "${USERHOME}/.oh-my-zsh/completions/_kubectl"
    chown -R "${USERNAME}" "${USERHOME}/.oh-my-zsh"
fi

# Install Helm, verify signature and checksum
echo "Downloading Helm..."
find_version_from_git_tags HELM_VERSION "https://github.com/helm/helm"
if [ "${HELM_VERSION::1}" != 'v' ]; then
    HELM_VERSION="v${HELM_VERSION}"
fi
mkdir -p /tmp/helm
helm_filename="helm-${HELM_VERSION}-linux-${architecture}.tar.gz"
tmp_helm_filename="/tmp/helm/${helm_filename}"
curl -sSL "https://get.helm.sh/${helm_filename}" -o "${tmp_helm_filename}"
curl -sSL "https://github.com/helm/helm/releases/download/${HELM_VERSION}/${helm_filename}.asc" -o "${tmp_helm_filename}.asc"
export GNUPGHOME="/tmp/helm/gnupg"
mkdir -p "${GNUPGHOME}"
chmod 700 ${GNUPGHOME}
curl -sSL "${HELM_GPG_KEYS_URI}" -o /tmp/helm/KEYS
echo -e "disable-ipv6\n${GPG_KEY_SERVERS}" > ${GNUPGHOME}/dirmngr.conf
gpg -q --import "/tmp/helm/KEYS"
if ! gpg --verify "${tmp_helm_filename}.asc" > ${GNUPGHOME}/verify.log 2>&1; then
    echo "Verification failed!"
    cat /tmp/helm/gnupg/verify.log
    exit 1
fi
if [ "${HELM_SHA256}" = "automatic" ]; then
    curl -sSL "https://get.helm.sh/${helm_filename}.sha256" -o "${tmp_helm_filename}.sha256"
    curl -sSL "https://github.com/helm/helm/releases/download/${HELM_VERSION}/${helm_filename}.sha256.asc" -o "${tmp_helm_filename}.sha256.asc"
    if ! gpg --verify "${tmp_helm_filename}.sha256.asc" > /tmp/helm/gnupg/verify.log 2>&1; then
        echo "Verification failed!"
        cat /tmp/helm/gnupg/verify.log
        exit 1
    fi
    HELM_SHA256="$(cat "${tmp_helm_filename}.sha256")"
fi
([ "${HELM_SHA256}" = "dev-mode" ] || (echo "${HELM_SHA256} *${tmp_helm_filename}" | sha256sum -c -))
tar xf "${tmp_helm_filename}" -C /tmp/helm
mv -f "/tmp/helm/linux-${architecture}/helm" /usr/local/bin/
chmod 0755 /usr/local/bin/helm
rm -rf /tmp/helm
if ! type helm > /dev/null 2>&1; then
    echo '(!) Helm installation failed!'
    exit 1
fi

# Install Minikube, verify checksum
if [ "${MINIKUBE_VERSION}" != "none" ]; then
    echo "Downloading minikube..."
    if [ "${MINIKUBE_VERSION}" = "latest" ] || [ "${MINIKUBE_VERSION}" = "lts" ] || [ "${MINIKUBE_VERSION}" = "current" ] || [ "${MINIKUBE_VERSION}" = "stable" ]; then
        MINIKUBE_VERSION="latest"
    else
        find_version_from_git_tags MINIKUBE_VERSION https://github.com/kubernetes/minikube
        if [ "${MINIKUBE_VERSION::1}" != "v" ]; then
            MINIKUBE_VERSION="v${MINIKUBE_VERSION}"
        fi
    fi
    # latest is also valid in the download URLs 
    curl -sSL -o /usr/local/bin/minikube "https://storage.googleapis.com/minikube/releases/${MINIKUBE_VERSION}/minikube-linux-${architecture}"    
    chmod 0755 /usr/local/bin/minikube
    if [ "$MINIKUBE_SHA256" = "automatic" ]; then
        MINIKUBE_SHA256="$(curl -sSL "https://storage.googleapis.com/minikube/releases/${MINIKUBE_VERSION}/minikube-linux-${architecture}.sha256")"
    fi
    ([ "${MINIKUBE_SHA256}" = "dev-mode" ] || (echo "${MINIKUBE_SHA256} */usr/local/bin/minikube" | sha256sum -c -))
    if ! type minikube > /dev/null 2>&1; then
        echo '(!) minikube installation failed!'
        exit 1
    fi
    # Create minkube folder with correct privs in case a volume is mounted here
    mkdir -p "${USERHOME}/.minikube"
    chown -R $USERNAME "${USERHOME}/.minikube"
    chmod -R u+wrx "${USERHOME}/.minikube"
fi

if ! type docker > /dev/null 2>&1; then
    echo -e '\n(*) Warning: The docker command was not found.\n\nYou can use one of the following scripts to install it:\n\nhttps://github.com/microsoft/vscode-dev-containers/blob/main/script-library/docs/docker-in-docker.md\n\nor\n\nhttps://github.com/microsoft/vscode-dev-containers/blob/main/script-library/docs/docker.md'
fi

# Clean up
rm -rf /var/lib/apt/lists/*

echo -e "\nDone!"
