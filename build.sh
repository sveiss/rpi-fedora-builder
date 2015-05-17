#!/usr/bin/env bash

# CONFIGURATION

WORK=$(pwd)/tmp
OUT=$(pwd)/out

IMG_XZ_URL=http://mirror.bytemark.co.uk/fedora/linux/releases/21/Images/armhfp/Fedora-Minimal-armhfp-21-5-sda.raw.xz
IMG_XZ_SHA256SUM=6bfcc365f42206abb51f72c9ad7ba9d88b6da776e7f7a4a0f510e68bf96ac49b

IMG_SHA256SUM=ce7e0993dbef70111bd9156a260672be6b492775cfa3cddb53cbcb655ef11720

RPI_UPDATE_URL=https://raw.githubusercontent.com/Hexxeh/rpi-update/master/rpi-update

################

set -e
set -u
set -o pipefail

## Cleanup

cleanup_mountpoints=()
cleanup_loopback=()

trap_err() {
        log_warn "Cleaning up after unclean exit..."
        trap - INT TERM EXIT
        cleanup
        exit 1
}

cleanup() {
        if [ ${#cleanup_mountpoints[@]} -ne 0 ]; then
                log_progress "Unmounting all images..."
                for ((i = ${#cleanup_mountpoints[@]}-1 ; i >= 0; i--)); do
                        log_progress "umount ${cleanup_mountpoints[$i]}"
                        umount -l "${cleanup_mountpoints[$i]}"
                done
                cleanup_mountpoints=()
        fi

        if [ ${#cleanup_loopback[@]} -ne 0 ]; then
                log_progress "Removing loop devices..."
                for ((i = ${#cleanup_loopback[@]}-1 ; i >= 0; i--)); do
                        losetup -d "${cleanup_loopback[$i]}"
                done
                cleanup_mountpoints=()
        fi
}

trap trap_err INT TERM EXIT

## Logging helpers

log_progress() {
        echo " [ .. ] $1"
}

log_completion() {
        echo " [ == ] $1"
}

log_warn() {
        echo " [ ++ ] $1"
}

log_error() {
        echo " [ ** ] $1"
}

fatal() {
        echo " [ !! ] $1"
        exit 1
}

## Main script

log_progress "Preparing..."

mkdir -p $WORK
mkdir -p $OUT

mkdir -p $WORK/mnt/usb
mkdir -p $WORK/mnt/src

src_xz=$(echo $IMG_XZ_URL | sed -e 's/.*\///')
src=$(basename -s .xz $src_xz)

log_progress "Validating source image..."

validate_xz_image() {
        (echo "$IMG_XZ_SHA256SUM $WORK/$src_xz" | sha256sum --check --quiet)
}

validate_image() {
        (echo "$IMG_SHA256SUM $WORK/$src" | sha256sum --check --quiet)
}

need_extract=1
need_download=1

if ([ -f $WORK/$src ] && validate_image) ; then 
        need_extract=0
        need_download=0
fi

if [ "$need_extract" = "1" ] ; then
        if ([ -f $WORK/$src_xz ] && validate_xz_image) ; then 
                need_download=0
        fi
fi

if [ "$need_download" = "1" ] ; then
        log_progress "Downloading source image..."
        curl -o $WORK/$src_xz $IMG_XZ_URL
        validate_xz_image || fatal "downloaded image didn't match checksum!"
fi

if [ "$need_extract" = "1" ] ; then
        log_progress "Extracting source image..."
        xzcat $WORK/$src_xz > $WORK/$src
        validate_image || fatal "extracted image didn't match checksum!"
fi

log_progress "Mounting source image..."

src_dev=$(losetup --show --find -P $WORK/$src)
cleanup_loopback+=("$src_dev")

mount -o ro ${src_dev}p3 $WORK/mnt/src
cleanup_mountpoints+=("$WORK/mnt/src")

log_progress "Preparing destination images..."

rm -f $WORK/usb.img
truncate -s 2000M $WORK/usb.img

usb_dev=$(losetup --show --find -P $WORK/usb.img)
cleanup_loopback+=("$usb_dev")
parted --script $usb_dev mklabel msdos mkpart primary linux-swap 1M 513M mkpart primary ext4 514M 100%

mkswap ${usb_dev}p1
mkfs.ext4 ${usb_dev}p2

rm -f $WORK/sd.img
truncate -s 100M $WORK/sd.img

sd_dev=$(losetup --show --find -P $WORK/sd.img)
cleanup_loopback+=("$sd_dev")
parted --script $sd_dev mklabel msdos mkpart primary 0% 100%

mkfs.fat -F16 ${sd_dev}p1 -n BOOT

parted --script $sd_dev set 1 lba on

log_progress "Mounting USB destination image..."

usbroot=$WORK/mnt/usb
mount ${usb_dev}p2 $usbroot
cleanup_mountpoints+=("$usbroot")

log_progress "rsyncing base system..."

rsync -a tmp/mnt/src/ $usbroot

log_progress "Mounting SD destination image..."

mount ${sd_dev}p1 $usbroot/boot
cleanup_mountpoints+=("$usbroot/boot")

log_progress "Removing Fedora kernel..."
rm -f $usbroot/var/lib/rpm/__db.*
rpm --root $usbroot -e kernel kernel-core kernel-modules arm-boot-config
rm -f $usbroot/var/lib/rpm/__db.*

log_progress "Building fstab..."

boot_uuid=$(blkid ${sd_dev}p1 -o value -s UUID)
root_uuid=$(blkid ${usb_dev}p2 -o value -s UUID)
swap_uuid=$(blkid ${usb_dev}p1 -o value -s UUID)

cat > $usbroot/etc/fstab <<EOF

# /etc/fstab
# Created by build.sh at $(date)

UUID=$root_uuid /        ext4   defaults    1 1
UUID=$boot_uuid /boot    vfat   defaults    1 2
UUID=$swap_uuid swap     swap   defaults    0 0

EOF

log_progress "Installing firmware..."

curl -o $usbroot/usr/local/rpi-update $RPI_UPDATE_URL
chmod a+x $usbroot/usr/local/rpi-update
SKIP_BACKUP=1 ROOT_PATH=$usbroot BOOT_PATH=$usbroot/boot $usbroot/usr/local/rpi-update

log_progress "Configuring firmware..."
root_partuuid=$(blkid ${usb_dev}p2 -o value -s PARTUUID)
cat > $usbroot/boot/cmdline.txt <<EOF
console=ttyAMA0,115200 kgdboc=ttyAMA0,115200 console=tty1 root=PARTUUID=$root_partuuid rootfstype=ext4 rootwait
EOF

log_progress "Configuring root password..."
salt=$(dd if=/dev/urandom bs=24 count=1 2>/dev/null | od -w32 -t x1 -An | tr -d ' ')
rootpw=$(dd if=/dev/urandom bs=24 count=1 2>/dev/null | od -w32 -t x1 -An | tr -d ' ')
crypted_password=$(printf "$salt\n$rootpw\n" | perl -e '$s = <> ; chomp $s ; $p = <> ; chomp $p ; print crypt($p, "\$6\$$s") . "\n"')

CPW="$crypted_password" perl -i -ne '@e = split(/:/) ; $e[1]=$ENV{"CPW"} if $e[0] eq "root" ;  print join ":", @e' $usbroot/etc/shadow

rm $usbroot/etc/systemd/system/multi-user.target.wants/initial-setup-text.service


cleanup
trap - INT TERM EXIT

log_progress "Finishing up..."

mv $WORK/usb.img $OUT/usb.img
mv $WORK/sd.img $OUT/sd.img

log_progress "Done!"

echo
echo 

log_completion "SD Image: $OUT/sd.img"
log_completion "USB Image: $OUT/usb.img"
log_completion "root Password: $rootpw"

