import { test, expect } from '@playwright/test';

// A story delivered as a single-file zip container must run identically to the
// bare file: the client detects the format from inside the zip, the worker
// explodes it into /sys, and the interpreter loads the story from there. Drives
// the full client → worker → glulxe path over the real zipped advent.ulx.
test.describe('Zipped container delivery', () => {
  test('runs a zipped story end-to-end', async ({ page }) => {
    await page.goto('/');
    await expect(page.locator('#status')).toContainText('initialized', { timeout: 15000 });

    await page.selectOption('#story', 'advent-zipped.zip');

    const output = page.locator('.win-buffer');
    await expect(output).toContainText('Welcome to Adventure', { timeout: 15000 });
    await expect(output).toContainText('End Of Road', { timeout: 5000 });

    // Interactive: input works, moves advance — the interpreter is really running.
    const statusBar = page.locator('.win-grid');
    await expect(statusBar).toContainText('Moves: 1', { timeout: 5000 });
    await page.locator('#input').fill('look');
    await page.locator('#send').click();
    await expect(statusBar).toContainText('Moves: 2', { timeout: 5000 });
  });
});
