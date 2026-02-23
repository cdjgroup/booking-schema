-- Seed data for local development
-- Runs on `supabase db reset`, NOT on production deploys.
-- Creates a test business "Acme Salon" with services, staff, availability,
-- a customer, and a sample booking.
--
-- UUID convention: hex-only prefixes for readability
-- User:     aaaa0001-...  Staff:    cccc0001-...  Customer: eeee0001-...
-- Business: bbbb0001-...  Service:  dddd0001-...

-- ============================================================
-- 1. Create test auth user
-- ============================================================
-- Supabase's auth schema handles user creation. We use the
-- supabase_auth_admin role to insert directly into auth.users.
-- The handle_new_user() trigger auto-creates the profiles row.
INSERT INTO auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at,
  confirmation_token, recovery_token,
  raw_app_meta_data, raw_user_meta_data
) VALUES (
  '00000000-0000-0000-0000-000000000000',
  'aaaa0001-0000-0000-0000-000000000001',
  'authenticated', 'authenticated',
  'owner@example.com',
  crypt('password123', gen_salt('bf')),
  NOW(), NOW(), NOW(),
  '', '',
  '{"provider":"email","providers":["email"]}',
  '{"full_name":"Test Owner"}'
);

-- Also insert into auth.identities (required by Supabase auth)
INSERT INTO auth.identities (
  id, user_id, provider_id, provider, identity_data, last_sign_in_at, created_at, updated_at
) VALUES (
  'aaaa0001-0000-0000-0000-000000000001',
  'aaaa0001-0000-0000-0000-000000000001',
  'aaaa0001-0000-0000-0000-000000000001',
  'email',
  '{"sub":"aaaa0001-0000-0000-0000-000000000001","email":"owner@example.com"}',
  NOW(), NOW(), NOW()
);

-- ============================================================
-- 2. Create business
-- ============================================================
INSERT INTO public.businesses (id, owner_id, name, slug, description, timezone)
VALUES (
  'bbbb0001-0000-0000-0000-000000000001',
  'aaaa0001-0000-0000-0000-000000000001',
  'Acme Salon',
  'acme-salon',
  'Full-service hair salon in downtown Springfield',
  'America/New_York'
);

-- ============================================================
-- 3. Create services
-- ============================================================
INSERT INTO public.services (id, business_id, name, description, duration_min, price_cents, color, sort_order) VALUES
  ('dddd0001-0000-0000-0000-000000000001', 'bbbb0001-0000-0000-0000-000000000001', 'Haircut',       'Classic haircut and style',    30, 2500, '#3B82F6', 1),
  ('dddd0001-0000-0000-0000-000000000002', 'bbbb0001-0000-0000-0000-000000000001', 'Hair Coloring', 'Full color treatment',         90, 8500, '#8B5CF6', 2),
  ('dddd0001-0000-0000-0000-000000000003', 'bbbb0001-0000-0000-0000-000000000001', 'Consultation',  'Free initial consultation',    15,    0, '#10B981', 3);

-- ============================================================
-- 4. Create staff
-- ============================================================
INSERT INTO public.staff (id, business_id, user_id, name, email, role) VALUES
  ('cccc0001-0000-0000-0000-000000000001', 'bbbb0001-0000-0000-0000-000000000001', 'aaaa0001-0000-0000-0000-000000000001', 'Alice Johnson', 'alice@acmesalon.com', 'owner'),
  ('cccc0001-0000-0000-0000-000000000002', 'bbbb0001-0000-0000-0000-000000000001', NULL,                                   'Bob Smith',     'bob@acmesalon.com',   'provider');

-- ============================================================
-- 5. Create availability
-- ============================================================
-- Alice: Mon-Fri 9:00-17:00
INSERT INTO public.availability (staff_id, day_of_week, start_time, end_time) VALUES
  ('cccc0001-0000-0000-0000-000000000001', 1, '09:00', '17:00'),
  ('cccc0001-0000-0000-0000-000000000001', 2, '09:00', '17:00'),
  ('cccc0001-0000-0000-0000-000000000001', 3, '09:00', '17:00'),
  ('cccc0001-0000-0000-0000-000000000001', 4, '09:00', '17:00'),
  ('cccc0001-0000-0000-0000-000000000001', 5, '09:00', '17:00');

