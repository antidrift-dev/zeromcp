export interface ToolPermissions {
  network?: string[] | boolean;
  fs?: 'read' | 'write' | boolean;
  exec?: boolean;
}

interface SandboxedFetch {
  (input: string | URL | Request, init?: RequestInit): Promise<Response>;
}

export interface SandboxOptions {
  logging?: boolean;
  bypass?: boolean;
}

export function validatePermissions(name: string, permissions?: ToolPermissions): void {
  if (!permissions) return;

  const elevated = [];
  if (permissions.fs) elevated.push(`fs: ${permissions.fs}`);
  if (permissions.exec) elevated.push('exec');

  if (elevated.length) {
    console.error(`[zeromcp] ${name} requests elevated permissions: ${elevated.join(' | ')}`);
  }
}

function resolveHostname(input: string | URL | Request): string {
  const url = typeof input === 'string' ? new URL(input)
    : input instanceof URL ? input
    : new URL(input.url);
  return url.hostname;
}

function isAllowed(hostname: string, allowlist: string[]): boolean {
  return allowlist.some(pattern => {
    if (pattern.startsWith('*.')) {
      return hostname.endsWith(pattern.slice(1)) || hostname === pattern.slice(2);
    }
    return hostname === pattern;
  });
}

export function createSandboxedFetch(
  name: string,
  permissions?: ToolPermissions,
  opts?: SandboxOptions
): SandboxedFetch {
  const { logging, bypass } = opts || {};

  return async (input: string | URL | Request, init?: RequestInit): Promise<Response> => {
    const hostname = resolveHostname(input);
    const method = init?.method || 'GET';

    // No permissions or network not specified or true = full access
    if (!permissions || permissions.network === undefined || permissions.network === true) {
      if (logging) console.error(`[zeromcp] ${name} → ${method} ${hostname}`);
      return globalThis.fetch(input, init);
    }

    if (permissions.network === false) {
      if (bypass) {
        if (logging) console.error(`[zeromcp] ⚠ ${name} → ${method} ${hostname} (network disabled — bypassed)`);
        return globalThis.fetch(input, init);
      }
      if (logging) console.error(`[zeromcp] ${name} ✗ ${method} ${hostname} (network disabled)`);
      throw new Error(`[zeromcp] ${name}: network access denied`);
    }

    if (Array.isArray(permissions.network)) {
      if (!isAllowed(hostname, permissions.network)) {
        if (bypass) {
          if (logging) console.error(`[zeromcp] ⚠ ${name} → ${method} ${hostname} (not in allowlist — bypassed)`);
          return globalThis.fetch(input, init);
        }
        if (logging) console.error(`[zeromcp] ${name} ✗ ${method} ${hostname} (not in allowlist)`);
        throw new Error(
          `[zeromcp] ${name}: network access denied for ${hostname} (allowed: ${permissions.network.join(', ')})`
        );
      }
      if (logging) console.error(`[zeromcp] ${name} → ${method} ${hostname}`);
    }

    return globalThis.fetch(input, init);
  };
}

export function createSandboxedFs(
  name: string,
  permissions?: ToolPermissions,
  opts?: SandboxOptions
): Record<string, (...args: unknown[]) => never> | null {
  if (permissions?.fs) return null;

  const { bypass, logging } = opts || {};

  const deny = (method: string) => (..._args: unknown[]) => {
    if (bypass) {
      if (logging) console.error(`[zeromcp] ⚠ ${name} → fs.${method} (no permission — bypassed)`);
      return;
    }
    throw new Error(`[zeromcp] ${name}: fs.${method} denied`);
  };

  return new Proxy({}, {
    get: (_, prop) => deny(String(prop)),
  }) as Record<string, (...args: unknown[]) => never>;
}

export function createSandboxedExec(
  name: string,
  permissions?: ToolPermissions,
  opts?: SandboxOptions
): Record<string, (...args: unknown[]) => never> | null {
  if (permissions?.exec) return null;

  const { bypass, logging } = opts || {};

  const deny = (method: string) => (..._args: unknown[]) => {
    if (bypass) {
      if (logging) console.error(`[zeromcp] ⚠ ${name} → exec.${method} (no permission — bypassed)`);
      return;
    }
    throw new Error(`[zeromcp] ${name}: child_process.${method} denied`);
  };

  return new Proxy({}, {
    get: (_, prop) => deny(String(prop)),
  }) as Record<string, (...args: unknown[]) => never>;
}

export interface SandboxContext {
  fetch: SandboxedFetch;
}

export function createSandbox(
  name: string,
  permissions?: ToolPermissions,
  opts?: SandboxOptions
): SandboxContext {
  return {
    fetch: createSandboxedFetch(name, permissions, opts),
  };
}
