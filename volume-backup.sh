#!/bin/bash

lib_dir=$(dirname $(readlink -f "$0"))

vgs="vg_rescue_a yoda-new"
mountpoint=/mnt/backup_snap
backup_host="root@xwing"
tty=$(tty)
auto_override_snap=1
# use method tar, for reduced stress on the target fs
method=tar
#
errors_fatal=1
dst_base_dir="/ext-backup/disk/yoda-new"
lv_exclude=".*_snap|.*-snap|.*_swap|.*-swap|xen-test.*|test"
lv_include=".*"
lv_snapshot_size="1G"
plain_partitions="/boot"
gpg_recipients=""
local_config_backup_dir="/offsite-backup/config"


args=$(getopt --longoptions "config:,vg:,backup-host:,auto-override-snap:,method:,dst-base-dir:,exclude:,include:,partitions:,gpg-recicpients:" -o "c:v:H:a:m:d:e:i:p:g:" -- "$@")
eval set -- $args
while [ $# -gt 0 ]; do
        parm="$1"
        shift
        case $parm in
		--config|-c)
			config_file="$1"
			shift;
			. $config_file
			;;
                --vg|-v)
                        vgs="$1"
			shift
                        ;;
                --backup-host|-H)
                        backup_host="$1"
			shift
                        ;;
                --auto-override-snap|-a)
                        auto_override_snap="$1"
			shift
                        ;;
                --method|-m)
                        method="$1"
			shift
                        ;;
                --dst-base-dir|-d)
                        dst_base_dir="$1"
			shift
                        ;;
                --exclude|-e)
                        lv_exclude="$1"
			shift
                        ;;
                --include|-i)
                        lv_include="$1"
			shift
                        ;;
		--partitions|-p)
			plain_partitions="$1"
			shift
			;;
		--gpg-recicpients|-g)
			gpg_recipients="$1"
			shift
			;;
		--)
                        break
        esac
done


handle_error() {
	local rv=$1
	local op=$2
	local dir=$3
	local msg=$4

	if [ $rv -eq 0 ]; then
		return
	fi
	echo "Error $rv on $op of $dir: $msg" >&2
	if [ $errors_fatal -gt 0 ]; then
		exit $rv
	fi
	return $rv
}

check_pipe() {
        for i in  "${PIPESTATUS[@]}"; do
                if [ $i -gt 0 ]; then
                        return $i
                fi
        done
        return 0
}

tar_cmd() {
	dir="$1"
	shift 1
	tar -cpS -C ${dir} . "$@" 2> >(grep -v 'socket ignored' >&2)
}

exit_handler() {
	if [ "$mountpoint" ] ; then
		if cat /proc/mounts | cut -d ' ' -f 2 | fgrep -q "$mountpoint"; then 
			echo "Cleanup: unmounting $mountpoint" >&2
			umount $mountpoint
		fi
	fi
	if [ "$snap_lv_path" -a -e "$snap_lv_path" ]; then 
		echo "Cleanup: removing snap lv $snap_lv_path" >&2
		lvremove -f $snap_lv_path
	fi
}

