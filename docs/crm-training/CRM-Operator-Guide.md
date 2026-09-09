# SKOK Bank CRM Operator Guide

This guide is the complete narration and quick-reference companion for the walkthrough video.

## 1. CRM and Customer Dashboard — Complete Walkthrough

A detailed guide to access, user management, financial records, approvals, branding, and the customer-facing result.

- Administrator workflow from sign-in to sign-out
- Every CRM table and action currently available
- Direct mapping from CRM changes to dashboard screens

**Narration**

Welcome to the complete SKOK Bank CRM operator walkthrough. This presentation explains how the administrator workspace connects to the customer dashboard, where each control lives, what every available action changes, and which actions need extra care. The walkthrough uses privacy-sanitized captures from the real interface. No customer update, approval, creation, or deletion was submitted while recording. We will begin with access and roles, continue through the directory and profile controls, then cover every operational table: transactions, balances, transfers, Interac, cards, bill payments, currency exchange, loans, wallets, crypto deposits, and taxes. We will finish with branding, security, known boundaries, and a practical operating checklist.

## 2. CRM writes the records; the dashboard presents them

Most customer screens are views over Supabase records managed from the CRM.

- CRM profile controls identity, hierarchy, KYC, IBAN, and feature access
- Table Manager controls balances, history, transfers, products, wallets, and taxes
- Customer Dashboard reads those records under row-level security
- Refresh after saving to verify the persisted result

**Narration**

The simplest mental model is this: the CRM is the operator side, Supabase is the source of truth, and the dashboard is the customer side. Profile controls affect identity, CRM hierarchy, KYC status, account IBAN, credentials, membership date, and Interac visibility. The Table Manager affects customer financial records. The dashboard then reads those records through row-level security, so a customer sees only their own information. Some panels are direct record editors, while a few actions also trigger business logic. For example, an approved transfer or crypto deposit can affect balances, while simply adding a transaction record does not necessarily recalculate a balance. After every material change, save, refresh the relevant table, and verify the customer-facing page.

## 3. Sign in, open the CRM, and confirm your role

Use an approved staff account, then navigate to /crm-admin.

- Enter the staff email and password on Online Banking
- Open /crm-admin after authentication
- Confirm the role badge: Admin, Superior Manager, or Agent
- Use Logout when the session is finished

**Narration**

Start on the Online Banking sign-in screen and use a staff account. After authentication, open slash CRM dash admin. At the top of the workspace, confirm the signed-in email and role badge before changing anything. An Admin sees the complete directory and all administrative controls. A Superior Manager sees their assigned team and can create customers or agents in their scope. An Agent sees assigned customers and can create customer accounts in their scope. The interface also enforces these rules in the database, so hiding a button is not the only protection. If the role is wrong, stop and correct the profile assignment rather than trying to work around the interface. Always use Logout at the end of the session, especially on a shared workstation.

## 4. Understand the dashboard before editing the CRM

The overview summarizes balances and recent activity; detail pages show the underlying records.

- Overview: consolidated balances, trends, and recent activity
- Transactions and Transfers: detailed histories
- Cards, Bill Pay, Exchange, Loans, Taxes, and Profile: product-specific views
- Analytics is derived from balance history and transaction data

**Narration**

Before changing a customer, understand what they see. The dashboard overview combines fiat and crypto balances with recent activity and analytics. The left navigation opens detailed pages for transactions, transfers, cards, bill payments, fixed deposits, currency exchange, loans, taxes, analytics, and profile. CRM changes often appear in more than one place. A new balance appears in the balance cards and can affect overview totals. A transaction appears in history and recent activity. A transfer appears in the transfer page and may also create or accompany financial movement. Branding and profile changes are visible throughout the dashboard. This is why the safest workflow starts by noting the current customer-facing state, making one controlled change, and then verifying every affected screen.

## 5. Where customers see CRM-managed information

Four representative dashboard areas and their CRM sources.

- Transactions ← banking and crypto transaction records
- Transfers ← bank, crypto, and permitted Interac requests
- Cards ← card records and approval status
- Taxes ← summary cards, tax records, wallets, and payment instructions

**Narration**

