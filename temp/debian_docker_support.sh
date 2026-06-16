#!/bin/bash
# by https://github.com/oneclickvirt/lxd

export DEBIAN_FRONTEND=noninteractive

# Update the package manager's package list
apt-get update

# Install packages needed to add the Docker GPG key
apt-get install -y apt-transport-https ca-certificates curl gnupg2 software-properties-common

# Add the Docker GPG key
install -m 0755 -d /etc/apt/keyrings
docker_gpg_tmp=$(mktemp)
if ! curl -fsSL https://download.docker.com/linux/debian/gpg -o "$docker_gpg_tmp"; then
  echo "Failed to download Docker GPG key."
  rm -f "$docker_gpg_tmp"
  exit 1
fi
if ! gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg "$docker_gpg_tmp"; then
  echo "Failed to install Docker GPG key."
  rm -f "$docker_gpg_tmp"
  exit 1
fi
rm -f "$docker_gpg_tmp"
chmod a+r /etc/apt/keyrings/docker.gpg

# Add the Docker repository to the package manager
arch=$(dpkg --print-architecture)
codename=$(lsb_release -cs 2>/dev/null)
if [ -z "$codename" ] && [ -f /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  codename="${VERSION_CODENAME:-}"
fi
if [ -z "$codename" ]; then
  echo "Cannot detect Debian codename for Docker repository."
  exit 1
fi
echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian ${codename} stable" >/etc/apt/sources.list.d/docker.list

# Update the package manager's package list (again)
apt-get update

# Install Docker
apt-get install -y docker-ce

# Add the current user to the "docker" group, so that we don't have to use "sudo" to run Docker commands
target_user="${SUDO_USER:-${USER:-root}}"
usermod -aG docker "$target_user"
