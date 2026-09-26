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
boot_needs_format=false
udisks_was_running=false
_bg_pids=""
_spin_log=""


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
	# Stop any background job still running.  kill $(jobs -p) is unreliable in
	# POSIX sh because command substitutions run in a subshell with an empty
	# job table (notably dash, which is /bin/sh on Debian/Ubuntu).
	for _p in $_bg_pids; do
		kill "$_p" 2>/dev/null || true
	done
	wait 2>/dev/null || true

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

	# Clean up the background job log if the trap fires mid-job
	if [ -n "$_spin_log" ] && [ -f "$_spin_log" ]; then
		rm -f "$_spin_log" 2>/dev/null || true
	fi

	# Clean up the download temp file if the trap fires mid-download
	if [ -n "$_dl_tmp" ] && [ -f "$_dl_tmp" ]; then
		rm -f "$_dl_tmp" 2>/dev/null || true
	fi

	# Restart udisks2 if we exit while it is suspended
	toggle_udisks start
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

# Called when the user answers 'q' at a prompt.
user_quit() {
	printf "\033[33mInstallation cancelled by user.\033[0m\n"
	exit 0
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
	while [ -z "$all_bdevs" ]; do
		printf "\033[1;31mNo eligible block devices found.\033[0m\n"
		printf "Ensure a disk is connected, then press Enter to rescan (or 'q' to quit): "
		read -r answer || input_closed
		case "$answer" in
			q|Q|quit|Quit|QUIT) user_quit ;;
		esac
		rescan_bdevs
	done

	i=1
	for dev in $all_bdevs; do
		size=$(cat "/sys/block/$dev/size")
		size=$((size / 2))
		size=$(formatSize "$size")

		# Check if removable (typically SD cards/USB drives)
		removable=""
		if [ -f "/sys/block/$dev/removable" ] && [ "$(cat "/sys/block/$dev/removable")" = "1" ]; then
			removable=$(printf ' \033[32m(Removable)\033[0m')
		fi

		printf '[%s] /dev/%s - %s%s\n' "$i" "$dev" "$size" "$removable"
		i=$((i + 1))
	done
	i=1

	echo
	printf "Select a disk (or 'q' to quit): "
	read -r devnum || input_closed

	case "$devnum" in
		q|Q|quit|Quit|QUIT) user_quit ;;
	esac

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

	if [ -z "$all_parts" ]; then
		printf '\033[1;31mNo partitions found on /dev/%s.\033[0m\n' "$1"
		printf "The disk must be partitioned before using manual mode.\n"
		# Return 3 (not 1) so the caller can tell "nothing to select" apart
		# from an invalid menu choice; retrying here would spin forever with
		# no prompt, since this branch never reads input.
		return 3
	fi

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
	printf "Select a partition (or 'q' to quit): "
	read -r partnum || input_closed

	case "$partnum" in
		q|Q|quit|Quit|QUIT) user_quit ;;
	esac

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

