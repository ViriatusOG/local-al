# AMD GPU tuning — setup notes for `al` (192.168.0.199)

Hardware: 2× Navi 48 GPUs, Ryzen 7 5800X (8c/16t), Ubuntu 24.04, ROCm 7.2.4.
- **card0** `09:00.0` = `0x1002:0x7551` = **Radeon AI PRO R9700** (32GB, 300W TBP)
- **card1** `0c:00.0` = `0x1002:0x7550` = **Radeon RX 9070 XT** (16GB, 304W SKU)

Repo: https://github.com/stew675/r9700-setup (adapted — see below).

## Tuning profiles
| Card | Undervolt | Power cap | Script / service |
|---|---|---|---|
| R9700 | −50 mV | 265 W | `tune_r9700.sh` / `amd-gpu-tune.service` |
| RX 9070 XT | −50 mV | 265 W | `tune_rx9070xt.sh` / `amd-rx9070xt-tune.service` |

IRQ pinning (`pin_gpu_irqs.sh` / `gpu-irq-pin.service`) applies to **both** cards:
each GPU's IRQ → a dedicated physical core (currently IRQ 109 → CPU 7, IRQ 110 → CPU 6;
IRQ numbers can change between boots, the service re-pins them at each boot). To prevent
interference, both physical cores including their SMT siblings (CPUs 6, 7, 14, 15) are
completely banned from irqbalance.

## Adaptations made vs. the original repo
- GPU discovery matches PCI IDs from `/sys/bus/pci/devices/*/vendor`+`device`
  (this box's `lspci`/pci.ids doesn't know the "R9700" name, so the repo's
  `grep -i R9700` finds nothing).
- R9700 tuning targets `0x7551` only; the 9070 XT gets its own script/profile,
  because the repo's −85mV/265W values are calibrated for the R9700.
- `tune_r9700.sh` / `tune_rx9070xt.sh` no longer hard-fail before a reboot: if
  `pp_od_clk_voltage` is missing (kernel flags not active yet) they log a skip
  and still apply the power cap. Includes a 10s wait for DRM initialization at boot.
- IRQ pinning picks dedicated *physical* cores (5800X = 8 physical cores /
  16 threads), pins the primary thread per core, and bans all SMT thread siblings
  from irqbalance.
- Kernel cmdline uses `iommu=pt` instead of `iommu=off` (ROCm 7.x on AMD CPUs
  requires IOMMU passthrough to maintain KFD memory management and container compatibility).
- GRUB installer backs up `/etc/default/grub` and safely appends flags without clobbering
  existing parameters.
- irqbalance drop-in sets environment overrides (`IRQBALANCE_ARGS` and `IRQBALANCE_BANNED_CPUS`)
  preserving Ubuntu's `--foreground` flag.

## Install (run on the server, once, as root)
```bash
sudo bash /home/hugo/projects/hugo/r9700-setup/apply-tuning.sh
```
Installs all scripts + services, backs up `/etc/default/grub`, adds the kernel flags
(`iommu=pt processor.max_cstate=2 pcie_aspm=off amdgpu.ppfeaturemask=0xffffffff`),
runs `update-grub`, then applies power caps immediately (works without a reboot).
The live llama-server keeps running.

## Benchmarking (llama-taco, run from its UI)
Model: Qwen3.8-27B IQ3_S + MTP (same on both cards). Full data in
`~/llama-taco/benchmarks.json`.

**R9700 (gpu0-only preset, 262k ctx)**
| | Stock (300W) | 265W/−85mV | 280W/−85mV | 280W/−50mV | 265W/−50mV (final) |
|---|---|---|---|---|---|
| Gen tps short | 62.7 | 62.3–63.0 | 63.2 | 63.1 | 62.1 |
| Gen tps long | 56.1 | 52.7–53.1 | 53.3 | 56.2 | 55.6 |
| Prompt tps short | 536.3 | 545.1 | 544.3 | 544.3 | 541.7 |
| Avg power | 289.9 W | 252.5–256.9 W | 271.3 W | 268.1 W | 254.7 W (−12%) |
| Peak temp | 91 °C | 82–90 °C | 92 °C | 88 °C | 84 °C (−7°C) |
| Tokens/Joule | 0.216 | 0.243–0.249 | 0.233 | 0.235 | 0.244 (+13%) |

Findings: the repo's −85mV cost ~5% on long-context gen (not the cap — 265→280W
changed nothing; it was the UV). −50mV at 265W gives full stock speed with −12%
power and −7°C.

**RX 9070 XT (gpu1-only preset)**
| | Stock (304W) | 250W/−50mV | 280W/−50mV | 280W/−65mV (final) |
|---|---|---|---|---|
| Gen tps short | 61.8 | 57.9 | 59.7 | 59.7 |
| Prompt tps short | 533.0 | 492.3 | 499.3 | 498.4 |
| Avg power | 293.1 W | 238.8 W | 257.7 W | 261.6 W |
| Peak temp | 84 °C | 78 °C | 78 °C | 78 °C |
| Tokens/Joule | 0.211 | 0.242 | 0.232 | 0.228 |

Findings: 250W was too aggressive (−6…−9%); 280W recovered to ~3–6% under stock.
Deeper UV at 280W (−50 → −65mV) bought no speed (not voltage-limited) — kept for
extra voltage headroom.

## After a reboot, verify
```bash
cat /proc/cmdline                      # flags present?
sudo bash /usr/local/bin/tune_r9700.sh # re-apply + print UV/power verification
sudo bash /usr/local/bin/tune_rx9070xt.sh
grep -A1 OD_VDDGFX_OFFSET /sys/class/drm/card0/device/pp_od_clk_voltage
cat /proc/irq/93/smp_affinity_list /proc/irq/94/smp_affinity_list   # expect 7 and 6
systemctl status amd-gpu-tune.service amd-rx9070xt-tune.service gpu-irq-pin.service
```

## Tuning further
To change values, edit `/usr/local/bin/tune_*.sh` AND this folder's copy, then
re-run the script (takes effect immediately, no reboot) and re-benchmark:
```bash
sudo sed -i 's/POWER_LIMIT_WATT=280/POWER_LIMIT_WATT=270/' /usr/local/bin/tune_rx9070xt.sh
sudo /usr/local/bin/tune_rx9070xt.sh
```
- R9700: raising the cap toward 280W should recover most of the ~5% long-context
  gen dip, still below stock.
- 9070 XT: the remaining ~4% vs stock is the power cap; raising it toward 300W
  closes the gap but gives back the power savings.
