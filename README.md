# Dual Navi 48 (Radeon AI PRO R9700 + RX 9070 XT) ROCm Tuning Guide

A battle-tested collection of scripts, systemd services, and configuration guides for optimizing a mixed multi-GPU setup on **Ubuntu 24.04** with AMD ROCm for large language model inference (`llama.cpp`, `llama-server`, `llama-taco`, and `vLLM`).

---

## Hardware & System Profile

- **Host**: Ubuntu 24.04 LTS (Linux kernel 6.8+), AMD Ryzen 7 5800X (8 physical cores / 16 threads), ROCm 7.x
- **GPU 0**: AMD Radeon AI PRO R9700 (`0x1002:0x7551`, 32 GB GDDR6, 300W TBP)
- **GPU 1**: AMD Radeon RX 9070 XT (`0x1002:0x7550`, 16 GB GDDR6, 304W TBP)

---

## Tuning Profiles

| GPU | Device ID | Undervolt | Power Limit | Script / Service | Impact |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Radeon AI PRO R9700** | `0x1002:0x7551` | **−85 mV** | **265W – 280W** | `tune_r9700.sh` / `amd-gpu-tune.service` | **63.2 tps** (+0.5 tps over stock) while saving ~19–33W |
| **Radeon RX 9070 XT** | `0x1002:0x7550` | **−65 mV** | **280W** | `tune_rx9070xt.sh` / `amd-rx9070xt-tune.service` | **59.7 tps**, **6 °C cooler** (78 °C peak), saving **~35W** |

---

## Key Features & Improvements

### 1. Multi-SKU Dynamic Sysfs Discovery
- Auto-detects R9700 and RX 9070 XT GPUs directly from `/sys/bus/pci/devices/*/vendor` and `device` IDs (does not depend on outdated `lspci` / `pci.ids` strings).
- Calibrated undervolts and power limits target each card independently.
- Built-in 10-second wait loop prevents systemd boot race conditions during early driver initialization.

### 2. Physical Core & SMT Sibling IRQ Isolation
- Pins each GPU's hardware PCIe interrupt to a dedicated physical CPU core (`pin_gpu_irqs.sh`).
- Fully isolates the physical cores by banning **both logical threads (primary and SMT siblings)** from `irqbalance`, eliminating interrupt jitter.
- Uses a systemd drop-in (`/etc/systemd/system/irqbalance.service.d/pin_gpu_irqs.conf`) with `Environment=` overrides to preserve Ubuntu's default `--foreground` daemon mode.

### 3. Safe, ROCm-Optimized Kernel Configuration
- Configures kernel flags safely via `apply-tuning.sh` with automatic timestamped `/etc/default/grub` backups.
- **`iommu=pt`**: Enables IOMMU pass-through (preserves ROCm KFD memory interfaces and virtualization/Docker compatibility without performance overhead).
- **`processor.max_cstate=2`**: Reduces CPU C-state wake latency during token generation.
- **`pcie_aspm=off`**: Disables PCIe Active State Power Management for sustained high-bandwidth transfers.
- **`amdgpu.ppfeaturemask=0xffffffff`**: Unlocks OverDrive voltage and clock manipulation in the `amdgpu` driver.

---

## One-Shot Installation

Run the installer on the server as `root`:

```bash
cd /path/to/r9700-setup
sudo bash apply-tuning.sh
```

### What it does:
1. Installs scripts to `/usr/local/bin/` and systemd units to `/etc/systemd/system/`.
2. Backs up `/etc/default/grub` and appends the kernel parameters cleanly.
3. Enables all systemd services to apply automatically on boot.
4. Applies power limits and IRQ pinning immediately without interrupting active workloads.

After running `apply-tuning.sh`, reboot once to activate the kernel flags required for undervolting:
```bash
sudo reboot
```

---

## Verification After Reboot

Run this all-in-one check to confirm kernel flags, services, undervolts, and IRQs:

