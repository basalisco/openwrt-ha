#!/bin/sh

echo "==============================================="
echo "   INSTALLATORE OPENWRT -> HA (VERSIONE ULTIMATE)"
echo "==============================================="

# 1. Installazione pacchetti
opkg update && opkg install mosquitto-client-nossl conntrack jsonfilter

# 2. Richiesta dati MQTT (Inclusa la porta)
read -p "Host MQTT: " MQTT_HOST
read -p "Porta MQTT (default 1883): " MQTT_PORT
MQTT_PORT=${MQTT_PORT:-1883} # Se vuoto, usa 1883
read -p "Username MQTT: " MQTT_USER
read -p "Password MQTT: " MQTT_PASS

mkdir -p /etc/openwrt-ha

# 3. Creazione script principale
cat << EOF > /etc/openwrt-ha/firewall.sh
#!/bin/sh
MQTT_HOST="$MQTT_HOST"
MQTT_PORT="$MQTT_PORT"
MQTT_USER="$MQTT_USER"
MQTT_PASS="$MQTT_PASS"
PREFIX="homeassistant"
NODE_ID="openwrt_router"
NODE_NAME="Router"
AVAIL_TOPIC="\$PREFIX/switch/\$NODE_ID/availability"
SENT_RULES_FILE="/tmp/sent_fw_rules"

# --- FUNZIONI DI SISTEMA ---
send_online() {
    mosquitto_pub -h "\$MQTT_HOST" -p "\$MQTT_PORT" -u "\$MQTT_USER" -P "\$MQTT_PASS" -t "\$AVAIL_TOPIC" -m "online" -r
}

send_stats() {
    while true; do
        UPTIME=\$(uptime | awk '{print \$3}' | sed 's/,//')
        LOAD=\$(cat /proc/loadavg | awk '{print \$1}')
        RAM=\$(free -m | grep Mem | awk '{print \$4}')
        
        mosquitto_pub -h "\$MQTT_HOST" -p "\$MQTT_PORT" -u "\$MQTT_USER" -P "\$MQTT_PASS" -t "\$PREFIX/sensor/\$NODE_ID/uptime/state" -m "\$UPTIME"
        mosquitto_pub -h "\$MQTT_HOST" -p "\$MQTT_PORT" -u "\$MQTT_USER" -P "\$MQTT_PASS" -t "\$PREFIX/sensor/\$NODE_ID/load/state" -m "\$LOAD"
        mosquitto_pub -h "\$MQTT_HOST" -p "\$MQTT_PORT" -u "\$MQTT_USER" -P "\$MQTT_PASS" -t "\$PREFIX/sensor/\$NODE_ID/ram/state" -m "\$RAM"
        sleep 60
    done
}

apply_firewall() {
    local rule_name="\$1"
    local action="\$2"
    INDEX=\$(uci show firewall | grep ".name='\$rule_name'" | cut -d'[' -f2 | cut -d']' -f1)
    if [ -n "\$INDEX" ]; then
        uci set firewall.@rule[\$INDEX].enabled="\$action"
        uci commit firewall
        /etc/init.d/firewall reload
        if [ "\$action" = "1" ]; then
            MAC=\$(uci get firewall.@rule[\$INDEX].src_mac 2>/dev/null)
            if [ -n "\$MAC" ]; then
                IP=\$(cat /tmp/dhcp.leases | grep -i "\$MAC" | awk '{print \$3}')
                [ -n "\$IP" ] && conntrack -D -s "\$IP" 2>/dev/null
            fi
        fi
        mosquitto_pub -h "\$MQTT_HOST" -p "\$MQTT_PORT" -u "\$MQTT_USER" -P "\$MQTT_PASS" -t "\$PREFIX/switch/\$NODE_ID/\$rule_name/state" -m "\$action" -r
    fi
}

cleanup_orphans() {
    [ ! -f "\$SENT_RULES_FILE" ] && return
    for OLD_NAME in \$(cat "\$SENT_RULES_FILE"); do
        if ! uci show firewall | grep "firewall.@rule" | grep -q ".name='\$OLD_NAME'"; then
            mosquitto_pub -h "\$MQTT_HOST" -p "\$MQTT_PORT" -u "\$MQTT_USER" -P "\$MQTT_PASS" -t "\$PREFIX/switch/\$NODE_ID/\$OLD_NAME/config" -r -n
        fi
    done
}

