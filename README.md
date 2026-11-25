📦 MeshalBox

Install your favorite Windows apps in one place.

MeshalBox is a Windows application that lets you browse an organized catalog of 300+ programs and install many of them at once using WinGet. The interface is available in English and Arabic.

⚡ Quick Start

Open PowerShell and run:

powershell
irm https://raw.githubusercontent.com/iMeshall/MeshalBox/main/install.ps1 | iex

This downloads the latest MeshalBox, then opens it with Administrator rights. Nothing else is installed on your PC, and you always get the newest version.

🔍 Safe to check first: the launcher is a short script — read install.ps1 before you run it. Everything MeshalBox installs comes from WinGet's official sources.

✨ Features
📚 Organized Catalog — 300+ apps in clear categories, with logos and short descriptions.
⚡ Batch Installation — Tick as many apps as you like and install them all in one go.
🔄 Upgrade & Uninstall — Upgrade all your apps, or remove the ones you no longer need.
✅ Installed Detection — See which apps are already on your PC; rescan any time (F5).
🔎 Fast Search — Press Ctrl + K to find any app instantly.
💾 Save & Load Selections — Export your app list to a file and import it on another PC.
🎨 Appearance — Dark and light modes with 8 color palettes (Classic Black, Mono, Dark Frost, Midnight Navy, Cyber Violet, Black & Red, Emerald, Amber). Your choice is remembered.
🌍 Bilingual — Switch between English and Arabic (with full right-to-left layout) at any time.
🧩 Grid or List View — Pick the layout you prefer.
📦 WinGet Integration — Uses the Windows Package Manager for every installation.
📋 Requirements
🪟 Windows 10 or Windows 11.
📦 WinGet (Windows Package Manager) — included with modern Windows; otherwise install App Installer from the Microsoft Store.
🌐 Internet connection.
🖥️ Getting Started
⚡ Option 1: One-line command (recommended)

Run the command from Quick Start in PowerShell. Accept the Windows (UAC) prompt, then browse the catalog and select the programs you want.

💻 Option 2: Run from Source
Download the repository (Code → Download ZIP) and extract it.
Keep MeshalBox.ps1 and applications.json in the same folder.
Right-click MeshalBox.ps1 → Run with PowerShell, or run:
powershell
powershell -ExecutionPolicy Bypass -File .\MeshalBox.ps1
📁 Project Structure
MeshalBox/
├── install.ps1          # one-line launcher
├── MeshalBox.ps1        # the application
├── applications.json    # the app catalog
├── README.md
├── README-ar.md
└── LICENSE
➕ Adding or Fixing an App

Edit applications.json — each app has its WinGet id, English and Arabic names, a category, a domain (used to fetch its logo) and a short description.

📄 License

Released under the MIT License.
