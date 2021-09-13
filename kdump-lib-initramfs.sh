#!/bin/sh
#
# Function and variables used in initramfs environment, POSIX compatible
#

. /lib/kdump-logger.sh

DEFAULT_PATH="/var/crash/"
KDUMP_PATH="/var/crash"
KDUMP_LOG_FILE="/run/initramfs/kexec-dmesg.log"
CORE_COLLECTOR=""
DEFAULT_CORE_COLLECTOR="makedumpfile -l --message-level 7 -d 31"
DMESG_COLLECTOR="/sbin/vmcore-dmesg"
FAILURE_ACTION="systemctl reboot -f"
DATEDIR=`date +%Y-%m-%d-%T`
HOST_IP='127.0.0.1'
DUMP_INSTRUCTION=""
SSH_KEY_LOCATION="/root/.ssh/kdump_id_rsa"
KDUMP_SCRIPT_DIR="/kdumpscripts"
DD_BLKSIZE=512
FINAL_ACTION="systemctl reboot -f"
KDUMP_PRE=""
KDUMP_POST=""
NEWROOT="/sysroot"
OPALCORE="/sys/firmware/opal/mpipl/core"
KDUMP_CONFIG_FILE="/etc/kdump.conf"

#initiate the kdump logger
dlog_init
if [ $? -ne 0 ]; then
    echo "failed to initiate the kdump logger."
    exit 1
fi

# Read kdump config in well formated style
kdump_read_conf()
{
    # Following steps are applied in order: strip trailing comment, strip trailing space,
    # strip heading space, match non-empty line, remove duplicated spaces between conf name and value
    [ -f "$KDUMP_CONFIG_FILE" ] && sed -n -e "s/#.*//;s/\s*$//;s/^\s*//;s/\(\S\+\)\s*\(.*\)/\1 \2/p" $KDUMP_CONFIG_FILE
}

# Retrieves config value defined in kdump.conf
# $1: config name, sed regexp compatible
kdump_get_conf_val() {
    # For lines matching "^\s*$1\s+", remove matched part (config name including space),
    # remove tailing comment, space, then store in hold space. Print out the hold buffer on last line.
    [ -f "$KDUMP_CONFIG_FILE" ] && \
        sed -n -e "/^\s*\($1\)\s\+/{s/^\s*\($1\)\s\+//;s/#.*//;s/\s*$//;h};\${x;p}" $KDUMP_CONFIG_FILE
}

is_mounted()
{
    findmnt -k -n $1 &>/dev/null
}

get_mount_info()
{
    local _info_type=$1 _src_type=$2 _src=$3; shift 3
    local _info=$(findmnt -k -n -r -o $_info_type --$_src_type $_src $@)

    [ -z "$_info" ] && [ -e "/etc/fstab" ] && _info=$(findmnt -s -n -r -o $_info_type --$_src_type $_src $@)

    echo $_info
}

is_ipv6_address()
{
    echo $1 | grep -q ":"
}

is_fs_type_nfs()
{
    [ "$1" = "nfs" ] || [ "$1" = "nfs4" ]
}

# If $1 contains dracut_args "--mount", return <filesystem type>
get_dracut_args_fstype()
{
    echo $1 | grep "\-\-mount" | sed "s/.*--mount .\(.*\)/\1/" | cut -d' ' -f3
}

# If $1 contains dracut_args "--mount", return <device>
get_dracut_args_target()
{
    echo $1 | grep "\-\-mount" | sed "s/.*--mount .\(.*\)/\1/" | cut -d' ' -f1
}

get_save_path()
{
    local _save_path=$(kdump_get_conf_val path)
    [ -z "$_save_path" ] && _save_path=$DEFAULT_PATH

    # strip the duplicated "/"
    echo $_save_path | tr -s /
}

get_root_fs_device()
{
    findmnt -k -f -n -o SOURCE /
}

# Return the current underlying device of a path, ignore bind mounts
get_target_from_path()
{
    local _target

    _target=$(df $1 2>/dev/null | tail -1 |  awk '{print $1}')
    [[ "$_target" == "/dev/root" ]] && [[ ! -e /dev/root ]] && _target=$(get_root_fs_device)
    echo $_target
}

get_fs_type_from_target()
{
    get_mount_info FSTYPE source $1 -f
}

get_mntpoint_from_target()
{
    # --source is applied to ensure non-bind mount is returned
    get_mount_info TARGET source $1 -f
}

