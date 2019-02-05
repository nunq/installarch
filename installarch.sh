#!/usr/bin/bash
# credit: https://gist.github.com/android10/3b36eb4bbb7e990a414ec4126e7f6b3f
# For laptops:
#   Disks: AHCI
#   Secure Boot: off

first() {
    ## Mostly Disk and partition configuration
    # Set keymap
    loadkeys de-latin1
    echo -e "\nSetup internet access\n"
    ip link show
    read -rp "net interface? (to skip this, press enter): " netint
    wifi-menu $netint
    # Sync clock
    timedatectl set-ntp true
    echo -e "\nCreate partitions\n"
    lsblk
    cgdisk
    wait
    # 1G EFI partition
    #   Hex code ef00
    #   Label boot
    # 4G Swap partition
    #   Hex code 8200
    #   Label swap
    # XG Linux partition
    #   Hex code 8300
    #   Label root
    echo -e "\nDisk setup\n"
    lsblk -f
    read -rp "boot partition? : " bootpart
    read -rp "linux partition? : " linuxpart
    read -rp "swap partition? (to skip this, press enter) : " swappart
    echo -e "\nCreating boot partition...\n"
    mkfs.fat -F32 "$bootpart"
    echo -e "\nSetup LUKS\n"
    echo -e "\nCreate LUKS encrypted partition\n"
    cryptsetup luksFormat "$linuxpart"
    echo -e "\nOpen LUKS encrypted partition\n"
    cryptsetup open "$linuxpart" luks
    mkfs.btrfs -L luks /dev/mapper/luks
    echo -e "\nCreating (or not creating) swap space...\n"
    # If $swappart is empty, mkswap will fail, but that's ok.
    mkswap "$swappart"
    echo -e "\nSetting up partitions...\n"
    # Create btrfs subvolumes
    mount -t btrfs /dev/mapper/luks /mnt
    btrfs subvolume create /mnt/@root
    btrfs subvolume create /mnt/@home
    btrfs subvolume create /mnt/@snapshots
    # Mount btrfs subvolumes
    umount /mnt
    mount -o subvol=@root /dev/mapper/luks /mnt
    mkdir /mnt/home
    mkdir /mnt/.snapshots
    mount -o subvol=@home /dev/mapper/luks /mnt/home
    mount -o subvol=@snapshots /dev/mapper/luks /mnt/.snapshots
    # Mount EFI partition
    mkdir /mnt/boot
    mount "$bootpart" /mnt/boot
    ## Pacman, pacstrap, fstab, chroot
    echo -e "\nPacman configuration and pacstrap...\n"
    # Configure pacman mirrors
    printf "Server = https://ftp.halifax.rwth-aachen.de/archlinux/\$repo/os/\$arch\nServer = http://archlinux.mirror.iphh.net/\$repo/os/\$arch\nServer = https://mirror.netcologne.de/archlinux/\$repo/os/\$arch\nServer = https://archlinux.nullpointer.io/\$repo/os/\$arch\nServer = https://packages.oth-regensburg.de/archlinux/\$repo/os/\$arch\nServer = http://ftp.uni-hannover.de/archlinux/\$repo/os/\$arch\n" | cat - /etc/pacman.d/mirrorlist > /etc/pacman.d/mirrorlist.new && mv /etc/pacman.d/mirrorlist.new /etc/pacman.d/mirrorlist
    # Install base & base-devel and mandatory packages for further setup
    pacstrap /mnt base base-devel intel-ucode networkmanager git curl
    echo -e "\nConfiguring fstab...\n"
    genfstab -L /mnt >> /mnt/etc/fstab
    printf "# !delete this!\n# Verify and adjust /mnt/etc/fstab\n# For all btrfs filesystems consider:\n# - Change relatime to noatime to reduce wear on SSD\n# - Adding discard to enable continuous TRIM for SSD\n# - Adding autodefrag to enable automatic defragmentation" >> /mnt/etc/fstab
    nano /mnt/etc/fstab
    echo -e "\nChrooting into /mnt..., please rerun this script with 'postchroot'\n"
    arch-chroot /mnt
}

