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
SECRET_KEY='Copiaesta**'
KEY_FILE='/etc/vps-manager.key'
PREFIJO_KEY='VPSJB1'   # prefijo de marca; tambien acepta keys viejas VPSMGR1
# URL del script en TU repo (para la opcion de auto-update)
REPO_RAW='https://raw.githubusercontent.com/pitubarrios/vps-manager/refs/heads/main/vps-manager.sh'
# --- VALIDACION ONLINE (opcional) ---
# Pone aca la URL de tu Worker de Cloudflare. Vacio = validacion offline (firma local).
LICENSE_URL='https://vps-licencias.jorgebarriosmpya.workers.dev'

GRACE_SECS=259200                      # 6h de gracia si el servidor no responde
LICENSE_CACHE='/etc/vps-license.cache'

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

consultar_licencia(){
    # Modo online: pregunta al Worker de Cloudflare.
    # Devuelve: 0 valida / 1 invalida / 2 servidor sin respuesta
    local KEY="$1" RESP
    [[ -z "$LICENSE_URL" ]] && return 2
    RESP=$(curl -G -fsS --max-time 10 -A "Mozilla/5.0" "$LICENSE_URL" \
        --data-urlencode "key=$KEY" --data-urlencode "id=$(machine_hash)" 2>/dev/null)
    [[ -z "$RESP" ]] && return 2
    if echo "$RESP" | grep -q '"valid":[[:space:]]*true'; then
        LICENSE_NOMBRE=$(echo "$RESP" | grep -o '"name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
        LICENSE_DIAS=$(echo "$RESP" | grep -o '"days_left"[[:space:]]*:[[:space:]]*[0-9]*' | head -1 | grep -o '[0-9]*$')
        return 0
    fi
    return 1
}

gate_licencia(){
    local INTENTOS=0 K RC
    echo -e "${AMARILLO}============================================================${NC}"
    echo -e "${AMARILLO}  LICENCIA REQUERIDA - VPS-JORGEBARRIOS${NC}"
    echo -e "${AMARILLO}============================================================${NC}"
    echo -e " ID de este servidor: ${BLANCO}$(machine_hash)${NC}"

    if [[ -n "$LICENSE_URL" ]]; then
        # ---------------- MODO ONLINE ----------------
        INFO "Validacion online activa."
        if [[ -f "$KEY_FILE" ]]; then
            K=$(cat "$KEY_FILE" 2>/dev/null)
            consultar_licencia "$K"; RC=$?
            if [[ $RC -eq 0 ]]; then
                date +%s > "$LICENSE_CACHE" 2>/dev/null
                LICENSE_OK="${LICENSE_NOMBRE:-cliente}"
                [[ -n "${LICENSE_DIAS:-}" ]] && LICENSE_EXP=$(( $(date +%s) + LICENSE_DIAS * 86400 ))
                return 0
            elif [[ $RC -eq 2 ]]; then
                if [[ -f "$LICENSE_CACHE" ]] && (( $(date +%s) - $(cat "$LICENSE_CACHE" 2>/dev/null || echo 0) < GRACE_SECS )); then
                    LICENSE_OK="modo gracia (servidor caido)"
                    return 0
                fi
                ERR "Servidor de licencias no responde y no hay gracia acumulada."
            fi
        fi
        while [[ $INTENTOS -lt 3 ]]; do
            read -r -p " INGRESE SU KEY > " K
            consultar_licencia "$K"; RC=$?
            if [[ $RC -eq 0 ]]; then
                echo "$K" > "$KEY_FILE" 2>/dev/null
                date +%s > "$LICENSE_CACHE" 2>/dev/null
                LICENSE_OK="${LICENSE_NOMBRE:-cliente}"
                [[ -n "${LICENSE_DIAS:-}" ]] && LICENSE_EXP=$(( $(date +%s) + LICENSE_DIAS * 86400 ))
                OK "Licencia aceptada. Bienvenido, ${LICENSE_OK}."
                sleep 1
                return 0
            elif [[ $RC -eq 2 ]]; then
                ERR "Servidor de licencias no responde. Intenta mas tarde."
            else
                ERR "Key invalida, expirada, revocada o de otro servidor."
            fi
            INTENTOS=$((INTENTOS+1))
        done
        echo -e "${ROJO}Sin licencia valida. Contacta al administrador.${NC}"
        exit 1
    fi

    # ---------------- MODO OFFLINE (firma local) ----------------
    echo -e " (usa ese ID con --bind para atar la key a este VPS)\n"
    if [[ -f "$KEY_FILE" ]] && validar_key "$(cat "$KEY_FILE" 2>/dev/null)"; then
        LICENSE_OK="$KEY_NOMBRE"; LICENSE_EXP="$KEY_EXP"; return 0
    fi
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
FILA(){
    if [[ -n "$3" ]]; then
        printf " ${AZUL}[%-2s]${NC} %-26s ${AZUL}[%-2s]${NC} %s\n" "$1" "$2" "$3" "$4"
    else
        printf " ${AZUL}[%-2s]${NC} %s\n" "$1" "$2"
    fi
}
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

reiniciar_vps(){
    read -r -p "Reiniciar el VPS ahora? Los servicios caeran. (s/n): " SN
    if [[ "$SN" == "s" ]]; then
        WARN "Reiniciando en 3 segundos..."
        sleep 3
        reboot
    else
        OK "Reinicio cancelado."
        PAUSA
    fi
}

# ------------------------------------------------------------
# PROTOCOLOS / CONEXIONES (Xray, OpenVPN)
# ------------------------------------------------------------
instalar_xray(){
    if command -v xray >/dev/null 2>&1; then
        read -r -p "Xray ya esta instalado. Reinstalar/configurar de nuevo? (s/n): " SN
        [[ "$SN" != "s" ]] && { PAUSA; return; }
    fi
    echo -e "${CIAN}--- INSTALADOR XRAY (VLESS + REALITY) ---${NC}"
    read -r -p "Puerto para Xray [8443]: " XP; XP=${XP:-8443}
    [[ "$XP" =~ ^[0-9]+$ && "$XP" -ge 1 && "$XP" -le 65535 ]] || { ERR "Puerto invalido."; PAUSA; return; }
    read -r -p "SNI (dominio camuflaje) [www.microsoft.com]: " SNI; SNI=${SNI:-www.microsoft.com}

    INFO "Instalando Xray (descarga oficial)..."
    bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1 \
        || { ERR "No se pudo instalar Xray (sin red?)."; PAUSA; return; }

    local KEYS UUID
    KEYS=$(xray x25519 2>/dev/null)
    local PRIV PUB
    PRIV=$(echo "$KEYS" | awk '/Private/{print $3}')
    PUB=$(echo "$KEYS"  | awk '/Public/{print $3}')
    UUID=$(xray uuid)
    [[ -z "$PRIV" || -z "$PUB" || -z "$UUID" ]] && { ERR "No se pudieron generar las claves."; PAUSA; return; }

    mkdir -p /usr/local/etc/xray
    cat > /usr/local/etc/xray/config.json <<XEOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "port": $XP,
    "protocol": "vless",
    "settings": {
      "clients": [{ "id": "$UUID", "flow": "xtls-rprx-vision" }],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "dest": "$SNI:443",
        "xver": 0,
        "serverNames": ["$SNI"],
        "privateKey": "$PRIV",
        "shortIds": [""]
      }
    },
    "sniffing": { "enabled": true, "destOverride": ["http", "tls"] }
  }],
  "outbounds": [{ "protocol": "freedom" }]
}
XEOF

    ufw allow "$XP/tcp" >/dev/null 2>&1
    systemctl enable --now xray 2>/dev/null || { /usr/local/bin/xray run -c /usr/local/etc/xray/config.json & }
    sleep 2
    local IP; IP=$(hostname -I | awk '{print $1}')
    local LINK="vless://$UUID@$IP:$XP?security=reality&encryption=none&pbk=$PUB&fp=chrome&sni=$SNI&flow=xtls-rprx-vision&sid=#VPS-JORGEBARRIOS"
    OK "Xray corriendo en el puerto $XP"
    echo
    echo -e " ${AMARILLO}Enlace para tu app (VLESS + Reality):${NC}"
    echo -e " ${VERDE}$LINK${NC}"
    echo
    INFO "Guarda ese enlace: es la config que importas en el cliente (v2rayNG / tu app)."
    PAUSA
}

