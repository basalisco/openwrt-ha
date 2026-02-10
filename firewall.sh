#!/bin/sh
echo "==============================================="
echo "   INSTALLATORE OPENWRT -> HOME ASSISTANT"
echo "   LOGICA: RESET TOTALE & RICARICA"
echo "==============================================="

# 1. Installazione pacchetti
opkg update
opkg install mosquitto-client-nossl conntrack jsonfilter

# 2. Dati MQTT
echo ""
read -p "Indirizzo IP Broker MQTT: " M_HOST
read -p "Username MQTT: " M_USER
read -p "Password MQTT: " M_PASS
M_PORT="1883"

mkdir -p /etc/openwrt-ha

# 3. Creazione dello script firewall.sh
cat << 'EOF' > /etc/openwrt-ha/firewall.sh
#!/bin/sh
MQTT_HOST="M_HOST_PLACEHOLDER"
MQTT_PORT="M_PORT_PLACEHOLDER"
MQTT_USER="M_USER_PLACEHOLDER"
MQTT_PASS="M_PASS_PLACEHOLDER"

PREFIX="homeassistant"
NODE_ID="openwrt_router"
NODE_NAME="Router OpenWrt"
SENT_RULES_FILE="/etc/openwrt-ha/sent_fw_rules"
LOG_FILE="/tmp/firewall_ha.log"

log() { echo "$(date): $1" >> "$LOG_FILE"; }

# Funzione per eliminare TUTTO quello che è stato creato in precedenza
clear_all_from_ha() {
    [ ! -f "$SENT_RULES_FILE" ] && return
    log "Inizio Tabula Rasa: cancellazione entità esistenti su Home Assistant..."
    
    while IFS='|' read -r OLD_NAME SAFE_NAME; do
        [ -z "$SAFE_NAME" ] && continue
        # Invio payload vuoto con RETAIN per forzare la rimozione del database di HA
        mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$PREFIX/switch/$NODE_ID/$SAFE_NAME/config" -r -n
        mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$PREFIX/switch/$NODE_ID/$SAFE_NAME/state" -r -n
    done < "$SENT_RULES_FILE"
    
    # Svuotiamo il file storico dopo la pulizia
    > "$SENT_RULES_FILE"
    # Attendiamo che il broker elabori le cancellazioni
    sleep 1
}

apply_firewall() {
    local rule_name="$1"
    local action="$2"
    INDEX=$(uci show firewall | grep ".name='$rule_name'" | cut -d'[' -f2 | cut -d']' -f1)
    [ -z "$INDEX" ] && INDEX=$(uci show firewall | grep ".name=$rule_name" | cut -d'[' -f2 | cut -d']' -f1)
    
    if [ -n "$INDEX" ]; then
        uci set firewall.@rule[$INDEX].enabled="$action"
        uci commit firewall
        /etc/init.d/firewall reload
        SAFE_NAME=$(echo "$rule_name" | tr ' ' '_')
        mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$PREFIX/switch/$NODE_ID/$SAFE_NAME/state" -m "$action" -r
    fi
}

discovery_and_state() {
    log "--- Avvio procedura di Refresh (Reset + Load) ---"
    
    # 1. CANCELLA TUTTE LE VECCHIE REGOLE
    clear_all_from_ha
    
    # 2. Registra il pulsante di aggiornamento
    REFRESH_PAYLOAD="{\"name\": \"Aggiorna Regole Firewall\", \"unique_id\": \"${NODE_ID}_refresh\", \"command_topic\": \"$PREFIX/button/$NODE_ID/refresh/set\", \"icon\": \"mdi:refresh\", \"device\": { \"identifiers\": [\"$NODE_ID\"], \"name\": \"$NODE_NAME\" }}"
    mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$PREFIX/button/$NODE_ID/refresh/config" -m "$REFRESH_PAYLOAD" -r
    
    # 3. Carica le regole attualmente presenti sul router
    i=0
    while true; do
        NAME=$(uci -q get firewall.@rule[$i].name)
        [ -z "$NAME" ] && break
        
        SAFE_NAME=$(echo "$NAME" | tr ' ' '_')
        # Salviamo nel file storico per la prossima pulizia
        echo "$NAME|$SAFE_NAME" >> "$SENT_RULES_FILE"
        
        BASE_TOPIC="$PREFIX/switch/$NODE_ID/$SAFE_NAME"
        PAYLOAD="{\"name\": \"Firewall $NAME\", \"unique_id\": \"${NODE_ID}_$SAFE_NAME\", \"state_topic\": \"$BASE_TOPIC/state\", \"command_topic\": \"$BASE_TOPIC/set\", \"payload_on\": \"1\", \"payload_off\": \"0\", \"device\": { \"identifiers\": [\"$NODE_ID\"], \"name\": \"$NODE_NAME\" }}"
        
        mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$BASE_TOPIC/config" -m "$PAYLOAD" -r
        
        ENABLED=$(uci -q get firewall.@rule[$i].enabled)
        [ -z "$ENABLED" ] && ENABLED="1"
        mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$BASE_TOPIC/state" -m "$ENABLED" -r
        
        i=$((i+1))
        usleep 100000
    done
    log "--- Refresh completato: caricate $i regole ---"
}

listen() {
    mosquitto_sub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$PREFIX/+/$NODE_ID/+/set" -v | while read -r line; do
        MSG="${line##* }"
        TOPIC="${line% *}"
        if echo "$TOPIC" | grep -q "refresh/set"; then
            discovery_and_state
            continue
        fi
        SAFE_NAME=$(echo "$TOPIC" | sed 's|.*/\(.*\)/set|\1|')
        ORIG_NAME=$(grep "|$SAFE_NAME$" "$SENT_RULES_FILE" | head -n 1 | cut -d'|' -f1)
        [ -n "$ORIG_NAME" ] && apply_firewall "$ORIG_NAME" "$MSG"
    done
}

discovery_and_state
listen
EOF

# Iniezione variabili reali
sed -i "s/M_HOST_PLACEHOLDER/$M_HOST/" /etc/openwrt-ha/firewall.sh
sed -i "s/M_PORT_PLACEHOLDER/$M_PORT/" /etc/openwrt-ha/firewall.sh
sed -i "s/M_USER_PLACEHOLDER/$M_USER/" /etc/openwrt-ha/firewall.sh
sed -i "s/M_PASS_PLACEHOLDER/$M_PASS/" /etc/openwrt-ha/firewall.sh

chmod +x /etc/openwrt-ha/firewall.sh

# 4. Creazione servizio init.d
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
/etc/init.d/firewall_ha restart

echo "==============================================="
echo "   INSTALLAZIONE COMPLETATA!"
echo "   Ora premi il tasto Aggiorna su Home Assistant."
echo "==============================================="