These four dashboard areas demonstrate the direct mapping. The Transactions page combines banking transaction records and crypto transaction records. The Transfers page combines bank and crypto transfers, with Interac shown only when that feature is enabled for the customer. The Cards page displays issued or requested card records and their status. The Taxes page combines the three tax summary amounts with tax records, tax wallet details, and, for specifically enabled customers, bank-payment instructions. The CRM tabs use nearly the same names, making navigation predictable. Remember that a row editor changes the record itself. It does not automatically imply a real external payment occurred. Operators must use statuses and references truthfully and follow the organization's approval process.

## 6. The directory screen has three responsibilities

Security notice, global branding, and user discovery are intentionally separated.

- Network Security card reports the application-level allowlist state
- Brand and institutional settings apply globally
- Full CRM directory finds and opens individual profiles
- Refresh reloads the latest data; Reset form discards unsaved branding edits

**Narration**

The initial Admin workspace has three distinct areas. First, the Network Security card tells you whether an application-level IP allowlist exists. In the current build it is an informational notice, not a live firewall control. Second, Brand and institutional settings are global: saving there can update logos, favicons, legal and institutional text, reference formatting, and invoice presentation across the public site and dashboard. Third, the CRM directory is where customer-specific work begins. Use Refresh to pull current remote values. Use Reset form only to discard unsaved branding changes. Do not confuse the global branding Save button with a customer-profile save; they affect different scopes.

## 7. Search, filter, paginate, and open the correct profile

Confirm identity twice before making financial changes.

- Search by name, email, user ID, KYC status, or CRM role
- Filter All users, Customers, Agents, Superior Managers, or Admins
- Choose 5, 10, 20, or 50 users per page
- Check email and role, then select Open profile

**Narration**

Use the directory to locate the correct person. Search matches full name, email, user ID, KYC status, and CRM role. Role filters separate customers, agents, superior managers, and administrators. Page-size and previous or next controls handle larger directories. Before selecting Open profile, verify at least two identifiers, normally full name and email. The directory may display a stored password for operational compatibility; treat that value as highly sensitive, never expose it in screen sharing, and avoid copying it unless the workflow truly requires it. When you open a profile, the CRM remembers the selected user and table state in the browser session, so use Back to search when switching customers rather than relying on browser history.

## 8. Create users with the correct role and ownership

Role choice controls both visibility and which accounts the staff member can manage.

- Admin can create Customer, Agent, Superior Manager, or Admin
- Superior Manager can create Customer or Agent
- Agent can create Customer only
- Set manager and agent assignments consistently
- Choose KYC state, email confirmation, membership date, and IBAN

**Narration**

Select Create new user to open the account form. Enter full name, a valid email, matching passwords of at least six characters, account IBAN when available, KYC status, CRM role, account creation date, and whether the member-since date should be visible. You can also mark the email as confirmed. Role rules are strict. Admins can create every role. Superior Managers can create customers and agents. Agents can create customers only. Customers and agents may be assigned to a superior manager; customers may also be assigned to an agent who belongs to the same manager. Submitting calls the admin-user-management Edge Function and should create both the Auth login and CRM profile. If creation returns user ID is required, the deployed function is outdated and must be updated before retrying. Never repeatedly submit after an uncertain response; refresh the directory first to avoid duplicates.

## 9. Profile Summary is the identity and access checkpoint

Review the customer before opening any financial table.

- Identity: full name, email, account IBAN, and user ID
- Compliance: KYC status
- Organization: CRM role, superior manager, and assigned agent
- Feature access: enable or disable Interac e-Transfer
- Refresh all tables after external or concurrent changes

**Narration**

The selected profile begins with a summary card. Review the customer's identity, email, account IBAN, KYC badge, CRM role, superior manager, and assigned agent. The credential copy controls are convenience features, but they are also sensitive and should be used sparingly. Below the summary is the Interac feature-access control. Enabling it makes the Interac tab available to the customer and allows new Interac submissions. Disabling it hides the customer tab and blocks new submissions, but existing history remains available to CRM staff. Refresh all tables reloads every customer-scoped dataset. Use it after another operator has made changes or when the page has been open for a long time.