instalar_openvpn(){
    if command -v openvpn >/dev/null 2>&1; then
        ERR "OpenVPN ya esta instalado."; PAUSA; return
    fi
    INFO "Descargando instalador de OpenVPN..."
    curl -fsSL -o /root/openvpn-install.sh https://raw.githubusercontent.com/angristan/openvpn-install/master/openvpn-install.sh \
        || { ERR "Sin red, no se pudo descargar."; PAUSA; return; }
    chmod +x /root/openvpn-install.sh
    INFO "Arrancando instalador (configuralo con los valores que quieras)..."
    AUTO_INSTALL=y bash /root/openvpn-install.sh
    OK "Listo. El archivo .ovpn del cliente queda en /root/"
    PAUSA
}

instalar_ssl_stunnel(){
    if command -v stunnel4 >/dev/null 2>&1 || command -v stunnel >/dev/null 2>&1; then
        read -r -p "Stunnel ya esta instalado. Reconfigurar? (s/n): " SN
        [[ "$SN" != "s" ]] && { PAUSA; return; }
    fi
    echo -e "${CIAN}--- INSTALADOR SSL (STUNNEL) ---${NC}"
    read -r -p "Puerto SSL [443]: " SP; SP=${SP:-443}
    [[ "$SP" =~ ^[0-9]+$ && "$SP" -ge 1 && "$SP" -le 65535 ]] || { ERR "Puerto invalido."; PAUSA; return; }
    read -r -p "Puerto SSH destino [22]: " SSHP; SSHP=${SSHP:-22}

    INFO "Instalando stunnel4..."
    apt update -y >/dev/null 2>&1
    apt install -y stunnel4 >/dev/null 2>&1 || { ERR "No se pudo instalar stunnel4."; PAUSA; return; }

    INFO "Generando certificado autofirmado (10 años)..."
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -subj "/CN=vps-jorgebarrios" \
        -keyout /etc/stunnel/stunnel.key -out /etc/stunnel/stunnel.crt >/dev/null 2>&1
    cat /etc/stunnel/stunnel.crt /etc/stunnel/stunnel.key > /etc/stunnel/stunnel.pem 2>/dev/null

    cat > /etc/stunnel/stunnel.conf <<SEOF
pid = /var/run/stunnel4.pid
cert = /etc/stunnel/stunnel.pem
client = no
socket = a:SO_REUSEADDR=1

[ssh-ssl]
accept = $SP
connect = 127.0.0.1:$SSHP
SEOF

    sed -i 's/^ENABLED=.*/ENABLED=1/' /etc/default/stunnel4 2>/dev/null
    ufw allow "$SP/tcp" >/dev/null 2>&1
    systemctl restart stunnel4 2>/dev/null || service stunnel4 restart 2>/dev/null
    sleep 1
    local IP; IP=$(hostname -I | awk '{print $1}')
    if pgrep -f stunnel >/dev/null 2>&1; then
        OK "Stunnel ACTIVO: SSL en el puerto $SP -> SSH local $SSHP"
        echo
        echo -e " ${AMARILLO}Datos para la config del cliente (HTTP Injector / tu app):${NC}"
        echo -e "  IP/Host: ${VERDE}$IP${NC}   Puerto SSL: ${VERDE}$SP${NC}"
        echo -e "  La app debe conectar por SSL/TLS al $SP y el trafico sale por SSH ($SSHP)."
    else
        ERR "Stunnel no levanto. Revisa con: systemctl status stunnel4"
    fi
    PAUSA
}

