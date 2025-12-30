#!/bin/sh
# --- CONFIGURAZIONE MQTT ---
MQTT_HOST="10.0.0.x"
MQTT_PORT="1883"
MQTT_USER="tuo_user"
MQTT_PASS="tuo_pass"
PREFIX="homeassistant"
NODE_ID="openwrt_router"
NODE_NAME="Router OpenWrt"

# File temporaneo per tracciare le regole inviate a HA
SENT_RULES_FILE="/tmp/sent_fw_rules"

# --- FUNZIONE APPLICAZIONE REGOLE ---
apply_firewall() {
    local rule_name="$1"
    local action="$2"
    
    INDEX=$(uci show firewall | grep ".name='$rule_name'" | cut -d'[' -f2 | cut -d']' -f1)
    
    if [ -n "$INDEX" ]; then
        echo "Azione su $rule_name: $action"
        uci set firewall.@rule[$INDEX].enabled="$action"
        uci commit firewall
        /etc/init.d/firewall reload
        
        if [ "$action" = "1" ]; then
            MAC=$(uci get firewall.@rule[$INDEX].src_mac 2>/dev/null)
            if [ -n "$MAC" ]; then
                IP=$(cat /tmp/dhcp.leases | grep -i "$MAC" | awk '{print $3}')
                [ -n "$IP" ] && conntrack -D -s "$IP" 2>/dev/null
            fi
        fi
        mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$PREFIX/switch/$NODE_ID/$rule_name/state" -m "$action" -r
    fi
}

# --- FUNZIONE DI PULIZIA ORFANI ---
# Rimuove da HA le regole che non esistono più sul router
cleanup_orphans() {
    [ ! -f "$SENT_RULES_FILE" ] && return
    
    echo "Controllo regole rimosse..."
    for OLD_NAME in $(cat "$SENT_RULES_FILE"); do
        if ! uci show firewall | grep "firewall.@rule" | grep -q ".name='$OLD_NAME'"; then
            echo "Regola '$OLD_NAME' non più presente. Rimuovo da Home Assistant..."
            # Inviando un payload vuoto (-n) al topic config, HA elimina l'entità
            mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" \
                -t "$PREFIX/switch/$NODE_ID/$OLD_NAME/config" -r -n
        fi
    done
}

# --- DISCOVERY & STATO ---
discovery_and_state() {
    # 1. Pulisce le regole vecchie prima di inviare le nuove
    cleanup_orphans

    echo "Eseguo scansione regole firewall..."
    
    # 2. Discovery del tasto REFRESH
    REFRESH_PAYLOAD="{
        \"name\": \"Aggiorna Regole Firewall\",
        \"unique_id\": \"${NODE_ID}_refresh\",
        \"command_topic\": \"$PREFIX/button/$NODE_ID/refresh/set\",
        \"icon\": \"mdi:refresh\",
        \"device\": { \"identifiers\": [\"$NODE_ID\"], \"name\": \"$NODE_NAME\" }
    }"
    mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$PREFIX/button/$NODE_ID/refresh/config" -m "$REFRESH_PAYLOAD" -r

    # 3. Scansione regole correnti
    i=0
    while true; do
        NAME=$(uci get firewall.@rule[$i].name 2>/dev/null)
        [ -z "$NAME" ] && break
        
        UNIQUE_ID="$NAME"
        BASE_TOPIC="$PREFIX/switch/$NODE_ID/$UNIQUE_ID"
        
        echo "Esporto regola: $NAME"

        PAYLOAD="{
            \"name\": \"Firewall $NAME\",
            \"unique_id\": \"$UNIQUE_ID\",
            \"state_topic\": \"$BASE_TOPIC/state\",
            \"command_topic\": \"$BASE_TOPIC/set\",
            \"payload_on\": \"1\",
            \"payload_off\": \"0\",
            \"device\": { \"identifiers\": [\"$NODE_ID\"], \"name\": \"$NODE_NAME\" }
        }"
        
        mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$BASE_TOPIC/config" -m "$PAYLOAD" -r
        
        ENABLED=$(uci get firewall.@rule[$i].enabled 2>/dev/null || echo "1")
        mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$BASE_TOPIC/state" -m "$ENABLED" -r
        
        i=$((i+1))
    done

    # 4. Aggiorna il file temporaneo con la lista attuale
    uci show firewall | grep "firewall.@rule" | grep ".name=" | cut -d"'" -f2 > "$SENT_RULES_FILE"
}

# --- LISTENER ---
listen() {
    echo "Listener pronto..."
    mosquitto_sub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$PREFIX/+/$NODE_ID/+/set" -v | while read -r line; do
        TOPIC=$(echo "$line" | cut -d' ' -f1)
        MSG=$(echo "$line" | cut -d' ' -f2)
        
        if echo "$TOPIC" | grep -q "button/.*/refresh/set"; then
            echo "Comando Refresh ricevuto: rieseguo scansione..."
            discovery_and_state
            continue
        fi

        R_NAME=$(echo "$TOPIC" | sed 's|/set$||; s|.*/||')
        if [ -n "$R_NAME" ]; then
            echo "Comando $MSG per regola: $R_NAME"
            apply_firewall "$R_NAME" "$MSG"
        fi
    done
}

discovery_and_state
listen