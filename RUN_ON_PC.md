# Run the Terrastep server on your own PC (for phone testing)

The phone app needs the Terrastep server running somewhere it can reach.
The simplest test setup: run the server on your Windows PC, with your phone
on the same Wi-Fi.

## Steps

1. Download this repository: GitHub → **Code** → **Download ZIP**, then
   extract the ZIP anywhere (e.g. Desktop).
2. Make sure Python 3 is installed (`python.org` — tick
   *"Add python.exe to PATH"* during setup).
3. Double-click **`run-terrastep-server.bat`** in the extracted folder.
   - It installs the one library the server needs (`h3`) the first time.
   - If Windows Firewall pops up, click **Allow**.
   - It prints this PC's address, like `http://192.168.1.42:8791`.
4. Keep that window **open** while testing — closing it stops the server.
5. The APK must be built with that exact address baked in
   (CI → *Terrastep CI* → *Run workflow* → `api_base` = the address above).
6. On the phone: same Wi-Fi as the PC, install the APK, sign up, walk.

## Notes

- If your PC's Wi-Fi address changes (router restart, new network), the app
  stops reaching the server — re-run the .bat, check the address, and rebuild
  the APK with the new one.
- The server stores its data in `server/terrastep.db` next to the code.
  Delete that file to start completely fresh.
- For a permanent pilot, deploy the same code to a host instead
  (`render.yaml` in this repo gives a one-click Render deploy).
