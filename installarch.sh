#!/usr/bin/bash
# some stuff is adapted from https://gist.github.com/android10/3b36eb4bbb7e990a414ec4126e7f6b3f
# Consider:
#   Disks: AHCI
#   Secure Boot: off
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
    btrfs subvolume create /mnt/@snapshots
    umount /mnt
    mount -o subvol=@root,compress=lzo /dev/mapper/luks /mnt
    mkdir /mnt/home
    mkdir /mnt/.snapshots
    mount -o subvol=@home,compress=lzo /dev/mapper/luks /mnt/home
    mount -o subvol=@snapshots,compress=lzo /dev/mapper/luks /mnt/.snapshots
    # Mount boot partition
    mkdir /mnt/boot
    mount "$bootpart" /mnt/boot
    printf "\nPacman configuration and pacstrap...\n\n"
    # Configure pacman mirrors
    printf "Server = https://ftp.halifax.rwth-aachen.de/archlinux/\$repo/os/\$arch\nServer = https://mirror.netcologne.de/archlinux/\$repo/os/\$arch\nServer = https://archlinux.nullpointer.io/\$repo/os/\$arch\nServer = http://ftp.uni-hannover.de/archlinux/\$repo/os/\$arch\n" | cat - /etc/pacman.d/mirrorlist > /etc/pacman.d/mirrorlist.new && mv /etc/pacman.d/mirrorlist.new /etc/pacman.d/mirrorlist
    # Install base & base-devel and mandatory packages for further setup
    pacstrap /mnt base base-devel btrfs-progs curl fish git intel-ucode networkmanager
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
    echo "$username ALL=(ALL) ALL" > /etc/sudoers.d/nils
    printf "\nConfiguring mkinitcpio...\n\n"
    sed -i 's/^BINARIES=.*/BINARIES=("\/usr\/bin\/btrfs")/' /etc/mkinitcpio.conf
    sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect modconf block keyboard sd-vconsole sd-encrypt filesystems fsck)/' /etc/mkinitcpio.conf
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
    # Enable NetworkManager for internet access after reboot
    sudo systemctl enable NetworkManager
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
    yay -S --needed --noconfirm $(curl -s https://raw.githubusercontent.com/hyphenc/installarch/master/packages.txt | tr "\n" " ")
}
gnomeconfig() {
    printf "Installing gnome theme..."
    git clone https://github.com/hyphenc/Equilux-compact
    sudo mv Equilux-compact/ /usr/share/themes/
    printf "\nConfiguring gnome...\n\n"
    # General
    gsettings set org.gnome.settings-daemon.plugins.color night-light-enabled true
    gsettings set org.gnome.settings-daemon.plugins.color night-light-schedule-automatic true
    gsettings set org.gnome.settings-daemon.plugins.power power-button-action suspend
    gsettings set org.gnome.settings-daemon.plugins.power idle-dim true
    gsettings set org.gnome.desktop.input-sources sources "[('xkb', 'de')]"
    gsettings set org.gnome.system.locale region "en_DK.UTF-8"
    # Interface
    gsettings set org.gnome.desktop.calendar show-weekdate true
    gsettings set org.gnome.desktop.datetime automatic-timezone true
    gsettings set org.gnome.desktop.interface clock-format "24h"
    gsettings set org.gnome.desktop.interface clock-show-seconds false
    gsettings set org.gnome.desktop.interface cursor-theme "Adwaita"
    gsettings set org.gnome.desktop.interface document-font-name "Liberation Serif 11"
    gsettings set org.gnome.desktop.interface enable-animations true
    gsettings set org.gnome.desktop.interface font-name "Fira Code 12"
    gsettings set org.gnome.desktop.interface gtk-theme "Equilux-compact"
    gsettings set org.gnome.desktop.interface icon-theme "Pop"
    gsettings set org.gnome.desktop.interface monospace-font-name "Fira Code 11"
    gsettings set org.gnome.desktop.interface show-battery-percentage true
    gsettings set org.gnome.shell.extensions.user-theme name "Equilux-compact"
    # Keybindings
    gsettings set org.gnome.desktop.wm.keybindings minimize "['<Super>Down']"
    gsettings set org.gnome.desktop.wm.keybindings show-desktop "['<Super>d']"
    gsettings set org.gnome.desktop.wm.keybindings switch-windows "['<Alt>Tab']"
    # Window Manager
    gsettings set org.gnome.desktop.wm.preferences action-double-click-titlebar 'toggle-maximize'
    gsettings set org.gnome.desktop.wm.preferences button-layout 'appmenu:minimize,maximize,close'
    gsettings set org.gnome.desktop.wm.preferences raise-on-click true
    # Nautilus
    gsettings set org.gnome.desktop.media-handling automount false
    gsettings set org.gnome.nautilus.compression default-compression-format "tar.xz"
    gsettings set org.gnome.nautilus.icon-view default-zoom-level standard
    gsettings set org.gnome.nautilus.preferences open-folder-on-dnd-hover true
    gsettings set org.gnome.nautilus.preferences show-create-link true
    gsettings set org.gnome.nautilus.window-state initial-size "(880, 490)"
    gsettings set org.gnome.nautilus.window-state sidebar-width 200
    # Miscellaneous
    gsettings set org.gnome.desktop.notifications show-in-lock-screen false
    gsettings set org.gnome.desktop.privacy remember-app-usage false
    gsettings set org.gnome.desktop.privacy report-technical-problems false
    gsettings set org.gnome.desktop.privacy send-software-usage-stats false
    gsettings set org.gnome.desktop.search-providers disabled "['org.gnome.Nautilus.desktop','org.gnome.Terminal.desktop']"
    gsettings set org.gnome.desktop.sound allow-volume-above-100-percent true
    gsettings set org.gnome.system.location enabled false
    gsettings set org.gnome.desktop.peripherals.touchpad tap-to-click true
}
userconfigs() {
    printf "\nConfiguring miscellaneous stuff...\n\n"
    sudo systemctl enable bluetooth
    sudo systemctl enable cronie
    sudo systemctl enable gdm
    # Get ix.io binary
    sudo curl -s ix.io/client -o /usr/bin/ix
    sudo chmod +x /usr/bin/ix
    # Turn on pacman & yay color
    sudo sed -i "s/^#Color/Color/" /etc/pacman.conf
    # Remove beep
    sudo rmmod pcspkr
    sudo echo "blacklist pcspkr" > /etc/modprobe.d/nobeep.conf
    # Fish-greeting func
    echo -e "function fish_greeting\n\tprintf '\\\n fish\\\n'\nend\n" > ~/.config/fish/functions/fish_greeting.fish
    # Cleanup
    rm -r ~/Sync
    # Dotfiles 
    mkdir ~/.cfg
    git clone --bare https://github.com/hyphenc/dotfiles ~/.cfg/
    git --git-dir=$HOME/.cfg/ --work-tree=$HOME config --local status.showUntrackedFiles no
    git --git-dir=$HOME/.cfg/ --work-tree=$HOME checkout
    # Fish shell setup
    printf "\nInstalling omf and configuring fish...\n\n"
    # Fish abbreviations
    fish -c 'abbr -a bm "bash ~/code/cmods/bm.sh"; abbr -a cdd "cd ~/Downloads"; abbr -a gaa "git add -A"; abbr -a gcm "git commit -S -m"; abbr -a gpo "git push origin"; abbr -a gst "git status"; abbr -a lsl "ls -l --block-size=M"; abbr -a news "newsboat"; abbr -a org "bash ~/code/shell/org.sh"; abbr -a p "sudo pacman"; abbr -a pws "python -m http.server"; abbr -a s "sudo systemctl"; abbr -a ß "proxychains"; abbr -a y "yay"; abbr -a cfg "git --git-dir=$HOME/.cfg/ --work-tree=$HOME"'
    # Set environment variables
    fish -c "set -Ux SHELL /usr/bin/fish; set -Ux EDITOR nvim; set -Ux BM_BMPATH $HOME/code/cmods/bm.html"
}
firewall() {
    printf "\nConfiguring firewall...\n\n"
    sudo ufw default deny
    # transmission
    sudo ufw allow Transmission
    # syncthing
    sudo ufw allow syncthing
    sudo ufw allow syncthing-gui
    # lan
    sudo ufw allow from 192.168.178.0/24
    # kdeconnect
    sudo ufw allow 1714:1764/udp
    sudo ufw allow 1714:1764/tcp
    # enable
    sudo ufw status
    sudo ufw --force enable
    sudo systemctl enable ufw
}
setupssh() {
    printf "\nConfiguring SSH\n\n"
    read -rp "port? : " sshport
    printf "Port %s\nPermitRootLogin no\nMaxAuthTries 2\nMaxSessions 2\nPubkeyAuthetication yes\nAuthorizedKeysFile .ssh/authorized_keys\nPasswordAuthentication no\nPermitEmptyPasswords no\nChallengeResponseAuthentication no\nUsePAM yes\nPrintMotd no\nX11Forwarding no\nSubsystem sftp /usr/lib/ssh/sftp-server\n" "$sshport" > /etc/ssh/sshd_config
    sudo ufw allow "$sshport"
    sudo systemctl start sshd
    sudo systemctl enable sshd
}
finished() {
    printf "\nConsider:\n Changing default shell to fish\n Enabling ssh with argument 'setupssh' \n Setting user password in gnome (to log in with gdm)\n Setting up email in Evolution\n Installing omf (curl -sL https://get.oh-my.fish | fish)\n And configuring it (fish -c omf install archlinux cd agnoster shellder && omf theme agnoster)\n running ./installarch later"
    printf "\nDone with setup. Have fun!\n\n"
}
case $1 in
    start)
        startscript ;;
    postchroot)
        postchroot ;;
    postreboot)
        installpkg
        userconfigs
        firewall
        finished ;;
    later)
	gnomeconfig ;;
    purge)
        purgepkg ;;
    setupssh)
        setupssh ;;
    *)
        printf "\n./installarch.sh [option]\n start: this is the first thing you run\n postreboot: run this after reboot\n purge: run this to remove packages\n setupssh: set up remote ssh access\n later: stuff you can run later\n\n" ;;
esac
