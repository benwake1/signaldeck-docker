<?php

/**
 * Remove reservations on the cypress queue left behind by a previous
 * all-in-one container. Only called by the entrypoint for the "all" role.
 */

require '/var/www/app/vendor/autoload.php';

$app = require '/var/www/app/bootstrap/app.php';
$app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();

$connection = config('queue.connections.redis.connection', 'default');
$queue      = 'cypress';

$reserved = app('redis')->connection($connection)->zcard("queues:{$queue}:reserved");

if ($reserved > 0) {
    app('redis')->connection($connection)->del("queues:{$queue}:reserved");
    echo "[signaldeck] Cleared {$reserved} stale reserved job(s) from the '{$queue}' queue.\n";
}
