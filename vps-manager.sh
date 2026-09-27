#!/usr/bin/env bash
# ============================================================
#  VPS-JORGEBARRIOS  -  Administracion de VPS (Ubuntu)
#  Menu SSH: usuarios, trafico, backup, banner + Webmin
#  Uso:  sudo bash vps-manager.sh
# ============================================================

set -u

ROJO='\033[1;31m'; VERDE='\033[1;32m'; AMARILLO='\033[1;33m'
AZUL='\033[1;34m'; CIAN='\033[1;36m'; BLANCO='\033[1;37m'
NC='\033[0m'

# --- LICENCIA / KEY -------------------------------------------
# El SECRET debe ser el mismo que en keygen.py
SECRET_KEY='Pitu5811*'
KEY_FILE='/etc/vps-manager.key'
PREFIJO_KEY='VPSJB1'   # prefijo de marca; tambien acepta keys viejas VPSMGR1
# URL del script en TU repo (para la opcion de auto-update)
REPO_RAW='https://raw.githubusercontent.com/pitubarrios/vps-manager/refs/heads/main/vps-manager.sh'

machine_hash(){
    if [[ -f /etc/machine-id ]]; then
        sha256sum /etc/machine-id 2>/dev/null | cut -c1-12
    else
        sha256sum /etc/hostname 2>/dev/null | cut -c1-12
    fi
}

