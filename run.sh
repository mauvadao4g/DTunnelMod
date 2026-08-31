#!/bin/bash

HOST='151.244.242.173'
CHAVE='vps878'
SSHKEY=~/.ssh/${CHAVE}
PORTA='22'
USER='root'
VPS_DOMINIO='vps878.maudossh.shop'
VPS_PORT='3001'
ADMIN_EMAIL='mauvadao4g@gmail.com'
ADMIN_PASSWORD="${MINHASENHA}"
INSTALL='install.sh'

_remote(){
ssh -p ${PORTA} -i ${SSHKEY}  ${USER}@${HOST}  '[[ -d /opt/dtunnel ]] && rm -rf /opt/dtunnel/*'

DOMAIN=${VPS_DOMINIO} \
  PORT=${VPS_PORT} ADMIN_EMAIL=${ADMIN_EMAIL} \
  ADMIN_PASSWORD=${ADMIN_PASSWORD} \
  SKIP_DNS_CHECK=1 \
  ./${INSTALL} --remote
}


_local(){
ZIP=dtMod.zip DOMAIN=${VPS_DOMINIO} PORT=${VPS_PORT} \
   ADMIN_EMAIL=${ADMIN_EMAIL}  \
   ADMIN_PASSWORD=${ADMIN_PASSWORD} \
   ASSUME_YES=1 \
   ./${INSTALL}
}


case "$1" in
-r|r|--remote|remote|vps|--vps)
_remote
;;

-l|l|--local|local)
_local
;;
*)
echo "$0 <--remote|--local>"
echo '--remote: Instala remotamente na vps'
echo '--local:  Instala localmente no local do script'
esac
