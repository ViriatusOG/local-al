#!/bin/bash
# One-shot installer for the AMD GPU tuning setup (Ubuntu).
# Tuning profiles:
#   - R9700:    -50mV undervolt, 265W power cap   (tune_r9700.sh)
#   - 9070 XT:  -50mV undervolt, 265W power cap   (tune_rx9070xt.sh)
#   - IRQ pinning for both GPUs                  (pin_gpu_irqs.sh)
# Run as root on the server:
#   sudo bash /path/to/r9700-setup/apply-tuning.sh
# Then reboot (required for the kernel flags that enable undervolting):
#   sudo reboot
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "== Installing GPU tuning scripts + services =="
install -m 0755 "$DIR/tune_r9700.sh" /usr/local/bin/tune_r9700.sh
install -m 0644 "$DIR/amd-gpu-tune.service" /etc/systemd/system/amd-gpu-tune.service
install -m 0755 "$DIR/tune_rx9070xt.sh" /usr/local/bin/tune_rx9070xt.sh
install -m 0644 "$DIR/amd-rx9070xt-tune.service" /etc/systemd/system/amd-rx9070xt-tune.service

echo "== Installing IRQ pinning script + service =="
install -m 0755 "$DIR/pin_gpu_irqs.sh" /usr/local/bin/pin_gpu_irqs.sh
install -m 0644 "$DIR/gpu-irq-pin.service" /etc/systemd/system/gpu-irq-pin.service

echo "== Configuring kernel cmdline flags =="
GRUB_FLAGS="iommu=pt processor.max_cstate=2 pcie_aspm=off amdgpu.ppfeaturemask=0xffffffff"
if grep -q 'amdgpu.ppfeaturemask' /etc/default/grub; then
    echo "Flags already present in /etc/default/grub (skipping)."
else
    BACKUP="/etc/default/grub.bak.$(date +%Y%m%d%H%M%S)"
    cp /etc/default/grub "$BACKUP"
    echo "Backed up /etc/default/grub -> $BACKUP"
    if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub; then
        sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=\"\(.*\)\"|GRUB_CMDLINE_LINUX_DEFAULT=\"\1 $GRUB_FLAGS\"|" /etc/default/grub
        # Clean up any potential double leading space if original was empty
        sed -i 's|GRUB_CMDLINE_LINUX_DEFAULT=" |GRUB_CMDLINE_LINUX_DEFAULT="|' /etc/default/grub
    elif grep -q '^GRUB_CMDLINE_LINUX=' /etc/default/grub; then
        sed -i "s|^GRUB_CMDLINE_LINUX=\"\(.*\)\"|GRUB_CMDLINE_LINUX=\"\1 $GRUB_FLAGS\"|" /etc/default/grub
        sed -i 's|GRUB_CMDLINE_LINUX=" |GRUB_CMDLINE_LINUX="|' /etc/default/grub
    else
        echo "GRUB_CMDLINE_LINUX=\"$GRUB_FLAGS\"" >> /etc/default/grub
    fi
    update-grub
fi

echo "== Enabling services (they run at boot) =="
systemctl daemon-reload
systemctl enable amd-gpu-tune.service amd-rx9070xt-tune.service gpu-irq-pin.service

echo "== Applying tuning immediately =="
echo "--- R9700: power limits / undervolt ---"
/usr/local/bin/tune_r9700.sh || echo "[warn] tune_r9700.sh reported issues (undervolt applies after reboot)"
echo "--- RX 9070 XT: power limits / undervolt ---"
/usr/local/bin/tune_rx9070xt.sh || echo "[warn] tune_rx9070xt.sh reported issues (undervolt applies after reboot)"
echo "--- IRQ pinning ---"
/usr/local/bin/pin_gpu_irqs.sh || echo "[warn] pin_gpu_irqs.sh reported issues"

echo
echo "=== Install complete ==="
echo "Reboot now to activate the kernel flags (undervolt needs them):"
echo "    sudo reboot"
