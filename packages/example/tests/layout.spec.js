import { test, expect } from '@playwright/test';

// Phase 5: the interpreter emits a semantic `layout` tree and the demo renders
// it as a nested CSS flexbox that stretches with the viewport. Adventure opens
// a status grid above the main buffer, so the layout is a column of a fixed
// grid row and a growing buffer.
test.describe('Responsive window layout', () => {
  test('renders a nested flex layout that reflows on resize', async ({ page }) => {
    await page.setViewportSize({ width: 1200, height: 800 });
    await page.goto('/');
    await expect(page.locator('#status')).toContainText('initialized', { timeout: 15000 });

    // The mounted root is a flex column (grid above buffer).
    const root = page.locator('#game-layout > div');
    await expect(root).toHaveCSS('display', 'flex');
    await expect(root).toHaveCSS('flex-direction', 'column');

    const grid = page.locator('.win-grid');
    const buffer = page.locator('.win-buffer');
    await expect(grid).toHaveCount(1);
    await expect(buffer).toHaveCount(1);
    await expect(buffer).toContainText('Welcome to Adventure');

    // The grid is a single fixed row (no grow); the buffer grows to fill.
    await expect(grid).toHaveCSS('flex-grow', '0');
    await expect(buffer).toHaveCSS('flex-grow', '1');
    const gridBox = await grid.boundingBox();
    const bufBox = await buffer.boundingBox();
    expect(bufBox.height).toBeGreaterThan(gridBox.height);

    // The status row must be tall enough for its text — the fixed cell size
    // includes the window's padding (measured from CSS), so it isn't clipped.
    const gridClipped = await grid.evaluate((el) => el.scrollHeight > el.clientHeight + 1);
    expect(gridClipped).toBe(false);

    // Narrowing the viewport reflows the flex layout: the buffer gets narrower
    // (driven by the ResizeObserver -> sendArrange path, no manual recompute).
    const wideWidth = bufBox.width;
    await page.setViewportSize({ width: 640, height: 800 });
    await expect
      .poll(async () => (await buffer.boundingBox()).width, { timeout: 5000 })
      .toBeLessThan(wideWidth);

    // Still interactive and coherent after the resize.
    await expect(buffer).toContainText('Welcome to Adventure');
    await expect(page.locator('#input')).toBeEnabled();
  });
});
