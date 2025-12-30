#!/bin/sh

echo "==============================================="
echo "   INSTALLATORE OPENWRT -> HOME ASSISTANT"
echo "==============================================="

# 1. Installazione pacchetti necessari
echo "--- Aggiornamento pacchetti e installazione dipendenze ---"
opkg update
opkg install mosquitto-client-nossl conntrack jsonfilter

# 2. Richiesta dati MQTT
echo ""
echo "Inserisci i dati per la connessione MQTT:"
read -p "Host MQTT (es. 192.168.1.50): " MQTT_HOST
read -p "Porta MQTT (default 1883): " MQTT_PORT
read -p "Username MQTT: " MQTT_USER
read -p "Password MQTT: " MQTT_PASS
echo ""

# 3. Creazione cartella di destinazione
mkdir -p /etc/openwrt-ha

# 4. Creazione dello script principale (firewall.sh)
echo "--- Creazione script principale in /etc/openwrt-ha/firewall.sh ---"
cat << EOF > /etc/openwrt-ha/firewall.sh
#!/bin/sh
MQTT_HOST="$MQTT_HOST"
MQTT_PORT="1883"
MQTT_USER="$MQTT_USER"
MQTT_PASS="$MQTT_PASS"
PREFIX="homeassistant"
NODE_ID="openwrt_router"
NODE_NAME="Router OpenWrt"
SENT_RULES_FILE="/tmp/sent_fw_rules"

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
    REFRESH_PAYLOAD="{\"name\": \"Aggiorna Regole Firewall\", \"unique_id\": \"\${NODE_ID}_refresh\", \"command_topic\": \"\$PREFIX/button/\$NODE_ID/refresh/set\", \"icon\": \"mdi:refresh\", \"device\": { \"identifiers\": [\"\$NODE_ID\"], \"name\": \"\$NODE_NAME\" }}"
    mosquitto_pub -h "\$MQTT_HOST" -p "\$MQTT_PORT" -u "\$MQTT_USER" -P "\$MQTT_PASS" -t "\$PREFIX/button/\$NODE_ID/refresh/config" -m "\$REFRESH_PAYLOAD" -r
    i=0
    while true; do
        NAME=\$(uci get firewall.@rule[\$i].name 2>/dev/null)
        [ -z "\$NAME" ] && break
        BASE_TOPIC="\$PREFIX/switch/\$NODE_ID/\$NAME"
        PAYLOAD="{\"name\": \"Firewall \$NAME\", \"unique_id\": \"\$NAME\", \"state_topic\": \"\$BASE_TOPIC/state\", \"command_topic\": \"\$BASE_TOPIC/set\", \"payload_on\": \"1\", \"payload_off\": \"0\", \"device\": { \"identifiers\": [\"\$NODE_ID\"], \"name\": \"\$NODE_NAME\" }}"
        mosquitto_pub -h "\$MQTT_HOST" -p "\$MQTT_PORT" -u "\$MQTT_USER" -P "\$MQTT_PASS" -t "\$BASE_TOPIC/config" -m "\$PAYLOAD" -r
        ENABLED=\$(uci get firewall.@rule[\$i].enabled 2>/dev/null || echo "1")
        mosquitto_pub -h "\$MQTT_HOST" -p "\$MQTT_PORT" -u "\$MQTT_USER" -P "\$MQTT_PASS" -t "\$BASE_TOPIC/state" -m "\$ENABLED" -r
        i=\$((i+1))
    done
    uci show firewall | grep "firewall.@rule" | grep ".name=" | cut -d"'" -f2 > "\$SENT_RULES_FILE"
}

listen() {
    mosquitto_sub -h "\$MQTT_HOST" -p "\$MQTT_PORT" -u "\$MQTT_USER" -P "\$MQTT_PASS" -t "\$PREFIX/+/\$NODE_ID/+/set" -v | while read -r line; do
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

# 5. Creazione del servizio init.d
echo "--- Configurazione servizio di sistema ---"
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
    killall mosquitto_sub 2>/dev/null
}
EOF

chmod +x /etc/init.d/firewall_ha
/etc/init.d/firewall_ha enable
/etc/init.d/firewall_ha start

echo "==============================================="
echo "   INSTALLAZIONE COMPLETATA CON SUCCESSO!"
echo "   Il servizio è attivo e configurato."
echo "==============================================="