validar_key(){
    # Uso: validar_key "$KEY"  -> 0 valida / 1 invalida
    local KEY BODY B64 SIG SIGC PAYLOAD NOMBRE EXP MACH
    KEY=$(echo "$1" | tr -d '[:space:]')
    case "$KEY" in ${PREFIJO_KEY}-*|VPSMGR1-*) ;; *) return 1 ;; esac
    BODY=${KEY#*-}
    SIG=${BODY##*-}
    B64=${BODY%-*}
    [[ -n "$B64" && -n "$SIG" && "$B64" != "$SIG" ]] || return 1
    SIGC=$(printf '%s' "$B64" | openssl dgst -sha256 -hmac "$SECRET_KEY" 2>/dev/null | awk '{print $NF}' | cut -c1-16 | tr 'a-f' 'A-F')
    [[ "$SIGC" == "$SIG" ]] || return 1
    PAYLOAD=$(printf '%s' "$B64" | base64 -d 2>/dev/null) || return 1
    NOMBRE=${PAYLOAD%%|*}; PAYLOAD=${PAYLOAD#*|}
    EXP=${PAYLOAD%%|*};  MACH=${PAYLOAD#*|}
    [[ -n "$NOMBRE" && -n "$EXP" ]] || return 1
    [[ "$EXP" != "0" && "$(date +%s)" -gt "$EXP" ]] && return 1
    if [[ -n "$MACH" && "$MACH" != "$(machine_hash)" ]]; then return 1; fi
    KEY_NOMBRE="$NOMBRE"
    KEY_EXP="$EXP"
    return 0
}

gate_licencia(){
    local INTENTOS=0 K
    if [[ -f "$KEY_FILE" ]] && validar_key "$(cat "$KEY_FILE" 2>/dev/null)"; then
        LICENSE_OK="$KEY_NOMBRE"; return 0
    fi
    echo -e "${AMARILLO}============================================================${NC}"
    echo -e "${AMARILLO}  LICENCIA REQUERIDA - VPS-JORGEBARRIOS${NC}"
    echo -e "${AMARILLO}============================================================${NC}"
    echo -e " ID de este servidor: ${BLANCO}$(machine_hash)${NC}"
    echo -e " (usa ese ID con --bind para atar la key a este VPS)\n"
    while [[ $INTENTOS -lt 3 ]]; do
        read -r -p " INGRESE SU KEY > " K
        if validar_key "$K"; then
            echo "$K" > "$KEY_FILE" 2>/dev/null
            LICENSE_OK="$KEY_NOMBRE"; LICENSE_EXP="$KEY_EXP"
            OK "Licencia aceptada. Bienvenido, ${LICENSE_OK}."
            sleep 1
            return 0
        fi
        ERR "Key invalida, expirada o de otro servidor."
        INTENTOS=$((INTENTOS+1))
    done
    echo -e "${ROJO}Sin licencia valida. Contacta al administrador.${NC}"
    exit 1
}

PAUSA(){ echo -e "\n${AMARILLO}Presiona ENTER para continuar...${NC}"; read -r; }
OK(){ echo -e "${VERDE}[OK]${NC} $1"; }
ERR(){ echo -e "${ROJO}[ERROR]${NC} $1"; }
INFO(){ echo -e "${CIAN}[INFO]${NC} $1"; }

cabecera(){
    clear
    local RAM_TOTAL RAM_USO CPU DISCO
    RAM_TOTAL=$(free -m | awk '/Mem:/{print $2}')
    RAM_USO=$(free -m | awk '/Mem:/{printf "%d%% (%dM)", $3*100/$2, $3}')
    CPU=$(top -bn1 | awk '/%Cpu/{printf "%.1f%%", 100-$8}' 2>/dev/null || echo "n/a")
    DISCO=$(df -h / | awk 'NR==2{print $5" ("$3"/"$2")"}')
    local ONLINE; ONLINE=$(who 2>/dev/null | wc -l)

    echo -e "${BLANCO}============================================================${NC}"
    echo -e "${CIAN}   VPS-JORGEBARRIOS   |   $(hostname)   |   Ubuntu $(lsb_release -rs 2>/dev/null)${NC}"
    echo -e "${BLANCO}============================================================${NC}"
    echo -e " IP      : $(curl -4 -s --max-time 3 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')"
    echo -e " Fecha   : $(date '+%d-%m-%Y   %H:%M:%S')   Uptime: $(uptime -p 2>/dev/null | cut -d' ' -f2-)"
    echo -e " RAM     : ${RAM_USO} / ${RAM_TOTAL}M    CPU: ${CPU}    Disco: ${DISCO}"
    echo -e " Online  : ${VERDE}${ONLINE}${NC} usuarios conectados   |   Webmin: $(estado_webmin_min)"
    local DIAS_LIC=""
    if [[ -n "${LICENSE_EXP:-}" && "${LICENSE_EXP:-0}" != "0" ]]; then
        DIAS_LIC=$(( (LICENSE_EXP - $(date +%s)) / 86400 ))
        [[ $DIAS_LIC -lt 0 ]] && DIAS_LIC=0
        DIAS_LIC=" (quedan ${DIAS_LIC}d)"
    fi
    echo -e " Licencia: ${VERDE}${LICENSE_OK:-sin key}${DIAS_LIC}${NC}   |   Servidor ID: $(machine_hash)"
    echo -e "${BLANCO}------------------------------------------------------------${NC}"
}

estado_webmin_min(){
    if dpkg -l webmin >/dev/null 2>&1; then
        if pgrep -f miniserv >/dev/null 2>&1; then echo -e "${VERDE}ACTIVO :10000${NC}"
        else echo -e "${AMARILLO}INSTALADO (detenido)${NC}"; fi
    else
        echo -e "${ROJO}NO INSTALADO${NC}"
    fi
}

# ------------------------------------------------------------
# GESTION DE USUARIOS SSH
# ------------------------------------------------------------
crear_usuario(){
    echo -e "${CIAN}--- CREAR USUARIO SSH ---${NC}"
    read -r -p "Nombre de usuario: " USU
    [[ -z "$USU" ]] && { ERR "Nombre vacio."; PAUSA; return; }
    id "$USU" >/dev/null 2>&1 && { ERR "El usuario ya existe."; PAUSA; return; }
    read -r -p "Dias de validez (ej. 30): " DIAS
    read -r -p "Conexion maxima (ej. 1) [1]: " MAXC; MAXC=${MAXC:-1}
    read -r -p "Contrasena: " CLAVE
    useradd -m -s /bin/bash "$USU" 2>/dev/null || { ERR "No se pudo crear."; PAUSA; return; }
    echo "$USU:$CLAVE" | chpasswd
    [[ "$DIAS" =~ ^[0-9]+$ ]] && chage -M "$DIAS" -E "$(date -d "+${DIAS} days" +%Y-%m-%d)" "$USU"
    # limite de sesiones SSH del usuario (usado por el limiter)
    mkdir -p /etc/vps-limits
    echo "$MAXC" > "/etc/vps-limits/$USU"
    getent group vpsusers >/dev/null 2>&1 && usermod -aG vpsusers "$USU" 2>/dev/null
    OK "Usuario '$USU' creado. Expira: $(chage -l "$USU" 2>/dev/null | awk -F': ' '/Password expires/{print $2}')"
    echo -e "IP: $(hostname -I | awk '{print $1}')  |  Puerto SSH: $(grep -i '^Port' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1 || echo 22)"
    PAUSA
}

cambiar_clave(){
    read -r -p "Usuario: " USU
    id "$USU" >/dev/null 2>&1 || { ERR "No existe."; PAUSA; return; }
    passwd "$USU" && OK "Clave actualizada."
    PAUSA
}

eliminar_usuario(){
    read -r -p "Usuario a eliminar: " USU
    id "$USU" >/dev/null 2>&1 || { ERR "No existe."; PAUSA; return; }
    read -r -p "Borrar tambien su /home? (s/n): " SN
    pkill -u "$USU" 2>/dev/null
    if [[ "$SN" == "s" ]]; then userdel -r "$USU" 2>/dev/null; else userdel "$USU"; fi
    OK "Usuario '$USU' eliminado."
    PAUSA
}

bloquear_usuario(){
    read -r -p "Usuario a bloquear/desbloquear: " USU
    id "$USU" >/dev/null 2>&1 || { ERR "No existe."; PAUSA; return; }
    if passwd -S "$USU" | grep -q ' L '; then usermod -U "$USU"; OK "'$USU' DESBLOQUEADO."
    else usermod -L "$USU"; pkill -u "$USU" 2>/dev/null; OK "'$USU' BLOQUEADO."; fi
    PAUSA
}

renovar_usuario(){
    read -r -p "Usuario: " USU
    id "$USU" >/dev/null 2>&1 || { ERR "No existe."; PAUSA; return; }
    read -r -p "Dias a agregar: " DIAS
    chage -M "$DIAS" -E "$(date -d "+${DIAS} days" +%Y-%m-%d)" "$USU"
    OK "'$USU' renovado por ${DIAS} dias (expira: $(chage -l "$USU" | awk -F': ' '/Password expires/{print $2}'))."
    PAUSA
}

listar_usuarios(){
    echo -e "${CIAN}--- USUARIOS DEL SISTEMA (humanos) ---${NC}"
    printf "%-16s %-22s %-14s %s\n" "USUARIO" "EXPIRA" "ESTADO" "HOME"
    awk -F: '$3>=1000 && $1!="nobody"{print $1}' /etc/passwd | while read -r U; do
        EXP=$(chage -l "$U" 2>/dev/null | awk -F': ' '/Password expires/{print $2}')
        EST=$(passwd -S "$U" 2>/dev/null | awk '{print $2}')
        [[ "$EST" == "P" ]] && EST="${VERDE}OK${NC}" || EST="${ROJO}LOCK${NC}"
        printf "%-16s %-22b %-14b %s\n" "$U" "$EXP" "$EST" "$(eval echo ~$U)"
    done
    PAUSA
}

conexiones_online(){
    echo -e "${CIAN}--- CONEXIONES ONLINE (SSH/pts) ---${NC}"
    who 2>/dev/null || echo "Sin sesiones."
    echo
    echo -e "${CIAN}Total procesos sshd:${NC} $(pgrep -c sshd 2>/dev/null || echo 0)"
    PAUSA
}

matar_conexion(){
    conexiones_online_rapido
    read -r -p "Usuario a desconectar: " USU
    pkill -u "$USU" 2>/dev/null && OK "Sesiones de '$USU' cerradas." || ERR "Sin sesiones activas."
    PAUSA
}
conexiones_online_rapido(){ who 2>/dev/null; echo; }

# ------------------------------------------------------------
# SISTEMA / RED
# ------------------------------------------------------------
monitoreo(){
    echo -e "${CIAN}--- MONITOREO ---${NC}"
    echo -e "Uptime : $(uptime)"
    free -h | sed 's/^/         /'
    echo
    df -h / /home 2>/dev/null | sed 's/^/         /'
    echo
    ss -tunap 2>/dev/null | awk 'NR>1{print $1, $5, $7}' | head -20
    PAUSA
}

optimizar(){
    INFO "Aplicando ajustes basicos de rendimiento..."
    cat > /etc/sysctl.d/99-vps-manager.conf <<EOF
vm.swappiness=10
vm.vfs_cache_pressure=50
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    modprobe tcp_bbr 2>/dev/null; echo "tcp_bbr" >> /etc/modules-load.d/bbr.conf 2>/dev/null
    sysctl --system >/dev/null 2>&1
    OK "Optimizacion aplicada (BBR + swappiness=10)."
    PAUSA
}

update_sistema(){
    INFO "Actualizando paquetes..."
    apt update && apt upgrade -y
    OK "Sistema actualizado."
    PAUSA
}

backup_basico(){
    DIR="/root/backups"; mkdir -p "$DIR"
    FILE="$DIR/backup-$(date +%F_%H%M).tar.gz"
    INFO "Creando backup de /etc, /home y lista de paquetes..."
    dpkg --get-selections > /root/paquetes.txt 2>/dev/null
    tar czf "$FILE" /etc /root/paquetes.txt --exclude=/etc/ssl/private 2>/dev/null
    OK "Backup creado: $FILE ($(du -h "$FILE" | cut -f1))"
    PAUSA
}

banner_ssh(){
    echo -e "${CIAN}--- BANNER SSH ---${NC}"
    echo "Escribe las lineas del banner (linea vacia para terminar):"
    : > /etc/banner-vps
    while IFS= read -r LINEA; do [[ -z "$LINEA" ]] && break; echo "$LINEA" >> /etc/banner-vps; done
    grep -q '^Banner' /etc/ssh/sshd_config && sed -i 's|^Banner.*|Banner /etc/banner-vps|' /etc/ssh/sshd_config || echo "Banner /etc/banner-vps" >> /etc/ssh/sshd_config
    systemctl reload sshd 2>/dev/null || systemctl reload ssh
    OK "Banner aplicado."
    PAUSA
}

# ------------------------------------------------------------
# WEBMIN  (instalador oficial vía repositorio)
# ------------------------------------------------------------
instalar_webmin(){
    echo -e "${CIAN}--- INSTALADOR WEBMIN ---${NC}"
    if dpkg -l webmin >/dev/null 2>&1; then
        INFO "Webmin ya esta instalado."
    else
        INFO "Instalando dependencias..."
        apt update -y && apt install -y curl wget gnupg2 software-properties-common
        INFO "Agregando repositorio oficial de Webmin..."
        local TMP; TMP=$(mktemp -d)
        if curl -fsSL -o "$TMP/setup-repos.sh" https://raw.githubusercontent.com/webmin/webmin/master/setup-repos.sh; then
            sh "$TMP/setup-repos.sh" -f
            INFO "Instalando Webmin..."
            apt update -y && apt install -y webmin
        else
            ERR "No se pudo descargar setup-repos.sh. Instalando .deb manual..."
            wget -q https://download.webmin.com/download/repository/pool/contrib/w/webmin/webmin_2.301_all.deb -O "$TMP/webmin.deb" \
              || wget -q https://prdownloads.sourceforge.net/webadmin/webmin_2.301_all.deb -O "$TMP/webmin.deb"
            apt install -y "$TMP/webmin.deb" || apt -f install -y
        fi
        rm -rf "$TMP"
    fi
    # firewall
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q active; then
        ufw allow 10000/tcp >/dev/null 2>&1 && INFO "Puerto 10000/tcp abierto en UFW."
    fi
    systemctl enable --now webmin 2>/dev/null
    echo
    local IP; IP=$(curl -4 -s --max-time 3 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
    OK "Webmin instalado."
    echo -e " Acceso  : ${VERDE}https://${IP}:10000${NC}"
    echo -e " Usuario : ${VERDE}root${NC} (o cualquier usuario con sudo)"
    echo -e " ${AMARILLO}Nota: si es una VM remota, acepta el aviso de certificado autofirmado.${NC}"
    PAUSA
}

remover_webmin(){
    INFO "Deteniendo y eliminando Webmin..."
    systemctl stop webmin 2>/dev/null
    apt purge -y webmin 2>/dev/null
    rm -f /etc/apt/sources.list.d/webmin.list /usr/share/keyrings/webmin.gpg
    apt update -y >/dev/null 2>&1
    OK "Webmin removido."
    PAUSA
}

menu_webmin(){
    while true; do
        cabecera
        echo -e "${BLANCO}===================== WEBMIN =====================${NC}"
        echo -e " [1] Instalar Webmin"
        echo -e " [2] Estado / Reiniciar Webmin"
        echo -e " [3] Abrir puerto 10000 (UFW)"
        echo -e " [4] Cambiar puerto de Webmin"
        echo -e " [5] Remover Webmin"
        echo -e " [0] Volver"
        read -r -p " Opcion > " OP
        case "$OP" in
            1) instalar_webmin ;;
            2) systemctl status webmin --no-pager -l | head -15; PAUSA ;;
            3) ufw allow 10000/tcp 2>/dev/null && OK "Puerto abierto." || ERR "UFW no activo."; PAUSA ;;
            4) read -r -p "Nuevo puerto: " P
               sed -i "s/^port=.*/port=$P/" /etc/webmin/miniserv.conf 2>/dev/null
               systemctl restart webmin 2>/dev/null && OK "Puerto cambiado a $P." || ERR "Webmin no instalado."
               PAUSA ;;
            5) remover_webmin ;;
            0) break ;;
            *) ERR "Opcion invalida."; sleep 1 ;;
        esac
    done
}