is_ssh_dump_target()
{
    [[ $(kdump_get_conf_val ssh) == *@* ]]
}

is_raw_dump_target()
{
    [[ $(kdump_get_conf_val raw) ]]
}

is_nfs_dump_target()
{
    if [[ $(kdump_get_conf_val nfs) ]]; then
        return 0;
    fi

    if is_fs_type_nfs $(get_dracut_args_fstype "$(kdump_get_conf_val dracut_args)"); then
        return 0
    fi

    local _save_path=$(get_save_path)
    local _target=$(get_target_from_path $_save_path)
    local _fstype=$(get_fs_type_from_target $_target)

    if is_fs_type_nfs $_fstype; then
        return 0
    fi

    return 1
}

is_fs_dump_target()
{
    [[ $(kdump_get_conf_val "ext[234]\|xfs\|btrfs\|minix") ]]
}

get_kdump_confs()
{
    local config_opt config_val

    while read config_opt config_val;
    do
        # remove inline comments after the end of a directive.
        case "$config_opt" in
            path)
                KDUMP_PATH="$config_val"
            ;;
            core_collector)
                [ -n "$config_val" ] && CORE_COLLECTOR="$config_val"
            ;;
            sshkey)
                if [ -f "$config_val" ]; then
                    SSH_KEY_LOCATION=$config_val
                fi
            ;;
            kdump_pre)
                KDUMP_PRE="$config_val"
            ;;
            kdump_post)
                KDUMP_POST="$config_val"
            ;;
            fence_kdump_args)
                FENCE_KDUMP_ARGS="$config_val"
            ;;
            fence_kdump_nodes)
                FENCE_KDUMP_NODES="$config_val"
            ;;
            failure_action|default)
                case $config_val in
                    shell)
                        FAILURE_ACTION="kdump_emergency_shell"
                    ;;
                    reboot)
                        FAILURE_ACTION="systemctl reboot -f && exit"
                    ;;
                    halt)
                        FAILURE_ACTION="halt && exit"
                    ;;
                    poweroff)
                        FAILURE_ACTION="systemctl poweroff -f && exit"
                    ;;
                    dump_to_rootfs)
                        FAILURE_ACTION="dump_to_rootfs"
                    ;;
                esac
            ;;
            final_action)
                case $config_val in
                    reboot)
                        FINAL_ACTION="systemctl reboot -f"
                    ;;
                    halt)
                        FINAL_ACTION="halt"
                    ;;
                    poweroff)
                        FINAL_ACTION="systemctl poweroff -f"
                    ;;
                esac
            ;;
        esac
    done <<< "$(kdump_read_conf)"

    if [ -z "$CORE_COLLECTOR" ]; then
        CORE_COLLECTOR="$DEFAULT_CORE_COLLECTOR"
        if is_ssh_dump_target || is_raw_dump_target; then
            CORE_COLLECTOR="$CORE_COLLECTOR -F"
        fi
    fi
}

# store the kexec kernel log to a file.
save_log()
{
    dmesg -T > $KDUMP_LOG_FILE

    if command -v journalctl > /dev/null; then
        journalctl -ab >> $KDUMP_LOG_FILE
    fi
    chmod 600 $KDUMP_LOG_FILE
}

# dump_fs <mount point>
dump_fs()
{
    local _exitcode
    local _mp=$1
    local _op=$(get_mount_info OPTIONS target $_mp -f)
    ddebug "dump_fs _mp=$_mp _opts=$_op"

    if ! is_mounted "$_mp"; then
        dinfo "dump path \"$_mp\" is not mounted, trying to mount..."
        mount --target $_mp
        if [ $? -ne 0 ]; then
            derror "failed to dump to \"$_mp\", it's not a mount point!"
            return 1
        fi
    fi

    # Remove -F in makedumpfile case. We don't want a flat format dump here.
    [[ $CORE_COLLECTOR = *makedumpfile* ]] && CORE_COLLECTOR=`echo $CORE_COLLECTOR | sed -e "s/-F//g"`

    local _dump_path=$(echo "$_mp/$KDUMP_PATH/$HOST_IP-$DATEDIR/" | tr -s /)

    dinfo "saving to $_dump_path"

    # Only remount to read-write mode if the dump target is mounted read-only.
    if [[ "$_op" = "ro"* ]]; then
       dinfo "Remounting the dump target in rw mode."
       mount -o remount,rw $_mp || return 1
    fi

    mkdir -p $_dump_path || return 1

    save_vmcore_dmesg_fs ${DMESG_COLLECTOR} "$_dump_path"
    save_opalcore_fs "$_dump_path"

    dinfo "saving vmcore"
    $CORE_COLLECTOR /proc/vmcore $_dump_path/vmcore-incomplete
    _exitcode=$?
    if [ $_exitcode -eq 0 ]; then
        mv $_dump_path/vmcore-incomplete $_dump_path/vmcore
        sync
        dinfo "saving vmcore complete"
    else
        derror "saving vmcore failed, _exitcode:$_exitcode"
    fi

    dinfo "saving the $KDUMP_LOG_FILE to $_dump_path/"
    save_log
    mv $KDUMP_LOG_FILE $_dump_path/
    if [ $_exitcode -ne 0 ]; then
        return 1
    fi

    # improper kernel cmdline can cause the failure of echo, we can ignore this kind of failure
    return 0
}

