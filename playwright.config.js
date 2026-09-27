const { defineConfig, devices } = require('@playwright/test')

// Keep @playwright/test at the Dockerfile's PLAYWRIGHT_DEPS_VERSION, so the
// browsers match the system libraries in the image.
module.exports = defineConfig({
  testDir: './playwright',
  retries: 0,
  use: {
    // The test runs inside the SignalDeck container: nginx is on port 80.
    baseURL: 'http://localhost',
    screenshot: 'only-on-failure',
    video: 'on',
  },
  projects: [
    { name: 'chromium', use: { ...devices['Desktop Chrome'] } },
    { name: 'firefox', use: { ...devices['Desktop Firefox'] } },
    { name: 'webkit', use: { ...devices['Desktop Safari'] } },
  ],
})
