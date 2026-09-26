#!/bin/bash

# --- CONFIGURATION ---
UNDERVOLT_MV=-50
POWER_LIMIT_WATT=265
POWER_LIMIT_HW=$(($POWER_LIMIT_WATT * 1000000))

# ---------------------

# Auto-discover the RX 9070 XT ONLY.
# PCI ID 0x1002:0x7550 = RX 9070/9070 XT (Navi 48, upstream pci.ids).
# NOTE: 0x1002:0x7551 = R9700 -- deliberately excluded (tuned separately).
# Benchmarked 2026-09-26: 280W/−65mV ~= 280W/−50mV (59.7 tps gen short, ~4% under
# stock 304W) while saving ~35W and 6°C. Deeper UV adds voltage headroom, no speed cost.
PCI_IDS=()
for DEV in /sys/bus/pci/devices/0000:*; do
    if [ -r "$DEV/device" ]; then
        DID="$(cat "$DEV/vendor"):$(cat "$DEV/device")"
        case "$DID" in
            0x1002:0x7550) PCI_IDS+=("$(basename "$DEV")") ;;
        esac
    fi
done
if [ ${#PCI_IDS[@]} -eq 0 ]; then
    while IFS= read -r line; do
        BUS_ID=$(echo "$line" | grep -oP '^\S+')
        PCI_IDS+=("0000:$BUS_ID")
    done < <(lspci | grep -i 9070)
fi

if [ ${#PCI_IDS[@]} -eq 0 ]; then
    echo "Error: No RX 9070 XT GPUs found."
    exit 1
fi

echo "Discovered ${#PCI_IDS[@]} RX 9070 XT GPU(s): ${PCI_IDS[*]}"
echo "---"

# Arrays to store resolved paths for verification
declare -a CARD_NAMES
declare -a HWMON_DIRS

tune_card() {
    local PCI_ID="$1"
    local idx="$2"

    # 1. Find the Card Name (e.g., card1) from the PCI Bus
    # Wait up to 10s in case amdgpu module initialization is still in progress at boot
    local attempts=0
    while [ ! -d "/sys/bus/pci/devices/$PCI_ID/drm" ] && [ $attempts -lt 10 ]; do
        sleep 1
        ((attempts++))
    done

    if [ ! -d "/sys/bus/pci/devices/$PCI_ID/drm" ]; then
        echo "[FAIL] PCI Device $PCI_ID not found or has no DRM driver attached."
        return 1
    fi

    local CARD_NAME
    CARD_NAME=$(ls "/sys/bus/pci/devices/$PCI_ID/drm" | grep -E '^card[0-9]+$' | head -n 1)

    if [ -z "$CARD_NAME" ]; then
        echo "[FAIL] Could not determine card name for $PCI_ID"
        return 1
    fi

    local CARD_PATH="/sys/class/drm/$CARD_NAME"
    CARD_NAMES[$idx]="$CARD_NAME"
    echo "Tuning GPU: $CARD_NAME ($PCI_ID)..."

    # 2. Force Manual Performance Level (Required for UV)
    if echo "manual" | tee "$CARD_PATH/device/power_dpm_force_performance_level" > /dev/null 2>&1; then
        echo "  -> Set performance level: manual"
    else
        echo "[FAIL] Failed to set Manual mode for $CARD_NAME."
        return 1
    fi

    # 3. Apply Undervolt (requires amdgpu.ppfeaturemask=0xffffffff kernel flag)
    if [ -e "$CARD_PATH/device/pp_od_clk_voltage" ]; then
        if echo "vo $UNDERVOLT_MV" | tee "$CARD_PATH/device/pp_od_clk_voltage" > /dev/null 2>&1 && \
           echo "c" | tee "$CARD_PATH/device/pp_od_clk_voltage" > /dev/null 2>&1; then
            echo "  -> Applied Undervolt (${UNDERVOLT_MV}mV)"
        else
            echo "[FAIL] Failed to apply Undervolt (${UNDERVOLT_MV}mV) for $CARD_NAME (offset rejected by driver?)"
            return 1
        fi
    else
        echo "[SKIP] pp_od_clk_voltage not available (amdgpu.ppfeaturemask kernel flag not active yet?)"
    fi

    # 4. Set Power Limit
    local HWMON_DIR
    HWMON_DIR=$(find "$CARD_PATH/device/hwmon" -mindepth 1 -maxdepth 1 -type d -name "hwmon*" | head -n 1)
    if [ -n "$HWMON_DIR" ] && [ -e "$HWMON_DIR/power1_cap" ]; then
        if echo "$POWER_LIMIT_HW" | tee "$HWMON_DIR/power1_cap" > /dev/null; then
            echo "  -> Applied Power Limit (${POWER_LIMIT_WATT}W)"
            HWMON_DIRS[$idx]="$HWMON_DIR"
        else
            echo "[FAIL] Failed to apply Power Limit for $CARD_NAME."
            return 1
        fi
    else
        echo "[FAIL] Could not find writable power1_cap under hwmon for $CARD_NAME."
        return 1
    fi

    echo "  -> Done."
    return 0
}

# Tune each discovered card
FAILED=0
idx=0
for PCI_ID in "${PCI_IDS[@]}"; do
    tune_card "$PCI_ID" "$idx" || ((FAILED++))
    echo "---"
    ((idx++))
done

if [ $FAILED -gt 0 ]; then
    echo "Completed with $FAILED failure(s)."
    exit 1
fi

echo "All GPUs tuned successfully."
echo ""
echo "=== VERIFICATION ==="

for i in "${!CARD_NAMES[@]}"; do
    CARD_NAME="${CARD_NAMES[$i]}"
    CARD_PATH="/sys/class/drm/$CARD_NAME"
    echo "--- $CARD_NAME ---"

    # Check Undervolt (label and value are on separate lines)
    UV_OUTPUT=$(cat "$CARD_PATH/device/pp_od_clk_voltage" 2>/dev/null)
    if [ -n "$UV_OUTPUT" ]; then
        OFFSET_LINE=$(echo "$UV_OUTPUT" | grep -A1 "^OD_VDDGFX_OFFSET:")
        if [ -n "$OFFSET_LINE" ]; then
            OFFSET_VAL=$(echo "$OFFSET_LINE" | tail -n1 | xargs)
            echo "  Undervolt: OD_VDDGFX_OFFSET: $OFFSET_VAL"
        else
            echo "  Undervolt: (could not parse offset from output)"
        fi
    else
        echo "  Undervolt: (not available until reboot with amdgpu.ppfeaturemask)"
    fi

    # Check Power Limit
    if [ -n "${HWMON_DIRS[$i]}" ]; then
        POWER_RAW=$(cat "${HWMON_DIRS[$i]}/power1_cap" 2>/dev/null)
        if [ -n "$POWER_RAW" ]; then
            POWER_W=$((POWER_RAW / 1000000))
            echo "  Power Limit: ${POWER_W}W (target: ${POWER_LIMIT_WATT}W)"
        else
            echo "  Power Limit: (unable to read)"
        fi
    else
        echo "  Power Limit: (hwmon path not available)"
    fi
done

echo ""
echo "=== DONE ==="
