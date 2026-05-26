import XCTest

final class KenopsiaWatchScreenshots: XCTestCase {

    func testNowPlayingScreenshot() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo-mode"]
        app.launch()

        // Allow time for the view to render with injected demo state.
        Thread.sleep(forTimeInterval: 3)

        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "01_watch_now_playing"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
