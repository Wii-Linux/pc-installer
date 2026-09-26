#!/bin/sh
set -e
product=$(printf '\033[33mWii Linux \033[1;36mArchPOWER\033[0m PC Installer')
product_plain="Wii Linux ArchPOWER PC Installer"
version="0.0.6"
printf "%s v%s\n" "$product" "$version"

if [ "$(id -u)" != "0" ]; then
	printf "\033[1;31mThis installer must be run as root!\033[0m\n"
	exit 1
fi

boot_blkdev=""
boot_mnt=""
rootfs_blkdev=""
rootfs_mnt=""
all_bdevs=""
separate_sd_and_rootfs=""


selection=""
selection_info=""

bug_report() {
	exec >&2
	printf 'Please attach everything below this line!\n'
	printf "=== %s - BUG REPORT ===\n" "$product_plain"
	printf 'VERSION: %s\n' "$version"
	for arg in "$@"; do
		printf '%s\n' "$arg"
	done
	printf '=== END OF BUG REPORT ===\n'
	printf 'Now exiting.  Please attach the following bug report and submit a GitHub issue.\n'
	exit 1
}

cleanup() {
	# Only attempt cleanup if variables are set
	if [ -n "$boot_mnt" ] && [ -d "$boot_mnt" ]; then
		if mountpoint -q "$boot_mnt" 2>/dev/null; then
			umount "$boot_mnt" 2>/dev/null || true
		fi
		rmdir "$boot_mnt" 2>/dev/null || true
	fi

	if [ -n "$rootfs_mnt" ] && [ -d "$rootfs_mnt" ]; then
		if mountpoint -q "$rootfs_mnt" 2>/dev/null; then
			umount "$rootfs_mnt" 2>/dev/null || true
		fi
		rmdir "$rootfs_mnt" 2>/dev/null || true
	fi
}
# On INT/TERM, just exit: the EXIT trap then runs cleanup exactly once.
# (Trapping INT with cleanup itself would return to the interrupted code
# afterward instead of stopping, and run cleanup a second time on exit.)
trap cleanup EXIT
trap "exit 1" INT TERM

# Called as 'read -r var || input_closed'.  On end of input (Ctrl+D or a
# closed stdin), read fails: under set -e that would kill the script with no
# explanation, and ignoring it would make menu loops spin forever on empty
# input, so exit cleanly instead.
input_closed() {
	printf '\n\033[1;33mNo input received; installation cancelled.\033[0m\n'
	exit 1
}

rescan_bdevs() {
	all_bdevs=$(find /sys/block/ -mindepth 1 -maxdepth 1 \
		! -name "loop*" ! -name "sr*" ! -name "ram*" ! -name "zram*" \
		! -name "dm-*" ! -name "md*" -exec basename {} \; | sort)
}


formatSize() {
	size=$1
	suffix="K"
	while [ "$size" -ge "1024" ]; do
		size=$((size / 1024))
		case $suffix in
			"K") suffix="M" ;;
			"M") suffix="G" ;;
			"G") suffix="T" ;;
		esac
	done

	printf '%s%s\n' "$size" "$suffix"
}

select_disk() {
	i=1
	for dev in $all_bdevs; do
		size=$(cat "/sys/block/$dev/size")
		size=$((size / 2))
		size=$(formatSize "$size")

		printf '[%s] /dev/%s - %s\n' "$i" "$dev" "$size"
		i=$((i + 1))
	done
	i=1

	echo
	printf "Select a disk: "
	read -r devnum || input_closed

	for dev in $all_bdevs; do
		if [ "$i" = "$devnum" ]; then
			selection=$dev
			return 0
		fi
		i=$((i + 1))
	done

	return 1
}


get_parts() {
	find "/sys/block/$1/" -mindepth 1 -maxdepth 1 -name "${1}*" -exec basename {} \; | sort -V
}

