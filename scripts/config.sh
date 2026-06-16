#!/bin/bash
# from https://github.com/oneclickvirt/lxd
# 2023.06.29

export DEBIAN_FRONTEND=noninteractive

divert_install_script() {
  local package_name=$1
  local divert_script="/usr/local/sbin/${package_name}-install"
  local install_script="/var/lib/dpkg/info/${package_name}.postinst"
  if [ -x "$(command -v yum)" ]; then
    divert_script="/usr/local/sbin/${package_name}-install"
    install_script="/var/lib/rpm/centos/${package_name}.postinst"
  elif [ -x "$(command -v apk)" ]; then
    # Alpine使用不同的路径
    divert_script="/usr/local/sbin/${package_name}-install"
    install_script="/var/lib/apk/scripts/${package_name}.post-install"
  elif [ -x "$(command -v pacman)" ]; then
    # Arch使用不同的路径
    divert_script="/usr/local/sbin/${package_name}-install"
    install_script="/var/lib/pacman/scripts/${package_name}.install"
  fi
  mkdir -p "$(dirname "$divert_script")" "$(dirname "$install_script")"
  ln -sf "${divert_script}" "${install_script}"
  echo '#!/bin/bash' >"${divert_script}"
  echo 'exit 1' >>"${divert_script}"
  chmod +x "${divert_script}"
}

write_apt_pin() {
  local prefs_file="/etc/apt/preferences"
  local pin_header="Package: zmap nmap masscan medusa apache2-utils hping3"
  if ! grep -Fq "$pin_header" "$prefs_file" 2>/dev/null; then
    cat >>"$prefs_file" <<'EOF'
Package: zmap nmap masscan medusa apache2-utils hping3
Pin: release *
Pin-Priority: -1
EOF
  fi
}

if [ -x "$(command -v apt-get)" ]; then
  write_apt_pin
fi

if [ -x "$(command -v apt-get)" ]; then
  sudo apt-get update
elif [ -x "$(command -v yum)" ]; then
  sudo yum update -y
elif [ -x "$(command -v dnf)" ]; then
  sudo dnf update -y
elif [ -x "$(command -v apk)" ]; then
  sudo apk update
elif [ -x "$(command -v pacman)" ]; then
  sudo pacman -Sy
fi

divert_install_script "zmap"
divert_install_script "nmap"
divert_install_script "masscan"
divert_install_script "medusa"
divert_install_script "hping3"
divert_install_script "apache2-utils"
rm -f -- "$0"
