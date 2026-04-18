<?PHP
/* cfg.php — small helpers for reading the plugin's bash-style config.
 *
 * The cfg file is sourced by the plugin's bash scripts (KEY="value"
 * syntax with # comments), so we can't round-trip it through PHP's
 * parse_ini_file: PHP chokes on parens in comments and on some
 * identifier-like characters.  A line-oriented regex parser is enough
 * for our purposes — values are always simple strings (no newlines,
 * no escaping beyond outer quotes).
 */

function hpe_mgmt_read_cfg($path) {
    $out = [];
    if (!is_readable($path)) return $out;
    foreach (file($path) as $line) {
        /* strip comments + blank lines */
        $line = trim($line);
        if ($line === '' || $line[0] === '#') continue;
        if (!preg_match('/^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/', $line, $m)) continue;
        $val = $m[2];
        /* strip balanced surrounding quotes (single or double) */
        if (strlen($val) >= 2 &&
            (($val[0] === '"' && $val[-1] === '"') ||
             ($val[0] === "'" && $val[-1] === "'"))) {
            $val = substr($val, 1, -1);
        }
        $out[$m[1]] = $val;
    }
    return $out;
}