# ------------------------------------------------------------
# HERRAMIENTAS EXTRA
# ------------------------------------------------------------
instalar_comando_global(){
    local DEST=/usr/local/bin/vpsmgr
    if cp "$(readlink -f "$0")" "$DEST" 2>/dev/null && chmod +x "$DEST"; then
        grep -q "alias vps=" /root/.bashrc 2>/dev/null || echo "alias vps='/usr/local/bin/vpsmgr'" >> /root/.bashrc
        OK "Instalado. Ahora entras desde cualquier lado con: ${VERDE}vpsmgr${NC} (o ${VERDE}vps${NC})"
    else
        ERR "No se pudo instalar en $DEST (permisos?)."
    fi
    PAUSA
}

limiter_aplicar(){
    mkdir -p /etc/vps-limits
    cat > /usr/local/bin/vps-limiter.sh <<'LIMEOF'
#!/bin/bash
# Limiter SSH: corta la sesion extra del usuario
U="$USER"
MAX=$(cat "/etc/vps-limits/$U" 2>/dev/null || echo 1)
N=$(who 2>/dev/null | awk -v u="$U" '$1==u' | wc -l)
if [ "$N" -ge "$MAX" ] && [ -n "$SSH_CONNECTION" ]; then
    T=$(tty 2>/dev/null | sed 's|/dev/||')
    echo "Limite de $MAX sesiones alcanzado."
    [ -n "$T" ] && pkill -KILL -t "$T" 2>/dev/null
    exit 0
fi
exec /bin/bash -l
LIMEOF
    chmod +x /usr/local/bin/vps-limiter.sh 2>/dev/null || { ERR "Sin permiso para escribir /usr/local/bin"; PAUSA; return; }
    sed -i '/# VPS-LIMITER-INICIO/,/# VPS-LIMITER-FIN/d' /etc/ssh/sshd_config
    {
      echo "# VPS-LIMITER-INICIO"
      echo "Match Group vpsusers"
      echo "    ForceCommand /usr/local/bin/vps-limiter.sh"
      echo "# VPS-LIMITER-FIN"
    } >> /etc/ssh/sshd_config
    getent group vpsusers >/dev/null 2>&1 || groupadd vpsusers
    for f in /etc/vps-limits/*; do
        [ -f "$f" ] && usermod -aG vpsusers "$(basename "$f")" 2>/dev/null
    done
    systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null
    OK "Limiter activo. Usuarios con limite: $(ls /etc/vps-limits/ 2>/dev/null | tr '\n' ' ')"
    INFO "Ojo: a los usuarios limitados se les deshabilita SFTP (ForceCommand)."
    PAUSA
}

limiter_quitar(){
    sed -i '/# VPS-LIMITER-INICIO/,/# VPS-LIMITER-FIN/d' /etc/ssh/sshd_config
    systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null
    OK "Limiter desactivado."
    PAUSA
}

instalar_fail2ban(){
    INFO "Instalando fail2ban (anti fuerza bruta SSH)..."
    apt update -y >/dev/null 2>&1
    apt install -y fail2ban >/dev/null 2>&1
    cat > /etc/fail2ban/jail.local <<'F2BEOF'
[sshd]
enabled  = true
port     = ssh
maxretry = 5
bantime  = 1h
F2BEOF
    systemctl enable --now fail2ban 2>/dev/null
    OK "Fail2ban activo: 5 intentos fallidos = baneo de 1 hora."
    PAUSA
}

cambiar_puerto_ssh(){
    read -r -p "Puerto SSH nuevo (ej. 2222): " P
    [[ "$P" =~ ^[0-9]+$ && "$P" -ge 1 && "$P" -le 65535 ]] || { ERR "Puerto invalido."; PAUSA; return; }
    sed -i 's/^#\?Port .*/Port '$P'/' /etc/ssh/sshd_config
    grep -q "^Port $P" /etc/ssh/sshd_config || echo "Port $P" >> /etc/ssh/sshd_config
    ufw allow "$P/tcp" >/dev/null 2>&1
    systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null
    OK "Puerto SSH: $P. ${AMARILLO}Abri otra terminal y proba conectarte ANTES de cerrar esta.${NC}"
    PAUSA
}

