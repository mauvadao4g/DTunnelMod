#!/bin/bash

FLARE='vps878.maudossh.shop'
VPS='151.244.242.173'
PORTA='22'
USER='root'
SSHKEY="$HOME/.ssh/vps878"
TRAJETO='~/'

FILE=(
    'dtMod.zip'
    'build_app'
    'install.sh'
    'send_vps.sh'
    'vps878.sh'
    'run.sh'
)

 echo '-------------------------------------'
echo -e "\e[1;33mEnviando files: ${FILE[*]}\e[0m"
echo '-------------------------------------'

for files in "${FILE[@]}"; do

    if scp \
        -P "$PORTA" \
        -o IdentitiesOnly=yes \
        -i "$SSHKEY" \
        -r "$files" \
        "${USER}@${VPS}:${TRAJETO}" \
        >/dev/null 2>&1
    then
        echo -e "\e[1;32mEnviado com sucesso: $files\e[0m"
    else
        echo -e "\e[1;31mErro ao enviar: $files\e[0m"
    fi

done
