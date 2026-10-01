from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import threading
import unittest


REPO = Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which("quickshell"), "Quickshell is needed for Qt rendering checks")
class TextRenderingTests(unittest.TestCase):
    def test_notices_and_errors_display_markup_literally_without_fetching_images(self):
        requests = []

        class ImageServer(BaseHTTPRequestHandler):
            def do_GET(self):
                requests.append(self.path)
                self.send_response(204)
                self.end_headers()

            def log_message(self, *args):
                pass

        server = ThreadingHTTPServer(("127.0.0.1", 0), ImageServer)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        payload = f'<b>Publisher title</b><img src="http://127.0.0.1:{server.server_port}/unexpected-image">'
        fields = ("notice", "lastError", "searchError", "playlistsError", "openListError", "queueError")
        expected = {field: ("Added to queue: " if field == "notice" else "") + payload for field in fields}
        service = {**expected, "searchLoading": False, "openListLoading": False,
                   "queueLoading": False, "queueRows": []}

        # Render the actual production Text objects in isolation. Only their
        # surrounding layout, palette, and service data are supplied by the test.
        # No real credentials, Spotify calls, or desktop session are involved.
        source = (REPO / "BarWidget.qml").read_text()
        blocks = re.findall(r"(?m)^(\s*)Text \{\n(.*?)^\1\}", source, flags=re.S)
        displays = []
        for field in fields:
            matches = [body for _, body in blocks if f"root.service.{field}" in body]
            self.assertEqual(len(matches), 1, f"Expected one production display for {field}")
            displays.append(f'Text {{\nobjectName: "{field}"\n' + matches[0] + "\n}")

        with tempfile.TemporaryDirectory(prefix="omafy-text-test-") as directory:
            stage = Path(directory)
            runtime = stage / "runtime"
            runtime.mkdir(mode=0o700)
            (stage / "qmldir").write_text("singleton Style 1.0 Style.qml\nsingleton Color 1.0 Color.qml\n")
            (stage / "Style.qml").write_text('pragma Singleton\nimport QtQuick\nQtObject { readonly property var font: ({ caption: 12 }) }\n')
            (stage / "Color.qml").write_text('pragma Singleton\nimport QtQuick\nQtObject { readonly property color urgent: "red" }\n')
            qml = '''import QtQuick
import Quickshell
import "."

FloatingWindow {
  id: root
  visible: true
  width: 600
  height: 600
  property bool loggedIn: true
  property string fontFamily: "Sans"
  property color spotifyGreen: "green"
  property color muted: "gray"
  property var service: SERVICE_DATA
  property var expected: EXPECTED_DATA
  Column {
    id: displays
    width: parent.width
    spacing: 4
    PRODUCTION_DISPLAYS
  }
  Timer {
    interval: 500
    running: true
    onTriggered: {
      var failures = []
      for (var i = 0; i < displays.children.length; i++) {
        var item = displays.children[i]
        if (item.textFormat !== Text.PlainText || item.text !== root.expected[item.objectName])
          failures.push(item.objectName)
      }
      if (failures.length) console.error("OMAFY_TEXT_FAILED: " + failures.join(", "))
      else console.log("OMAFY_TEXT_PASSED")
      Qt.quit()
    }
  }
}
'''
            qml = qml.replace("SERVICE_DATA", json.dumps(service)).replace("EXPECTED_DATA", json.dumps(expected))
            qml = qml.replace("PRODUCTION_DISPLAYS", "\n".join(displays))
            (stage / "shell.qml").write_text(qml)
            env = {**os.environ, "QT_QPA_PLATFORM": "offscreen", "QT_QPA_PLATFORMTHEME": "",
                   "WAYLAND_DISPLAY": "", "DISPLAY": "", "XDG_RUNTIME_DIR": str(runtime),
                   "XDG_CONFIG_HOME": str(stage / "config"), "XDG_STATE_HOME": str(stage / "state"),
                   "XDG_CACHE_HOME": str(stage / "cache"), "NO_PROXY": "127.0.0.1,localhost"}
            result = subprocess.run(["quickshell", "--no-color", "-p", str(stage)], env=env,
                                    capture_output=True, text=True, timeout=10)
            output = result.stdout + result.stderr
            self.assertEqual(result.returncode, 0, output)
            self.assertEqual(requests, [], "Text markup caused an image request")
            self.assertIn("OMAFY_TEXT_PASSED", output)
            self.assertNotRegex(output, "OMAFY_TEXT_FAILED|ReferenceError|TypeError|Failed to load")


if __name__ == "__main__":
    unittest.main()
