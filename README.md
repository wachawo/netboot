# PXEBoot Linux with Docker Compose + MikroTik

## Description
#### Service for distributing Linux ISO images over the network using PXE and HTTP.
- **TFTP** (pxelinux for BIOS, GRUB EFI for UEFI)
- **HTTP** (serves `/iso` and NoCloud for autoinstall)
- Menu is generated based on the contents of `./iso/` (each ISO is a separate menu item)

## Installation
#### 1. Set HOST and DEFAULT_ISO in `.env`
```bash
nano .env
```
```bash
HOST_ADDR=192.168.88.254
HTTP_PORT=8067
ISO_DIRECTORY=iso
ISO_DEFAULT=ubuntu-24.04.3-live-server-amd64.iso
```

#### 2. Generate a password hash for NoCloud
```bash
openssl passwd -6 'YouPasswordHere'
```

#### 3. Update username and password for autoinstall in ./etc/http/nocloud/user-data
```bash
    username: ubuntu
    password: "YourHashHere"
```

#### 4. Generate kernels/initrd and menu
```bash
bash bin/run.sh
```

#### 5. Start the services
```bash
docker compose up -d
```
#### 6. MikroTik DHCP + PXE setup

#### UEFI
```bash
/ip dhcp-server network set [find where address~"192.168.88.0/24"] next-server=192.168.88.254 boot-file-name=grubx64.efi
```
#### BIOS
```bash
/ip dhcp-server network set [find where address~"192.168.88.0/24"] next-server=192.168.88.254 boot-file-name=pxelinux.0
```