ver_puertos(){
    echo -e "${CIAN}--- PUERTOS ESCUCHANDO (TCP) ---${NC}"
    ss -tlnp 2>/dev/null | head -25
    echo
    echo -e "${CIAN}--- UFW (firewall) ---${NC}"
    if command -v ufw >/dev/null 2>&1; then
        ufw status verbose 2>/dev/null | head -20
    else
        echo "UFW no instalado."
    fi
    PAUSA
}

abrir_puerto(){
    read -r -p "Puerto a abrir (ej. 8080): " P
    [[ "$P" =~ ^[0-9]+$ && "$P" -ge 1 && "$P" -le 65535 ]] || { ERR "Puerto invalido."; PAUSA; return; }
    read -r -p "Protocolo (tcp/udp) [tcp]: " PROTO; PROTO=${PROTO:-tcp}
    [[ "$PROTO" != "tcp" && "$PROTO" != "udp" ]] && { ERR "Protocolo invalido."; PAUSA; return; }
    if ! command -v ufw >/dev/null 2>&1; then
        INFO "UFW no instalado, instalando..."
        apt update -y >/dev/null 2>&1 && apt install -y ufw >/dev/null 2>&1
    fi
    if ! ufw status 2>/dev/null | grep -q "Status: active"; then
        read -r -p "UFW no esta activo. Activarlo ahora? (s/n): " SN
        [[ "$SN" == "s" ]] && { ufw --force enable; INFO "UFW activado."; }
    fi
    ufw allow "$P/$PROTO" >/dev/null 2>&1 && OK "Puerto $P/$PROTO abierto."
    ufw status 2>/dev/null | grep -E "^$P/" || ERR "No se confirmo la regla."
    PAUSA
}

