import { chromium } from 'playwright';
import { mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';

const email = process.env.CRM_DEMO_EMAIL;
const password = process.env.CRM_DEMO_PASSWORD;
const baseUrl = process.env.CRM_DEMO_URL || 'http://127.0.0.1:5173';
const outputDirectory = path.resolve('docs/crm-training/assets/captures');

if (!email || !password) {
  throw new Error('CRM_DEMO_EMAIL and CRM_DEMO_PASSWORD are required');
}

await mkdir(outputDirectory, { recursive: true });

const browser = await chromium.launch({
  executablePath: 'C:/Program Files/Google/Chrome/Application/chrome.exe',
  headless: true,
});
const page = await browser.newPage({
  viewport: { width: 1600, height: 900 },
  deviceScaleFactor: 1,
});
const captures = [];
let selectedProfileName = '';

async function settle(milliseconds = 800) {
  await page.waitForTimeout(milliseconds);
}

async function acceptCookies() {
  const button = page.getByRole('button', { name: /accept all/i });
  if (await button.count()) {
    await button.click();
    await settle(300);
  }
}

async function sanitizeVisibleCustomerData() {
  await page.evaluate(({ selectedName }) => {
    const replacements = new Map();
    let emailIndex = 1;

    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    const nodes = [];
    while (walker.nextNode()) nodes.push(walker.currentNode);

    for (const node of nodes) {
      let value = node.textContent || '';
      if (selectedName && selectedName.length > 2) {
        value = value.split(selectedName).join('Alex Morgan');
      }
      value = value.replace(/[A-Z]{2}\d{2}[A-Z0-9]{10,30}/g, 'DEMO-IBAN-••••-4821');
      value = value.replace(/\b[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\b/gi, 'demo-record-id');
      value = value.replace(/[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}/g, (match) => {
        if (!replacements.has(match)) replacements.set(match, `demo.user${emailIndex++}@example.test`);
        return replacements.get(match);
      });
      value = value.replace(/\b(?:\d[ -]*?){13,19}\b/g, '•••• •••• •••• 4821');
      node.textContent = value;
    }

    const directoryNames = document.querySelectorAll('article p.text-xl');
    directoryNames.forEach((element, index) => {
      element.textContent = index === 0 ? 'Alex Morgan' : `Demo Customer ${index + 1}`;
    });

    const labels = [...document.querySelectorAll('p,span,label')];
    for (const label of labels) {
      const normalized = (label.textContent || '').trim().toLowerCase();
      if (normalized !== 'password' && normalized !== 'security answer' && normalized !== 'cvv') continue;
      const container = label.parentElement;
      if (!container) continue;
      for (const child of container.querySelectorAll('p,span,input')) {
        if (child === label) continue;
        if (child instanceof HTMLInputElement) child.value = '••••••••';
        else child.textContent = '••••••••';
      }
    }
  }, { selectedName: selectedProfileName });
}

async function capture(name, description, { sanitize = true } = {}) {
  if (sanitize) await sanitizeVisibleCustomerData();
  const file = path.join(outputDirectory, `${name}.png`);
  await page.screenshot({ path: file, animations: 'disabled' });
  captures.push({ name, description, file: path.relative(process.cwd(), file).replaceAll('\\', '/') });
}

async function visit(relativeUrl) {
  await page.goto(`${baseUrl}${relativeUrl}`, { waitUntil: 'domcontentloaded' });
  await settle(2_000);
  const loader = page.locator('.animate-spin').first();
  if (await loader.count()) {
    await loader.waitFor({ state: 'hidden', timeout: 10_000 }).catch(() => {});
  }
  await settle(500);
  await acceptCookies();
}

try {
  await visit('/online-banking');
  await capture('01-login', 'Secure sign-in screen', { sanitize: false });
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(password);
  await page.locator('form').getByRole('button', { name: /sign in/i }).click();
  await page.waitForURL(/\/(dashboard|kyc-status)/, { timeout: 20_000 });
  await settle(1_000);

  const dashboardRoutes = [
    ['02-dashboard-overview', '/dashboard', 'Customer dashboard overview'],
    ['03-dashboard-transactions', '/dashboard/transactions', 'Customer transaction history'],
    ['04-dashboard-transfers', '/dashboard/transfers', 'Customer transfer workspace'],
    ['05-dashboard-cards', '/dashboard/cards', 'Customer card controls'],
    ['06-dashboard-taxes', '/dashboard/taxes', 'Customer tax workspace'],
  ];
  for (const [name, route, description] of dashboardRoutes) {
    await visit(route);
    await capture(name, description);
  }

  await visit('/crm-admin');
  await capture('07-crm-directory', 'CRM directory, security notice, and branding controls');

  const createUserButton = page.getByRole('button', { name: 'Create new user' });
  if (await createUserButton.count()) {
    await createUserButton.click();
    await settle(400);
    await capture('08-create-user', 'Create-user form with role and assignment controls');
    const cancel = page.getByRole('button', { name: 'Cancel' }).last();
    if (await cancel.count()) await cancel.click();
    await settle(300);
  }

  const customersFilter = page.getByRole('button', { name: /^Customers\d+$/ });
  if (await customersFilter.count()) {
    await customersFilter.click();
    await settle(500);
  }
  await capture('09-customer-directory', 'Filtered customer directory');

  const firstProfileButton = page.getByRole('button', { name: 'Open profile' }).first();
  if (!(await firstProfileButton.count())) throw new Error('No customer profile is available for capture');
  const firstCard = firstProfileButton.locator('xpath=ancestor::article[1]');
  selectedProfileName = ((await firstCard.locator('p.text-xl').first().textContent()) || '').trim();
  await firstProfileButton.click();
  await settle(1_500);
  await capture('10-profile-summary', 'Customer profile summary and Interac access');

  const editProfile = page.getByRole('button', { name: 'Edit profile' });
  if (await editProfile.count()) {
    await editProfile.click();
    await settle(400);
    await capture('11-edit-profile', 'Profile, KYC, role, assignment, and credential editor');
    const cancel = page.getByRole('button', { name: 'Cancel' }).last();
    if (await cancel.count()) await cancel.click();
    await settle(300);
  }

  const deleteUser = page.getByRole('button', { name: 'Delete user' });
  if (await deleteUser.count()) {
    await deleteUser.click();
    await settle(400);
    await capture('12-delete-user', 'Protected permanent-deletion confirmation');
    const cancel = page.getByRole('button', { name: 'Cancel' }).last();
    if (await cancel.count()) await cancel.click();
    await settle(300);
  }

  const tabList = page.getByRole('tablist', { name: 'Active table' });
  await tabList.scrollIntoViewIfNeeded();
  await page.evaluate(() => window.scrollBy(0, -120));
  await settle(300);
  await capture('13-table-manager', 'Customer table manager and all operational areas');

  const tableCaptures = [
    ['Transactions', '14-transactions', 'Banking and crypto transaction administration'],
    ['Balances', '15-balances', 'Fiat and crypto balances with customer-wide status'],
    ['Transfers', '16-transfers', 'Bank and crypto transfer administration'],
    ['Interac e-Transfers', '17-interac', 'Interac request review and status workflow'],
    ['Cards', '18-cards', 'Card records and approval workflow'],
    ['Bill Payments', '19-bill-payments', 'Bill-payment records'],
    ['Currency Exchange', '20-currency-exchange', 'Fiat/crypto exchange controls and history'],
    ['Loans', '21-loans', 'Loan records and application status'],
    ['Wallets', '22-wallets', 'Crypto and tax wallet records'],
    ['Taxes', '23-taxes', 'Tax summary, payment instructions, and tax records'],
    ['Add Funds (Crypto)', '24-crypto-deposits', 'Crypto deposit requests'],
  ];

  for (const [label, name, description] of tableCaptures) {
    const tab = page.getByRole('tab', { name: new RegExp(`^${label.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}`) });
    if (!(await tab.count())) continue;
    await tab.click();
    await settle(700);
    await tabList.scrollIntoViewIfNeeded();
    await page.evaluate(() => window.scrollBy(0, -120));
    await settle(200);
    await capture(name, description);
  }

  await writeFile(
    path.resolve('docs/crm-training/captures.json'),
    `${JSON.stringify(captures, null, 2)}\n`,
    'utf8',
  );
  console.log(`Captured ${captures.length} CRM training frames in ${outputDirectory}`);
} finally {
  await browser.close();
}
