#!/bin/bash
# some stuff is adapted from https://gist.github.com/android10/3b36eb4bbb7e990a414ec4126e7f6b3f
# for initial network connection use iwctl (iwd)
if [[ $(id -u) -eq 0 ]] ; then
    loadkeys de-latin1
fi
curl -s https://raw.githubusercontent.com/hyphenc/installarch/master/installarch.sh > installarch.sh && chmod +x installarch.sh

bootpart="/dev/nvme0n1p1"
swappart="/dev/nvme0n1p2"
rootpart="/dev/nvme0n1p3"

startscript() {
    printf "please create partitions as follows:\nbootpart on /dev/nvme0n1p1\nswappart on /dev/nvme0n1p2\nrootpart on /dev/nvme0n1p3"
    timedatectl set-ntp true
    printf "\nCreate partitions\n\n"
    lsblk
    printf "\nExample:\n1G boot partition, hexcode ef00, label: boot\n2G swap partition, hexcode 8200, label: swap\n*G root partition, hexcode 8300, label: root\n\n(maybe take a picture with your phone to remember the hexcodes)\n\nPlease enter the disk to edit (e.g. /dev/nvme0n1):\n\n"
    cgdisk
    wait
    printf "\nCreating boot partition...\n\n"
    mkfs.fat -F32 "$bootpart"
    printf "\nCreate LUKS encrypted partition\n\n"
    cryptsetup luksFormat "$rootpart"
    printf "\nOpen LUKS encrypted partition\n\n"
    cryptsetup open "$rootpart" luks
    mkfs.ext4 -L luks /dev/mapper/luks
    printf "\nCreating (or not creating) swap space...\n\n"
    # If $swappart is empty, mkswap will fail, but that's ok.
    mkswap "$swappart" > /dev/null 2>&1
    printf "\nSetting up partitions...\n\n"
    mount /dev/mapper/luks /mnt
    # Mount boot partition
    mkdir /mnt/boot
    mount "$bootpart" /mnt/boot
    printf "\nPacman configuration and pacstrap...\n\n"
    # Configure pacman mirrors
    printf "Server = https://ftp.halifax.rwth-aachen.de/archlinux/\$repo/os/\$arch\nServer = https://mirror.netcologne.de/archlinux/\$repo/os/\$arch\nServer = https://archlinux.nullpointer.io/\$repo/os/\$arch\nServer = http://ftp.uni-hannover.de/archlinux/\$repo/os/\$arch\n" | cat - /etc/pacman.d/mirrorlist > /etc/pacman.d/mirrorlist.new && mv /etc/pacman.d/mirrorlist.new /etc/pacman.d/mirrorlist
    # Install base & base-devel and mandatory packages for further setup
    pacstrap -K /mnt base base-devel linux linux-firmware sof-firmware neovim tmux curl fish git intel-ucode iwd man-db man-pages
    printf "\nConfiguring fstab...\n\n"
    genfstab -L /mnt >> /mnt/etc/fstab
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
    printf "\nSet root password\n\n"
    passwd
    printf "\nAdding a normal user\n\n"
    read -rp "username? : " username
    useradd -m -G wheel -s /usr/bin/fish "$username"
    passwd "$username"
    echo "$username ALL=(ALL) ALL" > /etc/sudoers.d/$username
    printf "\nConfiguring mkinitcpio...\n\n"
    sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect modconf block keyboard sd-vconsole sd-encrypt filesystems fsck)/' /etc/mkinitcpio.conf
    printf "\n\nRegenerating initcpio image...\n\n"
    mkinitcpio -p linux
    printf "\nConfiguring systemd-boot...\n\n"
    # Setting up systemd-boot
    lsblk -f
    luksuuid=$(cryptsetup luksUUID "$rootpart")
    bootctl --esp-path=/boot install # TODO is using --esp-path correct here?
    printf "title\tArch Linux\nlinux\t/vmlinuz-linux\ninitrd\t/intel-ucode.img\ninitrd\t/initramfs-linux.img\noptions\trw luks.uuid=$luksuuid luks.name=$luksuuid=luks root=/dev/mapper/luks\n" > /boot/loader/entries/arch.conf
    mkdir -p /etc/pacman.d/hooks/
    printf "[Trigger]\nType = Package\nOperation = Upgrade\nTarget = systemd\n\n[Action]\nDescription = Updating systemd-boot\nWhen = PostTransaction\nExec = /usr/bin/systemctl restart systemd-boot-update.service\n" > /etc/pacman.d/hooks/100-systemd-boot.hook
    # Setting default bootloader entry
    printf "default arch\neditor no\nauto-entries 1\n" > /boot/loader/loader.conf
    # Setup internet access with iwd
    sudo systemctl enable iwd systemd-resolved systemd-networkd
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
    yay -S --needed --noconfirm --sudoloop $(curl -s https://raw.githubusercontent.com/nunq/dotfiles/main/.other/packages.txt | tr "\n" " ")
    yay -Rsndd --noconfirm dmenu # because it's a clipmenu dependency
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
    # Pulseaudio: automatically switch to newly-connected devices
    printf "# automatically switch to newly-connected devices\nload-module module-switch-on-connect\n" | sudo tee -a /etc/pulse/default.pa
    # Remove beep
    sudo rmmod pcspkr
    # Dotfiles
    printf "\nDeploying dotfiles\n"
    cd ~
    mkdir ~/.cfg
    git clone --bare https://github.com/nunq/dotfiles ~/.cfg/
    git --git-dir=$HOME/.cfg/ --work-tree=$HOME config --local status.showUntrackedFiles no
    rm -r ~/.config/fish/ # else git checkout wont work
    git --git-dir=$HOME/.cfg/ --work-tree=$HOME checkout
    cd .other/
    bash ./deploy
    wait
    cd ../
    # Fish shell setup
    printf "\nConfiguring fish shell...\n\n"
    # Set environment variables
    fish -c "set -Ux SHELL /usr/bin/fish; set -Ux EDITOR nvim"
    # Properly configure pacman mirrors
    printf "\nProperly configuring pacman mirrors...\n"
    sudo curl "https://www.archlinux.org/mirrorlist/?country=all&protocol=http&protocol=https&ip_version=4" -o /etc/pacman.d/mirrorlist.bak
    awk '/^## Germany$/{f=1}f==0{next}/^$/{exit}{print substr($0, 2)}' /etc/pacman.d/mirrorlist.bak | sudo tee /etc/pacman.d/mirrorlist.bak
    rankmirrors -n 6 /etc/pacman.d/mirrorlist.bak | sudo tee /etc/pacman.d/mirrorlist
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
        printf "\nDone.\n\n"
        printf "At this point you might want to restore crontabs, shell abbreviations, move over application-specific data (e.g. Firefox), etc.\n\n" ;;
    *)
        printf "\n./installarch.sh [option]\n start: this is the first thing you run\n postreboot: run this after reboot\n\n" ;;
esac
