#!/usr/bin/env bash
set -euxo pipefail
# Prepare PXE environment for UEFI/BIOS using ISO files from ./iso
# - Copies bootloaders (PXELINUX/GRUB) into etc/tftp
# - Extracts vmlinuz/initrd from each ./iso/*.iso into etc/tftp/kernels/<ISO_NAME>/
# - Generates UEFI menu (etc/tftp/grub/grub.cfg) and BIOS menu (etc/tftp/pxelinux.cfg/default)
# Requires: .env with HOST_ADDR, HTTP_PORT, ISO_DEFAULT


# ----------------------------- helpers ---------------------------------------
die() { echo "ERROR: $*" >&2; exit 1; }
msg() { echo -e "\033[1;32m[*]\033[0m $*"; }
warn() { echo -e "\033[1;33m[!]\033[0m $*"; }

root="$(cd "$(dirname "$0")/.."; pwd)"

[ -f "$root/.env" ] || die ".env not found in project root"
# shellcheck disable=SC1091
set -a; source "$root/.env"; set +a

HOST_ADDR="${HOST_ADDR:-}"
HTTP_PORT="${HTTP_PORT:-80}"
ISO_DEFAULT="${ISO_DEFAULT:-}"

[ -n "$HOST_ADDR" ] || die "HOST_ADDR is empty in .env"

BASE_URL="http://${HOST_ADDR}"
if [ -n "${HTTP_PORT}" ] && [ "${HTTP_PORT}" != "80" ]; then
  BASE_URL="${BASE_URL}:${HTTP_PORT}"
fi

ETC_TFTP="$root/etc/tftp"
GRUB_DIR="$ETC_TFTP/grub"
PXE_DIR="$ETC_TFTP/pxelinux.cfg"
KERNELS_DIR="$ETC_TFTP/kernels"
ISO_DIR="$root/iso"

mkdir -p "$GRUB_DIR" "$PXE_DIR" "$KERNELS_DIR"

# Prefer host DNS for docker runs
DOCKER_NET=(--network host --dns 1.1.1.1 --dns 8.8.8.8)

# ------------------------- bootloaders stage ---------------------------------
copy_bootloaders_from_host() {
  local ok=0
  if [ -f /usr/lib/PXELINUX/pxelinux.0 ]; then
    msg "Found PXELINUX on host, copying…"
    cp /usr/lib/PXELINUX/pxelinux.0 "$ETC_TFTP"/
    for f in ldlinux.c32 libcom32.c32 libutil.c32 menu.c32 reboot.c32; do
      if [ -f "/usr/lib/syslinux/modules/bios/$f" ]; then
        cp "/usr/lib/syslinux/modules/bios/$f" "$ETC_TFTP"/
      fi
    done
    ok=1
  fi

  if [ -f /usr/lib/grub/x86_64-efi/grubnetx64.efi ]; then
    msg "Found GRUB EFI on host, copying…"
    cp /usr/lib/grub/x86_64-efi/grubnetx64.efi "$ETC_TFTP/grubx64.efi"
    ok=1
  elif [ -f /usr/lib/grub/x86_64-efi-signed/grubnetx64.efi.signed ]; then
    msg "Found signed GRUB EFI on host, copying…"
    cp /usr/lib/grub/x86_64-efi-signed/grubnetx64.efi.signed "$ETC_TFTP/grubx64.efi"
    ok=1
  fi

  if [ -f /usr/share/grub/unicode.pf2 ]; then
    cp /usr/share/grub/unicode.pf2 "$ETC_TFTP/" || true
  fi

  return $ok
}

install_bootloaders_via_docker() {
  msg "Installing bootloaders via docker (ubuntu:24.04)…"
  docker run --rm "${DOCKER_NET[@]}" -v "$ETC_TFTP":/out ubuntu:24.04 bash -lc '
    set -ex
    apt-get -o Acquire::ForceIPv4=true update -qq
    DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::ForceIPv4=true install -y -qq pxelinux syslinux-common grub-efi-amd64-bin grub-common p7zip-full >/dev/null

    cp /usr/lib/PXELINUX/pxelinux.0 /out/pxelinux.0
    for f in ldlinux.c32 libcom32.c32 libutil.c32 menu.c32 reboot.c32; do
      cp "/usr/lib/syslinux/modules/bios/$f" "/out/$f"
    done

    if [ -f /usr/lib/grub/x86_64-efi/grubnetx64.efi ]; then
      cp /usr/lib/grub/x86_64-efi/grubnetx64.efi /out/grubx64.efi
    elif [ -f /usr/lib/grub/x86_64-efi-signed/grubnetx64.efi.signed ]; then
      cp /usr/lib/grub/x86_64-efi-signed/grubnetx64.efi.signed /out/grubx64.efi
    fi

    cp /usr/share/grub/unicode.pf2 /out/unicode.pf2 || true
  '
}

