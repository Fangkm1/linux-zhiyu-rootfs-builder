#!/usr/bin/env bash
set -euo pipefail

[[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { echo "Invalid username" >&2; exit 2; }
[[ "$HOST_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]] || { echo "Invalid hostname" >&2; exit 2; }
[[ "$PACKAGE_REPOSITORY" =~ ^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+$ ]] ||
    { echo "Invalid package repository. Use owner/repo." >&2; exit 2; }
case "${PACKAGE_REPOSITORY#*/}" in .|..) exit 2 ;; esac

case "$DESKTOP" in
    kde) desktop=(@kde-desktop sddm) display_manager=sddm.service ;;
    gnome) desktop=(@gnome-desktop gdm) display_manager=gdm.service ;;
    none) desktop=() display_manager= ;;
    *) exit 2 ;;
esac

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
    linux-zhiyu-images libcamera-zhiyu zhiyu-sensord hexagonrpc
)
dnf "${installroot[@]}" -y install \
    fedora-release fedora-repos fedora-gpg-keys filesystem basesystem \
    systemd systemd-udev systemd-networkd dbus-broker dnf5 \
    selinux-policy-targeted policycoreutils \
    glibc-langpack-en shadow-utils passwd sudo openssh-server \
    NetworkManager NetworkManager-wifi bluez wpa_supplicant \
    pipewire pipewire-alsa pipewire-pulseaudio wireplumber alsa-ucm \
    mesa-dri-drivers mesa-vulkan-drivers \
    ca-certificates git gcc gcc-c++ make meson ninja-build kernel-headers \
    pkgconf-pkg-config systemd-devel protobuf-c-devel protobuf-c-compiler \
    "${board[@]}" "${desktop[@]}"
install -Dm644 "$repo" "$target$repo"

mount --rbind /dev "$target/dev"
mount --make-rslave "$target/dev"
mount -t proc proc "$target/proc"
# Provide DNS while compiling inside the installroot.
install -m644 /etc/resolv.conf "$target/run/zhiyu-build-resolv.conf"
if [[ -e "$target/etc/resolv.conf" || -L "$target/etc/resolv.conf" ]]; then
    mv "$target/etc/resolv.conf" "$target/run/zhiyu-original-resolv.conf"
fi
ln -s /run/zhiyu-build-resolv.conf "$target/etc/resolv.conf"
ch() { chroot "$target" "$@"; }

clone_at() {
    ch git init "$1"
    ch git -C "$1" fetch --depth=1 "$2" "$3"
    ch git -C "$1" checkout --detach FETCH_HEAD
}
clone_at /var/tmp/qmic https://github.com/linux-msm/qmic.git 4574736afce75aa5eec1e1069a19563410167c9f
clone_at /var/tmp/qrtr https://github.com/linux-msm/qrtr.git 29e36ae164389580a0f8ea7a7fdb728140ae978d
clone_at /var/tmp/sensh https://gitlab.com/flamingradian/sensh.git 560b48080283fe73ca5e67635b566177028cebc9
clone_at /var/tmp/qbootctl https://github.com/linux-msm/qbootctl.git 39a6e6daaf029fb0a083777679a15ea2c18f72de
make_install() {
    ch meson setup "$1/build" "$1" --buildtype=release --prefix=/usr --libdir=lib64
    ch meson compile -C "$1/build"
    ch meson install -C "$1/build" --no-rebuild
}
ch make -C /var/tmp/qmic
ch make -C /var/tmp/qmic install
make_install /var/tmp/qrtr
ch ldconfig
ch meson setup /var/tmp/sensh/build /var/tmp/sensh --buildtype=release --prefix=/usr
ch meson compile -C /var/tmp/sensh/build
ch install -Dm755 /var/tmp/sensh/build/sensh /usr/local/bin/sensh
make_install /var/tmp/qbootctl

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
ch systemctl --root=/ enable NetworkManager.service sshd.service bluetooth.service getty@.service \
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
ch rpm -q "${board[@]}" mesa-dri-drivers mesa-vulkan-drivers

umount -R "$target/dev"
umount "$target/proc"
trap - EXIT
rm "$target/etc/resolv.conf" "$target/run/zhiyu-build-resolv.conf"
if [[ -e "$target/run/zhiyu-original-resolv.conf" || -L "$target/run/zhiyu-original-resolv.conf" ]]; then
    mv "$target/run/zhiyu-original-resolv.conf" "$target/etc/resolv.conf"
fi
dnf "${installroot[@]}" clean all
: > "$target/etc/machine-id"
for source in qmic qrtr sensh qbootctl; do rm -r "$target/var/tmp/$source"; done

# Preserve file contexts in the archive for the SELinux boot-image variant.
setfiles -F -r "$target" "$target/etc/selinux/targeted/contexts/files/file_contexts" "$target"
out="fedora-$RELEASE-aarch64-$DESKTOP-rootfs.tar.xz"
tar --numeric-owner --acls --xattrs --xattrs-include='*' --selinux \
    -C "$target" -I 'xz -9e -T0' -cpf "$out" .
sha256sum "$out" > "$out.sha256"
