#!/bin/sh
set -e
product="\033[33mWii Linux \033[1;36mArchPOWER\033[0m PC Installer"
version="0.0.6"
printf "$product v$version\n"

if [ "$(id -u)" != "0" ]; then
	printf "\033[1;31mThis installer must be run as root!\033[0m\n"
	exit 1
fi

boot_blkdev=""
boot_mnt=""
rootfs_blkdev=""
rootfs_mnt=""
all_bdevs=""
seperate_sd_and_rootfs=""


selection=""
selection_info=""

bug_report() {
	exec >&2
	echo "Please attach everything below this line!"
	printf "=== $product - BUG REPORT ===\n"
	echo "VERSION: $version"
	for arg in "$@"; do
		printf "$arg\n"
	done
	echo "=== END OF BUG REPORT ==="
	echo "Now exiting.  Please attach the following bug report and submit a GitHub issue."
	exit 1
}

rescan_bdevs() {
	all_bdevs=$(find /sys/block/ -mindepth 1 -maxdepth 1 \
		! -name "loop*" ! -name "sr*" ! -name "ram*" ! -name "zram*" -exec basename {} \;)
}


formatSize() {
	size=$1
	while [ "$size" -gt "1000" ]; do
		size=$((size / 1000))
		case $suffix in
			"") suffix="K" ;;
			"K") suffix="M" ;;
			"M") suffix="G" ;;
			"G") suffix="T" ;;
		esac
	done

	echo "${size}${suffix}"
}

select_disk() {
	i=1
	for dev in $all_bdevs; do
		size=$(cat "/sys/block/$dev/size")
		size=$((size * 512))
		size=$(formatSize $size)

		echo "[$i] /dev/$dev - $size"
		i=$((i + 1))
	done
	i=1

	echo
	printf "Select a disk: "
	read -r devnum

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
	find "/sys/block/$1/" -mindepth 1 -maxdepth 1 -name "${1}*" -exec basename {} \; | sort
}

select_part() {
	all_parts=$(get_parts "$1")

	i=1
	for part in $all_parts; do
		size=$(cat "/sys/block/$1/$part/size")
		size=$((size * 512))
		size="$(formatSize "$size")"

		echo "[$i] /dev/$part - $size"
		i=$((i + 1))
	done
	i=1

	echo
	printf "Select a partition: "
	read -r partnum

	for part in $all_parts; do
		if [ "$i" = "$partnum" ]; then
			selection=$part

			# give caller the partition size
			selection_info=$(cat "/sys/block/$1/$part/size")
			selection_info=$((selection_info * 512))

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
		size="$((2 * 1024 * 1024 * 1024))"
		size_readable="2GB"
		name="rootfs"
		name2="rootfs"
		correct_type="ext4"
	elif [ "$1" = "boot" ]; then
		size="$((256 * 1024 * 1024))"
		size_readable="256MB"
		name="boot files"
		name2="boot"
		correct_type="vfat"
	else
		printf "\033[1;31mInternal error - parameter 1 not boot or root"
		bug_report "Step: validate_part" "Param1: $1"
	fi

	# size >=256M for boot or >=2GB for root?
	if [ "$selection_info" -lt "$size" ]; then
		printf "\033[1;31mThis partition is not large enough to hold the $name!\nIt should be $size_readable or larger.\033[0m\n"
		return 1
	fi

	# is vfat?
	(
		eval "$(blkid --output=export "/dev/$selection")"
		if [ "$TYPE" != "$correct_type" ]; then
			printf "\033[1;33mWe must \033[31mFORMAT\033[33m this partition in order to make it usable for a $name2 partition.\n"
			printf "Are you \033[31mSURE\033[33m that you want to \033[31mFORMAT\033[33m this partition, and lose \033[31mALL DATA\033[33m on it?\033[0m [y/N] "

			read -r yesno
			case $yesno in
				y|Y|yes|YES)
					if [ "$1" = "root" ]; then
						mkfs.ext4 -O '^verity' -O '^metadata_csum_seed' -L 'arch' "/dev/$selection"
					elif [ "$1" = "boot" ]; then
						mkfs.vfat -F 32 "/dev/$selection"
					fi
					ret="$?"

					if [ "$ret" != "0" ]; then
						printf "\033[1;31mFATAL ERROR - Failed to format $name2 partition!\033[0m\n"
						bug_report "Step: format_part" "Return code: $?"
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
			case "$?" in
				1) printf "\033[1;31mInvalid option, please try again\033[0m\n"; continue ;;
				*)
					printf "\033[1;31mInternal error.  Please report the following info.\033[0m\n"
					bug_report "Step: select_part" "Return code: $ret" ;;
			esac
		}

		validate_part_selection "$2" || {
			case "$?" in
				1) printf "\033[1;31mInvalid option, please try again\033[0m\n"; continue ;;
				2) printf "\033[1;31mNot confirmed.\033[0m\n"; continue ;;
				*)
					printf "\033[1;31mInternal error.  Please report the following info.\033[0m\n";
					bug_report "Step: validate_part" "Return code: $ret" ;;
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
		printf "Would you like to store the boot files and rootfs on seperate devices?\033[0m [y/N] "
		read -r yesno
		case "$yesno" in
			y|Y|yes|YES) seperate_sd_and_rootfs=true; break ;;
			n|N|no|NO|"") seperate_sd_and_rootfs=false; break ;;
			*) printf "\033[1;31mInvalid option, please try again\033[0m\n" ;;
		esac
	done

	if [ "$seperate_sd_and_rootfs" = "true" ]; then
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
			umount "/dev/$dev"
			ret="$?"

			if [ "$ret" != "0" ]; then
				printf "\033[1;31mFATAL ERROR: Failed to unmount /dev/$dev\033[0m\n"
				bug_report "Step: auto_install_unmount" "Return code: $ret"
			fi
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
		printf "\033[1;31mFATAL ERROR: Failed to mount $1\033[0m\n"
		[ -d "$tmp" ] && rmdir "$tmp" || true

		bug_report "Step: mount_in_tmpdir__do_mnt" "Return code: $ret" "To be mounted: $1" "TempDir: $tmp"
	}

	# success
	echo "$tmp"
}