discovery_and_state() {
    cleanup_orphans
    send_online
    
    # Discovery Sensori e Button
    mosquitto_pub -h "\$MQTT_HOST" -p "\$MQTT_PORT" -u "\$MQTT_USER" -P "\$MQTT_PASS" -t "\$PREFIX/sensor/\$NODE_ID/uptime/config" -m "{\"name\": \"Uptime\", \"unique_id\": \"\${NODE_ID}_uptime\", \"state_topic\": \"\$PREFIX/sensor/\$NODE_ID/uptime/state\", \"device\": {\"identifiers\": [\"\$NODE_ID\"], \"name\": \"\$NODE_NAME\"}}" -r
    mosquitto_pub -h "\$MQTT_HOST" -p "\$MQTT_PORT" -u "\$MQTT_USER" -P "\$MQTT_PASS" -t "\$PREFIX/button/\$NODE_ID/refresh/config" -m "{\"name\": \"Aggiorna Regole\", \"unique_id\": \"\${NODE_ID}_refresh\", \"command_topic\": \"\$PREFIX/button/\$NODE_ID/refresh/set\", \"availability_topic\": \"\$AVAIL_TOPIC\", \"device\": {\"identifiers\": [\"\$NODE_ID\"]}}" -r

    # Discovery Regole Firewall (Nomi puliti per evitare troncamenti)
    i=0
    while true; do
        NAME=\$(uci get firewall.@rule[\$i].name 2>/dev/null)
        [ -z "\$NAME" ] && break
        
        # Pulizia nome: toglie prefissi comuni
        DISPLAY_NAME=\$(echo "\$NAME" | sed 's/Allow-//g; s/Block-//g; s/Blocco-//g')
        
        PAYLOAD="{\"name\": \"\$DISPLAY_NAME\", \"unique_id\": \"\$NAME\", \"state_topic\": \"\$PREFIX/switch/\$NODE_ID/\$NAME/state\", \"command_topic\": \"\$PREFIX/switch/\$NODE_ID/\$NAME/set\", \"availability_topic\": \"\$AVAIL_TOPIC\", \"payload_available\": \"online\", \"payload_not_available\": \"offline\", \"device\": {\"identifiers\": [\"\$NODE_ID\"]}}"
        mosquitto_pub -h "\$MQTT_HOST" -p "\$MQTT_PORT" -u "\$MQTT_USER" -P "\$MQTT_PASS" -t "\$PREFIX/switch/\$NODE_ID/\$NAME/config" -m "\$PAYLOAD" -r
        
        ENABLED=\$(uci get firewall.@rule[\$i].enabled 2>/dev/null || echo "1")
        mosquitto_pub -h "\$MQTT_HOST" -p "\$MQTT_PORT" -u "\$MQTT_USER" -P "\$MQTT_PASS" -t "\$PREFIX/switch/\$NODE_ID/\$NAME/state" -m "\$ENABLED" -r
        i=\$((i+1))
    done
    uci show firewall | grep "firewall.@rule" | grep ".name=" | cut -d"'" -f2 > "\$SENT_RULES_FILE"
}

send_stats &

listen() {
    mosquitto_sub -h "\$MQTT_HOST" -p "\$MQTT_PORT" -u "\$MQTT_USER" -P "\$MQTT_PASS" \
        -t "\$PREFIX/+/\$NODE_ID/+/set" \
        --will-topic "\$AVAIL_TOPIC" --will-payload "offline" --will-retain -v | while read -r line; do
        TOPIC=\$(echo "\$line" | cut -d' ' -f1)
        MSG=\$(echo "\$line" | cut -d' ' -f2)
        if echo "\$TOPIC" | grep -q "button/.*/refresh/set"; then
            discovery_and_state
            continue
        fi
        R_NAME=\$(echo "\$TOPIC" | sed 's|/set\$||; s|.*/||')
        [ -n "\$R_NAME" ] && apply_firewall "\$R_NAME" "\$MSG"
    done
}

discovery_and_state
listen
EOF

chmod +x /etc/openwrt-ha/firewall.sh

# 5. Creazione servizio init.d (Con gestione offline corretta)
cat << 'EOF' > /etc/init.d/firewall_ha
#!/bin/sh /etc/rc.common
START=99
USE_PROCD=1
start_service() {
    procd_open_instance
    procd_set_param command /bin/sh /etc/openwrt-ha/firewall.sh
    procd_set_param respawn
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}
stop_service() {
    . /etc/openwrt-ha/firewall.sh
    mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$AVAIL_TOPIC" -m "offline" -r
    killall mosquitto_sub 2>/dev/null
    killall firewall.sh 2>/dev/null
}
EOF

chmod +x /etc/init.d/firewall_ha
/etc/init.d/firewall_ha enable
/etc/init.d/firewall_ha start

echo "==============================================="
echo "   INSTALLAZIONE COMPLETATA!"
echo "   Dispositivo HA: $NODE_NAME (Porta: $MQTT_PORT)"
echo "==============================================="