show_disk_info() {
	disk="$1"

	printf "\033[1;33m=== Disk Information ===\033[0m\n"
	printf 'Device: /dev/%s\n' "$disk"

	# Show size
	size=$(cat "/sys/block/$disk/size")
	size=$((size / 2))
	size=$(formatSize "$size")
	printf 'Size: %s\n' "$size"

	# Show model if available
	if [ -f "/sys/block/$disk/device/model" ]; then
		model=$(sed 's/[[:space:]]*$//' "/sys/block/$disk/device/model")
		printf "Model: %s\n" "$model"
	fi

	# Show if removable
	if [ -f "/sys/block/$disk/removable" ]; then
		removable=$(cat "/sys/block/$disk/removable")
		if [ "$removable" = "1" ]; then
			printf "Type: Removable\n"
		else
			printf "Type: Fixed disk\n"
		fi
	fi

	# Show existing partitions
	parts=$(get_parts "$disk")
	if [ -n "$parts" ]; then
		printf "\nExisting partitions:\n"
		for part in $parts; do
			part_size=$(cat "/sys/block/$disk/$part/size")
			part_size=$((part_size / 2))
			part_size=$(formatSize "$part_size")
			printf '  /dev/%s - %s' "$part" "$part_size"

			# Show filesystem type and label if detectable
			fstype=$(blkid -s TYPE -o value "/dev/$part" 2>/dev/null || true)
			fslabel=$(blkid -s LABEL -o value "/dev/$part" 2>/dev/null || true)
			[ -n "$fstype" ] && printf ' (%s)' "$fstype"
			[ -n "$fslabel" ] && printf " [label: %s]" "$fslabel"
			unset fstype fslabel
			printf "\n"
		done
	else
		printf "\nNo existing partitions\n"
	fi

	printf "\033[1;33m========================\033[0m\n"
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

	# Warn before erasing. The root partition is always reformatted, so it must
	# always warn even when it is already ext4 (the case most likely to hold
	# real data). The boot partition is only reformatted when its type does not
	# already match, so it only warns on a mismatch.
	fstype=$(blkid -s TYPE -o value "/dev/$selection" 2>/dev/null || true)
	if [ "$1" = "root" ] || [ "$fstype" != "$correct_type" ]; then
		printf '\033[1;33mThis partition will be formatted as %s (%s).\n' "$name2" "$correct_type"
		printf "All existing data on it will be \033[31mERASED\033[33m during installation.\n"
		printf "Do you want to continue?\033[0m [y/N] "

		read -r yesno || input_closed
		case $yesno in
			y|Y|yes|YES)
				[ "$1" = "boot" ] && boot_needs_format=true
				return 0
				;;
			n|N|no|NO|"") return 2 ;;
			*)             return 3 ;;
		esac
	fi
}

validate_and_select_part() {
	while true; do
		select_part "$1" || {
			_rc="$?"
			case "$_rc" in
				1) printf "\033[1;31mInvalid option, please try again\033[0m\n"; continue ;;
				3)
					# No partitions on the disk; retrying can't help (the disk
					# needs partitioning first), and looping would spin without
					# a prompt. Abort rather than hang.
					printf "\033[1;31mCannot continue: the selected disk has no partitions to choose from.\033[0m\n"
					printf "Partition the disk first, or restart and use automatic mode.\n"
					exit 1 ;;
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
				3) printf "\033[1;31mInvalid answer, please try again\033[0m\n"; continue ;;
				*)
					printf "\033[1;31mInternal error.  Please report the following info.\033[0m\n"
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
		printf "Would you like to store the boot files and rootfs on separate devices?\033[0m [y/N/q] "
		read -r yesno || input_closed
		case "$yesno" in
			y|Y|yes|YES) separate_sd_and_rootfs=true; break ;;
			n|N|no|NO|"") separate_sd_and_rootfs=false; break ;;
			q|Q|quit|Quit|QUIT) user_quit ;;
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

# Suspend udisks2 while we repartition and format, so the desktop doesn't
# auto-mount or probe the partitions mid-operation.  udisks2 is D-Bus
# activated, so a plain stop would be undone by the next desktop request;
# mask it too.  --runtime keeps the mask in /run, so it is gone after a
# reboot even if the installer is killed before it can unmask.
# Only systemd is handled; udisks2 isn't used as a standalone service elsewhere.
# $1 = "stop" or "start"
toggle_udisks() {
	command -v systemctl >/dev/null 2>&1 || return 0

	if [ "$1" = "stop" ]; then
		if systemctl is-active --quiet udisks2; then
			printf 'Suspending udisks2 monitoring...\n'
			systemctl mask --runtime --quiet udisks2 2>/dev/null || true
			if systemctl stop udisks2; then
				udisks_was_running=true
			else
				systemctl unmask --runtime --quiet udisks2 2>/dev/null || true
				printf "\033[1;33mWarning: could not stop udisks2; continuing anyway.\033[0m\n"
			fi
		fi
	elif [ "$1" = "start" ]; then
		if [ "$udisks_was_running" = "true" ]; then
			printf 'Resuming udisks2 monitoring...\n'
			systemctl unmask --runtime --quiet udisks2 2>/dev/null || true
			systemctl start udisks2 2>/dev/null || true
			udisks_was_running=false
		fi
	fi
}



