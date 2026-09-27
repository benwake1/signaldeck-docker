# ci-fixture

Test project used by the signaldeck-docker build (`main` branch,
`.github/workflows/build.yml`). CI points a SignalDeck project at this branch
and runs it in the freshly built image, once with Cypress and once with
Playwright.

The tests only visit the SignalDeck container's own pages, so the result
doesn't depend on any outside website. Each runner has 3 tests with exactly
1 intentional failure, to prove screenshots and videos are captured.

Not part of the image.