postchroot() {
    echo -e "\nSetting up time...\n"
    rm /etc/localtime
    ln -s /usr/share/zoneinfo/Europe/Berlin /etc/localtime
    hwclock --systohc
    echo "en_DK.UTF-8 UTF-8" | cat - /etc/locale.gen > /tmp/localegen && mv /tmp/localegen /etc/locale.gen
    locale-gen
    echo -e "\nSetting locale and keymap...\n"
    echo "LANG=en_DK.UTF-8" > /etc/locale.conf
    echo "KEYMAP=de" > /etc/vconsole.conf
    echo -e "\nConfiguring hostname...\n"
    read -rp "hostname? : " hostnamevar
    echo "$hostnamevar" > /etc/hostname
    curl -s https://raw.githubusercontent.com/StevenBlack/hosts/master/alternates/fakenews-gambling/hosts > /etc/hosts
    echo -e "\nSet root password\n"
    passwd
    echo -e "\nAdding a normal user...\n"
    read -rp "username? : " username
    useradd -m -G wheel $username
    passwd $username
    echo "$username ALL=(ALL) ALL" > /etc/sudoers.d/nils
    ## setup boot
    echo -e "\nConfiguring mkinitcpio...\n"
    sed -i 's/HOOKS=(.*/# --- !!! please check this !!! ---\nHOOKS=(base systemd autodetect modconf block keyboard sd-vconsole sd-encrypt filesystems fsck)/' /etc/mkinitcpio.conf
    nano /etc/mkinitcpio.conf
    wait
    echo -e "\nRegenerating initrd img...\n"
    mkinitcpio -p linux
    echo -e "\nConfiguring boot...\n"
    # Setting up systemd-boot
    bootctl --path=/boot install
    # Creating bootloader entry
    luksuuid=$(cryptsetup luksUUID $linuxpart)
    printf "title\tArch Linux\nlinux\t/vmlinuz-linux\ninitrd\t/intel-ucode.img\ninitrd\t/intramfs-linux.img\noptions\trw luks.uuid=$luksuuid luks.name=$luksuuid=luks root=/dev/mapper/luks rootflags=subvol=@root\n" > /boot/loader/entries/arch.conf
    #Setting default bootloader entry
    printf "default arch\neditor no\nauto-entries 1\n" > /boot/loader/loader.conf
    echo -e "\nRebooting...\n"
    exit
    reboot
}

