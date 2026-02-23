# Booking & Scheduling -- Database Schema

PostgreSQL schema for a production-ready booking system. Includes double-booking prevention via `btree_gist` exclusion constraints, row-level security (RLS) for multi-tenancy, and time-slot availability functions.

## Architecture Highlights

- **Double-booking prevention** -- `btree_gist` exclusion constraint prevents overlapping bookings at the database level, not just application logic. See [`00009_bookings.sql`](migrations/00009_bookings.sql).

- **Row-Level Security (RLS)** -- Every table is protected with RLS policies scoped to the business owner. Uses the `(SELECT auth.uid())` pattern for optimal query-planner performance. See any table migration (e.g., [`00005_services.sql`](migrations/00005_services.sql)).

- **Slot availability calculation** -- A PL/pgSQL function computes available booking slots by intersecting staff availability windows with existing bookings. See [`00011_get_available_slots.sql`](migrations/00011_get_available_slots.sql).

- **Booking management** -- Cancel and reschedule logic with status tracking. See [`00017_booking_management.sql`](migrations/00017_booking_management.sql).

- **Stripe payment integration** -- Payment status tracking for paid bookings. See [`00018_stripe_payments.sql`](migrations/00018_stripe_payments.sql).

## Migrations

| File | Description |
|------|-------------|
| `00001_enable_extensions.sql` | Enable `btree_gist` and `pgcrypto` extensions |
| `00002_utility_functions.sql` | Helper functions |
| `00003_profiles.sql` | User profiles with RLS |
| `00004_businesses.sql` | Multi-tenant businesses |
| `00005_services.sql` | Services with RLS |
| `00006_staff.sql` | Staff with RLS |
| `00007_availability.sql` | Availability windows |
| `00008_customers.sql` | Customers with RLS |
| `00009_bookings.sql` | Bookings with `btree_gist` exclusion constraint |
| `00010_auto_rls_trigger.sql` | Auto-RLS function |
| `00011_get_available_slots.sql` | Slot availability function |
| `00017_booking_management.sql` | Cancel/reschedule logic |
| `00018_stripe_payments.sql` | Payment status tracking |

## Sample Data

[`seed.sql`](seed.sql) creates a demo business ("Acme Salon") with services, staff, availability, customers, and bookings. Useful for local development and demos.

## Usage

These migrations are designed for [Supabase](https://supabase.com) (PostgreSQL) and can be applied with:

```bash
supabase db reset  # Applies migrations + seed data
```

Or run them individually against any PostgreSQL database with `btree_gist` support.

## Part of the Booking & Scheduling Template

This schema is the database layer of the [Booking & Scheduling Template](https://cdjgroup.com) by CDJ Group -- a production-ready, full-stack booking system built with Next.js 15, Supabase, and Stripe.

## License

MIT -- see [LICENSE](LICENSE).
