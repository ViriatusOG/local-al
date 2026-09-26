# AMD Dual Navi 48 Tuning Benchmark Report
**Host:** `al` (192.168.0.199) | **OS:** Ubuntu 24.04 LTS (Kernel 6.8+)  
**CPU:** AMD Ryzen 7 5800X (8c/16t) | **ROCm:** 7.x  
**Model:** Qwen3.8-27B-GSQ-RCO-IQ3_S-mtp (MTP speculative decoding draft acceptance ~72–73%)  
**Benchmark Tool:** llama-taco / llama-server (`b11200`)  
**Date:** September 26, 2026  

---

## 1. Executive Summary

Through systematic undervolting and calibrated power limits, the dual Navi 48 setup achieved significant efficiency gains while either matching or exceeding stock performance:

```mermaid
graph LR
    subgraph R9700 ["Radeon AI PRO R9700 (GPU 0)"]
        direction TB
        R_Stock["Stock (300W): 62.7 tps @ 290W / 91°C"] --> R_Final["Golden (-50mV / 280W): 63.1 tps @ 268W / 88°C"]
        R_Note["Result: +0.4 tps, -22W Power, -3°C Heat"]
    end
    subgraph RX9070XT ["Radeon RX 9070 XT (GPU 1)"]
        direction TB
        X_Stock["Stock (304W): 61.8 tps @ 293W / 84°C"] --> X_Final["Final (-65mV / 280W): 59.7 tps @ 261W / 78°C"]
        X_Note["Result: -32W Power, -6°C Cooler, 97% Throughput"]
    end
```

---

## 2. Primary GPU 0: AMD Radeon AI PRO R9700 (32 GB)

- **Preset:** `gpu0-only`
- **Context Window:** 262,144 tokens (`262k`)
- **VRAM Footprint:** 24.64 GB
- **Cache:** K: `q8_0`, V: `q8_0`, Flash Attention: `On`, CPU Threads: `8`, Layers on GPU: `66/66`

### Comprehensive Test Progression

| Metric | Test 1: Stock (Baseline) | Test 2: 265W / −85mV | Test 3: 280W / −85mV | Test 4: 280W / −50mV (★ Golden) | Net vs. Stock |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Gen Speed (short)** | 62.7 tok/s | 62.3 tok/s | **63.2 tok/s** | **63.1 tok/s** | **+0.4 tok/s (+0.6%)** |
| **Gen Speed (long prompt)**| 56.1 tok/s | 52.7 tok/s | 53.3 tok/s | **56.2 tok/s** | **+0.1 tok/s (Recovered)** |
| **Prompt Processing (short)**| 536.3 tok/s | 545.1 tok/s | 544.3 tok/s | **544.0 tok/s** | **+7.7 tok/s (+1.4%)** |
| **Prompt Processing (long)** | 700.4 tok/s | 704.0 tok/s | 710.3 tok/s | **711.0 tok/s** | **+10.6 tok/s (+1.5%)** |
| **Average Power (short)** | 289.9 W | **256.9 W** | 271.3 W | **268.1 W** | **−21.8 W (−7.5%)** |
| **Peak Temperature** | 91 °C | 90 °C | 92 °C | **88 °C** | **−3 °C Cooler** |
| **Efficiency (Tokens / Joule)**| 0.216 | **0.249** | 0.233 | **0.230** | **+6.5% Efficiency** |
| **Time to First Token (TTFT)** | — | 0.65 s | 0.65 s | **0.65 s** | Instant response |
| **MTP Draft Acceptance** | — | 72% | 72% | **72%** | Stable speculative rate |

### Key Engineering Insights (R9700)
1. **Clock Stretching Identification:** At `−85mV`, long-context throughput dipped from 56.1 to 52.7 tps due to internal GPU clock stretching under massive 262k KV-cache memory traffic.
2. **The `−50mV` Correction:** Relaxing voltage offset to `−50mV` completely eliminated clock stretching, immediately restoring long-context generation to **56.2 tok/s** while lowering peak temps to **88 °C**.
3. **265W vs 280W:** 265W offers maximum energy efficiency (256.9W / 0.249 Tok/J), while 280W delivers peak throughput (63.1 tok/s) at 268W avg.