## 10. Edit identity carefully; delete only with explicit confirmation

Auth and Profile Sync changes login credentials as well as CRM data.

- Edit name, email, IBAN, KYC, password, date visibility, role, and assignments
- Email/password changes update Supabase Auth
- Save profile commits; Cancel closes without saving
- Delete user requires typing the matching email and cascades account data
- The last administrator and your own admin account are protected

**Narration**

Edit profile controls both authentication and CRM information. You can change the full name, email, account IBAN, KYC status, password, account creation date, date visibility, role, manager, and agent assignment, subject to your staff role. Email and password changes update Supabase Auth, not just the profile row. Role changes also reshape valid assignments: administrators and superior managers have no manager or agent above them; agents may belong to a superior manager; customers may belong to both a manager and an agent. Save profile commits the changes. Cancel closes the editor. Permanent deletion is intentionally separate. It requires the selected customer's exact email as confirmation, removes the Auth user, cascades customer records, and attempts storage cleanup. You cannot delete yourself, and the final administrator is protected. Export or document anything legally required before deletion.

## 11. One customer, eleven operational views

Each tab displays its row count and exposes only actions supported by that data type.

- Tabs: Transactions, Balances, Cards, Bill Payments, Currency Exchange, Loans
- Also: Wallets, Taxes, Transfers, Interac e-Transfers, Add Funds (Crypto)
- Add creates a row; Edit changes a row; Delete removes a row
- Refresh current table or Refresh all tables to verify persistence

**Narration**

The Table Manager is the center of customer operations. Eleven tabs combine the underlying database tables into task-oriented views. The count under each tab tells you how many relevant rows exist. Most views follow the same pattern: Add creates a new record, Edit opens a form for an existing record, Save commits, Cancel abandons edits, Delete removes the row, and Refresh reloads remote data. Some combined views ask which source type you want, such as banking versus crypto. Fields accept numbers, true, false, and null with automatic conversion, but that flexibility also means values must be checked carefully. Never create a second row merely because a save confirmation is slow. Refresh first, look for the existing ID or reference, and then decide whether a retry is needed.

## 12. Manage banking and crypto history in one view

These are activity records; balances are managed separately unless business logic explicitly links them.

- Banking: cash movements, card activity, and account-side entries
- Crypto: buy, sell, receive, send, and swap history
- Add Transaction selects the source type and opens its fields
- Edit corrects details; Delete removes the history entry
- Confirm timestamps, amount sign, currency/symbol, status, and reference

**Narration**

Transactions combines two sources. Banking transactions cover cash movements, card activity, and ordinary account records. Crypto transactions cover buy, sell, receive, send, and swap history. Select Add Transaction, choose the correct source, then enter only the fields required by that record type. Check the timestamp, transaction type, category, description, amount, balance-after value if used, currency or symbol, status, and reference. Edit is appropriate for correcting a record; Delete removes it from the customer history. A critical distinction: transaction history and account balance are separate records. Do not assume that manually creating a transaction automatically credits or debits the customer's balance. If both must change, use the approved business workflow and then verify both the Transactions tab and Balances tab.

## 13. Control amounts, order, and availability

Fiat and crypto balances are combined, but each remains a separate asset row.

- Add fiat or crypto balance with code, name, amount, and status
- Edit individual amount and asset details
- Move rows up or down to change dashboard display order
- Apply Available or Frozen to all balances
- Delete removes the asset from the customer's balance list

**Narration**

Balances combines fiat currencies and crypto assets. Add Balance asks whether the asset is fiat or crypto, then accepts a currency or token code, display name, amount, and status. Edit changes an individual row. Move controls change display order, which affects how assets are presented to the customer. The customer-wide status control applies Available or Frozen across every existing fiat and crypto balance. Use Frozen only under an authorized operational or compliance process, because it can block customer actions across multiple assets. If rows show mixed statuses, inspect them before applying a global value. Delete removes the asset row from the customer's balance list. After any amount, status, or order change, refresh balances and verify the overview and any action screen that relies on available funds.

## 14. Separate bank, crypto, and Interac workflows

Statuses are operational decisions and may trigger balance effects.