save_vmcore_dmesg_fs() {
    local _dmesg_collector=$1
    local _path=$2

    dinfo "saving vmcore-dmesg.txt to ${_path}"
    $_dmesg_collector /proc/vmcore > ${_path}/vmcore-dmesg-incomplete.txt
    _exitcode=$?
    if [ $_exitcode -eq 0 ]; then
        mv ${_path}/vmcore-dmesg-incomplete.txt ${_path}/vmcore-dmesg.txt
        chmod 600 ${_path}/vmcore-dmesg.txt

        # Make sure file is on disk. There have been instances where later
        # saving vmcore failed and system rebooted without sync and there
        # was no vmcore-dmesg.txt available.
        sync
        dinfo "saving vmcore-dmesg.txt complete"
    else
        if [ -f ${_path}/vmcore-dmesg-incomplete.txt ]; then
            chmod 600 ${_path}/vmcore-dmesg-incomplete.txt
        fi
        derror "saving vmcore-dmesg.txt failed"
    fi
}

save_opalcore_fs() {
    local _path=$1

    if [ ! -f $OPALCORE ]; then
        # Check if we are on an old kernel that uses a different path
        if [ -f /sys/firmware/opal/core ]; then
            OPALCORE="/sys/firmware/opal/core"
        else
            return 0
        fi
    fi

    dinfo "saving opalcore:$OPALCORE to ${_path}/opalcore"
    cp $OPALCORE ${_path}/opalcore
    if [ $? -ne 0 ]; then
        derror "saving opalcore failed"
        return 1
    fi

    sync
    dinfo "saving opalcore complete"
    return 0
}

dump_to_rootfs()
{

    if [[ $(systemctl status dracut-initqueue | sed -n "s/^\s*Active: \(\S*\)\s.*$/\1/p") == "inactive" ]]; then
        dinfo "Trying to bring up initqueue for rootfs mount"
        systemctl start dracut-initqueue
    fi

    dinfo "Clean up dead systemd services"
    systemctl cancel
    dinfo "Waiting for rootfs mount, will timeout after 90 seconds"
    systemctl start --no-block sysroot.mount

    _loop=0
    while [ $_loop -lt 90 ] && ! is_mounted /sysroot; do
        sleep 1
        _loop=$((_loop + 1))
    done

    if ! is_mounted /sysroot; then
        derror "Failed to mount rootfs"
        return
    fi

    ddebug "NEWROOT=$NEWROOT"
    dump_fs $NEWROOT
}

kdump_emergency_shell()
{
    ddebug "Switching to kdump emergency shell..."

    [ -f /etc/profile ] && . /etc/profile
    export PS1='kdump:${PWD}# '

    . /lib/dracut-lib.sh
    if [ -f /dracut-state.sh ]; then
        . /dracut-state.sh 2>/dev/null
    fi

    source_conf /etc/conf.d

    type plymouth >/dev/null 2>&1 && plymouth quit

    source_hook "emergency"
    while read _tty rest; do
        (
        echo
        echo
        echo 'Entering kdump emergency mode.'
        echo 'Type "journalctl" to view system logs.'
        echo 'Type "rdsosreport" to generate a sosreport, you can then'
        echo 'save it elsewhere and attach it to a bug report.'
        echo
        echo
        ) > /dev/$_tty
    done < /proc/consoles
    sh -i -l
    /bin/rm -f -- /.console_lock
}

do_failure_action()
{
    dinfo "Executing failure action $FAILURE_ACTION"
    eval $FAILURE_ACTION
}

do_final_action()
{
    dinfo "Executing final action $FINAL_ACTION"
    eval $FINAL_ACTION
}
