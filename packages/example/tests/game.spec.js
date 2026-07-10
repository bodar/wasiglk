import { test, expect } from '@playwright/test';

test.describe('WasiGlk Example', () => {
  test('loads and displays game output in buffer window', async ({ page }) => {
    await page.goto('/');

    // Wait for the game to initialize
    await expect(page.locator('#status')).toContainText('Game initialized', { timeout: 10000 });

    // Check that output contains game text (first location description)
    const output = page.locator('.win-buffer');
    await expect(output).toContainText('End Of Road', { timeout: 5000 });
    await expect(output).toContainText('Welcome to Adventure');

    // Input should be enabled
    const input = page.locator('#input');
    await expect(input).toBeEnabled();
  });

  test('displays status bar with score and moves', async ({ page }) => {
    await page.goto('/');

    // Wait for game to be ready
    await expect(page.locator('#status')).toContainText('Game initialized', { timeout: 10000 });

    // Status bar should show location and moves count
    const statusBar = page.locator('.win-grid');
    await expect(statusBar).toBeVisible({ timeout: 5000 });
    // Check for location (beginning of status line)
    await expect(statusBar).toContainText('At End Of Road');
    // Check for moves counter (may vary depending on saved state)
    await expect(statusBar).toContainText('Moves:');
  });

  test('accepts user input and increments move counter', async ({ page }) => {
    await page.goto('/');

    // Wait for game to be ready
    await expect(page.locator('#status')).toContainText('Game initialized', { timeout: 10000 });
    await expect(page.locator('#input')).toBeEnabled();

    // Get initial move count from status bar
    const statusBar = page.locator('.win-grid');
    await expect(statusBar).toContainText('Moves: 1', { timeout: 5000 });

    // Type a command
    await page.locator('#input').fill('look');
    await page.locator('#send').click();

    // Wait for response - move count should increment
    await expect(statusBar).toContainText('Moves: 2', { timeout: 5000 });

    // Input should be re-enabled after response
    await expect(page.locator('#input')).toBeEnabled({ timeout: 5000 });
  });

  test('handles multiple commands', async ({ page }) => {
    await page.goto('/');

    // Wait for game to be ready
    await expect(page.locator('#status')).toContainText('Game initialized', { timeout: 10000 });
    await expect(page.locator('#input')).toBeEnabled();

    const statusBar = page.locator('.win-grid');
    const input = page.locator('#input');
    const send = page.locator('#send');

    // First command
    await input.fill('look');
    await send.click();
    await expect(statusBar).toContainText('Moves: 2', { timeout: 5000 });
    await expect(input).toBeEnabled();

    // Second command
    await input.fill('inventory');
    await send.click();
    await expect(statusBar).toContainText('Moves: 3', { timeout: 5000 });
    await expect(input).toBeEnabled();

    // Third command - use a simple direction that won't work but increments moves
    await input.fill('north');
    await send.click();
    await expect(statusBar).toContainText('Moves: 4', { timeout: 5000 });
    await expect(input).toBeEnabled();
  });

  test('WASM files load correctly', async ({ page }) => {
    // Test that the WASM and story files are served correctly
    const wasmResponse = await page.request.get('/glulxe.wasm');
    expect(wasmResponse.status()).toBe(200);
    expect((await wasmResponse.body()).length).toBeGreaterThan(100000);

    const storyResponse = await page.request.get('/advent.ulx');
    expect(storyResponse.status()).toBe(200);
    expect((await storyResponse.body()).length).toBeGreaterThan(100000);
  });
});