- Transfers tab: add, edit, or delete bank and crypto records
- Interac tab: review recipient and security details
- Interac actions: Processing, Approve, Fail, or Return to Pending
- Completed/approved Interac rows cannot be casually deleted
- Verify balances and history after approval

**Narration**

Transfers separates standard bank and crypto records from Interac requests. In Transfers, Add Transfer first selects bank or crypto and then exposes the matching fields. Edit corrects routing, recipient, amount, fee, status, comment, or timestamps; Delete removes the record. Interac requests have a dedicated review card with recipient email or mobile information and security-question details. Available status actions are Mark Processing, Approve Transfer, Fail Transfer, and Return to Pending. Security answers are restricted to administrators. Completed or approved Interac requests receive stronger deletion protection. Treat approval as a financial action, not a display change: database triggers may update balances when a transfer reaches an approved state. Confirm source asset, amount, fee, recipient, and current status before approval, and verify both balance and transfer history afterward.

## 15. Manage product records and their customer-visible status

Card approval is explicit; bill-payment records use the standard editor.

- Cards: add, edit, delete, and approve pending applications
- Check card type, brand, masked number, holder, expiry, and status
- Bill Payments: add, edit, or delete payment records
- Check biller, amount, payment method, reference, status, and dates
- Never expose CVV or full card data in training material

**Narration**

The Cards tab manages card records and applications. Standard actions are Add, Edit, and Delete. When a card has pending approval status, a dedicated Approve Card action appears. Before approval, verify card type, brand, cardholder, expiry, and the intended masked display. Treat card numbers and CVV as restricted data and never include them in screenshots or support tickets. The Bill Payments tab uses the general record editor. Review the biller description, amount, payment method, account or reference information, status, and relevant dates. Changing a bill-payment status records the workflow state; it does not prove an external biller received funds. The customer sees these records on the corresponding dashboard page, so use clear descriptions and consistent statuses.

## 16. Use execution controls for exchanges; use records for loans

An executed exchange is different from editing exchange history.

- Currency Exchange supports fiat exchange, crypto swap, and cross-asset exchange
- Execution updates balances and creates history through database functions
- Exchange-history Edit corrects metadata; it is not a new trade
- Loans tab manages type, principal, rate, term, payment, and status
- Validate rates, fees, and decimal precision before saving

**Narration**

Currency Exchange is a specialized view. It can execute fiat-to-fiat exchange, crypto swap, and cross-asset exchange through database functions. An execution updates the appropriate balance rows and writes exchange or crypto history as one operation. Validate source asset, destination asset, source amount, destination amount, exchange rate, and fee before running it. Exchange history beneath the control can be edited or deleted for administrative correction, but editing history is not the same as executing a new conversion and should not be used to simulate one. The Loans tab is record-based. Add or edit the loan type, principal, interest rate, term, monthly payment, application or approval dates, status, and notes. The customer's Loans page reflects these records. Keep financial calculations and contractual approval outside ad-hoc data editing.

## 17. Wallet destinations and deposit requests are different records

A wallet identifies where to send; a deposit records what was received or requested.

- Wallets combines customer crypto wallets and the tax wallet
- Add/Edit wallet controls symbol, name, network, and address
- Add Funds (Crypto) manages deposit amount, symbol, hash, and status
- Approved deposits may credit the crypto balance through a trigger
- Verify network and transaction hash before approval

**Narration**

Wallets combines ordinary crypto wallets with the customer's tax wallet record. Add Wallet asks which source you are creating, then stores the asset symbol, display name, network, and wallet address. Edit corrects a destination; Delete removes it. A wallet address is not itself a deposit. The Add Funds Crypto tab manages crypto deposit requests with amount, symbol, transaction hash, network-related details, status, and timestamps. When a deposit reaches an approved status, database logic may credit the crypto balance. Therefore, verify the token, network, amount, transaction hash, and whether the deposit has already been processed before approval. Never approve the same blockchain transaction twice, and always refresh the crypto balance and transaction history afterward.

## 18. Three summary amounts plus supporting payment details

Pending, On Hold, and Paid cards are maintained independently.

