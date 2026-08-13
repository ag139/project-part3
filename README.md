# Infrastructure Provisioning Simulator

## Project Overview and Objectives
This project is a Python-based tool designed to simulate infrastructure provisioning. It allows users to dynamically define virtual machines, validates the input using `pydantic`, and stores the configurations in a JSON file. After configuring the machines, it automates the installation of a basic service (Nginx) using a Bash script, demonstrating integration between Python and shell scripting.

The main objectives are:
- Accept and validate user input for machine configurations.
- Store configurations persistently in `configs/instances.json`.
- Use object-oriented design with a `Machine` class.
- Automate service installation using a Bash script executed via Python's `subprocess` module.
- Implement robust logging and error handling.

## Setup and Execution Instructions

### Prerequisites
- Python 3.7+
- `pydantic` library
- Bash environment (Linux/macOS or WSL on Windows)

### Installation
1. Clone the repository to your local machine.
2. Install the required Python dependencies:
   ```bash
   pip install pydantic
   ```
3. Ensure the bash script is executable:
   ```bash
   chmod +x scripts/install_nginx.sh
   ```

### Execution
Run the main Python script from the root directory:
```bash
python src/infra_simulator.py
```

Follow the on-screen prompts to configure your virtual machines. Enter `done` when you are finished adding machines.

## Example Expected Output

**Console Output:**
```
Please enter the machine name (or 'done' to finish): web-server-01
Please enter the os (linux/windows): linux
Please enter the cpu: 4
Please enter the ram: 8
Machine created successfully.
Please enter the machine name (or 'done' to finish): done
```

**Log Output (`logs/provisioning.log`):**
```
2026-03-14 14:00:00,000 - INFO - Provisioning process started.
2026-03-14 14:00:00,001 - INFO - User input process started
2026-03-14 14:00:10,000 - INFO - Machine created: web-server-01
2026-03-14 14:00:10,001 - INFO - Logging machine: web-server-01, OS: linux, CPU: 4, RAM: 8
2026-03-14 14:00:10,002 - INFO - Machine web-server-01 created successfully.
2026-03-14 14:00:15,000 - INFO - User input process completed.
2026-03-14 14:00:15,001 - INFO - Instances saved to instances.json.
2026-03-14 14:00:15,002 - INFO - Starting service installation script.
2026-03-14 14:00:16,000 - INFO - Script output: 
...
2026-03-14 14:00:16,001 - INFO - Service installation completed successfully.
2026-03-14 14:00:16,002 - INFO - Provisioning process completed successfully.
```
