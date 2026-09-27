// 3 tests, exactly 1 failure. The build checks these counts, so keep them in
// step with .github/workflows/build.yml on main.
describe('SignalDeck login page', () => {
  it('serves the health endpoint', () => {
    cy.request('/up').its('status').should('eq', 200)
  })

  it('shows the login form', () => {
    cy.visit('/admin/login')
    cy.get('input[type="email"]').should('be.visible')
    cy.get('input[type="password"]').should('be.visible')
  })

  it('fails on purpose, to produce a screenshot', () => {
    cy.visit('/admin/login')
    cy.contains('This text is not on the page', { timeout: 1000 })
  })
})
