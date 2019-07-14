#!/bin/bash
# some stuff is adapted from https://gist.github.com/android10/3b36eb4bbb7e990a414ec4126e7f6b3f
# Consider ->Disks: AHCI, Secure Boot: off
# for initial network connection use netctl
if [[ $(id -u) -eq 0 ]] ; then
    loadkeys de-latin1
fi
curl -s https://raw.githubusercontent.com/hyphenc/installarch/master/installarch.sh > installarch.sh && chmod +x installarch.sh
startscript() {
    timedatectl set-ntp true
    printf "\nCreate partitions\n\n"
    lsblk
    printf "\nExample:\n1G boot partition, hexcode ef00, label: boot\n2G swap partition, hexcode 8200, label: swap\n*G root partition, hexcode 8300, label: root\n\n"
    cgdisk
    wait
    printf "\nDisk setup\n\n"
    lsblk -f
    read -rp "boot partition? : " bootpart
    read -rp "root partition? : " rootpart
    read -rp "swap partition? (to skip this, press enter) : " swappart
    printf "\nCreating boot partition...\n\n"
    mkfs.fat -F32 "$bootpart"
    printf "\nCreate LUKS encrypted partition\n\n"
    cryptsetup luksFormat "$rootpart"
    printf "\nOpen LUKS encrypted partition\n\n"
    cryptsetup open "$rootpart" luks
    mkfs.btrfs -L luks /dev/mapper/luks
    printf "\nCreating (or not creating) swap space...\n\n"
    # If $swappart is empty, mkswap will fail, but that's ok.
    mkswap "$swappart" > /dev/null 2>&1
    printf "\nSetting up partitions...\n\n"
    # Create and mount btrfs subvolumes
    mount -t btrfs /dev/mapper/luks /mnt
    btrfs subvolume create /mnt/@root
    btrfs subvolume create /mnt/@home
    umount /mnt
    mount -o subvol=@root,compress=lzo /dev/mapper/luks /mnt
    mkdir /mnt/home
    mount -o subvol=@home,compress=lzo /dev/mapper/luks /mnt/home
    # Mount boot partition
    mkdir /mnt/boot
    mount "$bootpart" /mnt/boot
    printf "\nPacman configuration and pacstrap...\n\n"
    # Configure pacman mirrors
    printf "Server = https://ftp.halifax.rwth-aachen.de/archlinux/\$repo/os/\$arch\nServer = https://mirror.netcologne.de/archlinux/\$repo/os/\$arch\nServer = https://archlinux.nullpointer.io/\$repo/os/\$arch\nServer = http://ftp.uni-hannover.de/archlinux/\$repo/os/\$arch\n" | cat - /etc/pacman.d/mirrorlist > /etc/pacman.d/mirrorlist.new && mv /etc/pacman.d/mirrorlist.new /etc/pacman.d/mirrorlist
    # Install base & base-devel and mandatory packages for further setup
    pacstrap /mnt base base-devel btrfs-progs curl fish git intel-ucode connman wpa_supplicant
    printf "\nConfiguring fstab...\n\n"
    genfstab -L /mnt >> /mnt/etc/fstab
    printf "# For all btrfs filesystems consider:\n# - Change relatime to noatime to reduce wear on SSD\n# - Adding discard to enable continuous TRIM for SSD\n# - (HHDs) Adding autodefrag to enable auto defragmentation\n# - Adding compress=lzo to use compression" >> /mnt/etc/fstab
    read -t 3 -rp "Do you want to review fstab? (y/timeout) : " readvar
    if [ "$readvar" == "y" ] ; then nano /mnt/etc/fstab ; wait ; unset readvar ; fi
    printf "\n\nChrooting into /mnt...\n"
    arch-chroot /mnt /bin/bash -c "curl -s https://raw.githubusercontent.com/hyphenc/installarch/master/installarch.sh > installarch.sh; chmod +x installarch.sh; ./installarch.sh postchroot"
}
postchroot() {
    printf "\nSetting up time...\n\n"
    rm /etc/localtime
    ln -s /usr/share/zoneinfo/Europe/Berlin /etc/localtime
    hwclock --systohc
    sed -i 's/^#en_DK.UTF-8 UTF-8/en_DK.UTF-8 UTF-8/' /etc/locale.gen
    locale-gen
    printf "\nSetting locale and keymap...\n\n"
    echo "LANG=en_DK.UTF-8" > /etc/locale.conf
    echo "KEYMAP=de" > /etc/vconsole.conf
    printf "Set hostname\n\n"
    read -rp "hostname? : " hostnamevar
    echo "$hostnamevar" > /etc/hostname
    curl -s https://raw.githubusercontent.com/StevenBlack/hosts/master/alternates/fakenews-gambling/hosts > /etc/hosts
    printf "\nSet root password\n\n"
    passwd
    printf "\nAdding a normal user\n\n"
    read -rp "username? : " username
    useradd -m -G wheel -s /usr/bin/fish "$username"
    passwd "$username"
    echo "$username ALL=(ALL) ALL" > /etc/sudoers.d/$username
    printf "\nConfiguring mkinitcpio...\n\n"
    sed -i 's/^BINARIES=.*/BINARIES=("\/usr\/bin\/btrfs")/' /etc/mkinitcpio.conf
    sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect modconf block keyboard sd-vconsole sd-encrypt filesystems fsck)/' /etc/mkinitcpio.conf
    mkdir -p /etc/systemd/system/connman.service.d/
    printf "[Service]\nExecStart=\nExecStart=/usr/bin/connmand -n -r\n" > /etc/systemd/system/connman.service.d/disable_dns_proxy.conf
    read -t 3 -rp "Do you want to review mkinitcpio.conf? (y/timeout) : " readvar
    if [ "$readvar" == "y" ] ; then
        nano /etc/mkinitcpio.conf ; wait ; unset readvar
    fi
    printf "\n\nRegenerating initcpio image...\n\n"
    mkinitcpio -p linux
    printf "\nConfiguring systemd-boot...\n\n"
    # Setting up systemd-boot
    lsblk -f
    read -rp "root partition? : " rootpart
    luksuuid=$(cryptsetup luksUUID "$rootpart")
    bootctl --path=/boot install
    printf "title\tArch Linux\nlinux\t/vmlinuz-linux\ninitrd\t/intel-ucode.img\ninitrd\t/initramfs-linux.img\noptions\trw luks.uuid=$luksuuid luks.name=$luksuuid=luks root=/dev/mapper/luks rootflags=subvol=@root\n" > /boot/loader/entries/arch.conf
    mkdir -p /etc/pacman.d/hooks/
    printf "[Trigger]\nType = Package\nOperation = Upgrade\nTarget = systemd\n\n[Action]\nDescription = Updating systemd-boot\nWhen = PostTransaction\nExec = /usr/bin/bootctl update\n" > /etc/pacman.d/hooks/100-systemd-boot.hook
    # Setting default bootloader entry
    printf "default arch\neditor no\nauto-entries 1\n" > /boot/loader/loader.conf
    # Setup internet access with ConnMan
    sudo systemctl start connman
    connmanctl
    wait
    sudo systemctl enable connman
    printf "\nPlease reboot and then rerun this script with 'postreboot'\n\n"
    exit
}
installpkg() {
    printf "\nUpdating system...\n\n"
    sudo pacman -Syyu --noconfirm
    printf "\nInstalling yay...\n\n"
    git clone https://aur.archlinux.org/yay.git
    cd yay || exit 1
    makepkg -si --noconfirm
    cd ~ || exit 1
    rm -rf yay/
    printf "\nInstalling packages...\n\n"
    yay -S --needed --noconfirm --sudoloop $(curl -s https://raw.githubusercontent.com/hyphenc/installarch/master/packages.txt | tr "\n" " ")
    # because it's a clipmenu dependency
    yay -Rsndd dmenu
}
buildpkg() {
    printf "\nBuilding dwm and dmenu...\n"
    mkdir -p code/proj
    cd code/proj
    git clone https://github.com/hyphenc/dmenu.git
    git clone https://github.com/hyphenc/dwm.git
    git clone https://github.com/hyphenc/xdm-simple.git
    cd dmenu/; make; sudo make install
    cd ../dwm/; make; sudo make install
    cd ../xdm-simple/; ./install.sh
    cd ~ || exit 1
}
userconfigs() {
    printf "\nConfiguring miscellaneous stuff...\n\n"
    sudo systemctl enable bluetooth
    sudo systemctl enable cronie
    # Turn on pacman & yay color
    sudo sed -i "s/^#Color/Color/" /etc/pacman.conf
    # pulseaudio: automatically switch to newly-connected devices
    printf "# automatically switch to newly-connected devices\nload-module module-switch-on-connect\n" | sudo tee -a /etc/pulse/default.pa
    # secure slock
    printf "Section \"ServerFlags\"\n\tOption \"DontVTSwitch\" \"True\"\nEndSection\n\nSection \"ServerFlags\"\n\tOption \"DontZap\"      \"True\"\n
EndSection\n" | sudo tee -a /etc/X11/xorg.conf
    # Remove beep
    sudo rmmod pcspkr
    echo "blacklist pcspkr" | sudo tee /etc/modprobe.d/nobeep.conf
    # Dotfiles
    printf "\nDeploying dotfiles\n"
    cd ~
    mkdir ~/.cfg
    git clone --bare https://github.com/hyphenc/dotfiles ~/.cfg/
    git --git-dir=$HOME/.cfg/ --work-tree=$HOME config --local status.showUntrackedFiles no
    git --git-dir=$HOME/.cfg/ --work-tree=$HOME checkout
    cd .other/
    bash ./deploy
    wait
    cd ../
    # Fish shell setup
    printf "\nConfiguring fish shell...\n\n"
    # Fish abbreviations
    fish -c 'abbr -a cdd "cd ~/Downloads"; abbr -a gaa "git add -A"; abbr -a gcm "git commit -S -m"; abbr -a gp "git push"; abbr -a gst "git status"; abbr -a gdm "git diff master"; abbr -a lsl "ls -l --block-size=M"; abbr -a cfg "git --git-dir=$HOME/.cfg/ --work-tree=$HOME"; abbr -a play "mpv -no-audio-display -shuffle"; abbr -a bak "~/code/shell/backup.sh"; abbr -a st ~/code/minor/shelltwitch/shelltwitch.sh.priv"; abbr -a mail "~/.scripts/mail"; abbr -a hue "~/code/proj/huec/hue"'
    # Set environment variables
    fish -c "set -Ux SHELL /usr/bin/fish; set -Ux EDITOR nvim"
    # Properly configure pacman mirrors
    printf "\nProperly configuring pacman mirrors...\n"
    sudo curl "https://www.archlinux.org/mirrorlist/?country=all&protocol=http&protocol=https&ip_version=4" -o /etc/pacman.d/mirrorlist.bak
    awk '/^## Germany$/{f=1}f==0{next}/^$/{exit}{print substr($0, 2)}' /etc/pacman.d/mirrorlist.bak | sudo tee /etc/pacman.d/mirrorlist.bak
    rankmirrors -n 6 /etc/pacman.d/mirrorlist.bak | sudo tee /etc/pacman.d/mirrorlist
}
firewall() {
    printf "\nConfiguring firewall...\n\n"
    sudo ufw default deny
    # syncthing
    sudo ufw allow syncthing
    sudo ufw allow syncthing-gui
    # lan
    sudo ufw allow from 192.168.178.0/24
    sudo ufw status
    sudo ufw --force enable
    sudo systemctl enable ufw
}
finished() {
    printf "\nDone with setup. I'd recommend running .nothome/deploy and rebooting.\n\n"
}
case $1 in
    start)
        startscript ;;
    postchroot)
        postchroot ;;
    postreboot)
        installpkg
        buildpkg
        userconfigs
        firewall
        finished ;;
    *)
        printf "\n./installarch.sh [option]\n start: this is the first thing you run\n postreboot: run this after reboot\n\n" ;;
esac
