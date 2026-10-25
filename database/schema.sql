-- ============================================================================
-- Zapp Survival Arena — PostgreSQL Database Schema
-- Compatible with Supabase, Neon, and Standard PostgreSQL 14+
-- ============================================================================

-- 1. Accounts Table: Authoritative player profiles & career statistics
CREATE TABLE IF NOT EXISTS accounts (
    username VARCHAR(32) PRIMARY KEY,
    token_hash VARCHAR(64) NOT NULL,
    wins INTEGER NOT NULL DEFAULT 0 CHECK (wins >= 0),
    losses INTEGER NOT NULL DEFAULT 0 CHECK (losses >= 0),
    draws INTEGER NOT NULL DEFAULT 0 CHECK (draws >= 0),
    matches_played INTEGER NOT NULL DEFAULT 0 CHECK (matches_played >= 0),
    eliminations INTEGER NOT NULL DEFAULT 0 CHECK (eliminations >= 0),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Index for instant global leaderboard queries:
-- Ordered by Wins DESC, Eliminations DESC, Matches Played DESC
CREATE INDEX IF NOT EXISTS idx_accounts_leaderboard
    ON accounts (wins DESC, eliminations DESC, matches_played DESC);

-- Index for token lookups
CREATE INDEX IF NOT EXISTS idx_accounts_token_hash
    ON accounts (token_hash);


-- 2. Match History Table: Global log of completed matches
CREATE TABLE IF NOT EXISTS match_history (
    session_id VARCHAR(64) PRIMARY KEY,
    timestamp TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    is_draw BOOLEAN NOT NULL DEFAULT FALSE,
    winner_name VARCHAR(32) NOT NULL DEFAULT 'NONE',
    rounds INTEGER NOT NULL DEFAULT 1 CHECK (rounds >= 1),
    final_stage INTEGER NOT NULL DEFAULT 1 CHECK (final_stage BETWEEN 1 AND 4),
    participants TEXT[] NOT NULL DEFAULT '{}'
);

-- Index for recent match history
CREATE INDEX IF NOT EXISTS idx_match_history_timestamp
    ON match_history (timestamp DESC);


-- 3. Row-Level Security (RLS) Configuration (for Supabase / PostgREST)
ALTER TABLE accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE match_history ENABLE ROW LEVEL SECURITY;

-- Allow public read access to leaderboard and public accounts
CREATE POLICY "Allow public read on accounts"
    ON accounts FOR SELECT
    USING (true);

-- Allow public read access on match history
CREATE POLICY "Allow public read on match history"
    ON match_history FOR SELECT
    USING (true);

-- Allow service role / authenticated backend full access
CREATE POLICY "Allow service insert/update on accounts"
    ON accounts FOR ALL
    USING (auth.role() = 'service_role' OR auth.role() = 'anon')
    WITH CHECK (true);

CREATE POLICY "Allow service insert on match history"
    ON match_history FOR ALL
    USING (auth.role() = 'service_role' OR auth.role() = 'anon')
    WITH CHECK (true);