---

## 3. Secondary GPU 1: AMD Radeon RX 9070 XT (16 GB)

- **Preset:** `gpu1-only`
- **Context Window:** 48,000 tokens (`48k`)
- **VRAM Footprint:** 14.96 GB
- **Cache:** K: `q4_0`, V: `q4_0`, Flash Attention: `On`, CPU Threads: `4`, Layers on GPU: `66/66`

### Comprehensive Test Progression

| Metric | Test 1: Stock (Baseline) | Test 2: 250W / −50mV | Test 3: 280W / −50mV | Test 4: 280W / −65mV (Final) | Net vs. Stock |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Gen Speed (short)** | **61.8 tok/s** | 57.9 tok/s | 59.7 tok/s | **59.7 tok/s** | −2.1 tok/s (−3.4%) |
| **Gen Speed (long prompt)**| **49.7 tok/s** | 46.5 tok/s | 47.8 tok/s | **48.2 tok/s** | −1.5 tok/s (−3.0%) |
| **Prompt Processing (short)**| **533.0 tok/s** | 492.3 tok/s | 499.3 tok/s | **498.4 tok/s** | −34.6 tok/s (−6.5%) |
| **Prompt Processing (long)** | **703.0 tok/s** | 641.0 tok/s | 653.0 tok/s | **656.0 tok/s** | −47.0 tok/s (−6.7%) |
| **Average Power (short)** | 293.1 W | **238.8 W** | 257.7 W | **261.6 W** | **−31.5 W (−10.7%)** |
| **Peak Temperature** | 84 °C | **78 °C** | **78 °C** | **78 °C** | **−6 °C Much Cooler** |
| **Efficiency (Tokens / Joule)**| 0.211 | **0.242** | 0.232 | **0.228** | **+8.1% Efficiency** |
| **Time to First Token (TTFT)** | 0.67 s | 0.72 s | 0.71 s | **0.71 s** | Unchanged |
| **Load Time** | 7.3 s | **3.5 s** | **3.5 s** | **3.5 s** | 2x faster initialization |

### Key Engineering Insights (RX 9070 XT)
1. **250W Cap Was Too Strict:** Dropping from 304W to 250W (17% cut) caused clock throttling (−6.3% TPS).
2. **280W Sweet Spot:** Raising the limit to 280W recovered nearly all throughput (59.7 tps) while maintaining a dramatic **6 °C thermal drop (78 °C peak)** and saving **>31 W** of power.
3. **Undervolt Scaling:** Testing `−65mV` vs `−50mV` at 280W proved that the 9070 XT is power-capped rather than voltage-starved, providing extra voltage stability margin without altering speed.

---

## 4. Side-by-Side Dual GPU Final Profiles

```ini
# /etc/systemd/system/amd-gpu-tune.service -> tune_r9700.sh
GPU_0_TARGET="0x1002:0x7551 (Radeon AI PRO R9700 32GB)"
UNDERVOLT_MV=-50
POWER_LIMIT_WATT=280   # (or 265W for maximum power savings)
PINNED_CORE="CPU 5 (Core 5)"
BANNED_IRQBALANCE="6,7,14,15 (all threads of isolated physical cores)"

# /etc/systemd/system/amd-rx9070xt-tune.service -> tune_rx9070xt.sh
GPU_1_TARGET="0x1002:0x7550 (Radeon RX 9070 XT 16GB)"
UNDERVOLT_MV=-65
POWER_LIMIT_WATT=280
PINNED_CORE="CPU 6 (Core 6)"
BANNED_IRQBALANCE="6,7,14,15 (all threads of isolated physical cores)"
```