install_boot() {
	echo "Now downloading the boot files..."
	tarball_name="wii_linux_sd_files_archpower-latest.tar.gz"
	if ! wget --continue "https://wii-linux.org/files/$tarball_name"; then
		printf "\033[1;31mFATAL ERROR: Failed to download boot files.\033[0m\n"
		exit 1
	fi

	boot_mnt="$(mount_in_tmpdir_or_die "$boot_blkdev")"
	echo "Now installing the boot files..."
	tar xzf "$tarball_name" -C "$boot_mnt/"
}

install_root() {
	tarball_name="wii_linux_rootfs_archpower-latest.tar.gz"
	echo "Now downloading the rootfs..."
	if ! wget --continue "https://wii-linux.org/files/$tarball_name"; then
		printf "\033[1;31mFATAL ERROR: Failed to download rootfs.\033[0m\n"
		exit 1
	fi

	rootfs_mnt="$(mount_in_tmpdir_or_die "$rootfs_blkdev")"
	echo "Now installing the rootfs... (this will take a VERY long time on most storage media)"
	tar -xP --acls --xattrs --same-owner --same-permissions --numeric-owner --sparse -f "$tarball_name" -C "$rootfs_mnt/"
	sync "$rootfs_mnt"
}


do_configure() {
	printf "\033[32mSuccess!  Your Wii Linux install has been written to disk!\n"
	printf "It's now time to configure your install, if you would like to.\033[0m\n"

	while true; do
		# discard any double-enter taps or similar
		timeout 0.1 dd if=/dev/stdin bs=1 count=10000 of=/dev/null 2>/dev/null || true
		printf "\033[33mWould you like to copy NetworkManager profiles from your host system?\033[0m [Y/n] "
		read -r yesno
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
		read -r yesno
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
	printf "\033[32mSuccess!  Now syncing to disk and cleaning up, please wait...\n"
	umount "$boot_mnt" || {
		printf "\033[1;31mFATAL ERROR: Failed to unmount boot partition.\033[0m\n"
		bug_report "Step: unmount_and_cleanup_boot" "Return code: $ret" "Boot mnt: $boot_mnt" "Root mnt: $rootfs_mnt"
	}

	rmdir "$boot_mnt" || {
		printf "\033[1;31mFATAL ERROR: Failed to delete temporary mount for boot partition.\033[0m\n"
		bug_report "Step: unmount_and_cleanup_boot" "Return code: $ret" "Boot mnt: $boot_mnt" "Root mnt: $rootfs_mnt"
	}

	umount "$rootfs_mnt" || {
		printf "\033[1;31mFATAL ERROR: Failed to unmount rootfs.\033[0m\n"
		bug_report "Step: unmount_and_cleanup_root" "Return code: $ret" "Boot mnt: $boot_mnt" "Root mnt: $rootfs_mnt"
	}

	rmdir "$rootfs_mnt" || {
		printf "\033[1;31mFATAL ERROR: Failed to delete temporary mount for rootfs.\033[0m\n"
		bug_report "Step: unmount_and_cleanup_root" "Return code: $ret" "Boot mnt: $boot_mnt" "Root mnt: $rootfs_mnt"
	}
}