select_part() {
	all_parts=$(get_parts "$1")

	i=1
	for part in $all_parts; do
		size=$(cat "/sys/block/$1/$part/size")
		size=$((size / 2))
		size="$(formatSize "$size")"

		printf '[%s] /dev/%s - %s\n' "$i" "$part" "$size"
		i=$((i + 1))
	done
	i=1

	echo
	printf "Select a partition: "
	read -r partnum || input_closed

	for part in $all_parts; do
		if [ "$i" = "$partnum" ]; then
			selection=$part

			# give caller the partition size (in KiB)
			selection_info=$(cat "/sys/block/$1/$part/size")
			selection_info=$((selection_info / 2))

			return 0
		fi
		i=$((i + 1))
	done

	return 1
}


# $1 = "root" or "boot"
validate_part_selection() {
	# sanity checks

	if [ "$1" = "root" ]; then
		size="$((1536 * 1024))" # 1.5GB (see the disk size minimum in automatic_install)
		size_readable="1.5GB"
		name="rootfs"
		name2="rootfs"
		correct_type="ext4"
	elif [ "$1" = "boot" ]; then
		size="$((256 * 1024))" # 256MB
		size_readable="256MB"
		name="boot files"
		name2="boot"
		correct_type="vfat"
	else
		printf "\033[1;31mInternal error - parameter 1 not boot or root\033[0m\n"
		bug_report "Step: validate_part" "Param1: $1"
	fi

	# size >=256M for boot or >=1.5GB for root?
	if [ "$selection_info" -lt "$size" ]; then
		printf '\033[1;31mThis partition is not large enough to hold the %s!\nIt should be %s or larger.\033[0m\n' "$name" "$size_readable"
		return 1
	fi

	# is vfat?
	(
		fstype=$(blkid -s TYPE -o value "/dev/$selection" 2>/dev/null || true)
		if [ "$fstype" != "$correct_type" ]; then
			printf '\033[1;33mWe must \033[31mFORMAT\033[33m this partition in order to make it usable for a %s partition.\n' "$name2"
			printf "Are you \033[31mSURE\033[33m that you want to \033[31mFORMAT\033[33m this partition, and lose \033[31mALL DATA\033[33m on it?\033[0m [y/N] "

			read -r yesno || input_closed
			case $yesno in
				y|Y|yes|YES)
					if [ "$1" = "root" ]; then
						mkfs.ext4 -O '^encrypt' -O '^verity' -O '^metadata_csum_seed' -L 'arch' "/dev/$selection"
					elif [ "$1" = "boot" ]; then
						mkfs.vfat -F 32 "/dev/$selection"
					fi
					ret="$?"

					if [ "$ret" != "0" ]; then
						printf '\033[1;31mFATAL ERROR - Failed to format %s partition!\033[0m\n' "$name2"
						bug_report "Step: format_part" "Return code: $ret"
					fi

					printf "\033[32mPartition formatted!\033[0m\n"
					;;
				n|N|no|NO)   return 2 ;;
				*)           return 3 ;;
			esac
		fi
	)

	ret="$?"
	if [ "$ret" = "0" ]; then
		return 0
	elif [ "$ret" = "1" ]; then
		# failed format
		exit 1
	elif [ "$ret" = "3" ] || [ "$ret" = "2" ]; then
		# invalid option / not confirmed
		return 1
	else
		# ???
		bug_report "Step: validate_$1" "Return code: $ret"
	fi
}

validate_and_select_part() {
	while true; do
		select_part "$1" || {
			_rc="$?"
			case "$_rc" in
				1) printf "\033[1;31mInvalid option, please try again\033[0m\n"; continue ;;
				*)
					printf "\033[1;31mInternal error.  Please report the following info.\033[0m\n"
					bug_report "Step: select_part" "Return code: $_rc" ;;
			esac
		}

		validate_part_selection "$2" || {
			_rc="$?"
			case "$_rc" in
				1) printf "\033[1;31mInvalid option, please try again\033[0m\n"; continue ;;
				2) printf "\033[1;31mNot confirmed.\033[0m\n"; continue ;;
				*)
					printf "\033[1;31mInternal error.  Please report the following info.\033[0m\n";
					bug_report "Step: validate_part" "Return code: $_rc" ;;
			esac
		}

		printf "\033[32mPartition validated!\033[0m\n"
		break
	done
}

