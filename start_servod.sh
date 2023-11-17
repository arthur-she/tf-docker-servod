# Copyright 2021 The ChromiumOS Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

#!/bin/bash

set -x

CONFIG_FILE_DIR="/var/lib/servod"
CONFIG_FILE=$CONFIG_FILE_DIR/config_$PORT
LOG="/var/log/servod_$PORT.STARTUP.log"
LOG_BACKUP_COUNT=1024
LOG_DIR="/var/log/servod"
DUT_CONTROL="/usr/local/bin/dut-control"
PTS_DIR="/run/pts"

# Default port to be 9999.
PORT=${PORT:-9999}
mkdir -p /var/lib/servod
. /hdctools/chromeos/servod_utils.sh

echo "Pre-start PORT=$PORT BOARD=$BOARD MODEL=$MODEL SERIAL=$SERIAL."

for CMD in iptables-legacy ip6tables-legacy ; do
    $CMD -A INPUT -p tcp --dport $PORT -j ACCEPT || echo "Failed to configure $CMD."
done

echo "Update config. PORT=$PORT BOARD=$BOARD MODEL=$MODEL SERIAL=$SERIAL."

# We'll want to update the config file with all the args passed in.
update_config $CONFIG_FILE BOARD $BOARD
update_config $CONFIG_FILE MODEL $MODEL
update_config $CONFIG_FILE SERIAL $SERIAL
update_config $CONFIG_FILE CONFIG $CONFIG
update_config $CONFIG_FILE DUAL_V4 $DUAL_V4

echo "Store servo hub location and servo micro serial if presents. "\
    "$CONFIG_FILE $SERIAL"
cache_servov4_hub_and_servo_micro $CONFIG_FILE $SERIAL
echo "Pre-start complete."

SERVO_MICRO_VIDPID="18d1:501a"
SERVO_V4_VIDPID="18d1:501b"

if [ ! -f $CONFIG_FILE ]; then
    echo "No configuration file ($CONFIG_FILE); terminating"
    stop
    exit 0
fi

if [ -z "$BOARD" ]; then
    echo "No board specified; terminating"
    stop
    exit 0
fi

MODEL_MSG=""
MODEL_FLAG=""
if [ -n "$MODEL" ]; then
    MODEL_FLAG="--model ${MODEL}"
    MODEL_MSG=" model ${MODEL}"
fi

SERIAL_FLAG=""
SERIAL_MSG=""
if [ -z "$SERIAL" ]; then
    log_output "No serial specified"
else
    SERIAL_FLAG="--serialname ${SERIAL}"
    SERIAL_MSG="using servo serial $SERIAL"
fi

BOARD_FLAG="--board ${BOARD}"
PORT_FLAG="--port ${PORT}"

if [ "$DEBUG" = "1" ]; then
    DEBUG_FLAG="--debug"
else
    DEBUG_FLAG=""
fi

CONFIG_FLAG=""
if [ ! -z "$CONFIG" ]; then
    CONFIG_FLAG="--config ${CONFIG}"
fi

REC_MODE_FLAG=""
if [ ! -z "$REC_MODE" ]; then
    REC_MODE_FLAG="--recovery_mode"
fi

if [ "$DUAL_V4" = "1" ]; then
    DUAL_V4_FLAG="--allow-dual-v4"
else
    DUAL_V4_FLAG=""
fi

if [ -n "$SERIAL" ]; then
    servodtool device -s $SERIAL reboot && sleep 5
fi

echo "Launching servod for $BOARD $MODEL_MSG on port $PORT $SERIAL_MSG"

servod \
    --host 0.0.0.0 \
    --log-dir-backup-count $LOG_BACKUP_COUNT \
    --log-dir $LOG_DIR \
    --recovery_mode \
    $BOARD_FLAG \
    $MODEL_FLAG \
    $SERIAL_FLAG \
    $PORT_FLAG \
    $DEBUG_FLAG \
    $REC_MODE_FLAG \
    $CONFIG_FLAG \
    $DUAL_V4_FLAG &

PID=$!
sleep 10

if [ -n "$LAVA_DEVICE" ]; then
    CPU_UART="$(${DUT_CONTROL} $PORT_FLAG cpu_uart_pty | awk -F':' '{print $2}')"
    [ -n "${CPU_UART}" ] && ln -fs "${CPU_UART}" "${PTS_DIR}/cpu_uart-${LAVA_DEVICE}"
    CR50_UART="$(${DUT_CONTROL} $PORT_FLAG cr50_uart_pty | awk -F':' '{print $2}')"
    [ -n "${CR50_UART}" ] && ln -fs "${CR50_UART}" "${PTS_DIR}/cr50_uart-${LAVA_DEVICE}"
    EC_UART="$(${DUT_CONTROL} $PORT_FLAG ec_uart_pty | awk -F':' '{print $2}')"
    [ -n "${EC_UART}" ] && ln -fs "${EC_UART}" "${PTS_DIR}/ec_uart-${LAVA_DEVICE}"
fi


wait $PID
echo "servod has been terminated!!"
