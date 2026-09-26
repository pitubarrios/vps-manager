#!/usr/bin/env bash
# ============================================================
#  VPS-MANAGER PRO  v1.0  -  Administracion de VPS (Ubuntu)
#  Menu SSH: usuarios, trafico, backup, banner + Webmin
#  Uso:  sudo bash vps-manager.sh
# ============================================================

set -u

ROJO='\033[1;31m'; VERDE='\033[1;32m'; AMARILLO='\033[1;33m'
AZUL='\033[1;34m'; CIAN='\033[1;36m'; BLANCO='\033[1;37m'
NC='\033[0m'

# --- LICENCIA / KEY -------------------------------------------
# El SECRET debe ser el mismo que en keygen.py
SECRET_KEY='cambia-esta-clave-super-secreta-2026'
KEY_FILE='/etc/vps-manager.key'
PREFIJO_KEY='VPSMGR1'

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
    case "$KEY" in ${PREFIJO_KEY}-*) ;; *) return 1 ;; esac
    BODY=${KEY#${PREFIJO_KEY}-}
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
    return 0
}

gate_licencia(){
    local INTENTOS=0 K
    if [[ -f "$KEY_FILE" ]] && validar_key "$(cat "$KEY_FILE" 2>/dev/null)"; then
        LICENSE_OK="$KEY_NOMBRE"; return 0
    fi
    echo -e "${AMARILLO}============================================================${NC}"
    echo -e "${AMARILLO}  LICENCIA REQUERIDA - VPS-MANAGER PRO${NC}"
    echo -e "${AMARILLO}============================================================${NC}"
    echo -e " ID de este servidor: ${BLANCO}$(machine_hash)${NC}"
    echo -e " (usa ese ID con --bind para atar la key a este VPS)\n"
    while [[ $INTENTOS -lt 3 ]]; do
        read -r -p " INGRESE SU KEY > " K
        if validar_key "$K"; then
            echo "$K" > "$KEY_FILE" 2>/dev/null
            LICENSE_OK="$KEY_NOMBRE"
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
    echo -e "${CIAN}   VPS-MANAGER PRO  v1.0   |   $(hostname)   |   Ubuntu $(lsb_release -rs 2>/dev/null)${NC}"
    echo -e "${BLANCO}============================================================${NC}"
    echo -e " IP      : $(curl -4 -s --max-time 3 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')"
    echo -e " Fecha   : $(date '+%d-%m-%Y   %H:%M:%S')   Uptime: $(uptime -p 2>/dev/null | cut -d' ' -f2-)"
    echo -e " RAM     : ${RAM_USO} / ${RAM_TOTAL}M    CPU: ${CPU}    Disco: ${DISCO}"
    echo -e " Online  : ${VERDE}${ONLINE}${NC} usuarios conectados   |   Webmin: $(estado_webmin_min)"
    echo -e " Licencia: ${VERDE}${LICENSE_OK:-sin key}${NC}   |   Servidor ID: $(machine_hash)"
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
    # limite de conexiones via pam_limits / profile
    echo "* hard maxlogins $MAXC" >> /etc/security/limits.conf
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
        0) echo -e "${VERDE}Hasta luego!${NC}"; exit 0 ;;
        *) ERR "Opcion invalida."; sleep 1 ;;
    esac
done