# Advance the spinner animation: sets $frame from the counter $i
next_frame() {
	i=$(( (i + 1) % 4 ))
	case $i in
		0) frame="|" ;;
		1) frame="/" ;;
		2) frame="-" ;;
		3) frame="\\" ;;
	esac
}

# $1 = PID to wait for, $2 = message
# Only shows that the process is still running; callers check its exit code.
spinner() {
	pid="$1"
	msg="$2"

	i=0
	while kill -0 "$pid" 2>/dev/null; do
		next_frame
		printf '\r[%s] %s...' "$frame" "$msg"
		sleep 0.1
	done
	printf '\r[*] %s finished.       \n' "$msg"
}

# Flush all pending writes, showing how fast the disk holding $2 is being
# written to.  Falls back to a plain spinner if the disk's stats can't be read.
# $1 = message, $2 = a partition (or disk) being written to
sync_progress() {
	msg="$1"
	part_name=$(basename "$2")

	# Writes are counted per disk, so find the disk the partition is on
	# (e.g. sda for /dev/sda2)
	if [ -e "/sys/block/$part_name" ]; then
		disk_name="$part_name"
	else
		disk_name=$(basename "$(dirname "$(readlink -f "/sys/class/block/$part_name")")")
	fi
	stat_file="/sys/block/$disk_name/stat"

	sync &
	_job=$!
	_bg_pids="${_bg_pids:+$_bg_pids }$_job"

	if [ ! -f "$stat_file" ]; then
		spinner "$_job" "$msg"
	else
		i=0
		ticks=0
		kb_s=""
		# Field 7 of the stat file is the number of 512-byte sectors written
		s1=$(awk '{print $7}' "$stat_file" 2>/dev/null || true)
		s1=${s1:-0}

		while kill -0 "$_job" 2>/dev/null; do
			next_frame

			# Update the rate every second (10 ticks)
			if [ "$ticks" -eq 10 ]; then
				s2=$(awk '{print $7}' "$stat_file" 2>/dev/null || true)
				s2=${s2:-0}
				kb_s=$(( (s2 - s1) / 2 ))
				[ "$kb_s" -lt 0 ] && kb_s=0
				s1=$s2
				ticks=0
			fi

			if [ -z "$kb_s" ]; then
				status="Calculating..."
			elif [ "$kb_s" -gt 0 ]; then
				status="Writing to $disk_name: $kb_s KB/s"
			else
				status="Finishing up"
			fi
			printf '\r[%s] %s... (%s)\033[K' "$frame" "$msg" "$status"

			sleep 0.1
			ticks=$((ticks + 1))
		done
		printf '\r[*] %s finished.\033[K\n' "$msg"
	fi

	wait "$_job" || true
	_bg_pids=""
}

# Run a command in the background with a spinner, keeping its output in a log
# that is only shown if it fails (so it can't garble the spinner line).
# $1 = message, rest = command.  Returns the command's exit code.
run_with_spinner() {
	msg="$1"
	shift

	_spin_log=$(mktemp)
	"$@" > "$_spin_log" 2>&1 &
	_job=$!
	_bg_pids="${_bg_pids:+$_bg_pids }$_job"

	spinner "$_job" "$msg"

	_job_ret=0
	wait "$_job" || _job_ret=$?
	# Forget the finished job, so cleanup can't kill an unrelated process
	# that has since reused its PID
	_bg_pids=""
	if [ "$_job_ret" -ne 0 ]; then
		printf '%s\n' '--- Error Log ---'
		cat "$_spin_log"
	fi
	rm -f "$_spin_log"
	_spin_log=""
	return "$_job_ret"
}

# $1 = partition to erase and format
format_boot_part() {
	wipefs -a "$1" && mkfs.vfat -F 32 "$1"
}

