#!/bin/sh
# --- CONFIGURAZIONE MQTT ---
MQTT_HOST="10.0.0.5"       # IP del tuo Broker (es. Home Assistant)
MQTT_PORT="1883"           # Porta MQTT standard
MQTT_USER="mqtt_user"
MQTT_PASS="mqttuser"
PREFIX="homeassistant"     # Prefisso per Discovery HA
NODE_ID="openwrt_router"   # Identificativo del router su HA
NODE_NAME="Router OpenWrt" # Nome del dispositivo principale


# --- FUNZIONE APPLICAZIONE REGOLE ---
apply_firewall() {
    local rule_name="$1"
    local action="$2"
    
    # Cerchiamo l'indice della regola in UCI
    INDEX=$(uci show firewall | grep ".name='$rule_name'" | cut -d'[' -f2 | cut -d']' -f1)
    
    if [ -n "$INDEX" ]; then
        echo "Azione: Imposto rule $rule_name (indice $INDEX) a stato $action"
        uci set firewall.@rule[$INDEX].enabled="$action"
        uci commit firewall
        /etc/init.d/firewall reload
        
        # Kill sessioni con conntrack se abilitiamo il blocco (action=1)
        if [ "$action" = "1" ]; then
            MAC=$(uci get firewall.@rule[$INDEX].src_mac 2>/dev/null)
            if [ -n "$MAC" ]; then
                IP=$(cat /tmp/dhcp.leases | grep -i "$MAC" | awk '{print $3}')
                [ -n "$IP" ] && conntrack -D -s "$IP" 2>/dev/null
            fi
        fi
        
        # Feedback immediato a Home Assistant
        mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$PREFIX/switch/$NODE_ID/$rule_name/state" -m "$action" -r
    else
        echo "Errore: Regola '$rule_name' non trovata in UCI"
    fi
}

# --- DISCOVERY & STATO ---
discovery_and_state() {
    echo "Inviando Discovery..."
    i=0
    while true; do
        NAME=$(uci get firewall.@rule[$i].name 2>/dev/null)
        [ -z "$NAME" ] && break
        
        UNIQUE_ID="$NAME"
        BASE_TOPIC="$PREFIX/switch/$NODE_ID/$UNIQUE_ID"
        
        PAYLOAD="{
            \"name\": \"Firewall $NAME\",
            \"unique_id\": \"$UNIQUE_ID\",
            \"state_topic\": \"$BASE_TOPIC/state\",
            \"command_topic\": \"$BASE_TOPIC/set\",
            \"payload_on\": \"1\",
            \"payload_off\": \"0\",
            \"device\": {
                \"identifiers\": [\"$NODE_ID\"],
                \"name\": \"$NODE_NAME\",
                \"manufacturer\": \"OpenWrt\"
            }
        }"
        
        mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$BASE_TOPIC/config" -m "$PAYLOAD" -r
        
        ENABLED=$(uci get firewall.@rule[$i].enabled 2>/dev/null || echo "1")
        mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$BASE_TOPIC/state" -m "$ENABLED" -r
        
        i=$((i+1))
    done
}

# --- LISTENER (PARSING CON SED) ---
# Usa sed per estrarre il nome senza bisogno del comando 'rev'
listen() {
    echo "Listener pronto..."
    mosquitto_sub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASS" -t "$PREFIX/switch/$NODE_ID/+/set" -v | while read -r line; do
        
        TOPIC=$(echo "$line" | cut -d' ' -f1)
        MSG=$(echo "$line" | cut -d' ' -f2)
        
        # LOGICA SED: rimuove '/set' finale e tutto quello che c'è prima dell'ultimo '/'
        # Trasforma 'homeassistant/switch/openwrt_router/testsmartv/set' in 'testsmartv'
        R_NAME=$(echo "$TOPIC" | sed 's|/set$||; s|.*/||')
        
        if [ -n "$R_NAME" ]; then
            echo "Ricevuto comando $MSG per la regola UCI: $R_NAME"
            apply_firewall "$R_NAME" "$MSG"
        fi
    done
}

discovery_and_state
listen