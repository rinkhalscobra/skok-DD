import { createClient } from '@supabase/supabase-js';
import { readFile } from 'node:fs/promises';

const DEMO_EMAIL = 'crm.training.demo@example.test';
const DEMO_PASSWORD = 'Training4821!';
const DEMO_NAME = 'CRM Training Customer';
const DEMO_IBAN = 'DE89370400440532013000';

function parseEnv(source) {
  return Object.fromEntries(
    source
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter((line) => line && !line.startsWith('#') && line.includes('='))
      .map((line) => {
        const separator = line.indexOf('=');
        return [line.slice(0, separator).trim(), line.slice(separator + 1).trim()];
      }),
  );
}

const env = parseEnv(await readFile(new URL('../.env', import.meta.url), 'utf8'));
const supabaseUrl = env.SUPABASE_URL || env.VITE_SUPABASE_URL;
const serviceKey = env.SUPABASE_SERVICE_ROLE_KEY || env.SUPABASE_SECRET_KEY || env.SERVICE_ROLE_KEY;

if (!supabaseUrl || !serviceKey) throw new Error('Supabase URL or service-role key is missing from .env');

const supabase = createClient(supabaseUrl, serviceKey, {
  auth: { autoRefreshToken: false, persistSession: false },
});

async function findDemoUser() {
  for (let page = 1; page <= 20; page += 1) {
    const { data, error } = await supabase.auth.admin.listUsers({ page, perPage: 100 });
    if (error) throw error;
    const match = data.users.find((user) => user.email?.toLowerCase() === DEMO_EMAIL);
    if (match) return match;
    if (data.users.length < 100) break;
  }
  return null;
}

let demoUser = await findDemoUser();
if (!demoUser) {
  const { data, error } = await supabase.auth.admin.createUser({
    email: DEMO_EMAIL,
    password: DEMO_PASSWORD,
    email_confirm: true,
    user_metadata: { full_name: DEMO_NAME },
  });
  if (error || !data.user) throw error || new Error('Demo user was not created');
  demoUser = data.user;
} else {
  const { data, error } = await supabase.auth.admin.updateUserById(demoUser.id, {
    password: DEMO_PASSWORD,
    email_confirm: true,
    user_metadata: { full_name: DEMO_NAME },
  });
  if (error || !data.user) throw error || new Error('Demo user was not updated');
  demoUser = data.user;
}

const cleanupTables = [
  'transactions',
  'fiat_balances',
  'crypto_balances',
  'cards',
  'bill_payments',
  'currency_exchanges',
  'loans',
  'crypto_transactions',
  'crypto_wallets',
  'crypto_transfers',
  'taxes',
  'tax_wallet_addresses',
  'bank_transfers',
  'crypto_deposits',
  'interac_transfers',
  'interac_access_settings',
  'tax_summary_cards',
  'tax_bank_payment_settings',
];

for (const table of cleanupTables) {
  const { error } = await supabase.from(table).delete().eq('user_id', demoUser.id);
  if (error && !/does not exist|schema cache/i.test(error.message)) {
    throw new Error(`Could not reset ${table}: ${error.message}`);
  }
}

const profile = {
  id: demoUser.id,
  full_name: DEMO_NAME,
  email: DEMO_EMAIL,
  account_iban: DEMO_IBAN,
  kyc_status: 'pending',
  crm_role: 'customer',
  is_admin: false,
  assigned_manager_id: null,
  assigned_agent_id: null,
  plain_password: DEMO_PASSWORD,
  show_account_created_at: true,
  updated_at: new Date().toISOString(),
};
let profilePayload = { ...profile };
let profileResult = await supabase.from('profiles').upsert(profilePayload, { onConflict: 'id' });
for (let attempt = 0; attempt < 8 && profileResult.error; attempt += 1) {
  const missingColumn = profileResult.error.message.match(/'([^']+)' column/)?.[1];
  if (!missingColumn || !(missingColumn in profilePayload)) break;
  delete profilePayload[missingColumn];
  profileResult = await supabase.from('profiles').upsert(profilePayload, { onConflict: 'id' });
}
if (profileResult.error) throw profileResult.error;

console.log(JSON.stringify({
  userId: demoUser.id,
  email: DEMO_EMAIL,
  name: DEMO_NAME,
  resetTables: cleanupTables.length,
}, null, 2));
