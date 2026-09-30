import QtQuick
import Quickshell
import "." as Omafy

Scope {
  Omafy.Service { id: service }

  Timer {
    interval: 50
    running: true
    repeat: true
    property int attempts: 0
    onTriggered: {
      if (++attempts > 100) {
        console.error("OMAFY_SMOKE_FAILED: auth helper did not complete")
        Qt.quit()
      } else if (service.authChecked) {
        if (service.loggedIn || service.authEnabled || service.tokenBusy || service.cacheKey !== "")
          console.error("OMAFY_SMOKE_FAILED: unexpected authenticated state")
        else
          console.log("OMAFY_SMOKE_PASSED")
        Qt.quit()
      }
    }
  }
}
