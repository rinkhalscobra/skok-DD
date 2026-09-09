import { chromium } from 'playwright';
import { copyFile, mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';

const baseUrl = process.env.CRM_DEMO_URL || 'http://127.0.0.1:5174';
const adminEmail = process.env.CRM_DEMO_EMAIL;
const adminPassword = process.env.CRM_DEMO_PASSWORD;
const demoEmail = 'crm.training.demo@example.test';
const demoPassword = 'Training4821!';
const demoName = 'CRM Training Customer';
const outputRoot = path.resolve('docs/crm-training/action-video');
const rawVideoPath = path.join(outputRoot, 'crm-action-demo-raw.webm');
const recordingTemp = path.join(process.env.TEMP || process.env.TMP || outputRoot, 'skok-crm-action-recording');
const scenes = JSON.parse(await readFile(path.resolve('docs/crm-training/action-scenes.json'), 'utf8'));
const timings = JSON.parse(await readFile(path.join(outputRoot, 'action-durations.json'), 'utf8'));

if (!adminEmail || !adminPassword) throw new Error('CRM_DEMO_EMAIL and CRM_DEMO_PASSWORD are required');
await mkdir(outputRoot, { recursive: true });
await mkdir(recordingTemp, { recursive: true });

const browser = await chromium.launch({
  executablePath: 'C:/Program Files/Google/Chrome/Application/chrome.exe',
  headless: true,
});
const context = await browser.newContext({
  viewport: { width: 1600, height: 900 },
  deviceScaleFactor: 1,
  recordVideo: { dir: recordingTemp, size: { width: 1600, height: 900 } },
});

await context.addInitScript(() => {
  const install = () => {
    if (!document.getElementById('training-cursor')) {
      const cursor = document.createElement('div');
      cursor.id = 'training-cursor';
      cursor.style.cssText = 'position:fixed;left:50%;top:50%;width:24px;height:24px;margin:-12px 0 0 -12px;border:3px solid #64f5bd;border-radius:50%;background:rgba(0,100,70,.22);box-shadow:0 0 0 3px rgba(255,255,255,.95),0 8px 24px rgba(0,0,0,.35);z-index:2147483647;pointer-events:none;transition:left .18s ease,top .18s ease,transform .12s ease;';
      document.documentElement.appendChild(cursor);
    }

    if (location.pathname === '/crm-admin' && !document.getElementById('training-privacy-shield')) {
      const shield = document.createElement('div');
      shield.id = 'training-privacy-shield';
      shield.innerHTML = '<div style="font:700 28px Georgia,serif">Opening the isolated training customer</div><div style="margin-top:10px;font:400 17px Arial,sans-serif;opacity:.82">The directory remains hidden until the demo-only search is applied.</div>';
      shield.style.cssText = 'position:fixed;inset:0;display:flex;flex-direction:column;align-items:center;justify-content:center;background:#06271f;color:white;z-index:2147483646;text-align:center;';
      document.documentElement.appendChild(shield);
    }
  };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', install);
  else install();
});

const page = await context.newPage();
const video = page.video();
const completedScenes = [];

async function sleep(ms) {
  await page.waitForTimeout(ms);
}

async function acceptCookies() {
  const button = page.getByRole('button', { name: /accept all/i });
  if (await button.count()) await button.first().click();
}

async function installTrainingUi() {
  await page.evaluate(() => {
    if (!document.getElementById('training-cursor')) {
      const cursor = document.createElement('div');
      cursor.id = 'training-cursor';
      cursor.style.cssText = 'position:fixed;left:50%;top:50%;width:24px;height:24px;margin:-12px 0 0 -12px;border:3px solid #64f5bd;border-radius:50%;background:rgba(0,100,70,.22);box-shadow:0 0 0 3px rgba(255,255,255,.95),0 8px 24px rgba(0,0,0,.35);z-index:2147483647;pointer-events:none;transition:left .18s ease,top .18s ease,transform .12s ease;';
      document.documentElement.appendChild(cursor);
    }
  });
}

async function showScene(index) {
  const scene = scenes[index];
  await page.evaluate(({ title, caption }) => {
    document.getElementById('training-scene-card')?.remove();
    const card = document.createElement('div');
    card.id = 'training-scene-card';
    card.innerHTML = `<div style="font:700 22px Georgia,serif">${title}</div><div style="margin-top:6px;font:400 14px Arial,sans-serif;color:#c6f7e5">${caption}</div>`;
    card.style.cssText = 'position:fixed;left:28px;bottom:24px;width:min(680px,calc(100vw - 56px));padding:18px 22px;border:1px solid rgba(100,245,189,.35);border-radius:18px;background:rgba(6,39,31,.96);color:white;box-shadow:0 18px 60px rgba(0,0,0,.28);z-index:2147483645;pointer-events:none;';
    document.documentElement.appendChild(card);
  }, scene);
  await sleep(900);
}

async function runScene(index, action) {
  const started = Date.now();
  await installTrainingUi();
  await showScene(index);
  await action();
  const targetMs = Math.round((timings[index]?.durationSeconds || 24) * 1000);
  const actionElapsed = Date.now() - started;
  const remaining = targetMs - actionElapsed;
  if (remaining > 0) await sleep(remaining);
  const actualDurationSeconds = Math.max(targetMs, actionElapsed) / 1000;
  completedScenes.push({
    ...scenes[index],
    startSeconds: completedScenes.reduce((sum, scene) => sum + scene.durationSeconds, 0),
    durationSeconds: actualDurationSeconds,
  });
}

async function pointTo(locator) {
  await locator.scrollIntoViewIfNeeded();
  const box = await locator.boundingBox();
  if (!box) return;
  const x = box.x + box.width / 2;
  const y = box.y + box.height / 2;
  await page.evaluate(({ x, y }) => {
    const cursor = document.getElementById('training-cursor');
    if (cursor) {
      cursor.style.left = `${x}px`;
      cursor.style.top = `${y}px`;
    }
  }, { x, y });
  await page.mouse.move(x, y, { steps: 8 });
  await sleep(250);
}

async function click(locator) {
  await pointTo(locator);
  await page.evaluate(() => {
    const cursor = document.getElementById('training-cursor');
    if (cursor) cursor.style.transform = 'scale(.65)';
  });
  await locator.click();
  await sleep(130);
  await page.evaluate(() => {
    const cursor = document.getElementById('training-cursor');
    if (cursor) cursor.style.transform = 'scale(1)';
  });
  await sleep(420);
}

async function fill(locator, value, { secret = false } = {}) {
  await pointTo(locator);
  await locator.click();
  await locator.fill('');
  if (secret) await locator.fill(value);
  else await locator.pressSequentially(value, { delay: 32 });
  await sleep(300);
}

async function chooseDropdown(label, option) {
  const container = page.getByText(label, { exact: true }).last().locator('..');
  const trigger = container.getByRole('button').first();
  await click(trigger);
  await click(page.getByRole('option', { name: option, exact: true }).last());
}

async function waitForIdle() {
  await page.locator('.animate-spin').first().waitFor({ state: 'hidden', timeout: 12_000 }).catch(() => {});
  await sleep(500);
}

async function login(email, password) {
  await page.goto(`${baseUrl}/online-banking`, { waitUntil: 'domcontentloaded' });
  const emailInput = page.locator('input[type="email"]');
  try {
    await emailInput.waitFor({ state: 'visible', timeout: 20_000 });
  } catch {
    await page.reload({ waitUntil: 'domcontentloaded' });
    await emailInput.waitFor({ state: 'visible', timeout: 45_000 });
  }
  await acceptCookies();
  await fill(emailInput, email);
  await fill(page.locator('input[type="password"]'), password, { secret: true });
  await click(page.locator('form').getByRole('button', { name: /sign in/i }));
  await page.waitForURL(/\/(dashboard|kyc-status)/, { timeout: 20_000 });
  await waitForIdle();
}

async function openDemoCustomer() {
  await page.goto(`${baseUrl}/crm-admin`, { waitUntil: 'domcontentloaded' });
  const search = page.getByPlaceholder('Search by name, email, or ID');
  await search.waitFor({ state: 'visible', timeout: 20_000 });
  await search.fill(demoEmail, { force: true });
  await page.getByText(demoName, { exact: true }).first().waitFor({ state: 'visible', timeout: 15_000 });
  await page.evaluate(() => document.getElementById('training-privacy-shield')?.remove());
  await sleep(800);
  const openProfile = page.getByRole('button', { name: 'Open profile' }).first();
  if (await openProfile.count()) await click(openProfile);
  await waitForIdle();
}

async function openTab(name) {
  const tab = page.getByRole('tab', { name: new RegExp(`^${name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}`) });
  await click(tab);
  await waitForIdle();
}

async function fillDraftField(key, value) {
  const keyInput = page.locator(`input[value="${key}"]`).last();
  const row = keyInput.locator('..');
  const valueControl = row.locator('input,textarea').nth(1);
  await fill(valueControl, value);
}

try {
  await page.goto(`${baseUrl}/online-banking`, { waitUntil: 'domcontentloaded' });
  const initialEmailInput = page.locator('input[type="email"]');
  try {
    await initialEmailInput.waitFor({ state: 'visible', timeout: 20_000 });
  } catch {
    await page.reload({ waitUntil: 'domcontentloaded' });
    await initialEmailInput.waitFor({ state: 'visible', timeout: 45_000 });
  }
  await acceptCookies();

  await runScene(0, async () => {
    await fill(initialEmailInput, adminEmail);
    await fill(page.locator('input[type="password"]'), adminPassword, { secret: true });
    await click(page.locator('form').getByRole('button', { name: /sign in/i }));
    await page.waitForURL(/\/(dashboard|kyc-status)/, { timeout: 20_000 });
    await openDemoCustomer();
    await pointTo(page.getByText(demoName, { exact: true }).first());
  });

  await runScene(1, async () => {
    await click(page.getByRole('button', { name: 'Edit profile' }));
    await chooseDropdown('KYC Status', 'Approved');
    await click(page.getByRole('button', { name: 'Save profile' }).last());
    await page.getByText(/Profile updated/i).waitFor({ state: 'visible', timeout: 15_000 }).catch(() => {});
    await click(page.getByRole('button', { name: 'Close profile editor' }).last());
    const enableInterac = page.getByRole('button', { name: 'Enable for customer' });
    if (await enableInterac.count()) {
      await click(enableInterac);
      await waitForIdle();
    }
    await pointTo(page.getByText('Interac e-Transfer', { exact: true }).first());
  });

  await runScene(2, async () => {
    await openTab('Balances');
    const add = page.getByRole('button', { name: /Add (first )?balance/i }).first();
    await click(add);
    await fill(page.getByLabel('Asset Code'), 'USD');
    await fill(page.getByLabel('Asset Name'), 'US Dollar');
    await fill(page.getByLabel('Starting Balance'), '1250.75');
    await click(page.getByRole('button', { name: 'Create balance' }));
    await page.getByText(/Fiat balance created/i).waitFor({ state: 'visible', timeout: 20_000 });
    await pointTo(page.getByText('1,250.75', { exact: true }).first());
  });

  await runScene(3, async () => {
    await click(page.getByRole('button', { name: 'Edit balance' }).first());
    await fill(page.getByLabel('New balance'), '2400.50');
    await chooseDropdown('Balance status', 'Pending');
    await click(page.getByRole('button', { name: 'Save balance' }));
    await page.getByText(/USD balance updated/i).waitFor({ state: 'visible', timeout: 15_000 }).catch(() => {});
    await chooseDropdown('Set customer balance status', 'Available');
    await click(page.getByRole('button', { name: 'Apply to all balances' }));
    await page.getByText(/Customer balance status set/i).waitFor({ state: 'visible', timeout: 15_000 }).catch(() => {});
    await pointTo(page.getByText('2,400.50', { exact: true }).first());
  });

  await runScene(4, async () => {
    await click(page.getByRole('button', { name: 'Add balance' }).first());
    await chooseDropdown('Balance Type', 'Crypto');
    await fill(page.getByLabel('Asset Code'), 'BTC');
    await fill(page.getByLabel('Asset Name'), 'Bitcoin');
    await fill(page.getByLabel('Starting Balance'), '0.25');
    await click(page.getByRole('button', { name: 'Create balance' }));
    await page.getByText(/Crypto balance created/i).waitFor({ state: 'visible', timeout: 25_000 });
    const moveUp = page.getByRole('button', { name: 'Move BTC up' });
    const moveDown = page.getByRole('button', { name: 'Move BTC down' });
    if (await moveUp.count() && await moveUp.isEnabled()) await click(moveUp);
    else if (await moveDown.count() && await moveDown.isEnabled()) await click(moveDown);
    else if (await moveUp.count()) await pointTo(moveUp);
    await pointTo(page.getByText('0.25', { exact: true }).first());
  });

  await runScene(5, async () => {
    await click(page.getByRole('button', { name: 'Logout' }));
    await page.waitForURL(/online-banking/, { timeout: 15_000 });
    await login(demoEmail, demoPassword);
    await page.goto(`${baseUrl}/dashboard`, { waitUntil: 'domcontentloaded' });
    await waitForIdle();
    const usdAmount = page.getByText(/2[,.]400[,.]50/).first();
    if (await usdAmount.count()) await pointTo(usdAmount);
    await sleep(1200);
    const btc = page.getByText('BTC', { exact: true }).first();
    if (await btc.count()) await pointTo(btc);
  });

  await runScene(6, async () => {
    const signOut = page.getByRole('button', { name: /Sign Out/i });
    if (await signOut.count()) await click(signOut.first());
    await login(adminEmail, adminPassword);
    await openDemoCustomer();
    await openTab('Transactions');
    await click(page.getByRole('button', { name: 'Add transaction' }).first());
    await fillDraftField('type', 'credit');
    await fillDraftField('details', 'Training deposit recorded');
    await fillDraftField('poi', 'DEMO-1001');
    await fillDraftField('comment', 'History only; balance updated separately');
    await click(page.getByRole('button', { name: 'Create transaction' }));
    await page.getByText(/Banking transaction created/i).waitFor({ state: 'visible', timeout: 15_000 });
    await pointTo(page.getByText(/Training deposit recorded/i).first());
  });

  await runScene(7, async () => {
    await click(page.getByRole('button', { name: 'Edit full record' }).first());
    const comment = page.getByLabel('Comment');
    if (await comment.count()) await fill(comment, 'Reviewed training activity');
    await click(page.getByRole('button', { name: 'Save record' }));
    await page.getByText(/record updated/i).waitFor({ state: 'visible', timeout: 15_000 }).catch(() => {});
    page.once('dialog', (dialog) => dialog.accept());
    await click(page.getByRole('button', { name: 'Delete', exact: true }).last());
    await waitForIdle();
    await click(page.getByRole('button', { name: /Refresh transactions/i }).first());
  });

  await runScene(8, async () => {
    for (const tabName of ['Transfers', 'Interac e-Transfers', 'Cards', 'Bill Payments', 'Currency Exchange', 'Loans', 'Wallets', 'Taxes', 'Add Funds (Crypto)']) {
      await openTab(tabName);
      await sleep(300);
    }
    await openTab('Balances');
    await pointTo(page.getByRole('button', { name: 'Refresh balances' }));
  });
} finally {
  await writeFile(path.join(outputRoot, 'recorded-scenes.json'), `${JSON.stringify(completedScenes, null, 2)}\n`, 'utf8');
  await context.close();
  if (video) {
    const generatedPath = await video.path();
    await copyFile(generatedPath, rawVideoPath);
  }
  await browser.close();
}

console.log(`RAW_VIDEO=${rawVideoPath}`);
