# Wii Linux PC Installer

This tool is designed to install **Wii Linux ArchPOWER** onto an SD Card (and optional USB drive)
from a Linux PC. It handles downloading the necessary files, partitioning the media,
and extracting the filesystem.

For more detailed instructions, please see
[the installation guide](https://wiki.wii-linux.org/wiki/Installation_Guide).

## Important: Read Before Running

This installer performs destructive operations on storage devices. As the script requires
`root` privileges to modify partition tables and filesystems, misuse could damage your host system.
The script will format and erase the device you select. **All data on that device will be
permanently lost**.

You are solely responsible for making sure you select the correct drive (e.g., your SD card, not
your system hard drive). We strongly recommend you read through and understand the steps before
executing the script.

## Features

The installer offers two primary modes of operation. The **Automatic Mode** is designed for fresh
installs; it automatically wipes the target SD card and creates the necessary FAT32 (Boot) and
ext4 (Root) partitions. Alternatively, **Manual Mode** allows you to select specific pre-existing
partitions if you have a custom setup.

To prevent accidents, the script attempts to identify "Removable" devices to help distinguish SD
cards from internal drives. It detects and offers to reuse previously downloaded installation
files to speed up subsequent runs. It also prompts you to configure essential settings such as
the Hostname, SSH, and Network profiles immediately after installation.

## Prerequisites

You will need a Linux system with `root` access, and an SD card (or USB drive) of at least 2GB.
The Wii can only boot from a disk with an MBR partition table; Automatic Mode creates one for you,
and Manual Mode will refuse a GPT disk.

This script requires a **GNU/Linux environment** with GNU coreutils and GNU tar. It will not work
on macOS or FreeBSD. Please install the following dependencies for your distribution before running
the installer. `pv` (progress bars) and `parted` (for `partprobe`) are optional but recommended.

### Debian / Ubuntu / Linux Mint / Pop!_OS

```bash
sudo apt update
sudo apt install util-linux fdisk e2fsprogs dosfstools wget tar pv parted
```

### Arch Linux / Manjaro / Garuda / CachyOS

```bash
sudo pacman -Syu util-linux e2fsprogs dosfstools wget tar pv parted
```

### Fedora / RHEL / Bazzite

```bash
# Note: On immutable systems like Bazzite, run this inside a toolbox or distrobox container
sudo dnf install util-linux e2fsprogs dosfstools wget tar pv parted
```

### Gentoo

```bash
emerge app-arch/tar sys-apps/util-linux sys-fs/e2fsprogs sys-fs/dosfstools net-misc/wget sys-apps/pv sys-block/parted
```

### Alpine Linux

```bash
# Note: Must install GNU tar and GNU coreutils to replace the Busybox equivalents
sudo apk add util-linux e2fsprogs dosfstools wget tar pv parted coreutils
```

## Usage

1. **Clone the repository:**

   ```bash
   git clone https://github.com/Wii-Linux/pc-installer
   cd pc-installer
   ```

2. **Run the installer:**

   ```bash
   sudo ./installer.sh
   ```

3. **Follow the on-screen prompts.**
   If you are unsure about a step, you can usually type `q` to quit safely. The script will
   attempt to clean up temporary mount points if interrupted.

## Tested Modes

| Installation mode   | Tested?       |
| ------------------- | ------------- |
| Automatic, SD Only  | Working       |
| Automatic, SD + USB | Unimplemented |
| Manual, SD Only     | Working       |
| Manual, SD + USB    | Unknown       |

## Tested Host Distros

| Tester    | Platform                      | Testing date | Status  | Additional Notes                  |
| --------- | ----------------------------- | ------------ | ------- | --------------------------------- |
| Techflash | Arch Linux, AMD64 PC          | Dec 03, 2024 | Working | Automatic w/ SD                   |
| Techflash | Debian 12, BeagleBone Black   | Dec 23, 2024 | Working | Manual w/ SD, took a few fixes    |
| Selim     | Ubuntu (24.04 LTS?), AMD64 PC | Dec 19, 2024 | Working | Automatic w/ SD, took a few fixes |

## Troubleshooting

If the script fails with a "Missing required commands" error, please ensure you have installed
the packages listed in the Prerequisites section above.

On systemd systems, the script temporarily stops the `udisks2` service while it partitions and
formats the disk, so your desktop environment doesn't try to mount the new partitions mid-install.
It is started again when the installer finishes or exits. Your desktop's disk and file manager
features may be unavailable until then.

After extraction, the final sync can take several minutes on slow SD cards while the written data
is flushed to the card. This is normal; the write rate is shown while it runs.

## Security Notes

**NetworkManager profiles:** When prompted, the installer can copy Wi-Fi and network profiles
from your host machine to the Wii's root filesystem. These profiles may contain **plaintext
credentials** (Wi-Fi passwords, VPN keys, etc.). Anyone with physical access to the SD card
will be able to read them. Only copy profiles you are comfortable having on removable media.

**Download verification:** Installation tarballs are fetched over HTTPS from `wii-linux.org`.
The connection is encrypted, but the installer does not perform checksum verification of the
downloaded files beyond what TLS provides.

## Community & Support

* **Main Website:** [wii-linux.org](https://wii-linux.org/)
* **Wiki:** [Wii-Linux Wiki](https://wiki.wii-linux.org/)
* **Discord:** [Join our Server](https://discord.com/invite/D9EBdRWzv2) for help and discussion.

## License

This program is distributed under the terms of the GNU General Public License, version 2.

Please see the [LICENSE](LICENSE) file for the full text.

## Disclaimer

This project is distributed in the hope that it will be useful, but **WITHOUT ANY WARRANTY**;
without even the implied warranty of **MERCHANTABILITY** or **FITNESS FOR A PARTICULAR PURPOSE**.
See the [GNU General Public License](https://www.gnu.org/licenses/old-licenses/gpl-2.0.html)
for more details.

**Use at your own risk.** By using this software, you acknowledge that you understand the risks
involved in disk partitioning and formatting. The authors are not responsible for data loss,
hardware damage, or system instability resulting from the use of this software.
