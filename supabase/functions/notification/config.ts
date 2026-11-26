// Provider configuration validation shared by the platform and admin APIs.
import { ApiError } from './http.ts';
import { PROVIDERS } from './adapters/index.ts';
import { allowedProviderUrl } from './adapters/http_generic.ts';

// deno-lint-ignore no-explicit-any
type Body = Record<string, any>;

const SECRETISH = /token|secret|password|private|key|auth/i;

export function validateProviderConfig(channel: string, cfg: unknown): Body | undefined {
  if (cfg === undefined) return undefined;
  if (!cfg || typeof cfg !== 'object' || Array.isArray(cfg) || JSON.stringify(cfg).length > 4096) {
    throw new ApiError(422, 'invalid_request', 'provider_config must be a small JSON object');
  }
  const c = cfg as Body;
  const provider = String(c.provider ?? 'mock').toLowerCase();
  if (!PROVIDERS[channel as keyof typeof PROVIDERS]?.includes(provider)) throw new ApiError(422, 'invalid_request', `Unsupported provider ${provider} for ${channel}`);
  for (const k of Object.keys(c)) {
    if (k !== 'secret_name' && SECRETISH.test(k)) throw new ApiError(422, 'invalid_request', `Put credentials in Vault and reference them with secret_name, not ${k}`);
  }
  if (provider === 'http') {
    if (typeof c.url !== 'string') throw new ApiError(422, 'invalid_request', 'http provider needs url');
    if (!c.url.includes('{{')) {
      try { allowedProviderUrl(c.url); } catch (e) { throw new ApiError(422, 'invalid_request', (e as Error).message); }
    }
    if (c.headers !== undefined && (typeof c.headers !== 'object' || Array.isArray(c.headers))) throw new ApiError(422, 'invalid_request', 'headers must be an object');
  }
  return { ...c, provider };
}