- Set amount and currency for Pending, On Hold, and Paid
- Taxes records hold the detailed tax history
- Tax wallet provides the crypto-payment destination
- Tax bank-payment settings hold beneficiary, IBAN, SWIFT, reference, minimum, and currency
- Bank-payment settings are available only to explicitly enabled customers

**Narration**

The Taxes view has three summary cards: Pending Taxes, On Hold, and Paid. Each amount is saved independently with its currency, and the customer dashboard displays the same summary. Below the cards, detailed tax records hold status, amounts, dates, descriptions, and payment-related fields. The tax wallet provides a crypto destination. Tax bank-payment settings provide beneficiary name, account or IBAN, SWIFT or BIC, bank details, payment reference, minimum amount, currency, and an enabled flag. In the current database, bank-payment settings are restricted to explicitly enabled customer IDs, so they are not a universal feature. Check the selected customer before promising that option. Tax figures are high-impact data: require supporting documentation, use a second-person review when possible, and verify the customer Taxes page after saving.

## 19. Branding is global; the IP card is informational

Saving this panel can change public pages, dashboard identity, icons, and invoices.

- Edit brand name, legacy keyword, logos, and generated favicon sizes
- Edit MFI identity, country/code, institutional and depositor-protection text
- Edit legal contact and invoice/reference configuration
- Preview first, upload assets, then Save site settings
- Configure real IP blocking at the host, identity provider, or edge firewall

**Narration**

Brand and institutional settings are global, not customer-specific. The panel controls the full brand name, legacy keyword replacement, navbar and dashboard logo, footer logo, favicon and application icon sizes, MFI identification, country and code, institutional description, depositor-protection text and link, legal contact, and invoice or reference presentation. The live preview helps confirm logo treatment before publishing. Uploading an asset prepares its URLs; press Save Site Settings to publish the complete form. Reset Form discards unsaved edits, while Refresh reloads the remote version. The IP Allowlist card does not enforce traffic restrictions. Real blocking must be configured before the CRM loads, at the hosting provider, identity provider, reverse proxy, or edge firewall. Database IP restrictions alone do not protect a browser route.

## 20. Know what this CRM does not currently manage

Avoid implying that a missing workflow exists merely because the database has a table.

- No dedicated CRM tab for Fixed Deposits
- No dedicated CRM tab for Scheduled Transfers
- KYC status is editable, but submitted documents have no review panel here
- Analytics is derived and has no direct CRM editor
- Create User requires a compatible deployed Edge Function

**Narration**

A complete training must also state the current boundaries. Although the customer dashboard includes Fixed Deposits and the database contains fixed-deposit and scheduled-transfer records, this CRM build has no dedicated tabs for those areas. KYC status can be changed in Edit Profile, but the CRM does not currently include a document-review panel for submitted KYC images. Dashboard analytics is derived from balance snapshots and activity; there is no direct analytics editor. Finally, Create User depends on the deployed admin-user-management Edge Function supporting the create action. If the front end and function versions differ, creation can fail even though the form is visible. These gaps should become separate implementation tasks rather than being handled through unrelated tables or improvised database edits.

## 21. Use the same five-step loop for every change

Identify, inspect, change, verify, and document.

- 1. Identify the customer using two independent details
- 2. Inspect current profile, balance, status, and related history
- 3. Make one authorized change and save once
- 4. Refresh CRM and verify every affected dashboard page
- 5. Record who requested, approved, and completed the action

**Narration**

Use one operating loop for every task. First, identify the customer with at least two independent details. Second, inspect the current profile, relevant asset balance, record status, and related history. Third, make one authorized change and submit it once. Fourth, refresh the CRM and verify every affected customer dashboard page. Fifth, record the request, approval, operator, timestamp, and resulting record ID in the organization's audit process. For high-impact actions such as changing credentials, freezing balances, approving transfers or deposits, editing tax amounts, changing roles, or deleting users, use second-person approval. Never include passwords, security answers, CVV values, full card numbers, or unrestricted wallet secrets in recordings or tickets. If the outcome is uncertain, stop and refresh before retrying. This concludes the complete CRM and dashboard walkthrough.