estado_protocolos(){
    echo -e "${CIAN}--- PROTOCOLOS ---${NC}"
    if command -v xray >/dev/null 2>&1; then
        local PUERTO; PUERTO=$(grep -o '"port": [0-9]*' /usr/local/etc/xray/config.json 2>/dev/null | head -1 | grep -o '[0-9]*')
        if pgrep -x xray >/dev/null 2>&1 || systemctl is-active --quiet xray 2>/dev/null; then
            echo -e " Xray:   ${VERDE}ACTIVO${NC} (puerto ${PUERTO:-?})"
        else
            echo -e " Xray:   ${AMARILLO}instalado, detenido${NC}"
        fi
    else
        echo -e " Xray:   ${ROJO}no instalado${NC}"
    fi
    if command -v stunnel4 >/dev/null 2>&1 || pgrep -f stunnel >/dev/null 2>&1; then
        local SPORT; SPORT=$(grep -A1 'ssh-ssl' /etc/stunnel/stunnel.conf 2>/dev/null | grep -o 'accept = [0-9]*' | grep -o '[0-9]*')
        pgrep -f stunnel >/dev/null 2>&1 \
            && echo -e " Stunnel (SSL): ${VERDE}ACTIVO${NC} (puerto ${SPORT:-?})" \
            || echo -e " Stunnel (SSL): ${AMARILLO}instalado, detenido${NC}"
    else
        echo -e " Stunnel (SSL): ${ROJO}no instalado${NC}"
    fi
    if command -v openvpn >/dev/null 2>&1; then
        systemctl is-active --quiet openvpn-server@server 2>/dev/null \
            && echo -e " OpenVPN: ${VERDE}ACTIVO${NC}" || echo -e " OpenVPN: ${AMARILLO}instalado, detenido${NC}"
    else
        echo -e " OpenVPN: ${ROJO}no instalado${NC}"
    fi
    PAUSA
}

