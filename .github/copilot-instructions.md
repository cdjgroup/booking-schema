# Copilot Instructions for booking-schema

PostgreSQL schema for a production-ready booking system. Standalone SQL — no application code.

## Stack
- **Database**: PostgreSQL (Supabase-compatible)
- **Language**: PL/pgSQL

## Key Conventions
- btree_gist exclusion constraints prevent double-booking
- RLS multi-tenancy on all tables
- Slot availability functions for calendar queries
- All migrations are idempotent (IF NOT EXISTS patterns)
- Test with `supabase test db`
