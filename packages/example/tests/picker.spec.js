import { test, expect } from '@playwright/test';

test.describe('Story picker', () => {
  test('defaults to Adventure and lists stories across interpreter types', async ({ page }) => {
    await page.goto('/');
    await expect(page.locator('#status')).toContainText('initialized', { timeout: 15000 });

    const select = page.locator('#story');
    await expect(select).toBeVisible();
    // One entry per shipped test story, spanning glulx / z-code / hugo / scott.
    await expect(select.locator('option')).toHaveCount(9);
    await expect(select).toHaveValue('advent.ulx');
    await expect(page.locator('#output')).toContainText('Welcome to Adventure');
  });

  test('switching to a Glulx graphics story renders a graphics canvas', async ({ page }) => {
    await page.goto('/');
    await expect(page.locator('#status')).toContainText('initialized', { timeout: 15000 });

    await page.selectOption('#story', 'graphwintest.gblorb');
    await expect(page.locator('#status')).toContainText('initialized', { timeout: 20000 });
    await expect(page.locator('#output')).toContainText('GraphWinTest');

    // The graphics window must materialise as a canvas.
    const canvas = page.locator('canvas');
    await expect(canvas).toHaveCount(1);

    // Draw an image and assert the canvas has non-transparent pixels.
    await page.locator('#input').fill('image 0');
    await page.locator('#send').click();
    await expect
      .poll(async () => page.evaluate(() => {
        const c = document.querySelector('canvas');
        if (!c) return false;
        const d = c.getContext('2d').getImageData(0, 0, c.width, c.height).data;
        for (let i = 3; i < d.length; i += 4) if (d[i] !== 0) return true;
        return false;
      }), { timeout: 5000 })
      .toBe(true);
  });

  test('switching to a Z-code story loads the fizmo interpreter', async ({ page }) => {
    await page.goto('/');
    await expect(page.locator('#status')).toContainText('initialized', { timeout: 15000 });

    await page.selectOption('#story', 'advent.z5');
    await expect(page.locator('#status')).toContainText('initialized', { timeout: 20000 });
    await expect(page.locator('#output')).toContainText('Adventure');
  });
});
