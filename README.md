# 📦 MeshalBox

**Install your favorite Windows apps in one place.**

MeshalBox is a Windows application that lets you browse an organized application catalog and install multiple programs at once using WinGet.

## ✨ Features

- 📚 **Organized Catalog** — Browse applications by category.
- ⚡ **Batch Installation** — Install multiple applications in one go.
- 🪟 **Windows Support** — Designed for Windows 10 and Windows 11.
- 🛠️ **PowerShell-Based** — Built with PowerShell.
- 📦 **WinGet Integration** — Uses the Windows Package Manager to install applications.
- 🚀 **Portable Executable** — Run the ready-to-use `.exe` without a traditional installation.

## 📋 Requirements

- 🪟 Windows 10 or Windows 11.
- 📦 WinGet (Windows Package Manager).

## 🚀 Downloads

- 📦 **[Download Latest Release](https://github.com/iMeshall/MeshalBox/releases/latest)** — Get the ready-to-run Windows executable.
- 💻 **[Source Code](https://github.com/iMeshall/MeshalBox)** — Browse or download the source files.

## 🖥️ Getting Started

### 📦 Option 1: Executable

1. Download `MeshalBox.exe` from the [latest release](https://github.com/iMeshall/MeshalBox/releases/latest).
2. Run the executable.
3. Browse the application catalog and select the programs you want to install.

### 💻 Option 2: Run from Source

Make sure both files are in the same directory:

- `MeshalBox.ps1`
- `applications.json`

Then:

1. Open PowerShell in that directory.
2. Run the script:

   ```powershell
   .\MeshalBox.ps1
   ```

3. Browse the catalog and select the applications you need.

## 📁 Project Structure

```text
MeshalBox/
├── MeshalBox.ps1
├── applications.json
├── README.md
├── README-ar.md
└── LICENSE
```

## 📄 License

Released under the [MIT License](LICENSE).