backup_dir() {
	local dir="$1"
	local dstpath="$2"

	case "$method" in
		rsync)
			ssh ${backup_host} "mkdir -p ${dstpath}" </dev/null ||
				handle_error $? "ssh-mkdir" $dir "ssh mkdir $dstpath failed with return code: $?" || return $?

			rsync -aSH --numeric-ids ${dir}/ ${backup_host}:${dstpath}/ ||
				handle_error $? "rsync" $dir "rsync failed with return code: $?"

				;;
		rsync-atomic)
			local newpath="${dstpath}.new"
			local oldpath="${dstpath}.old"

			ssh ${backup_host} "mkdir -p ${newpath}" </dev/null ||
			  handle_error $? "ssh-mkdir" $dir "ssh mkdir $dstpath failed with return code: $?" || return $?

			rsync -aSH --numeric-ids --delete --link-dest ${dstpath}/ ${dir}/ ${backup_host}:${newpath}/ ||
			  handle_error $? "rsync" $dir "rsync failed with return code: $?" || return $?

			ssh ${backup_host} \
				"rm -rf ${oldpath}; if [ -e ${dstpath} ] ; then mv ${dstpath} ${oldpath}; fi && mv ${newpath} ${dstpath}" </dev/null ||
			  handle_error $? "mv" $dir "mv of $newpath to $dstpath failed with return code: $?"
			;;
		tar)
			local dstdir=$(dirname "${dstpath}")	
			ssh ${backup_host} "mkdir -p ${dstdir}" </dev/null ||
			  handle_error $? "ssh-mkdir" $dir "ssh mkdir $dstpath failed with return code: $?" || return $?

			tar_cmd ${dir} | \
				ssh ${backup_host} "cat >${dstpath}.tar"

			check_pipe ||
			  handle_error $? "tar" $dir "tar failed with return code: $?" || return $?
			;;
		tar+gz)
			local dstdir=$(dirname "${dstpath}")	
			ssh ${backup_host} "mkdir -p ${dstdir}" </dev/null ||
			  handle_error $? "ssh-mkdir" $dir "ssh mkdir $dstpath failed with return code: $?" || return $?

			tar_cmd ${dir} | gzip | \
				ssh ${backup_host} "cat >${dstpath}.tar.gz"

			check_pipe ||
			  handle_error $? "tar" $dir "tar failed with return code: $?" || return $?

			;;
		tar+gpg)
			rec_opts=""
			for rec in $gpg_recipients; do
				rec_opts="$rec_opts -r $rec"
			done	
		
			local dstdir=$(dirname "${dstpath}")	
			ssh ${backup_host} "mkdir -p ${dstdir}" </dev/null ||
			  handle_error $? "ssh-mkdir" $dir "ssh mkdir $dstpath failed with return code: $?" || return $?

			tar_cmd ${dir} | gzip | \
			gpg -z 0 --cipher-algo AES $rec_opts --encrypt --sign | \
			ssh ${backup_host} "cat >${dstpath}.tar.gz.pgp"

			check_pipe ||
			  handle_error $? "tar+gpg" $dir "tar+pgp failed with return code: $?" || return $?

			;;
		tar+gpg+curl)
			rec_opts=""
			for rec in $gpg_recipients; do
				rec_opts="$rec_opts -r $rec"
			done	
		
			local dstdir=$(dirname "${dstpath}")	
			#echo "mkdir -p ${dstdir}" | ftp ${backup_host} ||
			#  handle_error $? "ftp-mkdir" $dir "ftp mkdir $dstpath failed with return code: $?" || return $?

                        if [[ "$backup_host" =~ ftp://.* ]]; then
                            mkdir_cmd="MKD"
                        else
                            mkdir_cmd="mkdir"
                        fi
    
                        # create path
                        # ensure rest ends with a /
                        local create_rest="$dstdir/"
                        local create_path=""
                        while [ "$create_rest" ]; do
                            local create_dir="${create_rest%%/*}"
                            local create_rest="${create_rest#*/}"
                            if [ ! "$create_dir" ]; then
                                continue
                            fi

                            create_path="${create_path:+$create_path/}$create_dir"

                            if ! curl $backup_host/$create_path/ >/dev/null 2>/dev/null; then
                                curl -Q "$mkdir_cmd $create_path" ${backup_host} ||
                                    handle_error $? "tar+gpg+curl" $create_path "tar+pgp+curl: ftp mkdir of $create_path failed with return code: $?" || return $?
                            fi
                        done

			tar_cmd ${dir} | gzip | \
			gpg -z 0 --cipher-algo AES $rec_opts --encrypt --sign | \
			curl -T - ${backup_host}/${dstpath}.tar.gz.pgp

			check_pipe ||
			  handle_error $? "tar+gpg+curl" $dir "tar+pgp+curl failed with return code: $?" || return $?

			;;
		*)
			echo "Unknown method: $method" >&2
			exit 1
	esac
}

set -e
mkdir -m 0700 -p $mountpoint
if grep -q $mountpoint /proc/mounts; then
	echo "CAREFUL: "
	echo "Mountpoint ${mountpoint} already mounted. Unmount?"
	read answer
	if [ "$answer"  != "yes" ];then
		exit 1
	fi
	umount $mountpoint
fi

if which vgcfgbackup >/dev/null; then
	echo "Backing up LVM configuration"
	mkdir -p ${local_config_backup_dir}/lvm
	vgcfgbackup -f ${local_config_backup_dir}/lvm/%s.cfg ||
	  handle_error $? "vgcfgbackup" $local_config_backup_dir "vgcfgbackug failed with return code: $?" 