# ------------------------------------------------------------
# TRAFICO POR USUARIO (iptables)
# ------------------------------------------------------------
trafico_activar(){
    iptables -N VPS-TRAFFIC 2>/dev/null
    iptables -F VPS-TRAFFIC 2>/dev/null
    local N=0 U
    for U in $(awk -F: '$3>=1000 && $1!="nobody"{print $1}' /etc/passwd); do
        iptables -A VPS-TRAFFIC -m owner --uid-owner "$U" -j RETURN 2>/dev/null && N=$((N+1))
    done
    iptables -C OUTPUT -j VPS-TRAFFIC 2>/dev/null || iptables -A OUTPUT -j VPS-TRAFFIC 2>/dev/null
    [[ $N -gt 0 ]] && OK "Contadores activos para $N usuarios (se suman usuarios nuevos al re-activar)." \
                   || ERR "No se pudieron crear reglas (iptables fallo?)."
    PAUSA
}

trafico_ver(){
    echo -e "${CIAN}--- CONSUMO POR USUARIO (desde el ultimo reset) ---${NC}"
    printf "%-16s %-12s %s\n" "USUARIO" "USADO" "LIMITE(GB)"
    iptables -L VPS-TRAFFIC -v -x -n 2>/dev/null | awk '/owner UID match/ {print $2, $NF}' | while read -r BYTES UIDN; do
        local U MB LIM
        U=$(id -un "$UIDN" 2>/dev/null || echo "uid$UIDN")
        MB=$(( BYTES / 1048576 ))
        LIM=$(cat "/etc/vps-trafico/$U" 2>/dev/null || echo "-")
        printf "%-16s %7d MB   %s\n" "$U" "$MB" "$LIM"
    done
    echo
    INFO "Para medir desde cero, usa la opcion 'reset' del menu de trafico."
    PAUSA
}

trafico_limite(){
    read -r -p "Usuario: " USU
    id "$USU" >/dev/null 2>&1 || { ERR "No existe."; PAUSA; return; }
    read -r -p "Limite en GB (0 = sin limite): " G
    [[ "$G" =~ ^[0-9]+$ ]] || { ERR "Numero invalido."; PAUSA; return; }
    mkdir -p /etc/vps-trafico
    echo "$G" > "/etc/vps-trafico/$USU"
    OK "Limite de $USU = ${G}GB."
    PAUSA
}

