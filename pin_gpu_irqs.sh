#!/bin/bash

echo "=== STARTING GPU IRQ INTERRUPT PINNING ==="

# Track whether irqbalance was running so we can restore it later
IRQBALANCE_WAS_ACTIVE=false
if systemctl is-active --quiet irqbalance; then
    IRQBALANCE_WAS_ACTIVE=true
fi

if [ "$IRQBALANCE_WAS_ACTIVE" = true ]; then
    echo "Temporarily stopping irqbalance service..."
    systemctl stop irqbalance
fi

# Auto-discover the Navi 48 GPUs to pin:
#   0x1002:0x7551 = Radeon AI PRO R9700
#   0x1002:0x7550 = RX 9070/9070 XT (included -- IRQ pinning is beneficial
#   for it too, even though undervolting is R9700-only).
# Fallback: match the name "R9700" in lspci output.
PCI_IDS=()
for DEV in /sys/bus/pci/devices/0000:*; do
    if [ -r "$DEV/device" ]; then
        DID="$(cat "$DEV/vendor"):$(cat "$DEV/device")"
        case "$DID" in
            0x1002:0x7550|0x1002:0x7551) PCI_IDS+=("$(basename "$DEV")") ;;
        esac
    fi
done
if [ ${#PCI_IDS[@]} -eq 0 ]; then
    while IFS= read -r line; do
        BUS_ID=$(echo "$line" | grep -oP '^\S+')
        PCI_IDS+=("0000:$BUS_ID")
    done < <(lspci | grep -i R9700)
fi

if [ ${#PCI_IDS[@]} -eq 0 ]; then
    echo "[FAIL] No Navi 48 GPUs found."
    exit 1
fi

echo "Discovered ${#PCI_IDS[@]} Navi 48 GPU(s) to pin: ${PCI_IDS[*]}"

declare -a GPU_IRQS
declare -a GPU_CARDS

for PCI_ID in "${PCI_IDS[@]}"; do
    if [ ! -d "/sys/bus/pci/devices/$PCI_ID/drm" ]; then
        echo "[FAIL] PCI Device $PCI_ID not found or has no DRM driver attached."
        continue
    fi

    CARD_NAME=$(ls "/sys/bus/pci/devices/$PCI_ID/drm" | grep -E '^card[0-9]+$' | head -n 1)
    if [ -z "$CARD_NAME" ]; then
        echo "[FAIL] Could not determine card name for $PCI_ID"
        continue
    fi

    CARD_PATH="/sys/class/drm/$CARD_NAME"
    IRQ=$(cat "$CARD_PATH/device/irq" 2>/dev/null)

    if [ -z "$IRQ" ]; then
        echo "[FAIL] Could not read IRQ for $CARD_NAME ($PCI_ID)"
        continue
    fi

    GPU_IRQS+=("$IRQ")
    GPU_CARDS+=("$CARD_NAME")
    echo "  $CARD_NAME ($PCI_ID) -> IRQ $IRQ"
done

if [ ${#GPU_IRQS[@]} -eq 0 ]; then
    echo "[FAIL] No valid R9700 IRQs discovered."
    exit 1
fi

echo "---"

NUM_CPUS=$(nproc)
NUM_GPUS=${#GPU_IRQS[@]}
echo "Total logical CPUs detected: $NUM_CPUS"

# Physical-core id per logical CPU
declare -a CORE_OF_CPU
for l in $(seq 0 $((NUM_CPUS - 1))); do
    t="/sys/devices/system/cpu/cpu$l/topology"
    if [ -r "$t/core_id" ]; then
        CORE_OF_CPU[$l]=$(cat "$t/core_id")
    else
        CORE_OF_CPU[$l]=$l
    fi
done

# Unique physical-core ids, highest first.
mapfile -t PHYS_ORDER < <(printf '%s\n' "${CORE_OF_CPU[@]}" | sort -n -u | tac)

declare -a USED_PHYS_IDS
declare -a PINNED_CPUS
idx=0
for IRQ in "${GPU_IRQS[@]}"; do
    PICKED=""
    for phys in "${PHYS_ORDER[@]}"; do
        # Skip physical cores already assigned to another GPU
        skip=false
        for u in ${USED_PHYS_IDS[@]+"${USED_PHYS_IDS[@]}"}; do
            [ "$u" = "$phys" ] && skip=true && break
        done
        [ "$skip" = true ] && continue

        # Pick the lowest-numbered logical CPU of this physical core
        for l in $(seq 0 $((NUM_CPUS - 1))); do
            if [ "${CORE_OF_CPU[$l]:-}" = "$phys" ]; then
                PICKED=$l
                break
            fi
        done
        if [ -n "$PICKED" ]; then
            USED_PHYS_IDS+=("$phys")
            break
        fi
    done

    if [ -z "$PICKED" ]; then
        echo "[FAIL] No free physical core left to pin IRQ $IRQ."
        exit 1
    fi

    CARD="${GPU_CARDS[$idx]}"
    PINNED_CPUS+=("$PICKED")
    echo "Mapping GPU $CARD (IRQ $IRQ) -> CPU $PICKED (physical core ${CORE_OF_CPU[$PICKED]})"
    echo "$PICKED" > "/proc/irq/$IRQ/smp_affinity_list"
    ((idx++))
done

# Fully isolate the used physical cores: ban ALL logical threads (SMT siblings)
# belonging to the assigned physical cores from irqbalance.
BANNED_CPUS_ARR=()
for l in $(seq 0 $((NUM_CPUS - 1))); do
    c="${CORE_OF_CPU[$l]:-}"
    for u in "${USED_PHYS_IDS[@]}"; do
        if [ "$c" = "$u" ]; then
            BANNED_CPUS_ARR+=("$l")
            break
        fi
    done
done

# Build the sorted comma-separated CPU list and hex mask for irqbalance.
mapfile -t BANNED_CPUS_SORTED < <(printf '%s\n' "${BANNED_CPUS_ARR[@]}" | sort -n -u)
BANNED_LIST=$(IFS=,; echo "${BANNED_CPUS_SORTED[*]}")
BANNED_MASK=0
for cpu in "${BANNED_CPUS_SORTED[@]}"; do
    if [ "$cpu" -lt 63 ]; then
        BANNED_MASK=$(( BANNED_MASK | (1 << cpu) ))
    fi
done
BANNED_HEX=$(printf '%x' "$BANNED_MASK")

# Re-pin any conflicting non-Navi48 amdgpu devices (like an iGPU)
declare -A NAVI_IRQ_MAP
for irq in "${GPU_IRQS[@]}"; do
    NAVI_IRQ_MAP[$irq]=1
done

while IFS= read -r line; do
    IRQ_NUM=$(echo "$line" | awk -F: '{print $1}' | tr -d ' ')
    DEV_INFO=$(echo "$line" | awk '{$1=""; print $0}' | xargs)
    if [ -z "$IRQ_NUM" ]; then
        continue
    fi

    [ "${NAVI_IRQ_MAP[$IRQ_NUM]:-0}" = "1" ] && continue

    CURRENT_LIST=$(cat "/proc/irq/$IRQ_NUM/smp_affinity_list" 2>/dev/null) || continue

    # Check if the conflicting IRQ lands on any of our isolated cores
    CONFLICT=false
    for cpu in "${BANNED_CPUS_SORTED[@]}"; do
        if [[ ",$CURRENT_LIST," == *",$cpu,"* ]]; then
            CONFLICT=true
            break
        fi
    done

    if [ "$CONFLICT" = true ]; then
        # Find the highest safe core not in BANNED_CPUS_SORTED
        NEW_CPU=$(( NUM_CPUS - 1 ))
        while [[ " ${BANNED_CPUS_SORTED[*]} " == *" $NEW_CPU "* ]] && [ "$NEW_CPU" -ge 0 ]; do
            ((NEW_CPU--))
        done

        if [ "$NEW_CPU" -ge 0 ]; then
            echo "Re-pinning non-Navi48 amdgpu device (IRQ $IRQ_NUM: $DEV_INFO) -> CPU $NEW_CPU"
            echo "$NEW_CPU" > "/proc/irq/$IRQ_NUM/smp_affinity_list"
        fi
    fi
done < <(grep -i amdgpu /proc/interrupts)

# Inject environment overrides to irqbalance
echo "Banning isolated physical cores from irqbalance: mask=$BANNED_HEX cpulist=$BANNED_LIST"
systemctl set-environment "IRQBALANCE_BANNED_CPUS=$BANNED_HEX"
systemctl set-environment "IRQBALANCE_BANNED_CPULIST=$BANNED_LIST"

# Maintain systemd drop-in for explicit IRQ banning and CPU isolation
# (Preserves --foreground in Ubuntu's default irqbalance.service)
DROPIN_DIR="/etc/systemd/system/irqbalance.service.d"
DROPIN_FILE="$DROPIN_DIR/pin_gpu_irqs.conf"
mkdir -p "$DROPIN_DIR"

BAN_ARGS=""
for IRQ in "${GPU_IRQS[@]}"; do
    BAN_ARGS+=" --banirq=$IRQ"
done

cat <<EOF > "$DROPIN_FILE"
[Service]
Environment="IRQBALANCE_BANNED_CPUS=$BANNED_HEX"
Environment="IRQBALANCE_BANNED_CPULIST=$BANNED_LIST"
Environment="IRQBALANCE_ARGS=$BAN_ARGS"
EOF

echo "Created systemd drop-in at $DROPIN_FILE: args=$BAN_ARGS cpulist=$BANNED_LIST"
systemctl daemon-reload

if [ "$IRQBALANCE_WAS_ACTIVE" = true ]; then
    echo "Restarting irqbalance service..."
    systemctl start irqbalance
fi

echo "=== IRQ PINNING COMPLETE ==="
exit 0
