ALTER TABLE public.site_branding
  ALTER COLUMN legal_contact_email SET DEFAULT 'support@skokbank.com';

UPDATE public.site_branding
SET legal_contact_email = 'support@skokbank.com',
    updated_at = now();
