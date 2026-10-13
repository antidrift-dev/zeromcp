<?php

namespace ZeroMcp;

class Sandbox
{
    public static function checkNetworkAccess(
        string $toolName,
        string $hostname,
        array $permissions,
        bool $bypass = false,
        bool $logging = false
    ): bool {
        $network = $permissions['network'] ?? null;

        // No permissions or network not specified = full access
        if ($network === null) {
            if ($logging) self::log("$toolName -> $hostname");
            return true;
        }

        // network: true = full access
        if ($network === true) {
            if ($logging) self::log("$toolName -> $hostname");
            return true;
        }

        // network: false = denied
        if ($network === false) {
            if ($bypass) {
                if ($logging) self::log("! $toolName -> $hostname (network disabled -- bypassed)");
                return true;
            }
            if ($logging) self::log("$toolName x $hostname (network disabled)");
            return false;
        }

        // network: [] (empty array) = denied
        if (is_array($network) && empty($network)) {
            if ($bypass) {
                if ($logging) self::log("! $toolName -> $hostname (network disabled -- bypassed)");
                return true;
            }
            if ($logging) self::log("$toolName x $hostname (network disabled)");
            return false;
        }

        // network: ["host1", "*.host2"] = allowlist
        if (is_array($network)) {
            if (self::isAllowed($hostname, $network)) {
                if ($logging) self::log("$toolName -> $hostname");
                return true;
            }
            if ($bypass) {
                if ($logging) self::log("! $toolName -> $hostname (not in allowlist -- bypassed)");
                return true;
            }
            if ($logging) self::log("$toolName x $hostname (not in allowlist)");
            return false;
        }

        // Unknown type — allow by default
        return true;
    }

    public static function isAllowed(string $hostname, array $allowlist): bool
    {
        foreach ($allowlist as $pattern) {
            if (str_starts_with($pattern, '*.')) {
                $suffix = substr($pattern, 1); // e.g. ".example.com"
                $base = substr($pattern, 2);   // e.g. "example.com"
                if (str_ends_with($hostname, $suffix) || $hostname === $base) {
                    return true;
                }
            } elseif ($hostname === $pattern) {
                return true;
            }
        }
        return false;
    }

    public static function extractHostname(string $url): string
    {
        $parsed = parse_url($url);
        return $parsed['host'] ?? $url;
    }

    private static function log(string $msg): void
    {
        Log::write("[zeromcp] $msg\n");
    }
}