```bash
echo "=== 1. CMDLINE ===" && cat /proc/cmdline | tr ' ' '\n' | grep -E 'ppfeaturemask|iommu|aspm'
echo -e "\n=== 2. SERVICES ===" && systemctl is-active amd-gpu-tune amd-rx9070xt-tune gpu-irq-pin
echo -e "\n=== 3. UNDERVOLTS ==="
grep -A1 OD_VDDGFX_OFFSET /sys/class/drm/card0/device/pp_od_clk_voltage 2>/dev/null
grep -A1 OD_VDDGFX_OFFSET /sys/class/drm/card1/device/pp_od_clk_voltage 2>/dev/null
echo -e "\n=== 4. IRQ PINNING ===" && head -n1 /proc/irq/93/smp_affinity_list /proc/irq/94/smp_affinity_list
```

Expected output:
- `iommu=pt`, `pcie_aspm=off`, `amdgpu.ppfeaturemask=0xffffffff`
- Services reporting `active`
- Card 0: `-85mV`, Card 1: `-65mV`
- IRQs pinned to distinct physical cores (e.g. CPU 5 and 6)

---

## Benchmark Results (llama-taco / Qwen3.8-27B IQ3_S + MTP)

All benchmarks measured with Qwen3.8-27B IQ3_S + MTP draft acceptance (72–73%):

### Radeon AI PRO R9700 (`gpu0-only`, 262k context)
| Profile | Gen Speed (short) | Gen Speed (long) | Prompt Speed | Avg Power | Peak Temp | Tokens / Joule |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Stock (300W cap)** | 62.7 tok/s | 56.1 tok/s | 536 tok/s | 289.9 W | 91 °C | 0.216 |
| **Tuned (265W, −85mV)** | 62.3 tok/s | 52.7 tok/s | 545 tok/s | **256.9 W** | **90 °C** | **0.249 (+15%)** |
| **Tuned (280W, −85mV)** | **63.2 tok/s** | 53.3 tok/s | **544 tok/s** | **271.3 W** | 92 °C | 0.233 |

### Radeon RX 9070 XT (`gpu1-only`, 48k context)
| Profile | Gen Speed (short) | Gen Speed (long) | Prompt Speed | Avg Power | Peak Temp | Tokens / Joule |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Stock (304W limit)** | 61.8 tok/s | 49.7 tok/s | 533 tok/s | 293.1 W | 84 °C | 0.211 |
| **Conservative (250W, −50mV)** | 57.9 tok/s | 46.5 tok/s | 492 tok/s | 238.8 W | 78 °C | 0.242 (+15%) |
| **Final (280W, −65mV)** | **59.7 tok/s** | **48.2 tok/s** | 499 tok/s | **261.6 W** | **78 °C (−6°C)** | **0.230 (+9%)** |

---

## Compiling llama.cpp with ROCm (RDNA 4 / Navi 48)

If compiling `llama.cpp` from source, configure CMake with RDNA 4 (`gfx1200;gfx1201`) targets and Flash Attention:

```bash
git clone https://github.com/ggml-org/llama.cpp.git
cd llama.cpp

HIPCXX="$(hipconfig -l)/clang" HIP_PATH="$(hipconfig -R)" cmake -S . -B build \
  -DGGML_RPC=1 \
  -DGGML_HIP=ON \
  -DGGML_NATIVE=1 \
  -DGGML_HIP_RCCL=ON \
  -DCMAKE_C_COMPILER=clang \
  -DCMAKE_BUILD_TYPE=Release \
  -DGGML_CUDA_NO_PEER_COPY=1 \
  -DGGML_HIP_ROCWMMA_FATTN=ON \
  -DCMAKE_CXX_COMPILER=clang++ \
  -DGPU_TARGETS="gfx1200;gfx1201" \
  -DCMAKE_INSTALL_RPATH="\$ORIGIN" \
  -DAMDGPU_TARGETS="gfx1200;gfx1201" \
  -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON

cmake --build build --config Release -j 6 -- VERBOSE=1
```

---

## Modifying Values on the Fly

Tuning values can be adjusted live on the server without rebooting:

```bash
# Example: Adjust 9070 XT power limit to 270W
sudo sed -i 's/POWER_LIMIT_WATT=280/POWER_LIMIT_WATT=270/' /usr/local/bin/tune_rx9070xt.sh
sudo /usr/local/bin/tune_rx9070xt.sh
```

---

## License

MIT License. Developed and adapted from [stew675/r9700-setup](https://github.com/stew675/r9700-setup).