# $1 = partition to erase and format
format_root_part() {
	wipefs -a "$1" && mkfs.ext4 -O '^encrypt,^verity,^metadata_csum_seed' -L 'arch' "$1"
}

# Extract a gzipped tarball, showing a progress bar if pv is installed and
# a spinner otherwise.  Returns non-zero if reading or extracting failed.
# $1 = tarball, $2 = destination directory, rest = extra tar options
extract_tarball() {
	_tarball="$1"
	_dest="$2"
	shift 2

	if ! command -v pv >/dev/null 2>&1; then
		run_with_spinner "Extracting" tar -xzf "$_tarball" "$@" -C "$_dest/"
		return
	fi

	# Save pv's exit code separately: without pipefail (not POSIX) a pipeline
	# only reports tar's, so a pv read error would go unnoticed and leave a
	# truncated install.
	_pv_rc=$(mktemp)
	_tar_ret=0
	{
		_r=0
		pv -p -t -e -r -b "$_tarball" || _r=$?
		printf '%s\n' "$_r" > "$_pv_rc"
	} | tar -xzf - "$@" -C "$_dest/" || _tar_ret=$?
	_pv_ret=$(cat "$_pv_rc" 2>/dev/null || printf '1')
	rm -f "$_pv_rc"

	[ "$_tar_ret" -ne 0 ] && return "$_tar_ret"
	return "$_pv_ret"
}

# $1 = URL, $2 = file name in the current directory
download_or_use_local() {
	url="$1"
	filename="$2"

	# Offer to reuse a copy left by a previous run
	if [ -f "./$filename" ]; then
		printf '\033[33mFound local file: %s\033[0m\n' "$filename"
		printf "Use local file? [Y/n] "
		read -r use_local || input_closed
		case "$use_local" in
			n|N|no|NO) ;;
			*)
				printf "\033[1;32mUsing local file!\033[0m\n"
				return 0
				;;
		esac
	fi

	# Download next to the final file and rename it into place only once
	# complete, so an interrupted download never looks like a finished one
	# (and a large tarball isn't staged in a RAM-backed /tmp).
	printf 'Downloading %s into %s...\n' "$filename" "$PWD"
	_dl_tmp=$(mktemp "./.$filename.XXXXXX")
	if ! wget --timeout=30 --tries=3 -O "$_dl_tmp" --show-progress --progress=bar:force "$url"; then
		rm -f "$_dl_tmp"
		_dl_tmp=""
		printf '\033[1;31mFATAL ERROR: Failed to download %s\033[0m\n' "$filename"
		exit 1
	fi

	if [ ! -s "$_dl_tmp" ]; then
		rm -f "$_dl_tmp"
		_dl_tmp=""
		printf '\033[1;31mFATAL ERROR: Downloaded file is empty: %s\033[0m\n' "$filename"
		exit 1
	fi

	mv -f "$_dl_tmp" "./$filename"
	_dl_tmp=""

	# mktemp creates the file private to root; make it readable, and let the
	# user who ran sudo delete or move it
	chmod 644 "./$filename"
	if [ -n "$SUDO_UID" ] && [ -n "$SUDO_GID" ]; then
		chown "$SUDO_UID:$SUDO_GID" "./$filename" 2>/dev/null || true
	fi

	printf "\033[32mDownload complete!\033[0m\n"
}

install_boot() {
	tarball_name="wii_linux_sd_files_archpower-latest.tar.gz"
	download_or_use_local "https://wii-linux.org/files/$tarball_name" "$tarball_name"

	boot_mnt="$(mount_in_tmpdir_or_die "$boot_blkdev")"
	printf 'Now installing the boot files...\n'
	# FAT32 has no Unix owners or permissions, so don't try to restore them
	extract_tarball "$tarball_name" "$boot_mnt" --no-same-owner --no-same-permissions || {
		ret=$?
		printf "\033[1;31mFATAL ERROR: Failed to extract boot files!\033[0m\n"
		bug_report "Step: install_boot_extract" "Return code: $ret"
	}
}