msg "[1/4] Bootloaders"
if ! copy_bootloaders_from_host; then
  warn "Bootloaders not found on host, falling back to docker install"
  install_bootloaders_via_docker
fi

# ------------------------- extraction stage ----------------------------------
extract_with_host_7z() {
  local iso="$1" outdir="$2"
  command -v 7z >/dev/null || command -v 7zz >/dev/null || return 1
  local _7z=$(command -v 7z || command -v 7zz)

  if "$_7z" l "$iso" casper/vmlinuz >/dev/null 2>&1; then
    "$_7z" x -y "$iso" casper/vmlinuz -so > "$outdir/vmlinuz"
    if "$_7z" l "$iso" casper/initrd >/dev/null 2>&1; then
      "$_7z" x -y "$iso" casper/initrd -so > "$outdir/initrd"
    else
      "$_7z" x -y "$iso" casper/initrd.img -so > "$outdir/initrd"
    fi
    return 0
  fi

  if "$_7z" l "$iso" install.amd/vmlinuz >/dev/null 2>&1; then
    "$_7z" x -y "$iso" install.amd/vmlinuz -so   > "$outdir/vmlinuz"
    "$_7z" x -y "$iso" install.amd/initrd.gz -so > "$outdir/initrd"
    return 0
  fi

  if "$_7z" l "$iso" live/vmlinuz >/dev/null 2>&1; then
    "$_7z" x -y "$iso" live/vmlinuz   -so > "$outdir/vmlinuz"
    "$_7z" x -y "$iso" live/initrd.img -so > "$outdir/initrd"
    return 0
  fi

  return 1
}

extract_with_docker() {
  local iso="$1" outdir="$2"
  docker run --rm "${DOCKER_NET[@]}" -v "$root":/work ubuntu:24.04 bash -lc '
    set -e
    apt-get -o Acquire::ForceIPv4=true update -qq
    DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::ForceIPv4=true install -y -qq p7zip-full >/dev/null
    cd /work
    iso="'"$iso"'"
    out="'"$outdir"'"

    if 7z l "$iso" casper/vmlinuz >/dev/null 2>&1; then
      7z x -y "$iso" casper/vmlinuz -so > "$out/vmlinuz"
      if 7z l "$iso" casper/initrd >/dev/null 2>&1; then
        7z x -y "$iso" casper/initrd -so > "$out/initrd"
      else
        7z x -y "$iso" casper/initrd.img -so > "$out/initrd"
      fi
    elif 7z l "$iso" install.amd/vmlinuz >/dev/null 2>&1; then
      7z x -y "$iso" install.amd/vmlinuz -so   > "$out/vmlinuz"
      7z x -y "$iso" install.amd/initrd.gz -so > "$out/initrd"
    elif 7z l "$iso" live/vmlinuz >/dev/null 2>&1; then
      7z x -y "$iso" live/vmlinuz -so    > "$out/vmlinuz"
      7z x -y "$iso" live/initrd.img -so > "$out/initrd"
    else
      echo "ERROR: unsupported ISO layout: $iso" >&2
      exit 1
    fi

    chmod 0644 "$out/vmlinuz" "$out/initrd"
  '
}

