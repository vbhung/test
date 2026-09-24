-- cam_engine.sql
-- Atomic transaction functions used by the application.

CREATE OR REPLACE FUNCTION get_referral_commission_rate(
  p_referrer_id UUID,
  p_referee_id UUID
) RETURNS NUMERIC(4,2) AS $$
DECLARE
  v_rank INTEGER;
BEGIN
  SELECT COUNT(*) + 1 INTO v_rank
  FROM profiles
  WHERE referred_by = p_referrer_id
    AND created_at < (SELECT created_at FROM profiles WHERE id = p_referee_id);

  IF v_rank IS NULL OR v_rank < 1 THEN
    v_rank := 1;
  END IF;

  IF v_rank <= 1 THEN RETURN 0.15;
  ELSIF v_rank = 2 THEN RETURN 0.13;
  ELSIF v_rank <= 4 THEN RETURN 0.10;
  ELSIF v_rank <= 9 THEN RETURN 0.07;
  ELSIF v_rank <= 19 THEN RETURN 0.05;
  ELSIF v_rank <= 49 THEN RETURN 0.02;
  ELSE RETURN 0.01;
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION process_cam_transaction(
  p_user_id UUID,
  p_type TEXT,
  p_amount NUMERIC(12,4),
  p_description TEXT,
  p_ref_id UUID DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
  v_balance_before NUMERIC(12,4);
  v_balance_after NUMERIC(12,4);
  v_tx_id UUID;
  v_referred_by UUID;
  v_referral_bonus NUMERIC(12,4);
  v_actual_amount NUMERIC(12,4);
BEGIN
  SELECT cam_balance, referred_by
    INTO v_balance_before, v_referred_by
  FROM profiles
  WHERE id = p_user_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'USER_PROFILE_NOT_FOUND';
  END IF;

  IF p_amount <= 0 THEN
    RAISE EXCEPTION 'INVALID_AMOUNT';
  END IF;

  v_actual_amount := p_amount;

  IF p_type IN ('earn', 'transfer_in', 'referral_bonus', 'admin_adjust_add', 'earn_review_release') THEN
    v_balance_after := v_balance_before + v_actual_amount;
  ELSIF p_type IN ('transfer_out', 'fee', 'redeem', 'admin_adjust_sub', 'earn_review_hold') THEN
    IF v_balance_before < p_amount THEN
      RAISE EXCEPTION 'INSUFFICIENT_BALANCE';
    END IF;
    v_balance_after := v_balance_before - p_amount;
  ELSE
    RAISE EXCEPTION 'INVALID_TRANSACTION_TYPE';
  END IF;

  UPDATE profiles
  SET
    cam_balance = v_balance_after,
    cam_total_earned = CASE
      WHEN p_type IN ('earn', 'referral_bonus', 'admin_adjust_add') THEN cam_total_earned + v_actual_amount
      ELSE cam_total_earned
    END,
    updated_at = NOW()
  WHERE id = p_user_id;

  INSERT INTO cam_transactions (
    user_id,
    type,
    amount,
    balance_before,
    balance_after,
    description,
    ref_id
  ) VALUES (
    p_user_id,
    p_type::cam_tx_type,
    v_actual_amount,
    v_balance_before,
    v_balance_after,
    p_description,
    p_ref_id
  ) RETURNING id INTO v_tx_id;

  IF p_type = 'earn' AND v_referred_by IS NOT NULL THEN
    IF EXISTS (SELECT 1 FROM referral_suspensions WHERE user_id = v_referred_by AND status = 'suspended') THEN
      v_referral_bonus := 0;
    ELSE
      v_referral_bonus := ROUND(p_amount * get_referral_commission_rate(v_referred_by, p_user_id), 4);
    END IF;

    IF v_referral_bonus > 0 THEN
      PERFORM process_cam_transaction(
        v_referred_by,
        'referral_bonus',
        v_referral_bonus,
        'Hoa hong gioi thieu tu thanh vien cap duoi',
        v_tx_id
      );

      INSERT INTO referral_earnings (referrer_id, referee_id, tx_id, amount)
      VALUES (v_referred_by, p_user_id, v_tx_id, v_referral_bonus);
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'tx_id', v_tx_id,
    'new_balance', v_balance_after
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION process_cam_transfer(
  p_sender_id UUID,
  p_recipient_username TEXT,
  p_total_deduction NUMERIC(12,4),
  p_fee NUMERIC(12,4),
  p_note TEXT DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
  v_sender profiles%ROWTYPE;
  v_receiver profiles%ROWTYPE;
  v_transfer_amount NUMERIC(12,4);
  v_transfer_id UUID;
BEGIN
  IF p_total_deduction <= 0 OR p_fee < 0 THEN
    RAISE EXCEPTION 'INVALID_TRANSFER_AMOUNT';
  END IF;

  v_transfer_amount := p_total_deduction - p_fee;
  IF v_transfer_amount <= 0 THEN
    RAISE EXCEPTION 'INVALID_TRANSFER_AMOUNT';
  END IF;

  SELECT *
    INTO v_sender
  FROM profiles
  WHERE id = p_sender_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'SENDER_NOT_FOUND';
  END IF;

  SELECT *
    INTO v_receiver
  FROM profiles
  WHERE lower(username) = lower(p_recipient_username);

  IF NOT FOUND THEN
    RAISE EXCEPTION 'RECIPIENT_NOT_FOUND';
  END IF;

  IF v_sender.id = v_receiver.id THEN
    RAISE EXCEPTION 'SELF_TRANSFER';
  END IF;

  -- Khong cho chuyen Cam giua nguoi co quan he referral (2 chieu)
  IF v_receiver.referred_by = v_sender.id OR v_sender.referred_by = v_receiver.id THEN
    RAISE EXCEPTION 'REFERRAL_TRANSFER_BLOCKED';
  END IF;

  IF v_sender.id < v_receiver.id THEN
    PERFORM 1 FROM profiles WHERE id = v_sender.id FOR UPDATE;
    PERFORM 1 FROM profiles WHERE id = v_receiver.id FOR UPDATE;
  ELSE
    PERFORM 1 FROM profiles WHERE id = v_receiver.id FOR UPDATE;
    PERFORM 1 FROM profiles WHERE id = v_sender.id FOR UPDATE;
  END IF;

  SELECT * INTO v_sender FROM profiles WHERE id = p_sender_id;
  SELECT * INTO v_receiver FROM profiles WHERE id = v_receiver.id;

  IF v_sender.cam_balance < p_total_deduction THEN
    RAISE EXCEPTION 'INSUFFICIENT_BALANCE';
  END IF;

  UPDATE profiles
  SET cam_balance = cam_balance - p_total_deduction, updated_at = NOW()
  WHERE id = v_sender.id;

  UPDATE profiles
  SET cam_balance = cam_balance + v_transfer_amount, updated_at = NOW()
  WHERE id = v_receiver.id;

  INSERT INTO transfers (sender_id, receiver_id, amount, fee, note, status)
  VALUES (v_sender.id, v_receiver.id, v_transfer_amount, p_fee, p_note, 'completed')
  RETURNING id INTO v_transfer_id;

  INSERT INTO cam_transactions (
    user_id, type, amount, balance_before, balance_after, ref_id, description
  ) VALUES
  (
    v_sender.id,
    'transfer_out',
    p_total_deduction,
    v_sender.cam_balance,
    v_sender.cam_balance - p_total_deduction,
    v_transfer_id,
    'Chuyen Cam cho ' || v_receiver.username || COALESCE(' - ' || p_note, '')
  ),
  (
    v_receiver.id,
    'transfer_in',
    v_transfer_amount,
    v_receiver.cam_balance,
    v_receiver.cam_balance + v_transfer_amount,
    v_transfer_id,
    'Nhan Cam tu ' || v_sender.username || COALESCE(' - ' || p_note, '')
  );

  RETURN jsonb_build_object(
    'transfer_id', v_transfer_id,
    'receiver_id', v_receiver.id,
    'receiver_username', v_receiver.username,
    'sender_username', v_sender.username,
    'transfer_amount', v_transfer_amount
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION process_redemption_request(
  p_user_id UUID,
  p_type redeem_type,
  p_amount_cam NUMERIC(12,4),
  p_amount_vnd NUMERIC(15,0),
  p_details JSONB
) RETURNS UUID AS $$
DECLARE
  v_result JSONB;
  v_ticket_id UUID;
  v_latest_redeem_at TIMESTAMPTZ;
  v_used_free_card_redeems INTEGER := 0;
  v_required_referrals INTEGER := 0;
  v_qualified_referrals INTEGER := 0;
BEGIN
  SELECT created_at
    INTO v_latest_redeem_at
  FROM redemptions
  WHERE user_id = p_user_id
    AND status <> 'rejected'
  ORDER BY created_at DESC
  LIMIT 1;

  IF v_latest_redeem_at IS NOT NULL AND v_latest_redeem_at > NOW() - INTERVAL '12 hours' THEN
    RAISE EXCEPTION 'REDEEM_COOLDOWN';
  END IF;

  IF p_type IN ('phone_card', 'game_card') THEN
    SELECT COUNT(*)
      INTO v_used_free_card_redeems
    FROM redemptions
    WHERE user_id = p_user_id
      AND type IN ('phone_card', 'game_card')
      AND status <> 'rejected';
  END IF;

  IF p_type = 'bank' OR v_used_free_card_redeems >= 3 THEN
    v_required_referrals := CASE
      WHEN p_amount_vnd <= 50000 THEN 1
      WHEN p_amount_vnd <= 100000 THEN 3
      WHEN p_amount_vnd <= 500000 THEN 5
      ELSE 10
    END;

    SELECT COUNT(*)
      INTO v_qualified_referrals
    FROM profiles referred
    WHERE referred.referred_by = p_user_id
      AND EXISTS (
        SELECT 1
        FROM earn_tasks task
        WHERE task.user_id = referred.id
          AND task.status = 'completed'
      );

    IF v_qualified_referrals < v_required_referrals THEN
      RAISE EXCEPTION 'QUALIFIED_REFERRALS_REQUIRED:%:%', v_required_referrals, v_qualified_referrals;
    END IF;
  END IF;

  v_result := process_cam_transaction(
    p_user_id,
    'redeem',
    p_amount_cam,
    'Tao yeu cau rut thuong',
    NULL
  );

  INSERT INTO redemptions (user_id, type, amount_cam, amount_vnd, status, details)
  VALUES (p_user_id, p_type, p_amount_cam, p_amount_vnd, 'pending', COALESCE(p_details, '{}'::jsonb))
  RETURNING id INTO v_ticket_id;

  RETURN v_ticket_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION process_redemption_decision(
  p_ticket_id UUID,
  p_status redeem_status,
  p_admin_note TEXT DEFAULT NULL,
  p_apply_fee BOOLEAN DEFAULT FALSE
) RETURNS UUID AS $$
DECLARE
  v_ticket redemptions%ROWTYPE;
  v_refund_amount NUMERIC(12,4);
  v_fee_amount NUMERIC(12,4) := 1;
  v_fee_note TEXT := '';
BEGIN
  IF p_status NOT IN ('completed', 'rejected') THEN
    RAISE EXCEPTION 'INVALID_REDEMPTION_STATUS';
  END IF;

  SELECT *
    INTO v_ticket
  FROM redemptions
  WHERE id = p_ticket_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'TICKET_NOT_FOUND';
  END IF;

  IF v_ticket.status <> 'pending' THEN
    RAISE EXCEPTION 'TICKET_ALREADY_PROCESSED';
  END IF;

  UPDATE redemptions
  SET
    status = p_status,
    admin_note = p_admin_note,
    processed_at = NOW()
  WHERE id = p_ticket_id;

  IF p_status = 'rejected' THEN
    -- Hoan tien day du theo default; chi tru phi 1 Cam khi admin chu dong apply_fee
    IF p_apply_fee AND v_ticket.amount_cam > v_fee_amount THEN
      v_refund_amount := v_ticket.amount_cam - v_fee_amount;
      v_fee_note := ' (tru 1 Cam phi lam phien)';
    ELSE
      v_refund_amount := v_ticket.amount_cam;
    END IF;

    IF v_refund_amount > 0 THEN
      PERFORM process_cam_transaction(
        v_ticket.user_id,
        'admin_adjust_add',
        v_refund_amount,
        'Hoan tien do rut bi tu choi' || v_fee_note,
        p_ticket_id
      );
    END IF;
  END IF;

  INSERT INTO notifications (user_id, title, body)
  VALUES (
    v_ticket.user_id,
    CASE WHEN p_status = 'completed' THEN 'Rút tiền thành công' ELSE 'Rút tiền thất bại' END,
    CASE
      WHEN p_status = 'completed' THEN
        'Yêu cầu rút ' || v_ticket.amount_vnd::TEXT || ' VND của bạn đã được thanh toán thành công.'
      ELSE
        'Yêu cầu rút của bạn đã bị từ chối và được hoàn tiền' || v_fee_note || '.'
    END || COALESCE(' Ghi chú: ' || p_admin_note, '')
  );

  RETURN v_ticket.user_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION process_earn_task_completion(
  p_task_id UUID,
  p_user_id UUID
) RETURNS JSONB AS $$
DECLARE
  v_task earn_tasks%ROWTYPE;
BEGIN
  SELECT *
    INTO v_task
  FROM earn_tasks
  WHERE id = p_task_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'TASK_NOT_FOUND';
  END IF;

  IF v_task.user_id <> p_user_id THEN
    RAISE EXCEPTION 'TASK_OWNER_MISMATCH';
  END IF;

  IF v_task.status <> 'pending' THEN
    RAISE EXCEPTION 'TASK_ALREADY_PROCESSED';
  END IF;

  UPDATE earn_tasks
  SET status = 'completed', completed_at = NOW()
  WHERE id = p_task_id;

  PERFORM process_cam_transaction(
    p_user_id,
    'earn',
    v_task.reward_cam,
    'Vuot link (' || v_task.provider_code || ')',
    v_task.id
  );

  RETURN jsonb_build_object('task_id', v_task.id, 'reward_cam', v_task.reward_cam);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- Bonus claim atomic: insert claim + cong Cam trong 1 transaction
-- Chong race condition (unique constraint + rollback tu dong)
-- ============================================================
CREATE OR REPLACE FUNCTION process_bonus_claim(
  p_user_id UUID,
  p_bonus_type TEXT,
  p_period TEXT,
  p_reward NUMERIC(12,4),
  p_description TEXT
) RETURNS JSONB AS $$
DECLARE
  v_tx_id UUID;
  v_claim_id UUID;
BEGIN
  IF p_reward <= 0 THEN
    RAISE EXCEPTION 'INVALID_REWARD';
  END IF;

  -- Insert claim (unique(user_id, bonus_type, period) se block duplicate)
  INSERT INTO bonus_claims (user_id, bonus_type, period)
  VALUES (p_user_id, p_bonus_type, p_period)
  RETURNING id INTO v_claim_id;

  -- Cong Cam atomic
  v_tx_id := (process_cam_transaction(
    p_user_id,
    'earn',
    p_reward,
    p_description,
    v_claim_id
  ) ->> 'tx_id')::UUID;

  RETURN jsonb_build_object('claim_id', v_claim_id, 'tx_id', v_tx_id, 'reward', p_reward);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- Lay thong ke shortlink (khong bi gioi han 1000 rows)
-- ============================================================
CREATE OR REPLACE FUNCTION get_earn_statistics()
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_total_users BIGINT;
  v_total_circulating NUMERIC;
  v_total_completions BIGINT;
  v_total_cam NUMERIC;
  v_provider_stats JSONB;
BEGIN
  SELECT COUNT(*) INTO v_total_users FROM profiles;

  SELECT COALESCE(SUM(cam_balance), 0) INTO v_total_circulating FROM profiles;

  SELECT COUNT(*), COALESCE(SUM(reward_cam), 0)
  INTO v_total_completions, v_total_cam
  FROM earn_tasks WHERE status = 'completed';

  SELECT COALESCE(JSONB_AGG(jsonb_build_object(
    'code', t.code,
    'name', COALESCE(p.name, t.code),
    'count', t.count,
    'totalCam', t.total_cam
  ) ORDER BY t.count DESC), '[]'::jsonb)
  INTO v_provider_stats
  FROM (
    SELECT provider_code AS code, COUNT(*) AS count, COALESCE(SUM(reward_cam), 0) AS total_cam
    FROM earn_tasks WHERE status = 'completed'
    GROUP BY provider_code
  ) t
  JOIN earn_providers p ON p.code = t.code AND p.is_active = true;

  RETURN jsonb_build_object(
    'totalUsers', v_total_users,
    'totalCirculating', v_total_circulating,
    'totalEarnCompletions', v_total_completions,
    'totalEarnCam', v_total_cam,
    'shortlinkStats', v_provider_stats
  );
END;
$$;