cambiar_limite(){
    echo -e "${CIAN}--- CAMBIAR LIMITE DE SESIONES ---${NC}"
    ls /etc/vps-limits/ 2>/dev/null | while read -r U; do
        printf "  %-16s max: %s\n" "$U" "$(cat /etc/vps-limits/$U 2>/dev/null)"
    done
    read -r -p "Usuario: " USU
    [[ -f "/etc/vps-limits/$USU" ]] || { ERR "Ese usuario no tiene limite (creado fuera del script?)."; PAUSA; return; }
    read -r -p "Nuevo maximo de sesiones: " M
    [[ "$M" =~ ^[0-9]+$ ]] || { ERR "Numero invalido."; PAUSA; return; }
    echo "$M" > "/etc/vps-limits/$USU"
    OK "Limite de '$USU' actualizado a $M sesiones."
    PAUSA
}

crear_test_ssh(){
    echo -e "${CIAN}--- CREAR USUARIO DE PRUEBA (vence en 1 dia) ---${NC}"
    read -r -p "Nombre base (le agrego prefijo test-): " NOMBRE
    local USU CLAVE
    USU="test-$(echo "$NOMBRE" | tr -cd 'a-zA-Z0-9' | tr 'A-Z' 'a-z' | cut -c1-18)"
    id "$USU" >/dev/null 2>&1 && { ERR "Ya existe."; PAUSA; return; }
    read -r -p "Conexion maxima [1]: " MAXC; MAXC=${MAXC:-1}
    CLAVE=$(tr -dc 'a-zA-Z0-9' </dev/urandom 2>/dev/null | head -c 10)
    [[ -z "$CLAVE" ]] && CLAVE="test123456"
    useradd -m -s /bin/bash "$USU" 2>/dev/null || { ERR "No se pudo crear."; PAUSA; return; }
    echo "$USU:$CLAVE" | chpasswd
    chage -M 1 -E "$(date -d '+1 day' +%Y-%m-%d)" "$USU" 2>/dev/null
    mkdir -p /etc/vps-limits; echo "$MAXC" > "/etc/vps-limits/$USU"
    getent group vpsusers >/dev/null 2>&1 && usermod -aG vpsusers "$USU" 2>/dev/null
    OK "Usuario de prueba creado:"
    echo -e "  Usuario: ${VERDE}$USU${NC}   Clave: ${VERDE}$CLAVE${NC}"
    echo -e "  ${AMARILLO}Vence manana. IP: $(hostname -I | awk '{print $1}')  Puerto: $(grep -i '^Port' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1 || echo 22)${NC}"
    PAUSA
}

