# sparkDash

Noctalia bar widget for live readings from one machine in sparkDash.

Settings → Plugins → sparkDash:

| Setting | What to put |
| --- | --- |
| sparkDash URL | `http://<host>:5555` or the page you already open, such as `http://<host>:5555/cost` |
| Access token | The `SPARKDASH_TOKEN` configured on the sparkDash host. The same value the dashboard asks for. Leave empty only if that server does not require a token. |
| Machine | Name, id, or LAN IP of the machine to show. Change this to any machine the dashboard knows. |
| Queue source | LLM requests, ComfyUI jobs, or both. Running is in-flight work. Queued is waiting work. |
| Queue | Running/queued, for example `2/1`. On by default. |
| Tokens per second | Decode rate, for example `128 tok/s`. On by default. |
| Prefill rate | Prefill rate, for example `900 pf/s`. Off by default. |
| GPU temperature | Pill meter and `74°`. On by default. |
| CPU temperature | Pill meter and `48°`. Off by default. |
| GPU usage | Pill meter and `96%`. Off by default. |
| GPU power | For example `33W`. Off by default. |
| VRAM | Pill meter and `84%`. Off by default. |
| Memory | Unified memory, or system RAM. Pill meter and `91%`. Off by default. |
| Refresh interval | Seconds between polls. Default is 5. |

Turn on any combination. The bar shows the machine's name, then the enabled readings in order, for example `spark1  1/0  128 tok/s  🌡▌ 74°`. On a vertical bar the names are left out. Temperature, usage, VRAM, and memory each get an icon and a vertical pill gauge, like the shell's system monitor, filled on a 0–100 scale (°C or %). Pills use the sparkDash overview alert levels, in sparkDash's orange (warning) and red (danger):

| Reading | Warning | Danger |
| --- | --- | --- |
| GPU / CPU temperature | ≥ 75° | > 80° |
| VRAM, unified memory | ≥ 85% | ≥ 90% |
| GPU usage | throttling, or GPU ≥ 80° | — |

System RAM never alerts, as in sparkDash. The bolt is highlighted while the machine has running or queued work. `off` means that machine is offline. `!` means the dashboard could not be read. Click the widget to open the panel. For the selected machine (and each of its workers) it shows:

- status, role, uptime, and hardware (device, GPU, CPU, cores, memory)
- health findings from sparkDash, and a warning when the GPU throttles
- meters for GPU/CPU temperature, GPU usage, GPU power against its limit, VRAM, memory (used/total), and the root disk, colored by the alert levels above
- graphs of recent history: throughput (decode and prefill tok/s), temperature (GPU and CPU), GPU load (usage and power), and memory (memory and VRAM). The service keeps the last 90 polls per machine, so the window is 90 × the refresh interval. It starts empty when the shell or plugin restarts.
- one card per LLM engine (model, backend, slots, running/queued, decode, per-stream and prefill rates, context, KV cache, prefix-cache hit rate, TTFT, ITL and E2E p95, token totals) and ComfyUI's queue

Below that is every machine sparkDash knows. Click a row to copy that machine's name, then paste it into **Machine**. **Open sparkDash** opens that machine in the browser. The panel shows every reading, whatever the bar settings are.

A machine with role head also shows each worker that points at it (`workerHeadId`, or the only head when a worker has none). The bar adds each worker after the head, behind a divider and its name, for example `… 59° │ spark2 🌡▌ 63°`. The panel lists those workers under **Workers**. A worker is labeled with the head it belongs to.

The plugin reads `GET /api/sparks` for the machine list, then `GET /api/sparks/{id}/metrics` for online state and the readings. Requests send `Authorization: Bearer <token>`.

Add the **queue** widget from the Add-widget picker, or set a bar entry to `fragosoSH/sparkdash:queue`.

## Install

Clone the repo and point a Noctalia path source at the clone. The plugin is in its `sparkdash/` folder:

```
git clone https://github.com/fragosoSH/sparkdash-plugin.git
noctalia msg plugins source add sparkdash path "$PWD/sparkdash-plugin"
noctalia msg plugins enable fragosoSH/sparkdash
```

To update, run `git pull` in the clone.
