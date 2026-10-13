<?php

namespace ZeroMcp;

/**
 * Diagnostic logging. The STDERR constant only exists under the CLI SAPI; under
 * php -S, FPM or Apache it is undefined, so fall back to the server's error log.
 */
class Log
{
    public static function write(string $message): void
    {
        if (defined('STDERR')) {
            fwrite(STDERR, $message);
            return;
        }
        error_log(rtrim($message, "\n"));
    }
}