install_root() {
	tarball_name="wii_linux_rootfs_archpower-latest.tar.gz"
	download_or_use_local "https://wii-linux.org/files/$tarball_name" "$tarball_name"

	rootfs_mnt="$(mount_in_tmpdir_or_die "$rootfs_blkdev")"
	printf 'Now installing the rootfs... (this may take a while depending on storage speed)\n'
	extract_tarball "$tarball_name" "$rootfs_mnt" --acls --xattrs --same-owner --same-permissions --numeric-owner --sparse || {
		ret=$?
		printf "\033[1;31mFATAL ERROR: Failed to extract rootfs!\033[0m\n"
		bug_report "Step: install_root_extract" "Return code: $ret"
	}
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
	sync_progress "Syncing" "$rootfs_blkdev"

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

	if [ "$boot_blkdev" = "$rootfs_blkdev" ]; then
		printf "\033[1;31mError: Boot and root must be different partitions!\033[0m\n"
		exit 1
	fi

	echo
	printf "\033[1;33m============================================================\033[0m\n"
	printf "\033[1;32m                      Ready to Install\033[0m\n"
	printf "\033[1;33m============================================================\033[0m\n"
	echo

	# Get sizes for confirmation display
	boot_name=$(basename "$boot_blkdev")
	boot_size=$(cat "/sys/class/block/$boot_name/size" 2>/dev/null || printf '0')
	boot_size=$(( boot_size / 2 ))
	boot_size=$(formatSize "$boot_size")

	root_name=$(basename "$rootfs_blkdev")
	root_size=$(cat "/sys/class/block/$root_name/size" 2>/dev/null || printf '0')
	root_size=$(( root_size / 2 ))
	root_size=$(formatSize "$root_size")

	printf 'Boot partition: \033[1;36m%s\033[0m (%s)\n' "$boot_blkdev" "$boot_size"
	printf 'Root partition: \033[1;36m%s\033[0m (%s)\n' "$rootfs_blkdev" "$root_size"
	echo
	printf "\033[1;33mThe installer will now:\033[0m\n"
	printf '  1. Format %s as FAT32 (if needed)\n' "$boot_blkdev"
	printf '  2. Format %s as ext4\n' "$rootfs_blkdev"
	printf "  3. Download and install Wii Linux ArchPOWER\n"
	echo
	printf "\033[1;31m!! Data on these partitions will be lost !!\033[0m\n"
	echo
	printf "Continue? [yes/NO] "
	read -r final_confirm || input_closed

	case "$final_confirm" in
		yes|YES)
			printf 'Proceeding with installation...\n'
			;;
		*)
			printf "\033[1;33mInstallation cancelled.\033[0m\n"
			exit 0
			;;
	esac

	toggle_udisks stop

	# Unmount selected partitions if the host OS has auto-mounted them
	printf 'Unmounting selected partitions...\n'
	for _dev in "$boot_blkdev" "$rootfs_blkdev"; do
		if grep -q "^$_dev " /proc/mounts; then
			umount "$_dev" || {
				printf "\033[1;31mFATAL ERROR: Failed to unmount %s\033[0m\n" "$_dev" >&2
				exit 1
			}
		fi
	done

	# Format boot if it wasn't already the correct type, always format rootfs
	if [ "$boot_needs_format" = "true" ]; then
		run_with_spinner "Formatting boot partition" format_boot_part "$boot_blkdev" || {
			ret=$?
			printf "\033[1;31mFailed to format boot partition!\033[0m\n"
			bug_report "Step: boot_format" "Return code: $ret" "Boot blkdev: $boot_blkdev"
		}
	fi
	run_with_spinner "Formatting rootfs" format_root_part "$rootfs_blkdev" || {
		ret=$?
		printf "\033[1;31mFailed to format rootfs!\033[0m\n"
		bug_report "Step: rootfs_format" "Return code: $ret" "Root blkdev: $rootfs_blkdev"
	}

	# Let udev finish processing the new filesystems before mounting them
	settle_udev
	sleep 2

	install_boot
	install_root

	do_configure

	unmount_and_cleanup

	# Resume udisks2 only after the partitions are fully unmounted
	toggle_udisks start
}