eliminar_vencidos(){
    local HOY N BORRADOS=0 U EXP
    HOY=$(date +%Y-%m-%d)
    for U in $(awk -F: '$3>=1000 && $1!="nobody"{print $1}' /etc/passwd); do
        EXP=$(chage -l "$U" 2>/dev/null | awk -F': ' '/Password expires/{print $2}')
        [[ -z "$EXP" || "$EXP" == "never" ]] && continue
        N=$(date -d "$EXP" +%Y-%m-%d 2>/dev/null) || continue
        if [[ "$N" < "$HOY" ]]; then
            pkill -u "$U" 2>/dev/null
            rm -f "/etc/vps-limits/$U"
            userdel -r "$U" 2>/dev/null
            INFO "Eliminado vencido: $U (vencio: $N)"
            BORRADOS=$((BORRADOS+1))
        fi
    done
    [[ $BORRADOS -eq 0 ]] && OK "No hay usuarios vencidos." || OK "Eliminados $BORRADOS usuarios vencidos."
    PAUSA
}

mantenimiento(){
    INFO "Limpiando sistema..."
    apt autoremove -y >/dev/null 2>&1
    apt clean >/dev/null 2>&1
    journalctl --vacuum-time=7d >/dev/null 2>&1
    find /tmp -type f -mtime +7 -delete 2>/dev/null
    ls -t /root/backups/*.tar.gz 2>/dev/null | tail -n +4 | xargs -r rm -f
    find /var/log -name "*.gz" -mtime +7 -delete 2>/dev/null
    OK "Listo: paquetes huerfanos, logs viejos, /tmp y backups (conservo los ultimos 3)."
    PAUSA
}

auto_menu(){
    if grep -q "VPS-JB-AUTOMENU-INICIO" "$HOME/.bashrc" 2>/dev/null; then
        OK "El auto-menu ya estaba activo."; PAUSA; return
    fi
    cat >> "$HOME/.bashrc" <<'AMEOF'
# VPS-JB-AUTOMENU-INICIO
case "$-" in *i*) [ -x /usr/local/bin/vpsmgr ] && /usr/local/bin/vpsmgr ;; esac
# VPS-JB-AUTOMENU-FIN
AMEOF
    OK "Auto-menu activo: la proxima vez que root inicie sesion (SSH o consola), el menu abre solo."
    PAUSA
}

quitar_auto_menu(){
    sed -i '/VPS-JB-AUTOMENU-INICIO/,/VPS-JB-AUTOMENU-FIN/d' "$HOME/.bashrc" 2>/dev/null
    OK "Auto-menu desactivado."
    PAUSA
}

diagnostico(){
    echo -e "${CIAN}--- DIAGNOSTICO DEL SERVIDOR ---${NC}"
    local RAM_P DISCO_P LOAD ADV=0
    RAM_P=$(free | awk '/Mem/{printf "%d", $3*100/$2}')
    DISCO_P=$(df -h / | awk 'NR==2{gsub(/%/,"",$5); print $5}')
    LOAD=$(cut -d' ' -f1 /proc/loadavg)
    echo -e " RAM: ${RAM_P}%   Disco: ${DISCO_P}%   Carga: $LOAD"
    [[ "$RAM_P" -gt 85 ]]    && { echo -e " ${ROJO}!${NC} RAM al ${RAM_P}%: cerrar procesos o agregar swap."; ADV=1; }
    [[ "$DISCO_P" -gt 85 ]]  && { echo -e " ${ROJO}!${NC} Disco al ${DISCO_P}%: correr Mantenimiento (26) y revisar /root/backups."; ADV=1; }
    systemctl is-failed --quiet sshd 2>/dev/null && { echo -e " ${ROJO}!${NC} sshd con fallos: 'systemctl status sshd'."; ADV=1; }
    pgrep -f miniserv >/dev/null 2>&1 || echo -e " ${AMARILLO}-${NC} Webmin no corre (menu 11)."
    lastb -i 2>/dev/null | head -5 | grep -q . && echo -e " ${AMARILLO}-${NC} Intentos de login fallidos recientes: conviene Fail2ban (17)."
    [[ $ADV -eq 0 ]] && echo -e " ${VERDE}OK${NC} Sin alertas graves."
    PAUSA
}

cambiar_hostname(){
    echo -e "${CIAN}Hostname actual: ${BLANCO}$(hostname)${NC}"
    read -r -p "Nuevo hostname (sin espacios, ej. vps): " H
    [[ -z "$H" || "$H" =~ [^a-zA-Z0-9.-] ]] && { ERR "Hostname invalido."; PAUSA; return; }
    hostnamectl set-hostname "$H" 2>/dev/null || { ERR "No se pudo cambiar."; PAUSA; return; }
    sed -i "s/127.0.1.1.*/127.0.1.1\t$H/" /etc/hosts 2>/dev/null
    OK "Hostname cambiado a '$H'. Se ve completo en la proxima sesion."
    PAUSA
}

auto_update(){
    [[ -z "$REPO_RAW" ]] && { ERR "REPO_RAW sin configurar."; PAUSA; return; }
    INFO "Descargando ultima version desde tu repo..."
    if wget -q "$REPO_RAW" -O /tmp/vpsmgr.new 2>/dev/null && bash -n /tmp/vpsmgr.new; then
        cp /tmp/vpsmgr.new /usr/local/bin/vpsmgr 2>/dev/null || cp /tmp/vpsmgr.new "$(readlink -f "$0")" 2>/dev/null
        chmod +x /usr/local/bin/vpsmgr 2>/dev/null
        OK "Script actualizado. Volves a entrar con vpsmgr."
    else
        ERR "No se pudo actualizar (sin red o repo caido)."
    fi
    PAUSA
}

