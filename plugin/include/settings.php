<?PHP
/* POST handler for hpe-mgmt.page.
 * Writes /boot/config/plugins/hpe-mgmt/hpe-mgmt.cfg and triggers the
 * install pipeline or a service restart, depending on which button was used.
 */

$plugin   = "hpe-mgmt";
$cfg_path = "/boot/config/plugins/$plugin/$plugin.cfg";
$rc       = "/etc/rc.d/rc.$plugin";
$plugdir  = "/usr/local/emhttp/plugins/$plugin";

function post($k, $default = '') {
    return isset($_POST[$k]) ? $_POST[$k] : $default;
}

$stack = post('STACK', 'modern');
if (!in_array($stack, ['modern','legacy','both'], true)) $stack = 'modern';

$extras = [];
foreach (['ssaducli','storcli','hponcfg','diag'] as $k) {
    if (isset($_POST["EX_$k"])) $extras[] = $k;
}

$mcp_dist = preg_replace('/[^A-Za-z]/', '', post('MCP_DIST', 'CentOS'));
$mcp_ver  = preg_replace('/[^A-Za-z0-9]/', '', post('MCP_VER', '8'));
$gpg      = isset($_POST['VERIFY_GPG']) ? '1' : '0';

$cfg  = "# HPE Management plugin configuration (written by settings page)\n";
$cfg .= 'STACK="'     . $stack    . "\"\n";
$cfg .= 'EXTRAS="'    . implode(' ', $extras) . "\"\n";
$cfg .= 'MCP_DIST="'  . $mcp_dist . "\"\n";
$cfg .= 'MCP_VER="'   . $mcp_ver  . "\"\n";
$cfg .= 'VERIFY_GPG="'. $gpg      . "\"\n";

@mkdir(dirname($cfg_path), 0755, true);
file_put_contents($cfg_path, $cfg);
echo "<pre>config saved to $cfg_path\n\n";
echo htmlspecialchars($cfg);
echo "</pre>";

if (isset($_POST['apply'])) {
    echo "<pre>Running install pipeline...\n";
    passthru("bash $plugdir/scripts/install.sh 2>&1");
    echo "</pre>";
} elseif (isset($_POST['restart'])) {
    echo "<pre>Restarting services...\n";
    passthru("$rc restart 2>&1");
    echo "</pre>";
}