automatic_install() {
	# currently, boot_blkdev is our SD Card.
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

	fatSize=""
	while true; do
		printf "\033[33mHow many MB of space would you like to reserve for the \033[32mFAT32 Boot files / Homebrew partition\033[33m?\033[0m [default:256, max:%s, q to quit] " "$max_fat_mb"
		read -r fatSz || input_closed
		case "$fatSz" in
			q|Q|quit|Quit|QUIT) user_quit ;;
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

	echo
	printf "\033[1;33m============================================================\033[0m\n"
	printf "\033[1;31m               WARNING: DESTRUCTIVE OPERATION\033[0m\n"
	printf "\033[1;33m============================================================\033[0m\n"
	echo

	show_disk_info "$sd_blkdev"

	echo
	printf "\033[1;31mThe automatic installer will:\033[0m\n"
	printf '  1. \033[1;31mERASE ALL DATA\033[0m on /dev/%s\n' "$sd_blkdev"
	printf '  2. Create a %sMB FAT32 partition for boot files\n' "$fatSize"
	printf "  3. Create an ext4 partition using remaining space for rootfs\n"
	printf "  4. Download and install Wii Linux ArchPOWER\n"
	echo
	printf "\033[1;31m!! ALL EXISTING DATA ON THIS DISK WILL BE PERMANENTLY LOST !!\033[0m\n"
	echo
	printf "Type 'YES' in CAPITAL letters to continue: "
	read -r final_confirm || input_closed

	if [ "$final_confirm" != "YES" ]; then
		printf "\033[1;33mInstallation cancelled.\033[0m\n"
		exit 0
	fi

	printf 'Proceeding with installation...\n'

	toggle_udisks stop

	# Unmount and erase any partitions on the disk before repartitioning
	printf 'Cleaning disk...\n'
	clean_disk "$sd_blkdev"

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

	run_with_spinner "Formatting boot partition" format_boot_part "$boot_blkdev" || {
		ret=$?
		printf "\033[1;31mFailed to format boot partition!\033[0m\n"
		bug_report "Step: auto_format" "Return code: $ret" "Boot blkdev: $boot_blkdev"
	}
	run_with_spinner "Formatting rootfs" format_root_part "$rootfs_blkdev" || {
		ret=$?
		printf "\033[1;31mFailed to format rootfs!\033[0m\n"
		bug_report "Step: auto_format" "Return code: $ret" "Root blkdev: $rootfs_blkdev"
	}

	# Let udev finish processing the new filesystems before mounting them
	settle_udev
	sleep 2

	install_boot
	install_root

	do_configure

	unmount_and_cleanup

	# Resume udisks2 only after the partitions are fully unmounted
	toggle_udisks start
}
# ====
# Start of the actual installer process
# ====
if ! command -v pv >/dev/null 2>&1; then
	printf "\033[1;33mNote: Install 'pv' for progress bars during extraction\033[0m\n"
	printf "  (This is optional, installation will work without it)\n"
	echo
fi

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
		printf "\033[33mWould you like \033[32m[A]utomatic\033[33m or \033[32m[M]anual\033[33m install?\033[0m [a/m/q] "
		read -r doauto || input_closed
		case "$doauto" in
			a|A|auto|Auto|AUTO|automatic|Automatic|AUTOMATIC) automatic_install ;;
			m|M|man|Man|MAN|manual|Manual|MANUAL) manual_install ;;
			q|Q|quit|Quit|QUIT) user_quit ;;
			*) printf "\033[1;31mInvalid option, please try again\033[0m\n"; continue ;;
		esac
		break
	done
else
	manual_install
fi

printf "\033[1;32mSUCCESS!!  If you're reading this, your Wii Linux install is complete!\033[0m\n"