-- Bob: Mon-Wed 10:00-18:00, Thu-Fri 8:00-16:00
INSERT INTO public.availability (staff_id, day_of_week, start_time, end_time) VALUES
  ('cccc0001-0000-0000-0000-000000000002', 1, '10:00', '18:00'),
  ('cccc0001-0000-0000-0000-000000000002', 2, '10:00', '18:00'),
  ('cccc0001-0000-0000-0000-000000000002', 3, '10:00', '18:00'),
  ('cccc0001-0000-0000-0000-000000000002', 4, '08:00', '16:00'),
  ('cccc0001-0000-0000-0000-000000000002', 5, '08:00', '16:00');

-- ============================================================
-- 6. Create customers
-- ============================================================
INSERT INTO public.customers (id, business_id, name, email, phone) VALUES
  ('eeee0001-0000-0000-0000-000000000001', 'bbbb0001-0000-0000-0000-000000000001', 'Jane Doe',     'jane@example.com',    '+1-555-0123'),
  ('eeee0001-0000-0000-0000-000000000002', 'bbbb0001-0000-0000-0000-000000000001', 'Carlos Rivera', 'carlos@example.com', '+1-555-0456'),
  ('eeee0001-0000-0000-0000-000000000003', 'bbbb0001-0000-0000-0000-000000000001', 'Priya Patel',   'priya@example.com',  '+1-555-0789');

-- ============================================================
-- 7. Create sample bookings (spread across next 7 days for a realistic demo)
-- ============================================================
INSERT INTO public.bookings (
  business_id, service_id, staff_id, customer_id,
  starts_at, ends_at, status, notes
) VALUES
  -- Tomorrow 10am: Jane, Haircut with Alice
  (
    'bbbb0001-0000-0000-0000-000000000001',
    'dddd0001-0000-0000-0000-000000000001',
    'cccc0001-0000-0000-0000-000000000001',
    'eeee0001-0000-0000-0000-000000000001',
    (CURRENT_DATE + INTERVAL '1 day' + INTERVAL '10 hours')::timestamptz,
    (CURRENT_DATE + INTERVAL '1 day' + INTERVAL '10 hours 30 minutes')::timestamptz,
    'confirmed',
    'First-time customer'
  ),
  -- Tomorrow 2pm: Carlos, Hair Coloring with Bob
  (
    'bbbb0001-0000-0000-0000-000000000001',
    'dddd0001-0000-0000-0000-000000000002',
    'cccc0001-0000-0000-0000-000000000002',
    'eeee0001-0000-0000-0000-000000000002',
    (CURRENT_DATE + INTERVAL '1 day' + INTERVAL '14 hours')::timestamptz,
    (CURRENT_DATE + INTERVAL '1 day' + INTERVAL '15 hours 30 minutes')::timestamptz,
    'confirmed',
    'Regular color touch-up'
  ),
  -- Day 3, 11am: Priya, Consultation with Alice
  (
    'bbbb0001-0000-0000-0000-000000000001',
    'dddd0001-0000-0000-0000-000000000003',
    'cccc0001-0000-0000-0000-000000000001',
    'eeee0001-0000-0000-0000-000000000003',
    (CURRENT_DATE + INTERVAL '3 days' + INTERVAL '11 hours')::timestamptz,
    (CURRENT_DATE + INTERVAL '3 days' + INTERVAL '11 hours 15 minutes')::timestamptz,
    'confirmed',
    'Wants to discuss wedding party styles'
  ),
  -- Day 5, 9am: Jane, Hair Coloring with Alice
  (
    'bbbb0001-0000-0000-0000-000000000001',
    'dddd0001-0000-0000-0000-000000000002',
    'cccc0001-0000-0000-0000-000000000001',
    'eeee0001-0000-0000-0000-000000000001',
    (CURRENT_DATE + INTERVAL '5 days' + INTERVAL '9 hours')::timestamptz,
    (CURRENT_DATE + INTERVAL '5 days' + INTERVAL '10 hours 30 minutes')::timestamptz,
    'confirmed',
    'Full balayage treatment'
  ),
  -- Day 6, 3pm: Carlos, Haircut with Bob
  (
    'bbbb0001-0000-0000-0000-000000000001',
    'dddd0001-0000-0000-0000-000000000001',
    'cccc0001-0000-0000-0000-000000000002',
    'eeee0001-0000-0000-0000-000000000002',
    (CURRENT_DATE + INTERVAL '6 days' + INTERVAL '15 hours')::timestamptz,
    (CURRENT_DATE + INTERVAL '6 days' + INTERVAL '15 hours 30 minutes')::timestamptz,
    'confirmed',
    NULL
  );
