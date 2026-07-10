import { test, expect } from '@playwright/test';

test.describe('Story picker', () => {
  test('defaults to Adventure and lists stories across interpreter types', async ({ page }) => {
    await page.goto('/');
    await expect(page.locator('#status')).toContainText('initialized', { timeout: 15000 });

    const select = page.locator('#story');
    await expect(select).toBeVisible();
    // One entry per shipped test story, spanning glulx / z-code / hugo / scott
    // plus zipped-container and Hugo/Scare graphics cases.
    await expect(select.locator('option')).toHaveCount(12);
    await expect(select).toHaveValue('advent.ulx');
    await expect(page.locator('.win-buffer')).toContainText('Welcome to Adventure');
  });

  test('switching to a Glulx graphics story renders a graphics window (SVG)', async ({ page }) => {
    await page.goto('/');
    await expect(page.locator('#status')).toContainText('initialized', { timeout: 15000 });

    await page.selectOption('#story', 'graphwintest.gblorb');
    await expect(page.locator('#status')).toContainText('initialized', { timeout: 20000 });
    await expect(page.locator('.win-buffer')).toContainText('GraphWinTest');

    // The graphics window materialises as an SVG surface (SvgRenderer).
    const svg = page.locator('.win-graphics svg');
    await expect(svg).toHaveCount(1);

    // Draw an image; the renderer adds an <image> element resolved from the Blorb.
    await page.locator('#input').fill('image 0');
    await page.locator('#send').click();
    await expect
      .poll(async () => page.evaluate(() =>
        document.querySelectorAll('.win-graphics svg image').length
      ), { timeout: 5000 })
      .toBeGreaterThan(0);
  });

  test('switching to a buffer-image story renders inline images', async ({ page }) => {
    await page.goto('/');
    await expect(page.locator('#status')).toContainText('initialized', { timeout: 15000 });

    await page.selectOption('#story', 'imagetest.gblorb');
    await expect(page.locator('#status')).toContainText('initialized', { timeout: 20000 });
    // The interpreter must actually support images (no scale-flags refusal).
    await expect(page.locator('.win-buffer')).not.toContainText('does not support');

    await page.locator('#input').fill('image');
    await page.locator('#send').click();

    // Inline images appear as <img> inside the buffer output and load.
    await expect
      .poll(async () => page.evaluate(() => {
        const imgs = document.querySelectorAll('.win-buffer img');
        return Array.from(imgs).filter((i) => i.complete && i.naturalWidth > 0).length;
      }), { timeout: 8000 })
      .toBeGreaterThan(0);
  });

  // Count every inline <img> with a server-supplied data: URI ever added to the
  // output, even ones the game later clears (splash images are transient). An
  // observer installed before the story loads captures them regardless.
  const installImageObserver = (page) => page.evaluate(() => {
    window.__dataImgs = 0;
    const out = document.getElementById('game-layout');
    const check = (n) => {
      if (n.nodeType === 1 && n.tagName === 'IMG' && String(n.src).startsWith('data:image/')) window.__dataImgs++;
    };
    new MutationObserver((muts) => muts.forEach((m) => m.addedNodes.forEach((n) => {
      check(n);
      if (n.nodeType === 1) n.querySelectorAll?.('img').forEach(check);
    }))).observe(out, { childList: true, subtree: true });
  });

  test('Hugo graphics story renders inline images via server data-URIs', async ({ page }) => {
    await page.goto('/');
    await expect(page.locator('#status')).toContainText('initialized', { timeout: 15000 });
    await installImageObserver(page);

    // Guilty Bastards ships its images in a companion resource file (zipped with
    // the .hex). Hugo synthesizes a Blorb server-side; since the client holds no
    // Blorb, the server delivers pixels as `data:` URIs. The intro draws images
    // on load.
    await page.selectOption('#story', 'guilty-graphics.zip');
    await expect(page.locator('#status')).toContainText('initialized', { timeout: 30000 });
    await expect(page.locator('.win-buffer')).not.toContainText('does not support');

    await expect
      .poll(async () => page.evaluate(() => window.__dataImgs), { timeout: 15000 })
      .toBeGreaterThan(0);
  });

  test('Scare (ADRIFT) graphics story renders inline images via server data-URIs', async ({ page }) => {
    await page.goto('/');
    await expect(page.locator('#status')).toContainText('initialized', { timeout: 15000 });
    await installImageObserver(page);

    // Paint!!! embeds a JPEG inside its .taf; Scare registers the byte-range via
    // garglk_add_resource_from_file and the server ships it as a `data:` URI. The
    // first room draws the image; dismiss the title screen to reach it.
    await page.selectOption('#story', 'paint.taf');
    await expect(page.locator('#status')).toContainText('initialized', { timeout: 30000 });
    await expect(page.locator('.win-buffer')).not.toContainText('does not support');

    // Advance past the intro/title screens (char or line input) to the first room.
    for (let i = 0; i < 3; i++) {
      await page.locator('#input').fill('');
      await page.locator('#send').click();
    }

    await expect
      .poll(async () => page.evaluate(() => window.__dataImgs), { timeout: 15000 })
      .toBeGreaterThan(0);
  });

  test('switching to a Z-code story loads the fizmo interpreter', async ({ page }) => {
    await page.goto('/');
    await expect(page.locator('#status')).toContainText('initialized', { timeout: 15000 });

    await page.selectOption('#story', 'advent.z5');
    await expect(page.locator('#status')).toContainText('initialized', { timeout: 20000 });
    await expect(page.locator('.win-buffer')).toContainText('Adventure');
  });
});
