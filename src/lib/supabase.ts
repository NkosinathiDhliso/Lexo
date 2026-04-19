/**
 * Supabase Client
 * Centralized Supabase client instance
 */

import { createClient } from '@supabase/supabase-js';

const pickFirstNonEmpty = (...values: Array<string | undefined>) => {
  for (const value of values) {
    const trimmed = value?.trim();
    if (trimmed) return trimmed;
  }
  return undefined;
};

const supabaseUrl = pickFirstNonEmpty(import.meta.env.VITE_SUPABASE_URL, import.meta.env.SUPABASE_URL);
const supabaseAnonKey = pickFirstNonEmpty(
  import.meta.env.VITE_SUPABASE_ANON_KEY,
  import.meta.env.SUPABASE_ANON_KEY
);

if (!supabaseUrl || !supabaseAnonKey) {
  const missing = [
    !supabaseUrl
      ? 'VITE_SUPABASE_URL (or SUPABASE_URL)'
      : null,
    !supabaseAnonKey
      ? 'VITE_SUPABASE_ANON_KEY (or SUPABASE_ANON_KEY)'
      : null,
  ]
    .filter(Boolean)
    .join(', ');

  throw new Error(
    `Missing Supabase environment variables: ${missing}. ` +
      'Set them in your .env or hosting environment and rebuild/redeploy the app.'
  );
}

export const supabase = createClient(supabaseUrl, supabaseAnonKey);
export { supabaseUrl };
