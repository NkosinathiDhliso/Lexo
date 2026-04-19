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

const stripWrappingQuotes = (value: string) => {
  if (
    (value.startsWith('"') && value.endsWith('"')) ||
    (value.startsWith("'") && value.endsWith("'"))
  ) {
    return value.slice(1, -1).trim();
  }
  return value;
};

const isPlaceholderValue = (value: string) => {
  const normalized = value.toLowerCase();
  return (
    normalized.includes('your_supabase') ||
    normalized.includes('your-project') ||
    normalized.includes('your_project') ||
    normalized.includes('placeholder')
  );
};

const normalizeSupabaseUrl = (value: string) => {
  const cleaned = stripWrappingQuotes(value.trim());

  // Allow project-ref-only format and normalize to full URL.
  if (/^[a-z0-9-]{20}$/i.test(cleaned)) {
    return `https://${cleaned}.supabase.co`;
  }

  // Allow host-only format without protocol.
  if (/^[a-z0-9-]+\.supabase\.co$/i.test(cleaned)) {
    return `https://${cleaned}`;
  }

  return cleaned;
};

const isValidHttpUrl = (value: string) => {
  try {
    const parsed = new URL(value);
    return parsed.protocol === 'http:' || parsed.protocol === 'https:';
  } catch {
    return false;
  }
};

const looksLikeJwt = (value: string) => value.startsWith('eyJ') && value.split('.').length === 3;

const deriveSupabaseUrlFromAnonKey = (anonKey: string) => {
  if (!looksLikeJwt(anonKey)) return undefined;

  const parts = anonKey.split('.');
  if (parts.length < 2) return undefined;

  try {
    const base64Url = parts[1];
    const base64 = base64Url.replace(/-/g, '+').replace(/_/g, '/');
    const padded = base64.padEnd(base64.length + ((4 - (base64.length % 4)) % 4), '=');
    const decoded = atob(padded);
    const payload = JSON.parse(decoded) as { ref?: string };

    if (payload.ref && /^[a-z0-9-]{20}$/i.test(payload.ref)) {
      return `https://${payload.ref}.supabase.co`;
    }
  } catch {
    return undefined;
  }

  return undefined;
};

let supabaseUrl = pickFirstNonEmpty(import.meta.env.VITE_SUPABASE_URL, import.meta.env.SUPABASE_URL);
let supabaseAnonKey = pickFirstNonEmpty(
  import.meta.env.VITE_SUPABASE_ANON_KEY,
  import.meta.env.SUPABASE_ANON_KEY
);

if (supabaseUrl) {
  supabaseUrl = normalizeSupabaseUrl(supabaseUrl);
}

if (supabaseAnonKey) {
  supabaseAnonKey = stripWrappingQuotes(supabaseAnonKey.trim());
}

// Guard against accidentally swapped env vars.
if (supabaseUrl && supabaseAnonKey && looksLikeJwt(supabaseUrl) && isValidHttpUrl(supabaseAnonKey)) {
  const swappedUrl = supabaseAnonKey;
  const swappedKey = supabaseUrl;
  supabaseUrl = swappedUrl;
  supabaseAnonKey = swappedKey;
  console.warn(
    'Supabase environment variables appear to be swapped. ' +
      'Using VITE/SUPABASE_ANON_KEY as URL and VITE/SUPABASE_URL as anon key.'
  );
}

if (supabaseAnonKey && (!supabaseUrl || isPlaceholderValue(supabaseUrl) || !isValidHttpUrl(supabaseUrl))) {
  const derivedUrl = deriveSupabaseUrlFromAnonKey(supabaseAnonKey);
  if (derivedUrl) {
    supabaseUrl = derivedUrl;
    console.warn(
      'Supabase URL was missing or invalid. Derived URL from anon key payload and continuing with that value.'
    );
  }
}

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

if (isPlaceholderValue(supabaseUrl) || !isValidHttpUrl(supabaseUrl)) {
  throw new Error(
    `Invalid Supabase URL "${supabaseUrl}". ` +
      'Set VITE_SUPABASE_URL (or SUPABASE_URL) to a valid URL such as ' +
      'https://<project-ref>.supabase.co, then rebuild/redeploy.'
  );
}

if (isPlaceholderValue(supabaseAnonKey)) {
  throw new Error(
    'Invalid Supabase anon key placeholder detected. ' +
      'Set VITE_SUPABASE_ANON_KEY (or SUPABASE_ANON_KEY) to your real anon key, then rebuild/redeploy.'
  );
}

export const supabase = createClient(supabaseUrl, supabaseAnonKey);
export { supabaseUrl };