select_root_disk() {
	while true; do
		printf "\033[33mYou can store \033[32mthe rootfs\033[33m (the actual system files and user data) on a different device.\n"
		printf "This, however, is highly experimental, and will disable the auto-partitioning feature of this script.\n"
		printf "Would you like to store the boot files and rootfs on separate devices?\033[0m [y/N] "
		read -r yesno || input_closed
		case "$yesno" in
			y|Y|yes|YES) separate_sd_and_rootfs=true; break ;;
			n|N|no|NO|"") separate_sd_and_rootfs=false; break ;;
			*) printf "\033[1;31mInvalid option, please try again\033[0m\n" ;;
		esac
	done

	if [ "$separate_sd_and_rootfs" = "true" ]; then
		while ! select_disk; do
			printf "\033[1;31mInvalid option, please try again\033[0m\n"
			rescan_bdevs
		done
		rootfs_blkdev="$selection"
	else
		rootfs_blkdev="$boot_blkdev"
	fi
}

clean_disk() {
	for dev in $(get_parts "$1") "$1"; do
		if grep -qw "/dev/$dev" /proc/mounts; then
			umount "/dev/$dev" || {
				ret=$?
				printf '\033[1;31mFATAL ERROR: Failed to unmount /dev/%s\033[0m\n' "$dev"
				bug_report "Step: auto_install_unmount" "Return code: $ret"
			}
		fi

		# known unmounted successfully
		wipefs -a "/dev/$dev"
	done
}

mount_in_tmpdir_or_die() {
	tmp="$(mktemp -d /tmp/wii-linux-installer.XXXXXX)" || {
		ret="$?"

		printf "\033[1;31mFATAL ERROR: Failed to create temporary directory\033[0m\n"
		bug_report "Step: mount_in_tmpdir__make_tmpdir" "Return code: $ret"
	}

	mount "$1" "$tmp" || {
		ret="$?"
		printf '\033[1;31mFATAL ERROR: Failed to mount %s\033[0m\n' "$1"
		[ -d "$tmp" ] && rmdir "$tmp" || true

		bug_report "Step: mount_in_tmpdir__do_mnt" "Return code: $ret" "To be mounted: $1" "TempDir: $tmp"
	}

	# success
	printf '%s\n' "$tmp"
}

# Portable udev settle: tries udevadm first, falls back to mdev on systems
# that use it instead. Callers should still follow up with a sleep if needed.
settle_udev() {
	if command -v udevadm >/dev/null 2>&1; then
		udevadm settle --timeout=10 2>/dev/null || true
	elif command -v mdev >/dev/null 2>&1; then
		mdev -s 2>/dev/null || true
	fi
}



install_boot() {
	printf 'Now downloading the boot files...\n'
	tarball_name="wii_linux_sd_files_archpower-latest.tar.gz"
	if ! wget --continue "https://wii-linux.org/files/$tarball_name"; then
		printf "\033[1;31mFATAL ERROR: Failed to download boot files.\033[0m\n"
		exit 1
	fi

	boot_mnt="$(mount_in_tmpdir_or_die "$boot_blkdev")"
	printf 'Now installing the boot files...\n'
	tar xzf "$tarball_name" -C "$boot_mnt/"
}

install_root() {
	tarball_name="wii_linux_rootfs_archpower-latest.tar.gz"
	printf 'Now downloading the rootfs...\n'
	if ! wget --continue "https://wii-linux.org/files/$tarball_name"; then
		printf "\033[1;31mFATAL ERROR: Failed to download rootfs.\033[0m\n"
		exit 1
	fi

	rootfs_mnt="$(mount_in_tmpdir_or_die "$rootfs_blkdev")"
	printf 'Now installing the rootfs... (this will take a VERY long time on most storage media)\n'
	tar -x --acls --xattrs --same-owner --same-permissions --numeric-owner --sparse -f "$tarball_name" -C "$rootfs_mnt/"
	sync "$rootfs_mnt"
}


