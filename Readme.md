# installarch.sh
a bash script that installs and configures arch linux for me.

expects an nvme ssd to be under `/dev/nvme0n1`, partition variables can be customized in the script though.

because the script does most things automatically without asking you should have a look at it before you use it, and not just blindly run it.

furthermore, it pretty much only gets updated when i get a new machine.

## usage
```
curl https://raw.githubusercontent.com/hyphenc/installarch/master/installarch.sh -o installarch.sh
bash ./installarch.sh
```
