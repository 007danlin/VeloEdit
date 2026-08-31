# VeloEdit analysis benchmark — MacBook Air M4 32 GB

Measured on 2026-08-22 with a real GoPro `GX010493.MP4` source. The source is HEVC (`hvc1`), 5312×2988, 59.94 fps, 22.87 seconds, 164 MiB. Each mode used a separate project with a cold analysis cache. Values are from the instrumented local debug CLI and are measurements, not projections.

| Mode | Wall time | Source / wall | Decoded | Frame-cache hits | Vision | VLM | Peak process RSS | Thermal | Runtime status |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | --- |
| Fast | 0.47 s | 49.08× | 4 | 2 | 4 | 0 | 0.06 GB | fair | valid local Fast |
| Balanced | 9.26 s | 2.47× | 8 | 4 | 8 | 0 | 0.08 GB | nominal | local fallback, 4B VLM unavailable |
| Quality | 9.35 s | 2.45× | 22 | 6 | 22 | 0 | 0.09 GB | nominal | local fallback, 8B VLM unavailable |
| Maximum | 14.92 s | 1.53× | 54 | 10 | 54 | 0 | 0.14 GB | nominal | local fallback, 30B VLM unavailable |

Fast deliberately performs no VLM call so a cold model cannot violate its faster-than-realtime contract. Balanced, Quality, and Maximum attempted their configured local model lifecycle; because those models were not installed, the measured runs completed through Apple Vision/local scoring. Peak RSS covers the VeloEdit process; an external Ollama process would need separate accounting when a VLM is available.
