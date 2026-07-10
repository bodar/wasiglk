import { test, expect } from '@playwright/test';

test.describe('Save/Restore', () => {
  test('can save the game', async ({ page }) => {
    const consoleLogs = [];
    page.on('console', msg => {
      consoleLogs.push(`[${msg.type()}] ${msg.text()}`);
    });

    await page.goto('/');

    await expect(page.locator('#status')).toContainText('Game initialized', { timeout: 10000 });
    await expect(page.locator('#input')).toBeEnabled();

    const input = page.locator('#input');
    const send = page.locator('#send');
    const output = page.locator('.win-buffer');

    // Save the game
    await input.fill('save');
    await send.click();
    await expect(output).toContainText('Ok.', { timeout: 5000 });

    // Wait for OPFS write to complete
    await page.waitForTimeout(500);

    // Verify OPFS file was created
    expect(consoleLogs.some(l => l.includes('Created persistent file'))).toBe(true);
  });

  test('save persists across page reload and restore succeeds', async ({ page }) => {
    const consoleLogs = [];
    page.on('console', msg => {
      consoleLogs.push(`[${msg.type()}] ${msg.text()}`);
    });

    await page.goto('/');

    await expect(page.locator('#status')).toContainText('Game initialized', { timeout: 10000 });
    await expect(page.locator('#input')).toBeEnabled();

    const input = page.locator('#input');
    const send = page.locator('#send');
    const output = page.locator('.win-buffer');
    const statusBar = page.locator('.win-grid');

    // Make a move to change game state
    await input.fill('in');
    await send.click();
    await expect(statusBar).toContainText('Moves: 2', { timeout: 5000 });
    await expect(output).toContainText('Inside Building', { timeout: 5000 });

    // Save the game
    await input.fill('save');
    await send.click();
    await expect(output).toContainText('Ok.', { timeout: 5000 });

    // Wait for OPFS write to complete
    await page.waitForTimeout(500);

    // Reload the page - save must persist via OPFS
    consoleLogs.length = 0;
    await page.reload();

    await expect(page.locator('#status')).toContainText('Game initialized', { timeout: 10000 });
    await expect(page.locator('#input')).toBeEnabled();

    // Verify the saved file was loaded from OPFS
    expect(consoleLogs.some(l => l.includes('Loaded') && !l.includes('Loaded 0'))).toBe(true);

    // Restore the game - verifies binary save data wasn't corrupted
    await input.fill('restore');
    await send.click();
    await expect(output).toContainText('Ok.', { timeout: 5000 });

    // Status bar should show restored game state (Inside Building, where we saved)
    await expect(statusBar).toContainText('Inside Building', { timeout: 5000 });
  });
});
