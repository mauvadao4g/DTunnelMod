#!/bin/bash

FLARE='vps878.maudossh.shop'
VPS='151.244.242.173'
PORTA='22'
USER='root'
SSHKEY=~/.ssh/vps878

mkdir -p ~/.ssh

# Gera a chave se nao existir.
[[ ! -f "$SSHKEY" ]] && {
	ssh-keygen -t ed25519 -f "$SSHKEY" -N "" -C "vps878" || {
		echo "Erro ao gerar a chave SSH."
		exit 1
	}
	echo "SSH key generated successfully."
}

# Copia a chave publica caso o login ainda nao funcione.
if ! ssh -p "$PORTA" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=5 \
	-i "$SSHKEY" "${USER}@${VPS}" exit 2>/dev/null; then
	echo "Copiando a chave publica para a VPS..."
	ssh-copy-id -p "$PORTA" -o IdentitiesOnly=yes -i "${SSHKEY}.pub" "${USER}@${VPS}" || {
		echo "Erro ao copiar a chave para a VPS."
		exit 1
	}
fi

ssh -p "$PORTA" -o IdentitiesOnly=yes -i "$SSHKEY" "${USER}@${VPS}"
