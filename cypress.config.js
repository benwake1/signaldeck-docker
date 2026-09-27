const { defineConfig } = require('cypress')

// SignalDeck passes the reporter and browser on the command line.
module.exports = defineConfig({
  video: true,
  retries: 0,
  defaultCommandTimeout: 5000,
  e2e: {
    // The test runs inside the SignalDeck container: nginx is on port 80.
    baseUrl: 'http://localhost',
    supportFile: false,
  },
})