# ------------------------------------------------------------
# CHECKUSER API (para apps cliente: validar usuarios SSH en JSON)
# ------------------------------------------------------------
checkuser_instalar(){
    echo -e "${CIAN}--- INSTALADOR CHECKUSER ---${NC}"
    local PORT TOKEN
    read -r -p "Puerto para el checkuser [8080]: " PORT; PORT=${PORT:-8080}
    [[ "$PORT" =~ ^[0-9]+$ ]] || { ERR "Puerto invalido."; PAUSA; return; }
    read -r -p "Token de seguridad (entero = aleatorio): " TOKEN
    [[ -z "$TOKEN" ]] && TOKEN=$(tr -dc 'a-zA-Z0-9' </dev/urandom 2>/dev/null | head -c 20)
    printf 'PORT=%s\nTOKEN=%s\n' "$PORT" "$TOKEN" > /etc/vps-checkuser.conf

    cat > /usr/local/bin/vps-checkuser.py <<'PYEOF'
#!/usr/bin/env python3
import json, subprocess, time
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs
CONF = "/etc/vps-checkuser.conf"
def conf():
    d = {"PORT": "8080", "TOKEN": ""}
    try:
        for line in open(CONF):
            k, _, v = line.strip().partition("=")
            if k in ("PORT", "TOKEN"): d[k] = v.strip()
    except FileNotFoundError: pass
    return d
def sh(*a):
    return subprocess.run(a, capture_output=True, text=True)
def user_info(name):
    if sh("id", name).returncode != 0:
        return {"username": name, "exists": False, "status": "notfound"}
    exp = ""
    for line in sh("chage", "-l", name).stdout.splitlines():
        if line.startswith("Password expires"):
            exp = line.split(":", 1)[1].strip()
    days, status = None, "active"
    if exp and exp != "never":
        try:
            ts = time.mktime(time.strptime(exp, "%b %d, %Y"))
            days = int((ts - time.time()) // 86400)
            if days < 0: status = "expired"
        except ValueError: pass
    try: lim = open(f"/etc/vps-limits/{name}").read().strip()
    except FileNotFoundError: lim = None
    who = sh("who").stdout
    online = sum(1 for l in who.splitlines() if l.split() and l.split()[0] == name)
    return {"username": name, "exists": True, "status": status,
            "password_expires": exp, "days_left": days,
            "online": online, "limit": lim}
class H(BaseHTTPRequestHandler):
    def _send(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers(); self.wfile.write(b)
    def log_message(self, *a): pass
    def do_GET(self):
        c = conf(); u = urlparse(self.path); qs = parse_qs(u.query)
        if c["TOKEN"] and qs.get("token", [""])[0] != c["TOKEN"]:
            return self._send(403, {"error": "forbidden"})
        if u.path in ("/checkuser.php", "/checkuser", "/check"):
            name = qs.get("user", [""])[0]
            if not name: return self._send(400, {"error": "falta parametro user"})
            return self._send(200, user_info(name))
        if u.path == "/status":
            who = [l for l in sh("who").stdout.splitlines() if l.strip()]
            tot = sh("awk", "-F:", "$3>=1000 && $1!=\"nobody\"", "/etc/passwd").stdout
            return self._send(200, {"service": "checkuser", "online_now": len(who),
                                    "total_users": len([l for l in tot.splitlines() if l.strip()])})
        return self._send(404, {"error": "not found"})
if __name__ == "__main__":
    c = conf()
    print(f"checkuser en 0.0.0.0:{c['PORT']}", flush=True)
    HTTPServer(("0.0.0.0", int(c["PORT"])), H).serve_forever()
PYEOF
    chmod +x /usr/local/bin/vps-checkuser.py

    cat > /etc/systemd/system/vps-checkuser.service <<SVCEOF
[Unit]
Description=CheckUser API (VPS-JORGEBARRIOS)
After=network.target

[Service]
ExecStart=/usr/bin/python3 /usr/local/bin/vps-checkuser.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SVCEOF
    systemctl daemon-reload
    systemctl enable --now vps-checkuser 2>/dev/null
    ufw allow "$PORT/tcp" >/dev/null 2>&1
    local IP; IP=$(hostname -I | awk '{print $1}')
    OK "CheckUser instalado y corriendo."
    echo -e " Prueba desde la VM:  curl http://localhost:$PORT/checkuser.php?user=TUUSUARIO&token=$TOKEN"
    echo -e " Desde afuera:        http://$IP:$PORT/checkuser.php?user=TUUSUARIO&token=$TOKEN"
    echo -e " ${AMARILLO}Guarda este token, se guarda en /etc/vps-checkuser.conf${NC}"
    PAUSA
}

checkuser_probar(){
    local P T IP
    P=$(awk -F= '/^PORT=/{print $2}' /etc/vps-checkuser.conf 2>/dev/null)
    T=$(awk -F= '/^TOKEN=/{print $2}' /etc/vps-checkuser.conf 2>/dev/null)
    IP=$(hostname -I | awk '{print $1}')
    read -r -p "Usuario a consultar: " U
    echo
    curl -s "http://localhost:${P:-8080}/checkuser.php?user=$U&token=$T" && echo || ERR "No responde. Estado:"
    systemctl status vps-checkuser --no-pager 2>/dev/null | head -6
    PAUSA
}

checkuser_quitar(){
    systemctl disable --now vps-checkuser 2>/dev/null
    rm -f /usr/local/bin/vps-checkuser.py /etc/systemd/system/vps-checkuser.service /etc/vps-checkuser.conf
    systemctl daemon-reload 2>/dev/null
    OK "CheckUser removido."
    PAUSA
}

menu_checkuser(){
    while true; do
        cabecera
        echo -e "${BLANCO}==================== CHECKUSER API ====================${NC}"
        echo -e " [1] Instalar / reinstalar"
        echo -e " [2] Estado del servicio"
        echo -e " [3] Probar consulta (consulta un usuario)"
        echo -e " [4] Ver token y puerto"
        echo -e " [5] Remover"
        echo -e " [0] Volver"
        read -r -p " Opcion > " OP
        case "$OP" in
            1) checkuser_instalar ;;
            2) systemctl status vps-checkuser --no-pager 2>/dev/null | head -15; PAUSA ;;
            3) checkuser_probar ;;
            4) cat /etc/vps-checkuser.conf 2>/dev/null || ERR "No instalado."; PAUSA ;;
            5) checkuser_quitar ;;
            0) break ;;
            *) ERR "Opcion invalida."; sleep 1 ;;
        esac
    done
}

