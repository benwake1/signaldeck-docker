// 3 tests per browser, exactly 1 failure each. The build checks these counts,
// so keep them in step with .github/workflows/build.yml on main.
const { test, expect } = require('@playwright/test')

test('serves the health endpoint', async ({ request }) => {
  const response = await request.get('/up')
  expect(response.status()).toBe(200)
})

test('shows the login form', async ({ page }) => {
  await page.goto('/admin/login')
  await expect(page.locator('input[type="email"]')).toBeVisible()
  await expect(page.locator('input[type="password"]')).toBeVisible()
})

test('fails on purpose, to produce a screenshot', async ({ page }) => {
  await page.goto('/admin/login')
  await expect(page.getByText('This text is not on the page')).toBeVisible({ timeout: 1000 })
})
