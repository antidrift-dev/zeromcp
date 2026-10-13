<?php

/**
 * Starts router.php under `php -S` on a free local port for the remote tests.
 */
final class FakeUpstream
{
    /** @var resource|null */
    private $proc = null;
    public int $port;

    public function start(): string
    {
        $sock = stream_socket_server('tcp://127.0.0.1:0');
        $name = stream_socket_get_name($sock, false);
        fclose($sock);
        $this->port = (int) substr($name, strrpos($name, ':') + 1);

        $cmd = [PHP_BINARY, '-S', "127.0.0.1:{$this->port}", __DIR__ . '/router.php'];
        $this->proc = proc_open($cmd, [0 => ['pipe', 'r'], 1 => ['file', '/dev/null', 'w'], 2 => ['file', '/dev/null', 'w']], $pipes);

        $deadline = microtime(true) + 5;
        while (microtime(true) < $deadline) {
            $c = @fsockopen('127.0.0.1', $this->port, $errno, $errstr, 0.2);
            if ($c) {
                fclose($c);
                return $this->url();
            }
            usleep(50000);
        }
        $this->stop();
        throw new RuntimeException("fake upstream did not start on port {$this->port}");
    }

    public function url(string $path = '/'): string
    {
        return "http://127.0.0.1:{$this->port}$path";
    }

    public function stop(): void
    {
        if ($this->proc !== null) {
            proc_terminate($this->proc);
            proc_close($this->proc);
            $this->proc = null;
        }
    }
}
