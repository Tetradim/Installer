# Sentinel Suite installer

Double-click **Install-Sentinel-Suite.cmd** on a 64-bit Windows 10 or 11 PC. The setup downloads and installs Node.js, Python, MongoDB, the Visual C++ runtime if needed, and the ten pinned Sentinel repositories. It creates each Python and Node environment, builds the Core and Archive dashboards, and puts **Sentinel Suite** on the desktop. Open that shortcut to choose a desktop bot or stop running bots. **Suite dashboard** starts MongoDB, Pulse, Edge, and Core together.

The first installation needs internet access and can take considerable time. If Windows asks for administrator approval to install the Visual C++ runtime, approve that prompt. The other runtimes are installed privately under `%LOCALAPPDATA%\Tetradim\SentinelSuite`. Setup is resumable: double-click the installer again after a network or package failure. A repair copy of the installer is saved in the installation folder. Logs are in `%LOCALAPPDATA%\Tetradim\SentinelSuite\logs\install.log` and individual launcher logs are on the desktop.

## What setup can and cannot automate

The Windows desktop bots are Pulse, Edge, Echo, Flare, Chain, Archive, and Core. The installer also downloads Sentinel Link, Nexus, and Iron and installs their local dependencies. Link's Chrome extensions still need installation and permission in Chrome. Nexus is an Android app and needs deployment to a phone. Iron is a broker-facing command-line core and needs broker software and account configuration. The installer does not enable live trading, connect a broker, create Discord credentials, or supply market-data subscriptions. Those are account-specific steps in the respective projects.

MongoDB is started as a private, loopback-only process when a bot needs it. Its database lives under `%LOCALAPPDATA%\Tetradim\SentinelSuite\data\mongodb`; setup and repair leave that data and existing `.env` files in place. The installer uses pinned source commits listed in `suite-manifest.json`, so a later branch update does not silently change customer installations. Review and update those commits when releasing a new installer version.

## Maintainer checks

The read-only install plan can be displayed with:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-Sentinel-Suite.ps1 -PlanOnly
```

Run the contract tests on Windows with:

```powershell
python -m unittest discover -s tests -v
```

The tests and plan mode do not download or install software. A full installation still needs to be tested on a clean Windows 10 or 11 x64 machine before distributing this to customers.
