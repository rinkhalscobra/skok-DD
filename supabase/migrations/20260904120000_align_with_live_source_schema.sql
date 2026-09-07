/*
 * Align the reproducible schema with the live source project.
 *
 * The source contains several dashboard-applied changes that were not recorded
 * in its migration history. This migration intentionally contains schema only:
 * no application rows or storage objects are copied.
 */

CREATE OR REPLACE FUNCTION public.can_manage_profile(p_profile_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_actor_id uuid := auth.uid();
  v_actor_role text := public.current_crm_role();
  v_target_role text;
  v_target_manager_id uuid;
  v_target_agent_id uuid;
BEGIN
  IF v_actor_id IS NULL OR p_profile_id IS NULL THEN
    RETURN false;
  END IF;

  IF v_actor_role = 'admin' THEN
    RETURN true;
  END IF;

  IF v_actor_id = p_profile_id THEN
    RETURN v_actor_role IN ('superior_manager', 'agent');
  END IF;

  SELECT
    public.get_crm_role(id),
    assigned_manager_id,
    assigned_agent_id
  INTO
    v_target_role,
    v_target_manager_id,
    v_target_agent_id
  FROM public.profiles
  WHERE id = p_profile_id;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  IF v_actor_role = 'superior_manager' THEN
    IF v_target_role = 'agent' AND v_target_manager_id = v_actor_id THEN
      RETURN true;
    END IF;

    IF v_target_role = 'customer' THEN
      IF v_target_manager_id = v_actor_id THEN
        RETURN true;
      END IF;

      IF v_target_agent_id IS NOT NULL AND EXISTS (
        SELECT 1
        FROM public.profiles AS agent_profile
        WHERE agent_profile.id = v_target_agent_id
          AND public.get_crm_role(agent_profile.id) = 'agent'
          AND agent_profile.assigned_manager_id = v_actor_id
      ) THEN
        RETURN true;
      END IF;
    END IF;

    RETURN false;
  END IF;

  IF v_actor_role = 'agent' THEN
    RETURN v_target_role = 'customer' AND v_target_agent_id = v_actor_id;
  END IF;

  RETURN false;
END;
$function$;

CREATE OR REPLACE FUNCTION public.can_manage_user_scope(p_user_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT CASE
    WHEN auth.uid() IS NULL OR p_user_id IS NULL THEN false
    WHEN auth.uid() = p_user_id THEN true
    ELSE public.can_manage_profile(p_user_id)
  END;
$function$;

CREATE OR REPLACE FUNCTION public.create_crypto_wallets_for_user(p_user_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  coins text[][] := ARRAY[
    ARRAY['BTC', 'Bitcoin', 'Bitcoin'],
    ARRAY['ETH', 'Ethereum', 'Ethereum'],
    ARRAY['SOL', 'Solana', 'Solana'],
    ARRAY['DOGE', 'Dogecoin', 'Dogecoin'],
    ARRAY['USDT', 'Tether', 'Tron'],
    ARRAY['USDC', 'USD Coin', 'Ethereum']
  ];
  coin text[];
BEGIN
  FOREACH coin SLICE 1 IN ARRAY coins LOOP
    INSERT INTO crypto_wallets (user_id, symbol, name, wallet_address, network)
    VALUES (
      p_user_id,
      coin[1],
      coin[2],
      generate_wallet_address(coin[3]),
      coin[3]
    )
    ON CONFLICT (user_id, symbol) DO NOTHING;
  END LOOP;
END;
$function$;

CREATE OR REPLACE FUNCTION public.current_crm_role()
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT public.get_crm_role(auth.uid());
$function$;

CREATE OR REPLACE FUNCTION public.ensure_default_fiat_balances()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  current_user_id uuid := auth.uid();
BEGIN
  IF current_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  PERFORM public.seed_default_fiat_balances(current_user_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.execute_cross_asset_exchange(p_user_id uuid, p_direction text, p_from_asset text, p_to_asset text, p_from_amount numeric, p_to_amount numeric, p_exchange_rate numeric, p_fee numeric DEFAULT 0)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_source_balance numeric;
  v_target_balance numeric;
  v_source_status text;
  v_target_status text;
  v_exchange_id uuid;
BEGIN
  IF NOT public.can_manage_user_scope(p_user_id) THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  IF p_direction NOT IN ('fiat_to_crypto', 'crypto_to_fiat') THEN
    RAISE EXCEPTION 'Unsupported cross-asset exchange direction';
  END IF;

  IF p_from_amount <= 0 OR p_to_amount <= 0 OR p_exchange_rate <= 0 THEN
    RAISE EXCEPTION 'Amounts and exchange rate must be positive';
  END IF;

  IF p_direction = 'fiat_to_crypto' THEN
    SELECT balance, status
    INTO v_source_balance, v_source_status
    FROM public.fiat_balances
    WHERE user_id = p_user_id AND currency = p_from_asset
    FOR UPDATE;

    SELECT balance, status
    INTO v_target_balance, v_target_status
    FROM public.crypto_balances
    WHERE user_id = p_user_id AND symbol = p_to_asset
    FOR UPDATE;
  ELSE
    -- Lock fiat before crypto in both directions to avoid opposite-direction deadlocks.
    SELECT balance, status
    INTO v_target_balance, v_target_status
    FROM public.fiat_balances
    WHERE user_id = p_user_id AND currency = p_to_asset
    FOR UPDATE;

    SELECT balance, status
    INTO v_source_balance, v_source_status
    FROM public.crypto_balances
    WHERE user_id = p_user_id AND symbol = p_from_asset
    FOR UPDATE;
  END IF;

  IF v_source_balance IS NULL THEN
    RAISE EXCEPTION 'Source balance not found';
  END IF;

  IF v_target_balance IS NULL THEN
    RAISE EXCEPTION 'Destination balance not found';
  END IF;

  IF COALESCE(v_source_status, 'available') <> 'available' THEN
    RAISE EXCEPTION 'Source balance is % and cannot be exchanged', v_source_status;
  END IF;

  IF COALESCE(v_target_status, 'available') <> 'available' THEN
    RAISE EXCEPTION 'Destination balance is % and cannot receive exchanged funds', v_target_status;
  END IF;

  IF v_source_balance < p_from_amount THEN
    RAISE EXCEPTION 'Insufficient balance. Available: %', v_source_balance;
  END IF;

  IF p_direction = 'fiat_to_crypto' THEN
    UPDATE public.fiat_balances
    SET balance = balance - p_from_amount
    WHERE user_id = p_user_id AND currency = p_from_asset;

    UPDATE public.crypto_balances
    SET balance = balance + p_to_amount
    WHERE user_id = p_user_id AND symbol = p_to_asset;
  ELSE
    UPDATE public.crypto_balances
    SET balance = balance - p_from_amount
    WHERE user_id = p_user_id AND symbol = p_from_asset;

    UPDATE public.fiat_balances
    SET balance = balance + p_to_amount
    WHERE user_id = p_user_id AND currency = p_to_asset;
  END IF;

  INSERT INTO public.currency_exchanges (
    user_id,
    from_currency,
    to_currency,
    from_amount,
    to_amount,
    exchange_rate,
    fee,
    status
  )
  VALUES (
    p_user_id,
    p_from_asset,
    p_to_asset,
    p_from_amount,
    p_to_amount,
    p_exchange_rate,
    GREATEST(COALESCE(p_fee, 0), 0),
    'completed'
  )
  RETURNING id INTO v_exchange_id;

  RETURN v_exchange_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.execute_crypto_swap(p_user_id uuid, p_from_symbol text, p_to_symbol text, p_from_amount numeric, p_to_amount numeric, p_from_price_usd numeric, p_to_price_usd numeric, p_fee_usd numeric)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_current_balance numeric;
  v_source_status text;
  v_target_status text;
  v_tx_id uuid;
  v_from_name text;
  v_to_name text;
  v_total_value numeric;
BEGIN
  IF NOT public.can_manage_user_scope(p_user_id) THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  IF p_from_symbol = p_to_symbol THEN
    RAISE EXCEPTION 'Source and destination must differ';
  END IF;

  IF p_from_amount <= 0 THEN
    RAISE EXCEPTION 'Amount must be positive';
  END IF;

  SELECT balance, name, status
  INTO v_current_balance, v_from_name, v_source_status
  FROM public.crypto_balances
  WHERE user_id = p_user_id AND symbol = p_from_symbol
  FOR UPDATE;

  IF v_current_balance IS NULL THEN
    RAISE EXCEPTION 'Source crypto balance not found';
  END IF;

  IF COALESCE(v_source_status, 'available') <> 'available' THEN
    RAISE EXCEPTION 'Source crypto balance is % and cannot be swapped', v_source_status;
  END IF;

  SELECT name, status
  INTO v_to_name, v_target_status
  FROM public.crypto_balances
  WHERE user_id = p_user_id AND symbol = p_to_symbol
  FOR UPDATE;

  IF v_target_status IS NOT NULL AND v_target_status <> 'available' THEN
    RAISE EXCEPTION 'Destination crypto balance is % and cannot receive swapped funds', v_target_status;
  END IF;

  IF v_current_balance < p_from_amount THEN
    RAISE EXCEPTION 'Insufficient balance. Available: %', v_current_balance;
  END IF;

  v_total_value := p_from_amount * p_from_price_usd;

  UPDATE public.crypto_balances
  SET balance = balance - p_from_amount
  WHERE user_id = p_user_id AND symbol = p_from_symbol;

  UPDATE public.crypto_balances
  SET balance = balance + p_to_amount
  WHERE user_id = p_user_id AND symbol = p_to_symbol;

  IF NOT FOUND THEN
    INSERT INTO public.crypto_balances (user_id, symbol, name, balance, status)
    VALUES (p_user_id, p_to_symbol, COALESCE(v_to_name, p_to_symbol), p_to_amount, 'available');
  END IF;

  INSERT INTO public.crypto_transactions (
    user_id, type, symbol, name, amount, price_per_unit,
    total_value, fee, from_symbol, to_symbol, status, description
  )
  VALUES (
    p_user_id, 'swap', p_from_symbol, v_from_name, p_from_amount, p_from_price_usd,
    v_total_value, p_fee_usd, p_from_symbol, p_to_symbol, 'completed',
    'Swap ' || p_from_amount || ' ' || p_from_symbol || ' to ' || round(p_to_amount, 8) || ' ' || p_to_symbol
  )
  RETURNING id INTO v_tx_id;

  RETURN v_tx_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.execute_currency_exchange(p_user_id uuid, p_from_currency text, p_to_currency text, p_from_amount numeric, p_to_amount numeric, p_exchange_rate numeric, p_fee numeric DEFAULT 0)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_from_currency text := upper(trim(p_from_currency));
  v_to_currency text := upper(trim(p_to_currency));
  v_current_balance numeric;
  v_source_status text;
  v_target_status text;
  v_exchange_id uuid;
BEGIN
  IF NOT public.can_manage_user_scope(p_user_id) THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  IF v_from_currency !~ '^[A-Z]{3}$' OR v_to_currency !~ '^[A-Z]{3}$' THEN
    RAISE EXCEPTION 'Fiat currencies must use 3-letter ISO codes';
  END IF;

  IF v_from_currency = v_to_currency THEN
    RAISE EXCEPTION 'Source and destination currencies must differ';
  END IF;

  IF p_from_amount <= 0 OR p_to_amount <= 0 OR p_exchange_rate <= 0 THEN
    RAISE EXCEPTION 'Amounts and exchange rate must be positive';
  END IF;

  IF COALESCE(p_fee, 0) < 0 THEN
    RAISE EXCEPTION 'Fee cannot be negative';
  END IF;

  IF abs(p_to_amount - round(p_from_amount * p_exchange_rate, 2)) > 0.011 THEN
    RAISE EXCEPTION 'Destination amount does not match the quoted exchange rate';
  END IF;

  -- Always lock a pair in currency order so opposite-direction exchanges cannot deadlock.
  PERFORM id
  FROM public.fiat_balances
  WHERE user_id = p_user_id
    AND currency IN (v_from_currency, v_to_currency)
  ORDER BY currency
  FOR UPDATE;

  SELECT balance, status
  INTO v_current_balance, v_source_status
  FROM public.fiat_balances
  WHERE user_id = p_user_id AND currency = v_from_currency;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Source currency balance not found';
  END IF;

  SELECT status
  INTO v_target_status
  FROM public.fiat_balances
  WHERE user_id = p_user_id AND currency = v_to_currency;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Destination currency balance not found';
  END IF;

  IF COALESCE(v_source_status, 'available') <> 'available' THEN
    RAISE EXCEPTION 'Source currency balance is % and cannot be exchanged', v_source_status;
  END IF;

  IF COALESCE(v_target_status, 'available') <> 'available' THEN
    RAISE EXCEPTION 'Destination currency balance is % and cannot receive exchanged funds', v_target_status;
  END IF;

  IF v_current_balance < p_from_amount THEN
    RAISE EXCEPTION 'Insufficient balance. Available: %', v_current_balance;
  END IF;

  UPDATE public.fiat_balances
  SET balance = balance - p_from_amount
  WHERE user_id = p_user_id AND currency = v_from_currency;

  UPDATE public.fiat_balances
  SET balance = balance + p_to_amount
  WHERE user_id = p_user_id AND currency = v_to_currency;

  INSERT INTO public.currency_exchanges (
    user_id,
    from_currency,
    to_currency,
    from_amount,
    to_amount,
    exchange_rate,
    fee,
    status
  )
  VALUES (
    p_user_id,
    v_from_currency,
    v_to_currency,
    p_from_amount,
    p_to_amount,
    p_exchange_rate,
    COALESCE(p_fee, 0),
    'completed'
  )
  RETURNING id INTO v_exchange_id;

  RETURN v_exchange_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.generate_tax_wallet_address()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF NEW.wallet_address = '' OR NEW.wallet_address IS NULL THEN
    NEW.wallet_address := 'TX-' || upper(substr(md5(NEW.user_id::text || now()::text || random()::text), 1, 8))
      || '-' || upper(substr(md5(random()::text), 1, 4))
      || '-' || upper(substr(md5(random()::text || NEW.user_id::text), 1, 4))
      || '-' || upper(substr(md5(now()::text || random()::text), 1, 8));
  END IF;
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.generate_wallet_address(network_name text)
 RETURNS text
 LANGUAGE plpgsql
AS $function$
DECLARE
  hex_chars text := '0123456789abcdef';
  addr text := '';
  i int;
BEGIN
  CASE network_name
    WHEN 'Bitcoin' THEN
      addr := 'bc1q';
      FOR i IN 1..38 LOOP
        addr := addr || substr(hex_chars, floor(random() * 16 + 1)::int, 1);
      END LOOP;
    WHEN 'Ethereum' THEN
      addr := '0x';
      FOR i IN 1..40 LOOP
        addr := addr || substr(hex_chars, floor(random() * 16 + 1)::int, 1);
      END LOOP;
    WHEN 'Solana' THEN
      addr := '';
      FOR i IN 1..44 LOOP
        addr := addr || substr('123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz', floor(random() * 58 + 1)::int, 1);
      END LOOP;
    WHEN 'Dogecoin' THEN
      addr := 'D';
      FOR i IN 1..33 LOOP
        addr := addr || substr('123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz', floor(random() * 58 + 1)::int, 1);
      END LOOP;
    WHEN 'Tron' THEN
      addr := 'T';
      FOR i IN 1..33 LOOP
        addr := addr || substr(hex_chars || 'ABCDEF', floor(random() * 22 + 1)::int, 1);
      END LOOP;
    ELSE
      addr := '0x';
      FOR i IN 1..40 LOOP
        addr := addr || substr(hex_chars, floor(random() * 16 + 1)::int, 1);
      END LOOP;
  END CASE;
  RETURN addr;
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_crm_role(p_user_id uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT COALESCE(
    (
      SELECT CASE
        WHEN lower(btrim(COALESCE(crm_role, ''))) IN ('customer', 'agent', 'superior_manager', 'admin') THEN lower(btrim(crm_role))
        WHEN is_admin THEN 'admin'
        ELSE 'customer'
      END
      FROM public.profiles
      WHERE id = p_user_id
    ),
    'customer'
  );
$function$;

CREATE OR REPLACE FUNCTION public.handle_bank_transfer_approved()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  source_balance numeric;
  source_status text;
  target_balance numeric;
  target_status text;
  previous_status text;
BEGIN
  previous_status := CASE WHEN TG_OP = 'INSERT' THEN NULL ELSE OLD.status END;

  IF NEW.status IS DISTINCT FROM previous_status
    AND auth.uid() = NEW.user_id
    AND NOT public.is_crm_staff()
    AND (TG_OP <> 'INSERT' OR NEW.status <> 'pending')
  THEN
    RAISE EXCEPTION 'Only authorized CRM staff can change transfer status';
  END IF;

  IF TG_OP = 'UPDATE'
    AND previous_status IN ('approved', 'completed')
    AND NEW.status NOT IN ('approved', 'completed')
  THEN
    RAISE EXCEPTION 'A finalized transfer cannot return to a non-final status';
  END IF;

  IF TG_OP = 'UPDATE'
    AND previous_status IN ('approved', 'completed')
    AND ROW(NEW.user_id, NEW.transfer_type, NEW.amount, NEW.currency, NEW.target_currency)
      IS DISTINCT FROM
      ROW(OLD.user_id, OLD.transfer_type, OLD.amount, OLD.currency, OLD.target_currency)
  THEN
    RAISE EXCEPTION 'Finalized transfer financial details cannot be changed';
  END IF;

  IF NEW.status IN ('approved', 'completed')
    AND (previous_status IS NULL OR previous_status NOT IN ('approved', 'completed'))
  THEN
    IF NEW.transfer_type = 'internal' THEN
      IF NEW.target_currency IS NULL OR NEW.target_currency = '' THEN
        RAISE EXCEPTION 'Internal bank transfer requires a target currency';
      END IF;

      IF NEW.target_currency = NEW.currency THEN
        RAISE EXCEPTION 'Internal bank transfer currencies must differ';
      END IF;

      PERFORM id
      FROM public.fiat_balances
      WHERE user_id = NEW.user_id
        AND currency IN (NEW.currency, NEW.target_currency)
      ORDER BY currency
      FOR UPDATE;
    ELSE
      PERFORM id
      FROM public.fiat_balances
      WHERE user_id = NEW.user_id AND currency = NEW.currency
      FOR UPDATE;
    END IF;

    SELECT balance, status
    INTO source_balance, source_status
    FROM public.fiat_balances
    WHERE user_id = NEW.user_id AND currency = NEW.currency;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Source % balance not found', NEW.currency;
    END IF;

    IF COALESCE(source_status, 'available') <> 'available' THEN
      RAISE EXCEPTION 'Source % balance is % and cannot be approved for transfer', NEW.currency, source_status;
    END IF;

    IF source_balance < NEW.amount THEN
      RAISE EXCEPTION 'Insufficient % balance for transfer approval', NEW.currency;
    END IF;

    IF NEW.transfer_type = 'internal' THEN
      SELECT balance, status
      INTO target_balance, target_status
      FROM public.fiat_balances
      WHERE user_id = NEW.user_id AND currency = NEW.target_currency;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'Target % balance not found', NEW.target_currency;
      END IF;

      IF COALESCE(target_status, 'available') <> 'available' THEN
        RAISE EXCEPTION 'Target % balance is % and cannot receive transfer funds', NEW.target_currency, target_status;
      END IF;
    END IF;

    UPDATE public.fiat_balances
    SET balance = balance - NEW.amount
    WHERE user_id = NEW.user_id AND currency = NEW.currency;

    IF NEW.transfer_type = 'internal' THEN
      UPDATE public.fiat_balances
      SET balance = balance + NEW.amount
      WHERE user_id = NEW.user_id AND currency = NEW.target_currency;
    END IF;
  END IF;

  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.handle_crypto_transfer_approved()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  source_balance numeric;
  source_status text;
  target_balance numeric;
  target_status text;
  previous_status text;
BEGIN
  previous_status := CASE WHEN TG_OP = 'INSERT' THEN NULL ELSE OLD.status END;

  IF NEW.status IS DISTINCT FROM previous_status
    AND auth.uid() = NEW.user_id
    AND NOT public.is_crm_staff()
    AND (TG_OP <> 'INSERT' OR NEW.status <> 'pending')
  THEN
    RAISE EXCEPTION 'Only authorized CRM staff can change transfer status';
  END IF;

  IF TG_OP = 'UPDATE'
    AND previous_status IN ('approved', 'completed')
    AND NEW.status NOT IN ('approved', 'completed')
  THEN
    RAISE EXCEPTION 'A finalized transfer cannot return to a non-final status';
  END IF;

  IF TG_OP = 'UPDATE'
    AND previous_status IN ('approved', 'completed')
    AND ROW(NEW.user_id, NEW.transfer_type, NEW.direction, NEW.amount, NEW.symbol, NEW.target_symbol)
      IS DISTINCT FROM
      ROW(OLD.user_id, OLD.transfer_type, OLD.direction, OLD.amount, OLD.symbol, OLD.target_symbol)
  THEN
    RAISE EXCEPTION 'Finalized transfer financial details cannot be changed';
  END IF;

  IF NEW.status IN ('approved', 'completed')
    AND (previous_status IS NULL OR previous_status NOT IN ('approved', 'completed'))
  THEN
    IF NEW.amount <= 0 THEN
      RAISE EXCEPTION 'Transfer amount must be positive';
    END IF;

    IF NEW.direction = 'receive' THEN
      PERFORM id
      FROM public.crypto_balances
      WHERE user_id = NEW.user_id AND symbol = NEW.symbol
      FOR UPDATE;

      SELECT balance, status
      INTO target_balance, target_status
      FROM public.crypto_balances
      WHERE user_id = NEW.user_id AND symbol = NEW.symbol;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'Target % balance not found', NEW.symbol;
      END IF;

      IF COALESCE(target_status, 'available') <> 'available' THEN
        RAISE EXCEPTION 'Target % balance is % and cannot receive transfer funds', NEW.symbol, target_status;
      END IF;

      UPDATE public.crypto_balances
      SET balance = balance + NEW.amount
      WHERE user_id = NEW.user_id AND symbol = NEW.symbol;

    ELSE
      IF NEW.transfer_type = 'internal' THEN
        IF NEW.target_symbol IS NULL OR NEW.target_symbol = '' THEN
          RAISE EXCEPTION 'Internal crypto transfer requires a target symbol';
        END IF;

        IF NEW.target_symbol = NEW.symbol THEN
          RAISE EXCEPTION 'Internal crypto transfer symbols must differ';
        END IF;

        PERFORM id
        FROM public.crypto_balances
        WHERE user_id = NEW.user_id
          AND symbol IN (NEW.symbol, NEW.target_symbol)
        ORDER BY symbol
        FOR UPDATE;
      ELSE
        PERFORM id
        FROM public.crypto_balances
        WHERE user_id = NEW.user_id AND symbol = NEW.symbol
        FOR UPDATE;
      END IF;

      SELECT balance, status
      INTO source_balance, source_status
      FROM public.crypto_balances
      WHERE user_id = NEW.user_id AND symbol = NEW.symbol;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'Source % balance not found', NEW.symbol;
      END IF;

      IF COALESCE(source_status, 'available') <> 'available' THEN
        RAISE EXCEPTION 'Source % balance is % and cannot be approved for transfer', NEW.symbol, source_status;
      END IF;

      IF source_balance < NEW.amount THEN
        RAISE EXCEPTION 'Insufficient % balance for transfer approval', NEW.symbol;
      END IF;

      IF NEW.transfer_type = 'internal' THEN
        SELECT balance, status
        INTO target_balance, target_status
        FROM public.crypto_balances
        WHERE user_id = NEW.user_id AND symbol = NEW.target_symbol;

        IF NOT FOUND THEN
          RAISE EXCEPTION 'Target % balance not found', NEW.target_symbol;
        END IF;

        IF COALESCE(target_status, 'available') <> 'available' THEN
          RAISE EXCEPTION 'Target % balance is % and cannot receive transfer funds', NEW.target_symbol, target_status;
        END IF;
      END IF;

      UPDATE public.crypto_balances
      SET balance = balance - NEW.amount
      WHERE user_id = NEW.user_id AND symbol = NEW.symbol;

      IF NEW.transfer_type = 'internal' THEN
        UPDATE public.crypto_balances
        SET balance = balance + NEW.amount
        WHERE user_id = NEW.user_id AND symbol = NEW.target_symbol;
      END IF;
    END IF;
  END IF;

  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.handle_deposit_approval()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_balance_status text;
BEGIN
  IF OLD.status = 'pending' AND NEW.status = 'approved' THEN
    SELECT status
    INTO v_balance_status
    FROM public.crypto_balances
    WHERE user_id = NEW.user_id AND symbol = NEW.symbol;

    IF v_balance_status IS NOT NULL AND v_balance_status <> 'available' THEN
      RAISE EXCEPTION 'Target % balance is % and cannot receive deposit funds', NEW.symbol, v_balance_status;
    END IF;

    UPDATE public.crypto_balances
    SET balance = balance + NEW.amount
    WHERE user_id = NEW.user_id AND symbol = NEW.symbol;

    IF NOT FOUND THEN
      INSERT INTO public.crypto_balances (user_id, symbol, name, balance, status)
      VALUES (NEW.user_id, NEW.symbol, NEW.crypto_name, NEW.amount, 'available');
    END IF;
  END IF;

  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.handle_new_user()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  btc_id uuid := gen_random_uuid();
  eth_id uuid := gen_random_uuid();
  sol_id uuid := gen_random_uuid();
  usdt_id uuid := gen_random_uuid();
  usdc_id uuid := gen_random_uuid();
BEGIN
  INSERT INTO public.profiles (id, full_name, email)
  VALUES (
    NEW.id,
    COALESCE(NEW.raw_user_meta_data->>'full_name', ''),
    COALESCE(NEW.email, '')
  );

  PERFORM public.seed_default_fiat_balances(NEW.id);

  INSERT INTO public.crypto_balances (id, user_id, symbol, name, balance)
  VALUES
    (btc_id, NEW.id, 'BTC', 'Bitcoin', 0),
    (eth_id, NEW.id, 'ETH', 'Ethereum', 0),
    (sol_id, NEW.id, 'SOL', 'Solana', 0),
    (usdt_id, NEW.id, 'USDT', 'Tether', 0),
    (usdc_id, NEW.id, 'USDC', 'USD Coin', 0);

  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.handle_new_user_crypto_wallets()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  PERFORM create_crypto_wallets_for_user(NEW.id);
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.is_admin_user()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT public.current_crm_role() = 'admin';
$function$;

CREATE OR REPLACE FUNCTION public.is_crm_staff()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT public.current_crm_role() IN ('admin', 'superior_manager', 'agent');
$function$;

CREATE OR REPLACE FUNCTION public.secure_profile_privileged_fields()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_actor_role text := public.current_crm_role();
  v_assigned_agent_manager_id uuid;
  v_kyc_submission_user_id text := current_setting('app.kyc_submission_user_id', true);
BEGIN
  NEW.crm_role := CASE
    WHEN lower(btrim(COALESCE(NEW.crm_role, ''))) IN ('customer', 'agent', 'superior_manager', 'admin') THEN lower(btrim(NEW.crm_role))
    WHEN COALESCE(NEW.is_admin, false) THEN 'admin'
    ELSE 'customer'
  END;

  IF auth.role() IS NULL OR auth.role() = 'service_role' THEN
    NULL;
  ELSIF TG_OP = 'INSERT' THEN
    IF v_actor_role <> 'admin' THEN
      NEW.crm_role := 'customer';
      NEW.is_admin := false;
      NEW.kyc_status := 'pending';
      NEW.account_iban := '';
      NEW.assigned_manager_id := null;
      NEW.assigned_agent_id := null;
    END IF;
  ELSIF v_actor_role = 'admin' THEN
    NULL;
  ELSIF v_actor_role = 'superior_manager' THEN
    NEW.id := OLD.id;
    NEW.created_at := OLD.created_at;
    NEW.crm_role := OLD.crm_role;
    NEW.is_admin := OLD.is_admin;
    NEW.assigned_manager_id := OLD.assigned_manager_id;

    IF OLD.crm_role <> 'customer' THEN
      NEW.assigned_agent_id := OLD.assigned_agent_id;
    ELSIF NEW.assigned_agent_id IS DISTINCT FROM OLD.assigned_agent_id AND NEW.assigned_agent_id IS NOT NULL THEN
      IF NOT EXISTS (
        SELECT 1
        FROM public.profiles AS agent_profile
        WHERE agent_profile.id = NEW.assigned_agent_id
          AND public.get_crm_role(agent_profile.id) = 'agent'
          AND agent_profile.assigned_manager_id = auth.uid()
      ) THEN
        RAISE EXCEPTION 'Superior managers can assign only their own agents';
      END IF;
    END IF;
  ELSIF v_actor_role = 'agent' THEN
    NEW.id := OLD.id;
    NEW.created_at := OLD.created_at;
    NEW.crm_role := OLD.crm_role;
    NEW.is_admin := OLD.is_admin;
    NEW.assigned_manager_id := OLD.assigned_manager_id;
    NEW.assigned_agent_id := OLD.assigned_agent_id;
  ELSE
    NEW.id := OLD.id;
    NEW.created_at := OLD.created_at;
    NEW.crm_role := OLD.crm_role;
    NEW.is_admin := OLD.is_admin;
    NEW.account_iban := OLD.account_iban;
    NEW.assigned_manager_id := OLD.assigned_manager_id;
    NEW.assigned_agent_id := OLD.assigned_agent_id;

    IF OLD.id = auth.uid()
      AND OLD.kyc_status IN ('pending', 'rejected')
      AND NEW.kyc_status = 'submitted'
      AND v_kyc_submission_user_id = OLD.id::text
      AND EXISTS (
        SELECT 1
        FROM public.kyc_submissions
        WHERE user_id = OLD.id
      ) THEN
      NEW.kyc_status := 'submitted';
    ELSE
      NEW.kyc_status := OLD.kyc_status;
    END IF;
  END IF;

  IF NEW.id = NEW.assigned_manager_id OR NEW.id = NEW.assigned_agent_id THEN
    RAISE EXCEPTION 'Profiles cannot be assigned to themselves';
  END IF;

  IF NEW.crm_role IN ('admin', 'superior_manager') THEN
    NEW.assigned_manager_id := null;
    NEW.assigned_agent_id := null;
  ELSIF NEW.crm_role = 'agent' THEN
    NEW.assigned_agent_id := null;

    IF NEW.assigned_manager_id IS NOT NULL
      AND public.get_crm_role(NEW.assigned_manager_id) <> 'superior_manager' THEN
      RAISE EXCEPTION 'Agents can be assigned only to superior managers';
    END IF;
  ELSE
    IF NEW.assigned_manager_id IS NOT NULL
      AND public.get_crm_role(NEW.assigned_manager_id) <> 'superior_manager' THEN
      RAISE EXCEPTION 'Customers can be assigned only to superior managers';
    END IF;

    IF NEW.assigned_agent_id IS NOT NULL THEN
      SELECT assigned_manager_id
      INTO v_assigned_agent_manager_id
      FROM public.profiles
      WHERE id = NEW.assigned_agent_id
        AND public.get_crm_role(id) = 'agent';

      IF NOT FOUND THEN
        RAISE EXCEPTION 'Assigned agent must have the agent role';
      END IF;

      IF NEW.assigned_manager_id IS NULL THEN
        NEW.assigned_manager_id := v_assigned_agent_manager_id;
      ELSIF v_assigned_agent_manager_id IS NOT NULL
        AND NEW.assigned_manager_id <> v_assigned_agent_manager_id THEN
        RAISE EXCEPTION 'Assigned agent belongs to a different superior manager';
      END IF;
    END IF;
  END IF;

  NEW.is_admin := (NEW.crm_role = 'admin');
  NEW.updated_at := now();

  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.seed_crypto_transactions_for_user(target_user_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  INSERT INTO crypto_transactions (user_id, type, symbol, name, amount, price_per_unit, total_value, fee, status, description, tx_hash, created_at)
  VALUES
    (target_user_id, 'buy',     'BTC',  'Bitcoin',   0.15,    62450.00,  9367.50,   14.05, 'completed', 'Bought 0.15 BTC',               'a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4', now() - interval '45 days'),
    (target_user_id, 'buy',     'ETH',  'Ethereum',  2.5,     3420.00,   8550.00,   12.82, 'completed', 'Bought 2.5 ETH',                'b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5', now() - interval '40 days'),
    (target_user_id, 'buy',     'SOL',  'Solana',    25.0,    142.50,    3562.50,   5.34,  'completed', 'Bought 25 SOL',                  'c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6', now() - interval '35 days'),
    (target_user_id, 'receive', 'BTC',  'Bitcoin',   0.05,    63100.00,  3155.00,   0.00,  'completed', 'Received 0.05 BTC from wallet',  'd4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1', now() - interval '30 days'),
    (target_user_id, 'sell',    'ETH',  'Ethereum',  1.0,     3510.00,   3510.00,   5.27,  'completed', 'Sold 1 ETH',                     'e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2', now() - interval '25 days'),
    (target_user_id, 'swap',    'SOL',  'Solana',    10.0,    148.00,    1480.00,   2.96,  'completed', 'Swapped 10 SOL for 0.43 ETH',    'f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3', now() - interval '20 days'),
    (target_user_id, 'buy',     'DOGE', 'Dogecoin',  5000.0,  0.165,     825.00,    1.24,  'completed', 'Bought 5000 DOGE',               'a7b8c9d0e1f2a7b8c9d0e1f2a7b8c9d0', now() - interval '18 days'),
    (target_user_id, 'send',    'BTC',  'Bitcoin',   0.02,    64200.00,  1284.00,   3.50,  'completed', 'Sent 0.02 BTC to external wallet','b8c9d0e1f2a7b8c9d0e1f2a7b8c9d0e1', now() - interval '15 days'),
    (target_user_id, 'buy',     'ETH',  'Ethereum',  0.75,    3580.00,   2685.00,   4.03,  'completed', 'Bought 0.75 ETH',                'c9d0e1f2a7b8c9d0e1f2a7b8c9d0e1f2', now() - interval '10 days'),
    (target_user_id, 'sell',    'DOGE', 'Dogecoin',  2500.0,  0.172,     430.00,    0.65,  'completed', 'Sold 2500 DOGE',                 'd0e1f2a7b8c9d0e1f2a7b8c9d0e1f2a7', now() - interval '7 days'),
    (target_user_id, 'buy',     'BTC',  'Bitcoin',   0.08,    65100.00,  5208.00,   7.81,  'completed', 'Bought 0.08 BTC',                'e1f2a7b8c9d0e1f2a7b8c9d0e1f2a7b8', now() - interval '3 days'),
    (target_user_id, 'receive', 'ETH',  'Ethereum',  0.25,    3640.00,   910.00,    0.00,  'completed', 'Received 0.25 ETH from wallet',  'f2a7b8c9d0e1f2a7b8c9d0e1f2a7b8c9', now() - interval '1 day');
END;
$function$;

CREATE OR REPLACE FUNCTION public.seed_default_fiat_balances(p_user_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'A user id is required';
  END IF;

  WITH defaults(currency, name, sort_order) AS (
    VALUES
      ('USD'::text, 'US Dollar'::text, 0),
      ('EUR'::text, 'Euro'::text, 1),
      ('CAD'::text, 'Canadian Dollar'::text, 2),
      ('CHF'::text, 'Swiss Franc'::text, 3)
  ),
  current_position AS (
    SELECT COALESCE(MAX(display_order), -1) AS max_order
    FROM public.fiat_balances
    WHERE user_id = p_user_id
  ),
  missing AS (
    SELECT
      defaults.currency,
      defaults.name,
      ROW_NUMBER() OVER (ORDER BY defaults.sort_order) - 1 AS position_offset
    FROM defaults
    WHERE NOT EXISTS (
      SELECT 1
      FROM public.fiat_balances AS existing
      WHERE existing.user_id = p_user_id
        AND existing.currency = defaults.currency
    )
  )
  INSERT INTO public.fiat_balances (
    user_id,
    currency,
    name,
    balance,
    status,
    display_order
  )
  SELECT
    p_user_id,
    missing.currency,
    missing.name,
    0,
    'available',
    (current_position.max_order + missing.position_offset + 1)::integer
  FROM missing
  CROSS JOIN current_position
  ON CONFLICT (user_id, currency) DO NOTHING;
END;
$function$;

CREATE OR REPLACE FUNCTION public.set_tax_summary_card(target_user_id uuid, target_status text, target_amount numeric, target_currency text)
 RETURNS SETOF tax_summary_cards
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  normalized_currency text := upper(trim(target_currency));
  summary_status text;
BEGIN
  IF NOT public.is_admin_user() THEN
    RAISE EXCEPTION 'Admin access required';
  END IF;

  IF target_status NOT IN ('pending', 'on_hold', 'paid') THEN
    RAISE EXCEPTION 'Invalid tax status';
  END IF;

  IF target_amount < 0 THEN
    RAISE EXCEPTION 'Tax amount cannot be negative';
  END IF;

  IF normalized_currency !~ '^[A-Z]{3}$' THEN
    RAISE EXCEPTION 'Currency must be a three-letter ISO code';
  END IF;

  FOREACH summary_status IN ARRAY ARRAY['pending', 'on_hold', 'paid']
  LOOP
    INSERT INTO public.tax_summary_cards (user_id, status, amount, currency, updated_at)
    VALUES (
      target_user_id,
      summary_status,
      CASE WHEN summary_status = target_status THEN target_amount ELSE 0 END,
      normalized_currency,
      now()
    )
    ON CONFLICT (user_id, status) DO UPDATE
    SET
      amount = CASE
        WHEN tax_summary_cards.status = target_status THEN target_amount
        ELSE tax_summary_cards.amount
      END,
      currency = normalized_currency,
      updated_at = now();
  END LOOP;

  RETURN QUERY
  SELECT *
  FROM public.tax_summary_cards
  WHERE user_id = target_user_id
  ORDER BY status;
END;
$function$;

CREATE OR REPLACE FUNCTION public.snapshot_crypto_balance()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  usd_rate numeric;
BEGIN
  CASE NEW.symbol
    WHEN 'BTC' THEN usd_rate := 62000;
    WHEN 'ETH' THEN usd_rate := 3400;
    WHEN 'SOL' THEN usd_rate := 145;
    WHEN 'USDC' THEN usd_rate := 1;
    WHEN 'USDT' THEN usd_rate := 1;
    ELSE usd_rate := 1;
  END CASE;

  INSERT INTO balance_snapshots (user_id, asset_type, symbol, balance, balance_usd, snapshot_date)
  VALUES (NEW.user_id, 'crypto', NEW.symbol, NEW.balance, NEW.balance * usd_rate, CURRENT_DATE);

  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.snapshot_fiat_balance()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  usd_rate numeric;
BEGIN
  CASE NEW.currency
    WHEN 'USD' THEN usd_rate := 1;
    WHEN 'EUR' THEN usd_rate := 1.08;
    WHEN 'CAD' THEN usd_rate := 0.74;
    ELSE usd_rate := 1;
  END CASE;

  INSERT INTO balance_snapshots (user_id, asset_type, symbol, balance, balance_usd, snapshot_date)
  VALUES (NEW.user_id, 'fiat', NEW.currency, NEW.balance, NEW.balance * usd_rate, CURRENT_DATE);

  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.submit_kyc_verification(p_date_of_birth date, p_nationality text, p_id_type text, p_id_number text, p_id_front_url text, p_id_back_url text, p_selfie_url text, p_address_line1 text, p_address_line2 text, p_city text, p_state text, p_postal_code text, p_country text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_user_id uuid := auth.uid();
  v_current_status text;
  v_submission_id uuid;
  v_storage_prefix text;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication is required';
  END IF;

  SELECT kyc_status
  INTO v_current_status
  FROM public.profiles
  WHERE id = v_user_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'User profile not found';
  END IF;

  IF v_current_status IN ('submitted', 'approved') THEN
    SELECT id
    INTO v_submission_id
    FROM public.kyc_submissions
    WHERE user_id = v_user_id
    ORDER BY submitted_at DESC
    LIMIT 1;

    RETURN v_submission_id;
  END IF;

  IF v_current_status NOT IN ('pending', 'rejected') THEN
    RAISE EXCEPTION 'Identity verification cannot be submitted from status %', v_current_status;
  END IF;

  IF p_date_of_birth IS NULL
    OR p_date_of_birth > (current_date - interval '18 years')::date
    OR p_date_of_birth < (current_date - interval '120 years')::date THEN
    RAISE EXCEPTION 'A valid adult date of birth is required';
  END IF;

  IF btrim(COALESCE(p_nationality, '')) = ''
    OR btrim(COALESCE(p_id_number, '')) = ''
    OR btrim(COALESCE(p_address_line1, '')) = ''
    OR btrim(COALESCE(p_city, '')) = ''
    OR btrim(COALESCE(p_postal_code, '')) = ''
    OR btrim(COALESCE(p_country, '')) = '' THEN
    RAISE EXCEPTION 'All required identity and address fields must be provided';
  END IF;

  IF p_id_type NOT IN ('passport', 'drivers_license', 'national_id') THEN
    RAISE EXCEPTION 'Unsupported identity document type';
  END IF;

  v_storage_prefix := v_user_id::text || '/';

  IF COALESCE(p_id_front_url, '') NOT LIKE (v_storage_prefix || '%')
    OR COALESCE(p_selfie_url, '') NOT LIKE (v_storage_prefix || '%')
    OR (p_id_type <> 'passport' AND COALESCE(p_id_back_url, '') NOT LIKE (v_storage_prefix || '%'))
    OR (COALESCE(p_id_back_url, '') <> '' AND p_id_back_url NOT LIKE (v_storage_prefix || '%')) THEN
    RAISE EXCEPTION 'KYC document paths must belong to the authenticated user';
  END IF;

  INSERT INTO public.kyc_submissions (
    user_id,
    date_of_birth,
    nationality,
    id_type,
    id_number,
    id_front_url,
    id_back_url,
    selfie_url,
    address_line1,
    address_line2,
    city,
    state,
    postal_code,
    country
  )
  VALUES (
    v_user_id,
    p_date_of_birth,
    btrim(p_nationality),
    p_id_type,
    btrim(p_id_number),
    p_id_front_url,
    COALESCE(p_id_back_url, ''),
    p_selfie_url,
    btrim(p_address_line1),
    btrim(COALESCE(p_address_line2, '')),
    btrim(p_city),
    btrim(COALESCE(p_state, '')),
    btrim(p_postal_code),
    btrim(p_country)
  )
  RETURNING id INTO v_submission_id;

  PERFORM set_config('app.kyc_submission_user_id', v_user_id::text, true);

  UPDATE public.profiles
  SET kyc_status = 'submitted'
  WHERE id = v_user_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Could not update identity verification status';
  END IF;

  RETURN v_submission_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.touch_interac_access_settings_updated_at()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.touch_tax_bank_payment_settings_updated_at()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.user_has_interac_access(target_user_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT COALESCE((
    SELECT enabled
    FROM public.interac_access_settings
    WHERE user_id = target_user_id
  ), false);
$function$;

ALTER TABLE public.crypto_wallets
  DROP CONSTRAINT IF EXISTS crypto_wallets_user_id_symbol_network_key,
  DROP COLUMN IF EXISTS chain_id,
  DROP COLUMN IF EXISTS token_contract,
  DROP COLUMN IF EXISTS token_decimals,
  DROP COLUMN IF EXISTS payment_uri_scheme;

ALTER TABLE public.crypto_wallets
  ADD CONSTRAINT crypto_wallets_user_id_symbol_key UNIQUE (user_id, symbol);

ALTER TABLE public.tax_wallet_addresses
  DROP COLUMN IF EXISTS symbol,
  DROP COLUMN IF EXISTS network,
  DROP COLUMN IF EXISTS chain_id,
  DROP COLUMN IF EXISTS token_contract,
  DROP COLUMN IF EXISTS token_decimals,
  DROP COLUMN IF EXISTS payment_uri_scheme;

ALTER TABLE public.interac_access_settings
  ALTER COLUMN enabled SET DEFAULT true;

NOTIFY pgrst, 'reload schema';