do_configure() {
	printf "\033[32mSuccess!  Your Wii Linux install has been written to disk!\n"
	printf "It's now time to configure your install, if you would like to.\033[0m\n"

	while true; do
		# discard any double-enter taps or similar
		timeout 0.1 dd if=/dev/stdin bs=1 count=10000 of=/dev/null 2>/dev/null || true
		printf "\033[33mWould you like to copy NetworkManager profiles from your host system?\033[0m [Y/n] "
		read -r yesno || input_closed
		case "$yesno" in
			y|Y|yes|YES|"") copy_nm=true ;;
			n|N|no|NO) copy_nm=false ;;
			*) printf "\033[1;31mInvalid answer!  Please try again.\033[0m\n"; continue ;;
		esac
		break
	done

	if [ "$copy_nm" = "true" ]; then
		if [ -d /etc/NetworkManager/system-connections ] &&
		! [ -z "$(ls -A /etc/NetworkManager/system-connections)" ]; then
			cp -a /etc/NetworkManager/system-connections/* "$rootfs_mnt/etc/NetworkManager/system-connections/"
		fi
	fi

	while true; do
		# discard any double-enter taps or similar
		timeout 0.1 dd if=/dev/stdin bs=1 count=10000 of=/dev/null 2>/dev/null || true
		printf "\033[33mWould you like to enable the SSH daemon to start automatically for remote login?\033[0m [Y/n] "
		read -r yesno || input_closed
		case "$yesno" in
			y|Y|yes|YES|"") ssh=true ;;
			n|N|no|NO) ssh=false ;;
			*) printf "\033[1;31mInvalid answer!  Please try again.\033[0m\n"; continue ;;
		esac
		break
	done

	if [ "$ssh" = "true" ]; then
		ln -sf "/usr/lib/systemd/system/sshd.service" "$rootfs_mnt/etc/systemd/system/multi-user.target.wants/sshd.service"
	fi

	# TODO: More here.... set up user account?
}

unmount_and_cleanup() {
	printf "\033[32mSuccess!  Now syncing to disk and cleaning up, please wait...\033[0m\n"
	umount "$boot_mnt" || {
		ret=$?
		printf "\033[1;31mFATAL ERROR: Failed to unmount boot partition.\033[0m\n"
		bug_report "Step: unmount_and_cleanup_boot" "Return code: $ret" "Boot mnt: $boot_mnt" "Root mnt: $rootfs_mnt"
	}

	rmdir "$boot_mnt" || {
		ret=$?
		printf "\033[1;31mFATAL ERROR: Failed to delete temporary mount for boot partition.\033[0m\n"
		bug_report "Step: unmount_and_cleanup_boot" "Return code: $ret" "Boot mnt: $boot_mnt" "Root mnt: $rootfs_mnt"
	}

	umount "$rootfs_mnt" || {
		ret=$?
		printf "\033[1;31mFATAL ERROR: Failed to unmount rootfs.\033[0m\n"
		bug_report "Step: unmount_and_cleanup_root" "Return code: $ret" "Boot mnt: $boot_mnt" "Root mnt: $rootfs_mnt"
	}

	rmdir "$rootfs_mnt" || {
		ret=$?
		printf "\033[1;31mFATAL ERROR: Failed to delete temporary mount for rootfs.\033[0m\n"
		bug_report "Step: unmount_and_cleanup_root" "Return code: $ret" "Boot mnt: $boot_mnt" "Root mnt: $rootfs_mnt"
	}
}

manual_install() {
	# The Wii's FAT drivers (libfat in the Homebrew Channel, FatFs in BootMii)
	# only read MBR partition tables, so a GPT boot disk would install without
	# error and then never boot.  Automatic mode always writes an MBR table.
	pttype=$(blkid -p -s PTTYPE -o value "/dev/$boot_blkdev" 2>/dev/null || true)
	if [ -n "$pttype" ] && [ "$pttype" != "dos" ]; then
		printf '\033[1;31mThe SD card / boot disk uses a %s partition table, but the Wii can only boot from MBR.\033[0m\n' "$pttype"
		printf "Repartition it with an MBR (DOS) partition table, or restart the installer and\nchoose automatic mode (which repartitions the whole disk).\n"
		exit 1
	fi

	printf "\033[33mWe now need to know \033[32mwhat partition to store the boot files\033[33m in.\033[0m\n"
	validate_and_select_part "$boot_blkdev" "boot"
	boot_blkdev="/dev/$selection"

	printf "\033[33mWe now need to know \033[32mwhat partition to store the root filesystem\033[33m in.\033[0m\n"
	validate_and_select_part "$rootfs_blkdev" "root"
	rootfs_blkdev="/dev/$selection"

	install_boot

	printf 'Wiping rootfs...\n'

	wipefs -a "$rootfs_blkdev" && mkfs.ext4 -O '^encrypt' -O '^verity' -O '^metadata_csum_seed' -L 'arch' "$rootfs_blkdev" || {
		ret="$?"
		printf "\033[1;31mFailed to format rootfs!\033[0m\n"
		bug_report "Step: rootfs_format" "Return code: $ret" "Root blkdev: $rootfs_blkdev"
	}
	install_root

	do_configure

	unmount_and_cleanup
}

automatic_install() {
	# currently, boot_blkdev is our SD Card.
	# Let's unmount and erase any partitions on it before we try to repartition
	sd_blkdev="$boot_blkdev"

	sys_size=$(cat "/sys/block/$sd_blkdev/size" 2>/dev/null || printf '0')
	total_mb=$((sys_size / 2048))

	# The Wii requires an MBR partition table, which has a strict 2TB limit.
	if [ "$total_mb" -gt 2097152 ]; then
		printf "\033[1;33mWarning: This drive is larger than 2TB.\nThe Wii (and MBR partition tables) only support up to 2TB.\nOnly the first 2TB of this drive will be used.\033[0m\n"
		total_mb=2097152
	fi

	# Minimum space required: 256MB boot + 1536MB (1.5GB) rootfs + 2MB partition
	# table overhead = 1794MB.  This lets a "2GB" card (2,000,000,000 bytes,
	# about 1907MiB) hold a minimal install.
	if [ "$total_mb" -lt 1794 ]; then
		printf "\033[1;31mError: This disk is too small. At least 1.8GB of space is required.\033[0m\n"
		exit 1
	fi

	max_fat_mb=$((total_mb - 1536 - 2))

	printf 'Cleaning disk...\n'
	clean_disk "$sd_blkdev"

	fatSize=""
	while true; do
		printf "\033[33mHow many MB of space would you like to reserve for the \033[32mFAT32 Boot files / Homebrew partition\033[33m?\033[0m [default:256, max:%s] " "$max_fat_mb"
		read -r fatSz || input_closed
		case "$fatSz" in
			*[!0-9]*) printf "\033[1;31mInvalid input!  Please type a number.\033[0m\n"; continue ;;
			'') fatSize="256" ;;
			*)
				# valid number
				fatSize="$fatSz"
		esac
		unset fatSz

		if [ "$fatSize" -lt 256 ]; then
			printf "\033[1;31mThe boot partition must be at least 256 MB!\033[0m\n"
			continue
		fi

		if [ "$fatSize" -gt "$max_fat_mb" ]; then
			printf "\033[1;31mThe requested size leaves less than 1.5GB for the root filesystem!\nMaximum allowed is %s MB.\033[0m\n" "$max_fat_mb"
			continue
		fi

		break
	done

	printf 'Repartitioning...\n'

	# Calculate partition sizes in sectors
	fat_sectors=$((fatSize * 2048))

	# If the drive was artificially capped at 2TB, sfdisk needs explicit size instructions
	# for the second partition to prevent it from failing by trying to span past the MBR limit.
	if [ "$total_mb" -eq 2097152 ]; then
		root_sectors=$(( (2097152 - fatSize - 2) * 2048 ))
		cat << EOF | sfdisk "/dev/$sd_blkdev" || { printf "\033[1;31mFATAL ERROR: Failed to partition disk\033[0m\n" >&2; exit 1; }
label: dos
start=2048, size=$fat_sectors, type=c, bootable
type=83, size=$root_sectors
EOF
	else
		# Create partition table with sfdisk
		cat << EOF | sfdisk "/dev/$sd_blkdev" || { printf "\033[1;31mFATAL ERROR: Failed to partition disk\033[0m\n" >&2; exit 1; }
label: dos
start=2048, size=$fat_sectors, type=c, bootable
type=83
EOF
	fi

	printf 'Synchronizing partition table with kernel...\n'
	partprobe "/dev/$sd_blkdev" 2>/dev/null || true
	settle_udev

	# Derive partition names: devices ending in a digit (e.g. mmcblk0, nvme0n1)
	# use a 'p' separator (mmcblk0p1), others just append the number (sda1)
	case "$sd_blkdev" in
		*[0-9])
			boot_blkdev="/dev/${sd_blkdev}p1"
			rootfs_blkdev="/dev/${sd_blkdev}p2"
			;;
		*)
			boot_blkdev="/dev/${sd_blkdev}1"
			rootfs_blkdev="/dev/${sd_blkdev}2"
			;;
	esac

	# Wait for partition device nodes to appear; slow SD cards and USB
	# adapters can take a moment after partprobe and device settle.
	printf 'Waiting for partitions to initialize...\n'
	_wait=0
	while [ "$_wait" -lt 10 ]; do
		[ -b "$boot_blkdev" ] && [ -b "$rootfs_blkdev" ] && break
		sleep 1
		_wait=$((_wait + 1))
	done
	if [ ! -b "$boot_blkdev" ] || [ ! -b "$rootfs_blkdev" ]; then
		printf "\033[1;31mFATAL ERROR: Partition device nodes did not appear after partitioning.\033[0m\n" >&2
		exit 1
	fi

	printf 'Formatting...\n'
	mkfs.vfat -F 32 "$boot_blkdev" && mkfs.ext4 -O '^encrypt' -O '^verity' -O '^metadata_csum_seed' -L 'arch' "$rootfs_blkdev" || {
		ret="$?"
		printf "\033[1;31mFailed to format partitions!\033[0m\n"
		bug_report "Step: auto_format" "Return code: $ret" "Boot blkdev: $boot_blkdev" "Root blkdev: $rootfs_blkdev"
	}

	install_boot
	install_root

	do_configure

	unmount_and_cleanup
}
# ====
# Start of the actual installer process
# ====
printf 'We need to gather some info about where you would like to install to...\n'
rescan_bdevs

printf "\033[33mWe now need to know where your \033[32mSD Card\033[33m is.\033[0m\n"
while ! select_disk; do
	printf "\033[1;31mInvalid option, please try again\033[0m\n"
	rescan_bdevs
done
boot_blkdev="$selection"

select_root_disk

if [ "$separate_sd_and_rootfs" = "false" ]; then
	while true; do
		printf "\033[33mWould you like \033[32m[A]utomatic\033[33m or \033[32m[M]anual\033[33m install?\033[0m "
		read -r doauto || input_closed
		case "$doauto" in
			a|A|auto|Auto|AUTO|automatic|Automatic|AUTOMATIC) automatic_install ;;
			m|M|man|Man|MAN|manual|Manual|MANUAL) manual_install ;;
			*) printf "\033[1;31mInvalid option, please try again\033[0m\n"; continue ;;
		esac
		break
	done
else
	manual_install
fi

printf "\033[1;32mSUCCESS!!  If you're reading this, your Wii Linux install is complete!\033[0m\n"
