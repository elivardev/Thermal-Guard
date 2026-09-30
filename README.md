# Thermal-Guard

A lightweight, robust Bash script designed to monitor CPU temperature and dynamically adjust maximum frequency limits (preventive throttling) to prevent overheating, featuring built-in hysteresis logic, emergency overrides, and detailed logging.

---

## 🧪 Test Environment & Compatibility
* **Tested Operating System:** Linux Mint Cinnamon V22.3
* **Tested Processor:** Intel Core i5-7200U (7th Generation)
* **Target Architecture:** Primarily targeted at Intel CPUs supporting `cpupower` and standard thermal zones.

---

## ⚠️ Disclaimer
**USE AT YOUR OWN RISK.** This script is provided "as is", without warranty of any kind, express or implied. Modifying CPU frequencies and thermal management behaviors can affect system performance, stability, or hardware behavior. While the script includes multiple safety checks and emergency overrides, I take no responsibility for any hardware damage, data loss, or system instability resulting from its use.

---

## 📋 Prerequisites & Dependencies

This script requires root privileges to interact with kernel-level CPU frequency and thermal controls. Ensure the following tools are installed on your system (e.g., on Debian/Ubuntu/Linux Mint derivatives):

```bash
sudo apt update
sudo apt install linux-tools-common lm-sensors
```

* **`cpupower`**: Used to query and modify CPU frequency states and governors.
* **`lm-sensors`**: Used to accurately read hardware temperature sensors.

---

## 💡 Things to Keep in Mind (Compatibility Notes)

1. **CPU Generation & Architecture:** 
   The script was specifically tuned and tested on an **Intel Core i5-7200U**. If you are using a different CPU generation, brand (e.g., AMD Ryzen), or hybrid architecture (such as Intel's performance/efficient cores on 12th gen and newer), default frequency steps and thermal thresholds may need careful adjustment.
2. **Frequency Matching (P-States):** 
   The frequencies defined in the script (`1.5GHz`, `2.0GHz`, `2.5GHz`, etc.) must be supported by your specific processor architecture. You can check your CPU's available frequency limits by running:
   ```bash
   cpupower frequency-info
   ```
   If you supply a frequency that your CPU does not support, `cpupower` will reject the configuration.
3. **Governors:** 
   The default scaling governor is set to `performance`, but you can change it to match your workflow preferences.

---

## 🚀 Installation & Usage

1. **Clone or download** the script to your local machine:
   ```bash
   git clone https://github.com/elivardev/Thermal-Guard.git
   cd Thermal-Guard
   ```
2. **Make the script executable:**
   ```bash
   chmod +x cpu-throttle.sh
   ```
3. **Run the script manually (requires root):**
   ```bash
   sudo ./cpu-throttle.sh
   ```

---

## ⚙️ Configuration Variables

You can customize the script's behavior by editing the configuration block at the top of `cpu-throttle.sh`:

| Variable | Default | Description |
| :--- | :--- | :--- |
| `MIN_FREQ` | `1.5GHz` | Minimum allowed CPU frequency during throttling or recovery. |
| `MAX_FREQ_NORMAL` | `2.5GHz` | Maximum CPU frequency when temperatures are normal. |
| `MAX_FREQ_REDUCED` | `2.0GHz` | Reduced maximum CPU frequency applied when `TEMP_HIGH` is reached. |
| `GOVERNOR` | `performance` | CPU scaling governor to apply (`performance`, `powersave`, etc.). |
| `TEMP_HIGH` | `80` | Temperature threshold (°C) that triggers reduced frequency mode. |
| `TEMP_LOW` | `70` | Temperature threshold (°C) that restores normal frequency mode (hysteresis). |
| `SLEEP_INTERVAL` | `5` | Polling interval in seconds between temperature checks. |
| `MAX_TEMP_EMERGENCY` | `95` | Critical safety temperature (°C) that forces an immediate emergency `powersave` throttle. |
| `LOG_FILE` | `/var/log/cpu-throttle.log` | Destination path for script activity logs. |

---

## 🔄 Running as a Systemd Service (Background Execution)

To have the script run automatically in the background on system startup, you can set it up as a systemd service.

1. Create a systemd service file:
   ```bash
   sudo nano /etc/systemd/system/cpu-throttle.service
   ```

2. Paste the following configuration (adjust the path to where your script is stored):
   ```ini
   [Unit]
   Description=CPU Temperature Governor and Throttling Service
   After=network.target

   [Service]
   Type=simple
   ExecStart=/usr/local/bin/cpu-throttle.sh
   Restart=on-failure
   RestartSec=5

   [Install]
   WantedBy=multi-user.target
   ```

3. Reload systemd, enable, and start the service:
   ```bash
   sudo systemctl daemon-reload
   sudo systemctl enable cpu-throttle.service
   sudo systemctl start cpu-throttle.service
   ```

4. Check status and logs:
   ```bash
   sudo systemctl status cpu-throttle.service
   tail -f /var/log/cpu-throttle.log
   ```

---

## 📄 License

This project is open-source software licensed under the **GNU General Public License v3.0 (GNU GPLv3)**. See the [LICENSE](LICENSE) file for more details.

---
