# Build and deploy the iPad app from Windows using your Mac

[简体中文](windows-ipad.zh-CN.md)

The main workflow runs from Windows through the project's `ios/build.py` entry point. Windows validates your local game folder and handles installation/import on the selected iPad. Your Mac runs Xcode, compiles the app, and signs it. Windows does not compile the iOS app.

## Before you start

- Use an unmodified, legally obtained USA Rev. 2 / v81 game folder that you have already decrypted and extracted. The workflow does not decrypt discs or accept WUD/WUX/WUA archives.
- Install Python 3 and Microsoft's OpenSSH Client on Windows. The normal `ssh` and `scp` programs must be available in `PATH`.
- Install iTunes for Windows and make sure Apple Mobile Device Service is available/running. Connect the iPad to Windows and complete pairing and trust prompts yourself before running the workflow; the tools do not pair or trust devices automatically.
- Enable Remote Login on your Mac. Install/select Xcode with the iPhoneOS SDK, Python 3, and CMake 4.1 or newer. The Mac must be able to fetch the public GitHub repository, and its Xcode signing setup must be ready for your Team ID and Bundle ID.
- Configure an SSH host alias in your normal Windows SSH configuration, or use a hostname/IP directly. Before running the workflow, connect manually and verify the Mac's host key using a trusted fingerprint. The helper requires the key to already be in `known_hosts` and uses key/agent authentication in batch mode.
- Keep the game folder, final IPA, and any retained transfer archive private. Build output under the ignored `build/` directory is permitted; do not commit or publish game-derived files.
- Leave enough free disk space for an uncompressed ZIP64 game archive on Windows and the transferred game plus generated C/Xcode build output on the Mac.

The public commit selected by the Windows checkout must have an `ios/build.py` supporting both `--ipa-output` and `--build-number`. The Mac checks those options before the game archive is created or sent. If the selected public commit lacks either option, the workflow stops before transferring game data. Uncommitted local source changes are not sent to the Mac.

## Main workflow: build, install, and import

Create the project device environment once from PowerShell in the checkout:

```powershell
python -m venv .local-tools/device-venv
.\.local-tools\device-venv\Scripts\python.exe -m pip install -r ios/device-requirements.txt
```

Run the main flow with that same environment's Python:

```powershell
.\.local-tools\device-venv\Scripts\python.exe .\ios\build.py `
  --deploy `
  --remote-mac build-mac `
  --device-id YOUR_IPAD_DEVICE_ID `
  --game "D:\Games\TPHD-USA-Rev2-v81" `
  --team YOURTEAMID `
  --bundle-id com.example.tphd `
  --build-number 202611221234
```

Replace the host alias, exact iPad device identifier, game path, Team ID, and registered Bundle ID with your own values. `--build-number` is optional and digits only. `--deploy` uses the selected public commit to build/sign on the Mac, then Windows verifies the IPA, installs it on the selected iPad, imports the same game folder, and launches the app. The IPA output defaults to the ignored `build/` folder; `--ipa-output` can select another allowed private path.

The full flow is:

1. Windows validates the supplied game folder and targets only the `--device-id` you selected.
2. The remote helper checks the public commit, Mac toolchain, and staging space before sending game data. It transfers a private ZIP64 archive and the Mac checks its paths, hashes, and game version.
3. The Mac builds/signs the app with Xcode and returns an IPA plus size and SHA-256 receipt. It verifies the signed app at `build/ios-game/<configuration>-iphoneos/wwhd.app` and validates the packaged `Payload/*.app`.
4. Windows verifies the IPA and receipt, then handles installation and game import to the iPad.

SSH and SCP use `BatchMode=yes`, `StrictHostKeyChecking=yes`, and a 15-second connection timeout. Unknown host keys or unavailable key authentication fail promptly; verify/configure SSH locally and retry. The helper never accepts host keys or changes SSH trust settings, and does not collect passwords, private keys, Apple credentials, certificates, or provisioning secrets. Team ID and Bundle ID are identifiers passed to the Mac build. The connection timeout does not limit build duration.

## Advanced: build and download an IPA only

For a build without installation/import, call the helper directly:

```powershell
.\.local-tools\device-venv\Scripts\python.exe .\ios\remote_build.py `
  --host build-mac `
  --game "D:\Games\TPHD-USA-Rev2-v81" `
  --source-revision PUBLIC_40_CHARACTER_COMMIT `
  --team YOURTEAMID `
  --bundle-id com.example.tphd `
  --output "D:\PrivateBuilds\TPHD.ipa"
```

Replace the example values with your own. `--build-number` is optional; if omitted, the Mac uses its current Unix timestamp. `--cmake` can name a CMake executable or Mac path if CMake is not available as `cmake` on the Mac's `PATH`. This helper only builds and downloads the IPA; it does not install the IPA or import the game folder.

The final IPA is published without replacing an existing file. The output volume must support hard links; if it does not, the verified download is retained as a partial file and the helper stops.

If an operation fails, the helper retains its local transfer archive and its uniquely named `/tmp/tphd-remote-<id>` Mac stage for diagnosis. It deletes only that stage after a verified IPA download. Remove retained game data yourself after you have finished inspecting a failed run.