installpkg() {
    echo -e "\nUpdating system...\n"
    sudo pacman -Syyu
    echo -e "\nInstalling yay...\n"
    git clone https://aur.archlinux.org/yay.git
    cd yay
    makepkg -si
    echo -e "\nInstalling packages...\n" #update pastes +sshfs,bluez
    yay -S --needed --noconfirm $(curl -s http://ix.io/1zX5 | tr "\n" " ")
}

fish() {
    echo -e "\nChanging default shell to fish\n"
    chsh -s /usr/bin/fish
    echo -e "\nInstalling omf and configuring fish...\n"
    curl -sL https://get.oh-my.fish | fish
    omf install archlinux cd fish-spec omf agnoster shellder fonts
    omf theme shellder
    fonts install --available Inconsolata
    # Fish-greeting func
    printf "function fish_greeting\n\techo -e '\\\n fish\\\n'\nend\n" > ~/.config/fish/functions/fish_greeting.fish
    # Fish abbreviations
    abbr -a ß proxychains
    abbr -a org "bash ~/code/shell/org.sh"
    abbr -a lsl "ls -l --block-size=M"
    abbr -a p "sudo pacman"
    abbr -a y "yay"
    abbr -a cdd "cd ~/Downloads"
    abbr -a pws "python -m http.server"
    abbr -a bm "bash ~/code/cmods/bm.sh"
    abbr -a s "sudo systemctl"
    abbr -a news "newsboat"
    # Set environment variables
    set -Ux SHELL /usr/bin/fish
    set -Ux EDITOR nvim
}

system() {
    echo -e "\nConfiguring systemd services...\n"
    sudo systemctl enable NetworkManager
    sudo systemctl enable cronie
    sudo systemctl enable bluetooth
    sudo systemctl enable gdm
}

gnome() {
    echo -e "\nConfiguring gnome...\n"
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
    gsettings set org.gnome.desktop.interface enable-animations
    gsettings set org.gnome.desktop.interface font-name "Fira Code 12"
    gsettings set org.gnome.desktop.interface gtk-theme "Equilux-compact"
    gsettings set org.gnome.desktop.interface icon-theme "Pop"
    gsettings set org.gnome.desktop.interface monospace-font-name "Fira Code 11"
    gsettings set org.gnome.desktop.interface show-battery-percentage true
    gsettings set org.gnome.shell.extensions.user-theme name "Equilux-compact"
    # Keybindings
    gsettings set org.gnome.desktop.wm.keybindings minimize ["<Super>Down"]
    gsettings set org.gnome.desktop.wm.keybindings show-desktop ['<Super>d']
    gsettings set org.gnome.desktop.wm.keybindings switch-windows ['<Alt>Tab']
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
    gsettings set org.gnome.desktop.search-providers disabled ["org.gnome.Nautilus.desktop","org.gnome.Terminal.desktop"]
    gsettings set org.gnome.desktop.sound allow-volume-above-100-percent false
    gsettings set org.gnome.system.location enabled false
}

domisc() {
    echo -e "\nConfiguring startup apps...\n"
    # Startup apps
    mkdir -p ~/.config/autostart
    chmod 700 ~/.config
    chmod 755 ~/.config/autostart
    printf "[Desktop Entry]\nName='syncthing'\nComment='Run syncthing'\nExec=nohup syncthing -no-browser -home='/home/nils/.config/syncthing'\nTerminal=false\nType=Application\n" > ~/.config/autostart/syncthing.desktop
    printf "[Desktop Entry]\nName='wipe image cache'\nComment='Run wipe image cache'\nExec='wipe -rf .cache/thumbnails/ ; wipe -rf .cache/sxiv/'\nTerminal=false\nType=Application\n" > ~/.config/autostart/wipeimagecache.desktop
    # Install fonts?
    #cp to ~/.fonts then fc-cache -f -v ?
    echo -e "\nConfiguring miscellaneous stuff...\n"
    # Get ix.io binary
    sudo curl -s ix.io/client > /usr/local/bin/ix
    sudo chmod +x /usr/bin/ix
    # Turn on pacman color
    sudo echo "Color" >> /etc/pacman.conf
    # nvim init.vim
    printf "syntax on\nset number\nset encoding=utf-8\nset nocompatible\nset clipboard=unnamedplus\n" > ~/.config/nvim/init.vim
    # .tmux.conf
    printf "set-option -g prefix C-a\nunbind-key C-b\nbind-key C-a send-prefix\n# Use m to toggle mouse mode\nunbind m\nbind m setw mouse\nset -g status-left \" \"\nset -g status-right \"%H:%M:%S\"\" \"\nset -g status-fg colour231\nset -g status-bg colour234\n# more intuitive keybindings for splitting\nunbind %\nbind h split-window -v\nunbind '\"'\nbind v split-window -h\n#set -g window-status-format \"#I:#W\"\nset -g status-interval 1\n" > ~/.tmux.conf
    # .gitconfig
    printf "[credential]\n\thelper = cache\n[user]\n\tname = hyphenc\n\temail = 46054695+hyphenc@users.noreply.github.com\n" > ~/.gitconfig
}

purge() {
    echo -e "\nRemoving packages...\n"
    yay -Rsn $(curl -s http://ix.io/LINK | tr "\n" " ")
 }

firewall() {
    echo -e "\nConfiguring firewall...\n"
    sudo ufw default deny
    # sshd
    sudo ufw allow 54191
    # transmission
    sudo ufw allow Transmission
    # syncthing
    sudo ufw allow syncthing
    sudo ufw allow syncthing-gui
    # testing port
    sudo ufw allow 8000
    # lan
    sudo ufw allow from 192.168.0.0/24
    # kdeconnect
    sudo ufw allow 1714:1764/udp
    sudo ufw allow 1714:1764/tcp
    # enable
    sudo ufw status
    sudo ufw --force enable
    sudo systemctl enable ufw
}

setupssh() {
    echo -e "\nConfiguring SSH\n"
    echo -e "Port 54191\nPermitRootLogin no\nMaxAuthTries 2\nMaxSessions 2\nPubkeyAuthetication yes\nAuthorizedKeysFile .ssh/authorized_keys\nPasswordAuthentication no\nPermitEmptyPasswords no\nChallengeResponseAuthentication no\nUsePAM yes\nPrintMotd no\nX11Forwarding no\nSubsystem sftp /usr/lib/ssh/sftp-server" > /etc/ssh/sshd_config
    sudo systemctl start sshd
    sudo systemctl enable sshd
}

finished() {
    echo -e "\nconsider:\n Changing root shell to fish\n Enabling ssh with argument 'setupssh' \n Setting user password in gnome (to log in with gdm)\n Setting up email in Evolution"
    echo -e "\nDone with setup. Have fun!\n"
}

case $1 in
    first)
        first
        exit ;;
    postchroot)
        postchroot
        exit ;;
    postreboot)
        installpkg
        fish
        system
        gnome
        domisc
        firewall
        finished
        exit ;;
    purge)
        purge
        exit ;;
    setupssh)
        setupssh
        exit ;;
    *)
        echo -e "\n./installarch.sh [argument] options:\n first, postchroot, purge (and setupssh)\n" ;;
esac