msg "[2/4] Extracting kernels from ISO in $ISO_DIR"
shopt -s nullglob
mapfile -t isos < <(ls -1 "$ISO_DIR"/*.iso 2>/dev/null | sort -V || true)
if [ "${#isos[@]}" -eq 0 ]; then
  warn "No ISO files found in $ISO_DIR"
fi

for iso in "${isos[@]}"; do
  name="$(basename "$iso")"
  base="${name%.iso}"
  outdir="$KERNELS_DIR/$base"
  mkdir -p "$outdir"
  msg "  - $name"

  if ! extract_with_host_7z "$iso" "$outdir"; then
    warn "    host 7z not available or layout not matched, using docker…"
    extract_with_docker "$iso" "$outdir"
  fi
done

# ------------------------- GRUB (UEFI) menu ----------------------------------
msg "[3/4] Generating GRUB menu: $GRUB_DIR/grub.cfg"
GRUB_CFG="$GRUB_DIR/grub.cfg"
{
  cat <<'HDR'
set timeout=10
set default=0
if loadfont /unicode.pf2 ; then
  set gfxmode=auto
  terminal_output gfxterm
fi

menuentry 'Reboot' { reboot }
menuentry 'Poweroff' { halt }

HDR

  idx=0
  def_index=0

  for iso in "${isos[@]}"; do
    name="$(basename "$iso")"
    base="${name%.iso}"

    if [[ "$name" == *ubuntu*live-server* ]]; then
      echo "menuentry 'Ubuntu Server (autoinstall) — ${name}' {"
      echo "    linux /kernels/${base}/vmlinuz ip=dhcp cloud-config-url=/dev/null iso-url=${BASE_URL}/iso/${name} autoinstall ds=nocloud-net;s=${BASE_URL}/nocloud/ ---"
      echo "    initrd /kernels/${base}/initrd"
      echo "}"
      (( idx+=1 ))
      [[ "$name" == "$ISO_DEFAULT" ]] && def_index=$((idx-1))

      echo "menuentry 'Manual — ${name}' {"
      echo "    linux /kernels/${base}/vmlinuz ip=dhcp cloud-config-url=/dev/null iso-url=${BASE_URL}/iso/${name} ---"
      echo "    initrd /kernels/${base}/initrd"
      echo "}"
      (( idx+=1 ))

    elif [[ "$name" == *ubuntu*desktop* || "$name" == *xubuntu* ]]; then
      echo "menuentry '${name}' {"
      echo "    linux /kernels/${base}/vmlinuz ip=dhcp boot=casper url=${BASE_URL}/iso/${name} ---"
      echo "    initrd /kernels/${base}/initrd"
      echo "}"
      (( idx+=1 ))
      [[ "$name" == "$ISO_DEFAULT" ]] && def_index=$((idx-1))

    elif [[ "$name" == *kali-linux*installer* ]]; then
      echo "menuentry '${name} (Debian Installer)' {"
      echo "    linux /kernels/${base}/vmlinuz auto=true priority=critical interface=auto ---"
      echo "    initrd /kernels/${base}/initrd"
      echo "}"
      (( idx+=1 ))
      [[ "$name" == "$ISO_DEFAULT" ]] && def_index=$((idx-1))

    else
      echo "menuentry '${name}' {"
      echo "    linux /kernels/${base}/vmlinuz ip=dhcp ---"
      echo "    initrd /kernels/${base}/initrd"
      echo "}"
      (( idx+=1 ))
      [[ "$name" == "$ISO_DEFAULT" ]] && def_index=$((idx-1))
    fi
  done

  echo "set default=${def_index}"
} > "$GRUB_CFG"

# ------------------------- PXELINUX (BIOS) menu ------------------------------
msg "[4/4] Generating PXELINUX menu: $PXE_DIR/default"
PXE_CFG="$PXE_DIR/default"
{
  cat <<'H1'
DEFAULT menu.c32
PROMPT 0
TIMEOUT 100
MENU TITLE PXE Boot Menu
H1

  for iso in "${isos[@]}"; do
    name="$(basename "$iso")"
    base="${name%.iso}"

    if [[ "$name" == *ubuntu*live-server* ]]; then
      cat <<E
LABEL ${base}-auto
  MENU LABEL ${name} (Auto)
  KERNEL kernels/${base}/vmlinuz
  INITRD kernels/${base}/initrd
  APPEND ip=dhcp cloud-config-url=/dev/null iso-url=${BASE_URL}/iso/${name} autoinstall ds=nocloud-net;s=${BASE_URL}/nocloud/ ---

LABEL ${base}-manual
  MENU LABEL ${name} (Manual)
  KERNEL kernels/${base}/vmlinuz
  INITRD kernels/${base}/initrd
  APPEND ip=dhcp cloud-config-url=/dev/null iso-url=${BASE_URL}/iso/${name} ---
E
    elif [[ "$name" == *ubuntu*desktop* || "$name" == *xubuntu* ]]; then
      cat <<E
LABEL ${base}
  MENU LABEL ${name}
  KERNEL kernels/${base}/vmlinuz
  INITRD kernels/${base}/initrd
  APPEND ip=dhcp boot=casper url=${BASE_URL}/iso/${name} ---
E
    elif [[ "$name" == *kali-linux*installer* ]]; then
      cat <<E
LABEL ${base}
  MENU LABEL ${name} (Debian)
  KERNEL kernels/${base}/vmlinuz
  INITRD kernels/${base}/initrd
  APPEND auto=true priority=critical interface=auto ---
E
    else
      cat <<E
LABEL ${base}
  MENU LABEL ${name}
  KERNEL kernels/${base}/vmlinuz
  INITRD kernels/${base}/initrd
  APPEND ip=dhcp ---
E
    fi
  done
} > "$PXE_CFG"

echo
msg "Done."
echo "  Bootloaders: $ETC_TFTP/{pxelinux.0,*.c32,grubx64.efi,unicode.pf2}"
echo "  Kernels:     $KERNELS_DIR/<ISO_NAME>/{vmlinuz,initrd}"
echo "  UEFI menu:   $GRUB_CFG"
echo "  BIOS menu:   $PXE_CFG"
echo
echo "Next steps:"
echo "  docker compose up -d"
echo "  MikroTik DHCP: next-server=${HOST_ADDR}, bootfile BIOS=pxelinux.0, UEFI=grubx64.efi"
