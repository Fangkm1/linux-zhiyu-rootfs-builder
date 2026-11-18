#!/usr/bin/env bash
set -euo pipefail

[[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { echo "Invalid username" >&2; exit 2; }
[[ "$HOST_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]] || { echo "Invalid hostname" >&2; exit 2; }
[[ "$PACKAGE_REPOSITORY" =~ ^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+$ ]] ||
    { echo "Invalid package repository. Use owner/repo." >&2; exit 2; }
case "${PACKAGE_REPOSITORY#*/}" in .|..) exit 2 ;; esac

case "$DESKTOP" in
    kde) desktop=(@kde-desktop @kde-apps @kde-media) display_manager=plasmalogin.service ;;
    gnome) desktop=(@gnome-desktop) display_manager=gdm.service ;;
    none) desktop=(glibc-langpack-en) display_manager= ;;
    *) exit 2 ;;
esac
if [[ -n "$display_manager" ]]; then
    desktop+=(
        'langpacks-*' glibc-all-langpacks
        google-noto-sans-vf-fonts google-noto-sans-cjk-vf-fonts google-noto-color-emoji-fonts
    )
fi

dnf -y install tar xz policycoreutils
target=$(mktemp -d)
trap 'umount -R "$target/dev" 2>/dev/null || true; umount "$target/proc" 2>/dev/null || true' EXIT
repo=/etc/yum.repos.d/zhiyu.repo
cat > "$repo" <<REPO
[zhiyu]
name=Zhiyu device packages
baseurl=https://raw.githubusercontent.com/$PACKAGE_REPOSITORY/rpm-repodata/fedora/
enabled=1
gpgcheck=0
repo_gpgcheck=0
skip_if_unavailable=0
REPO

installroot=(
    --installroot="$target" --use-host-config --releasever="$RELEASE"
    --setopt=tsflags=nodocs
)
board=(
    linux-zhiyu-modules linux-zhiyu-headers linux-zhiyu-firmware
    linux-zhiyu-images libcamera-zhiyu zhiyu-sensord hexagonrpc sensh
)
# Keep the translation files carried by RPMs in addition to the langpacks.
rpm_config="$target/.zhiyu-rpm-config"
install -d "$rpm_config/rpm"
printf '%%_install_langs all\n' > "$rpm_config/rpm/macros"
XDG_CONFIG_HOME="$rpm_config" dnf "${installroot[@]}" -y install \
    @core @standard gettext-runtime \
    fedora-release fedora-repos fedora-gpg-keys passwd \
    NetworkManager-wifi bluez wpa_supplicant \
    pipewire pipewire-alsa pipewire-pulseaudio wireplumber alsa-ucm \
    mesa-dri-drivers mesa-vulkan-drivers \
    qbootctl qmic qrtr \
    "${board[@]}" "${desktop[@]}"
install -Dm644 "$rpm_config/rpm/macros" "$target/etc/rpm/macros.zhiyu-langpacks"
rm "$rpm_config/rpm/macros"
rmdir "$rpm_config/rpm" "$rpm_config"
if [[ "$DESKTOP" == kde && ! -s "$target/usr/share/locale/zh_CN/LC_MESSAGES/plasmashell.mo" ]]; then
    echo "Plasma Chinese translation was omitted from the RPM transaction" >&2
    exit 1
fi
install -Dm644 "$repo" "$target$repo"

mount --rbind /dev "$target/dev"
mount --make-rslave "$target/dev"
mount -t proc proc "$target/proc"
ch() { chroot "$target" "$@"; }

install -d "$target/etc/systemd/system"
ch systemd-sysusers /usr/lib/sysusers.d/fastrpc.conf
ch systemd-tmpfiles --create /usr/lib/tmpfiles.d/hexagonrpc.conf
cat > "$target/etc/systemd/system/zhiyu-boot-success.service" <<'UNIT'
[Unit]
Description=Mark the active slot as successfully booted
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/bin/qbootctl -m

[Install]
WantedBy=multi-user.target
UNIT

printf '%s\n' "$HOST_NAME" > "$target/etc/hostname"
printf 'CHASSIS=tablet\n' > "$target/etc/machine-info"
printf 'LANG=en_US.UTF-8\n' > "$target/etc/locale.conf"
printf '127.0.0.1 localhost %s\n::1 localhost\n' "$HOST_NAME" > "$target/etc/hosts"
ch useradd -m -G wheel "$USERNAME"
printf '%s:%s\n' "$USERNAME" "$PASSWORD" | ch chpasswd
ch passwd -l root
ch systemctl --root=/ disable qbootctl.service
ch systemctl --root=/ enable NetworkManager.service sshd.service bluetooth.service getty@.service chronyd.service \
    hexagonrpcd-adsp-rootpd.service hexagonrpcd-adsp-sensorspd.service \
    zhiyu-sensord.service zhiyu-boot-success.service
if [[ -n "$display_manager" ]]; then
    # Fedora desktop packages can set the alias during installation.
    if ! ch test -e /etc/systemd/system/display-manager.service; then
        ch systemctl --root=/ --force enable "$display_manager"
    fi
    ch systemctl --root=/ set-default graphical.target
else
    ch systemctl --root=/ set-default multi-user.target
fi
ch rpm -q "${board[@]}" mesa-dri-drivers mesa-vulkan-drivers \
    hostname gettext-runtime chrony zram-generator zram-generator-defaults qbootctl qmic qrtr

umount -R "$target/dev"
umount "$target/proc"
trap - EXIT
dnf "${installroot[@]}" clean all
: > "$target/etc/machine-id"

# Preserve file contexts in the archive for the SELinux boot-image variant.
setfiles -F -r "$target" "$target/etc/selinux/targeted/contexts/files/file_contexts" "$target"
out="fedora-$RELEASE-aarch64-$DESKTOP-rootfs.tar.xz"
tar --numeric-owner --acls --xattrs --xattrs-include='*' --selinux \
    -C "$target" -I 'xz -9e -T0' -cpf "$out" .
sha256sum "$out" > "$out.sha256"