# ------------------------------------------------------------
# MENU PRINCIPAL
# ------------------------------------------------------------
[[ $EUID -ne 0 ]] && { echo -e "${ROJO}Ejecuta como root o con sudo.${NC}"; exit 1; }

gate_licencia

while true; do
    cabecera
    echo -e "${BLANCO}--------- GESTION DE USUARIOS / SSH / SISTEMA ---------${NC}"
    echo -e " ${AZUL}[1]${NC} Crear usuario SSH      ${AZUL}[6]${NC}  Listar usuarios"
    echo -e " ${AZUL}[2]${NC} Cambiar clave          ${AZUL}[7]${NC}  Conexiones online"
    echo -e " ${AZUL}[3]${NC} Bloquear/Desbloquear   ${AZUL}[8]${NC}  Desconectar usuario"
    echo -e " ${AZUL}[4]${NC} Eliminar usuario       ${AZUL}[9]${NC}  Banner SSH"
    echo -e " ${AZUL}[5]${NC} Renovar usuario        ${AZUL}[10]${NC} Backup basico"
    echo
    echo -e "${BLANCO}--------- WEBMIN / SISTEMA / ACTUALIZACIONES ----------${NC}"
    echo -e " ${AZUL}[11]${NC} Menu Webmin (instalar) ${AZUL}[13]${NC} Optimizar VPS (BBR)"
    echo -e " ${AZUL}[12]${NC} Monitoreo              ${AZUL}[14]${NC} Update del sistema"
    echo
    echo -e "${BLANCO}--------- EXTRAS / SEGURIDAD / AUTO-START -----------${NC}"
    echo -e " ${AZUL}[15]${NC} Comando global (vpsmgr) ${AZUL}[18]${NC} Cambiar puerto SSH"
    echo -e " ${AZUL}[16]${NC} Limiter SSH (activar)   ${AZUL}[19]${NC} Auto-update del script"
    echo -e " ${AZUL}[17]${NC} Fail2ban (anti ataque)  ${AZUL}[20]${NC} Quitar limiter"
    echo -e " ${AZUL}[21]${NC} Ver puertos abiertos    ${AZUL}[22]${NC} Abrir puerto"
    echo -e " ${AZUL}[23]${NC} Cambiar hostname"
    echo
    echo -e "${BLANCO}--------- PANEL / HERRAMIENTAS AVANZADAS --------------${NC}"
    echo -e " ${AZUL}[24]${NC} Crear test SSH (1 dia)  ${AZUL}[27]${NC} Auto-menu al login"
    echo -e " ${AZUL}[25]${NC} Eliminar vencidos       ${AZUL}[28]${NC} Quitar auto-menu"
    echo -e " ${AZUL}[26]${NC} Mantenimiento           ${AZUL}[29]${NC} Cambiar limite usuario"
    echo -e " ${AZUL}[30]${NC} Diagnostico del servidor"
    echo -e " ${AZUL}[31]${NC} CheckUser API (apps cliente)"
    echo -e " ${AZUL}[0]${NC} Salir"
    echo
    read -r -p " INFORME UNA OPCION > " OP
    case "$OP" in
        1) crear_usuario ;;
        2) cambiar_clave ;;
        3) bloquear_usuario ;;
        4) eliminar_usuario ;;
        5) renovar_usuario ;;
        6) listar_usuarios ;;
        7) conexiones_online ;;
        8) matar_conexion ;;
        9) banner_ssh ;;
        10) backup_basico ;;
        11) menu_webmin ;;
        12) monitoreo ;;
        13) optimizar ;;
        14) update_sistema ;;
        15) instalar_comando_global ;;
        16) limiter_aplicar ;;
        17) instalar_fail2ban ;;
        18) cambiar_puerto_ssh ;;
        19) auto_update ;;
        20) limiter_quitar ;;
        21) ver_puertos ;;
        22) abrir_puerto ;;
        23) cambiar_hostname ;;
        24) crear_test_ssh ;;
        25) eliminar_vencidos ;;
        26) mantenimiento ;;
        27) auto_menu ;;
        28) quitar_auto_menu ;;
        29) cambiar_limite ;;
        30) diagnostico ;;
        31) menu_checkuser ;;
        0) echo -e "${VERDE}Hasta luego!${NC}"; exit 0 ;;
        *) ERR "Opcion invalida."; sleep 1 ;;
    esac
done