trafico_cortar(){
    local CORTADOS=0
    for F in /etc/vps-trafico/*; do
        [[ -f "$F" ]] || continue
        local U G USED
        U=$(basename "$F"); G=$(cat "$F")
        [[ "$G" =~ ^[0-9]+$ && "$G" -gt 0 ]] || continue
        USED=$(iptables -L VPS-TRAFFIC -v -x -n 2>/dev/null | awk -v uid="$(id -u "$U" 2>/dev/null)" '$0 ~ "owner UID match "uid {print $2; exit}')
        [[ -n "$USED" && $(( USED / 1073741824 )) -ge "$G" ]] || continue
        if ! passwd -S "$U" 2>/dev/null | grep -q ' L '; then
            usermod -L "$U" 2>/dev/null; pkill -u "$U" 2>/dev/null
            INFO "$U supero su limite (${G}GB) y fue bloqueado."
            CORTADOS=$((CORTADOS+1))
        fi
    done
    [[ $CORTADOS -eq 0 ]] && OK "Nadie supero su limite." || OK "Bloqueados: $CORTADOS."
    PAUSA
}

trafico_reset(){
    iptables -Z VPS-TRAFFIC 2>/dev/null && OK "Contadores en cero." || ERR "La cadena no existe (activa antes)."
    PAUSA
}

menu_trafico(){
    while true; do
        cabecera
        echo -e "${BLANCO}================ TRAFICO POR USUARIO ================${NC}"
        echo -e " [1] Activar contadores"
        echo -e " [2] Ver consumo"
        echo -e " [3] Poner limite (GB) a un usuario"
        echo -e " [4] Cortar usuarios que superaron el limite"
        echo -e " [5] Resetear contadores"
        echo -e " [0] Volver"
        read -r -p " Opcion > " OP
        case "$OP" in
            1) trafico_activar ;;
            2) trafico_ver ;;
            3) trafico_limite ;;
            4) trafico_cortar ;;
            5) trafico_reset ;;
            0) break ;;
            *) ERR "Opcion invalida."; sleep 1 ;;
        esac
    done
}

# ------------------------------------------------------------
# SWAP / HYSTERIA2 / RESTORE
# ------------------------------------------------------------
agregar_swap(){
    if swapon --show 2>/dev/null | grep -q '/swapfile'; then
        ERR "Ya hay una swapfile activa."; PAUSA; return
    fi
    read -r -p "Tamaño del swap en GB [1]: " G; G=${G:-1}
    [[ "$G" =~ ^[0-9]+$ && "$G" -ge 1 ]] || { ERR "Tamaño invalido."; PAUSA; return; }
    INFO "Creando swap de ${G}GB..."
    fallocate -l "${G}G" /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=$((G*1024)) status=none
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null 2>&1
    swapon /swapfile 2>/dev/null
    if swapon --show 2>/dev/null | grep -q '/swapfile'; then
        grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
        OK "Swap de ${G}GB activa y persistente."
    else
        rm -f /swapfile
        ERR "No se pudo activar la swap."
    fi
    PAUSA
}

instalar_hysteria(){
    if command -v hysteria >/dev/null 2>&1; then
        read -r -p "Hysteria2 ya esta instalado. Reconfigurar? (s/n): " SN
        [[ "$SN" != "s" ]] && { PAUSA; return; }
    fi
    echo -e "${CIAN}--- INSTALADOR HYSTERIA2 (UDP) ---${NC}"
    read -r -p "Puerto UDP [8443]: " HP; HP=${HP:-8443}
    [[ "$HP" =~ ^[0-9]+$ && "$HP" -ge 1 && "$HP" -le 65535 ]] || { ERR "Puerto invalido."; PAUSA; return; }
    INFO "Instalando Hysteria2..."
    bash <(curl -fsSL https://get.hy2.sh/) >/dev/null 2>&1 \
        || { ERR "No se pudo instalar (sin red?)."; PAUSA; return; }
    mkdir -p /etc/hysteria
    openssl req -x509 -nodes -newkey rsa:2048 -days 3650 -subj "/CN=vps-jorgebarrios" \
        -keyout /etc/hysteria/server.key -out /etc/hysteria/server.crt >/dev/null 2>&1
    local PASS; PASS=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 20)
    cat > /etc/hysteria/config.yaml <<HEOF
listen: :$HP
auth:
  type: password
  password: "$PASS"
tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key
HEOF
    ufw allow "$HP/udp" >/dev/null 2>&1
    systemctl enable --now hysteria-server >/dev/null 2>&1
    sleep 1
    local IP; IP=$(hostname -I | awk '{print $1}')
    if systemctl is-active --quiet hysteria-server 2>/dev/null || pgrep -x hysteria >/dev/null 2>&1; then
        OK "Hysteria2 corriendo en UDP $HP"
        echo
        echo -e " ${AMARILLO}Enlace para el cliente (NekoBox / tu app):${NC}"
        echo -e " ${VERDE}hysteria2://$PASS@$IP:$HP/?insecure=1#VPS-JORGEBARRIOS${NC}"
    else
        ERR "Hysteria no levanto. Revisa: journalctl -u hysteria-server"
    fi
    PAUSA
}

restaurar_backup(){
    local DIR=/root/backups
    echo -e "${CIAN}--- BACKUPS DISPONIBLES ---${NC}"
    ls -lh "$DIR"/*.tar.gz 2>/dev/null || { ERR "No hay backups en $DIR."; PAUSA; return; }
    read -r -p "Archivo a restaurar (nombre exacto, Enter = el mas reciente): " F
    [[ -z "$F" ]] && F=$(ls -t "$DIR"/*.tar.gz 2>/dev/null | head -1)
    [[ -f "$F" ]] || F="$DIR/$F"
    [[ -f "$F" ]] || { ERR "Archivo no encontrado."; PAUSA; return; }
    echo
    echo -e "${ROJO}ATENCION: esto pisa la configuracion actual de /etc${NC}"
    echo -e "${ROJO}(incluye usuarios, claves y la key de licencia).${NC}"
    read -r -p "Escribi RESTAURAR para confirmar: " CONF
    [[ "$CONF" != "RESTAURAR" ]] && { ERR "Cancelado."; PAUSA; return; }
    INFO "Restaurando $F ..."
    tar xzf "$F" -C / 2>/dev/null
    OK "Restaurado. Recomendado: reiniciar el VPS (opcion 32)."
    PAUSA
}

# ------------------------------------------------------------
# MENU PRINCIPAL
# ------------------------------------------------------------
[[ $EUID -ne 0 ]] && { echo -e "${ROJO}Ejecuta como root o con sudo.${NC}"; exit 1; }

gate_licencia

while true; do
    cabecera
    echo -e "${BLANCO}--------- GESTION DE USUARIOS / SSH / SISTEMA ---------${NC}"
    FILA 1  "Crear usuario SSH"        6  "Listar usuarios"
    FILA 2  "Cambiar clave"            7  "Conexiones online"
    FILA 3  "Bloquear/Desbloquear"    8  "Desconectar usuario"
    FILA 4  "Eliminar usuario"        9  "Banner SSH"
    FILA 5  "Renovar usuario"         10 "Backup basico"
    echo
    echo -e "${BLANCO}--------- WEBMIN / SISTEMA / ACTUALIZACIONES ----------${NC}"
    FILA 11 "Menu Webmin (instalar)"  13 "Optimizar VPS (BBR)"
    FILA 12 "Monitoreo"               14 "Update del sistema"
    echo
    echo -e "${BLANCO}--------- EXTRAS / SEGURIDAD / AUTO-START -----------${NC}"
    FILA 15 "Comando global (vpsmgr)" 18 "Cambiar puerto SSH"
    FILA 16 "Limiter SSH (activar)"   19 "Auto-update del script"
    FILA 17 "Fail2ban (anti ataque)"  20 "Quitar limiter"
    FILA 21 "Ver puertos abiertos"    22 "Abrir puerto"
    FILA 23 "Cambiar hostname"        "" ""
    echo
    echo -e "${BLANCO}--------- PANEL / HERRAMIENTAS AVANZADAS --------------${NC}"
    FILA 24 "Crear test SSH (1 dia)"  27 "Auto-menu al login"
    FILA 25 "Eliminar vencidos"       28 "Quitar auto-menu"
    FILA 26 "Mantenimiento"           29 "Cambiar limite usuario"
    FILA 30 "Diagnostico del servidor" "" ""
    FILA 31 "CheckUser API (apps)"    32 "Reiniciar VPS"
    echo
    echo -e "${BLANCO}--------- PROTOCOLOS / CONEXIONES ---------------------${NC}"
    FILA 33 "Xray (VLESS + Reality)" 34 "OpenVPN"
    FILA 35 "Estado de protocolos"   36 "SSL (Stunnel puerto 443)"
    echo
    echo -e "${BLANCO}--------- RECURSOS / DATOS / RECUPERACION ------------${NC}"
    FILA 37 "Trafico por usuario (GB)" 38 "Agregar swap"
    FILA 39 "Hysteria2 (UDP)"          40 "Restaurar backup"
    echo
    echo -e " ${AZUL}[0]${NC}  Salir"
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
        32) reiniciar_vps ;;
        33) instalar_xray ;;
        34) instalar_openvpn ;;
        35) estado_protocolos ;;
        36) instalar_ssl_stunnel ;;
        37) menu_trafico ;;
        38) agregar_swap ;;
        39) instalar_hysteria ;;
        40) restaurar_backup ;;
        0) echo -e "${VERDE}Hasta luego!${NC}"; exit 0 ;;
        *) ERR "Opcion invalida."; sleep 1 ;;
    esac
done
