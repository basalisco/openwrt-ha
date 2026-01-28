#!/bin/sh
echo "==============================================="
echo "   INSTALLATORE OPENWRT -> HOME ASSISTANT"
echo "==============================================="

# 1. Installazione pacchetti necessari
opkg update
opkg install mosquitto-client-nossl conntrack jsonfilter

# 2. Richiesta dati MQTT
echo "Inserisci i dati per la connessione MQTT:"
read -p "Host MQTT (es. 192.168.1.50): " MQTT_HOST
read -p "Username MQTT: " MQTT_USER
read -p "Password MQTT: " MQTT_PASS
MQTT_PORT="1883"

# 3. Creazione cartella e script principale
mkdir -p /etc/openwrt-ha

cat << EOF > /etc/openwrt-ha/firewall.sh
#!/bin/sh
MQTT_HOST="$MQTT_HOST"
MQTT_PORT="$MQTT_PORT"
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
        SAFE_NAME=\$(echo "\$rule_name" | tr ' ' '_')
        mosquitto_pub -h "\$MQTT_HOST" -p "\$MQTT_PORT" -u "\$MQTT_USER" -P "\$MQTT_PASS" -t "\$PREFIX/switch/\$NODE_ID/\$SAFE_NAME/state" -m "\$action" -r
    fi
}

discovery_and_state() {
    REFRESH_PAYLOAD="{\"name\": \"Aggiorna Regole Firewall\", \"unique_id\": \"\${NODE_ID}_refresh\", \"command_topic\": \"\$PREFIX/button/\$NODE_ID/refresh/set\", \"icon\": \"mdi:refresh\", \"device\": { \"identifiers\": [\"\$NODE_ID\"], \"name\": \"\$NODE_NAME\" }}"
    mosquitto_pub -h "\$MQTT_HOST" -p "\$MQTT_PORT" -u "\$MQTT_USER" -P "\$MQTT_PASS" -t "\$PREFIX/button/\$NODE_ID/refresh/config" -m "\$REFRESH_PAYLOAD" -r
    > "\$SENT_RULES_FILE"
    i=0
    while true; do
        NAME=\$(uci -q get firewall.@rule[\$i].name)
        [ -z "\$NAME" ] && break
        SAFE_NAME=\$(echo "\$NAME" | tr ' ' '_')
        echo "\$NAME|\$SAFE_NAME" >> "\$SENT_RULES_FILE"
        BASE_TOPIC="\$PREFIX/switch/\$NODE_ID/\$SAFE_NAME"
        PAYLOAD="{\"name\": \"Firewall \$NAME\", \"unique_id\": \"\${NODE_ID}_\$SAFE_NAME\", \"state_topic\": \"\$BASE_TOPIC/state\", \"command_topic\": \"\$BASE_TOPIC/set\", \"payload_on\": \"1\", \"payload_off\": \"0\", \"device\": { \"identifiers\": [\"\$NODE_ID\"], \"name\": \"\$NODE_NAME\" }}"
        mosquitto_pub -h "\$MQTT_HOST" -p "\$MQTT_PORT" -u "\$MQTT_USER" -P "\$MQTT_PASS" -t "\$BASE_TOPIC/config" -m "\$PAYLOAD" -r
        ENABLED=\$(uci -q get firewall.@rule[\$i].enabled)
        [ -z "\$ENABLED" ] && ENABLED="1"
        mosquitto_pub -h "\$MQTT_HOST" -p "\$MQTT_PORT" -u "\$MQTT_USER" -P "\$MQTT_PASS" -t "\$BASE_TOPIC/state" -m "\$ENABLED" -r
        i=\$((i+1))
        usleep 50000
    done
}

listen() {
    mosquitto_sub -h "\$MQTT_HOST" -p "\$MQTT_PORT" -u "\$MQTT_USER" -P "\$MQTT_PASS" -t "\$PREFIX/+/\$NODE_ID/+/set" -v | while read -r line; do
        MSG="\${line##* }"
        TOPIC="\${line% *}"
        if echo "\$TOPIC" | grep -q "refresh/set"; then
            discovery_and_state
            continue
        fi
        SAFE_NAME=\$(echo "\$TOPIC" | sed 's|.*/\(.*\)/set|\1|')
        ORIGINAL_NAME=\$(grep "|\$SAFE_NAME$" "\$SENT_RULES_FILE" | cut -d'|' -f1)
        [ -n "\$ORIGINAL_NAME" ] && apply_firewall "\$ORIGINAL_NAME" "\$MSG"
    done
}

discovery_and_state
listen
EOF

chmod +x /etc/openwrt-ha/firewall.sh

# 4. Creazione Servizio Init
cat << 'EOF' > /etc/init.d/firewall_ha
#!/bin/sh /etc/rc.common
START=99
USE_PROCD=1
start_service() {
    procd_open_instance
    procd_set_param command /bin/sh /etc/openwrt-ha/firewall.sh
    procd_set_param respawn
    procd_close_instance
}
stop_service() {
    killall mosquitto_sub 2>/dev/null
}
EOF

chmod +x /etc/init.d/firewall_ha
/etc/init.d/firewall_ha enable
/etc/init.d/firewall_ha start

echo "INSTALLAZIONE COMPLETATA!"