fi

for cfg_resource in /etc/xen /etc/fstab; do
	echo "Backing up local cfg resource $cfg_resource"
	if [ -e $cfg_resource ]; then
		rsync -aR $cfg_resource ${local_config_backup_dir}/ ||
		  handle_error $? "rsync" $cfg_resource "rsync of cfg_resourcer $cfg_resource failed with return code: $?" || continue
	fi
done

for part in $plain_partitions; do
	echo "Backing up plain directory $part"
	backup_dir $part ${dst_base_dir}/plain/${part}  || echo "Backup of plain partition $part failed"
done

trap exit_handler SIGQUIT SIGINT SIGTERM ERR EXIT

for vg in $vgs; do 
   echo "---------------------------------------------------------------------------------------------"
   echo "Backing up volume group $vg"

   if [ ! -e /dev/$vg ]; then
	handle_error 1 "Volume Group $vg does not exist" || continue 
   fi

   for lv in $(ls /dev/$vg); do
        echo "Backing up lv group $lv"
	lv_path=/dev/$vg/$lv
	snap_lv=${lv}_snap
	snap_lv_path=/dev/${vg}/${snap_lv}
	dstpath="${dst_base_dir}/lvm/$vg/$lv"

	if echo "$lv" | grep -q -E "^$lv_exclude$" ; then
		continue
	elif echo "$lv" | grep -q -E "^$lv_include$" ; then
		true
	else
		echo "Skipping $lv by default"
    		continue		
	fi

	is_snapshot=$(lvs -o lv_attr --noheadings $lv_path | awk -F ' ' '{ if($1 ~ /^s/) print 1; else print 0 };') 
	if [ $is_snapshot -gt 0 ]; then
		echo "Skipping $lv -- is snapshot"
		continue
	fi


	if test -e ${snap_lv_path}; then
		if [ $auto_override_snap -eq 0 ] ;then
			echo "CAREFUL: "
			echo "Source Snap volume ${snap_lv_path} already exists. Overwrite?"
			read answer <$tty
			if [ "$answer"  != "yes" ];then
				continue
			fi
		else
			echo "Automatically removing snap : $snap_lv-path"
			if grep -q $snap_lv /proc/mounts; then
				umount $snap_lv_path || echo "Path not mounted"
			fi	
			lvremove -f $snap_lv_path || 
				handle_error $? "lvremove" $snap_lv_path "lvremove of old snapshot $snap_lv_path failed with return code: $?" || continue
		fi		
	fi

	lvcreate --snapshot -L${lv_snapshot_size} -n ${snap_lv} ${lv_path} ||
	   handle_error $?  "lvcreate" "$lv" "Snapshot creation for $lv failed: $!" || continue

	$lib_dir/im-detect-filesystems ${snap_lv_path} >$local_config_backup_dir/${lv}.filesystem ||
	   handle_error $?  "im-detect-filesystems" "$lv" "Could not detect filesystems for $lv ($!)" || { lvremove -f ${snap_lv_path}; continue; }

	if grep -q xfs $local_config_backup_dir/${lv}.filesystem ; then
		# xfs identifies file systems by UUID on disk, refuses to mount 2 filesystems with the same uuid
		# can be overriden with 'nouuid'
		mount -o ro,nouuid ${snap_lv_path} $mountpoint || 
 		   handle_error $?  "mount" "$snap_lv" "Could not mount $snap_lv to $mountpoint ($!)" || 
	   	{ lvremove -f ${snap_lv_path}; continue; }
	else
		mount -o ro ${snap_lv_path} $mountpoint || 
 		   handle_error $?  "mount" "$snap_lv" "Could not mount $snap_lv to $mountpoint ($!)" || 
	   	{ lvremove -f ${snap_lv_path}; continue; }
	fi

	backup_dir ${mountpoint} ${dstpath}  ||
	    handle_error $? "Backup of lv $snap_lv failed"

	umount ${mountpoint} ||
 	   handle_error $?  "umount" "$snap_lv" "Could not umount $snap_lv"

	lvremove -f  ${snap_lv_path} ||
 	   handle_error $?  "lvremove" "$snap_lv" "Could not lvremove -f $snap_lv"
   done
done

backup_dir ${local_config_backup_dir}/ ${dst_base_dir}/config || 
    handle_error $? "Backup of local config dir ${local_config_backup_dir} failed"