manual_install() {
	printf "\033[33mWe now need to know \033[32mwhat partition to store the boot files\033[33m in.\033[0m\n"
	validate_and_select_part "$boot_blkdev" "boot"
	boot_blkdev="/dev/$selection"

	printf "\033[33mWe now need to know \033[32mwhat partition to store the root filesystem\033[33m in.\033[0m\n"
	validate_and_select_part "$rootfs_blkdev" "root"
	rootfs_blkdev="/dev/$selection"

	install_boot

	echo "Wiping rootfs..."

	wipefs -a "$rootfs_blkdev" && mkfs.ext4 -O '^verity' -O '^metadata_csum_seed' -L 'arch' "$rootfs_blkdev" || {
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
	# Let's unmount and erase any partitons on it before we try to repartition
	sd_blkdev="$boot_blkdev"

	echo "Cleaning disk..."
	clean_disk "$sd_blkdev"

	fatSize=""
	while true; do
		printf "\033[33mHow many MB of space would you like to reserve for the \033[32mFAT32 Boot files / Homebrew partiton\033[33m?\033[0m [default:256] "
		read -r fatSz
		case "$fatSz" in
			*[!0-9]*) printf "\033[1;31mInvalid input!  Please type a number.\033[0m\n"; continue ;;
			'') fatSize="+256M" ;;
			*)
				# valid number
				fatSize="+${fatSz}M"
		esac
		unset fatSz
		break
	done

	echo "Repartitioning..."
	cat << EOF | fdisk "/dev/$sd_blkdev" > /dev/null
o
n
p
1

$fatSize
n
p
2


w
EOF

	# set up a loop device so we get a consistent partition scheme of /dev/loopXp#
	loopdev="$(losetup --direct-io=on --show -P -f "/dev/$sd_blkdev")" && [ "$loopdev" != "" ] || {
		ret="$?"
		printf "\033[1;31mLoop device creation failed!\033[0m\n"
		bug_report "Step: loopdev_create" "Return code: $ret"
	}

	echo "Giving the kernel a few seconds to populate the partition table"
	sync
	sleep 3

	boot_blkdev="${loopdev}p1"
	rootfs_blkdev="${loopdev}p2"

	echo "Fomatting..."
	mkfs.vfat -F 32 "$boot_blkdev" && mkfs.ext4 -O '^verity' -O '^metadata_csum_seed' -L 'arch' "$rootfs_blkdev" || {
		ret="$?"
		printf "\033[1;31mFailed to format loopdev!\033[0m\n"
		bug_report "Step: loopdev_format" "Return code: $ret" "Boot blkdev: $boot_blkdev" "Root blkdev: $rootfs_blkdev"
	}

	install_boot
	install_root

	do_configure

	unmount_and_cleanup
	losetup -d "$loopdev"
}
# ====
# Start of the actual installer process
# ====
echo "We need to gather some info about where you would like to install to..."
rescan_bdevs

printf "\033[33mWe now need to know where your \033[32mSD Card\033[33m is.\033[0m\n"
while ! select_disk; do
	printf "\033[1;31mInvalid option, please try again\033[0m\n"
	rescan_bdevs
done
boot_blkdev="$selection"

select_root_disk

if [ "$seperate_sd_and_rootfs" = "false" ]; then
	while true; do
		printf "\033[33mWould you like \033[32m[A]utomatic\033[33m or \033[32m[M]anual\033[33m install?\033[0m "
		read -r doauto
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
