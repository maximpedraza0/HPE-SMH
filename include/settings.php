<?PHP
/* POST handler for hpe-mgmt.page.
 * Writes /boot/config/plugins/hpe-mgmt/hpe-mgmt.cfg and triggers the
 * install pipeline, a service restart, or a stop, depending on which
 * submit button was used.  Output streams into the progressFrame iframe.
 */

$plugin   = "hpe-mgmt";
$plugdir  = "/usr/local/emhttp/plugins/$plugin";
$cfg_path = "/boot/config/plugins/$plugin/$plugin.cfg";
$rc       = "/etc/rc.d/rc.$plugin";

function post($k, $default = '') {
    return isset($_POST[$k]) ? $_POST[$k] : $default;
}

/* --- sanitise inputs --- */
$stack = post('STACK', 'modern');
if (!in_array($stack, ['modern','legacy','both'], true)) $stack = 'modern';

$extras = [];
foreach (['ssaducli','storcli','hponcfg'] as $k) {
    if (isset($_POST["EX_$k"])) $extras[] = $k;
}

$mcp_dist = preg_replace('/[^A-Za-z]/',    '', post('MCP_DIST', 'CentOS'));
$mcp_ver  = preg_replace('/[^A-Za-z0-9]/', '', post('MCP_VER',  '8'));
$spp_ver  = preg_replace('/[^0-9.]/',      '', post('SPP_LEGACY_VER', '2022.03.0'));

$install_amsd = isset($_POST['INSTALL_AMSD'])    ? '1' : '0';
$snmp_rev     = isset($_POST['ENABLE_SNMP_REV']) ? '1' : '0';
$gpg          = isset($_POST['VERIFY_GPG'])      ? '1' : '0';

/* --- write cfg --- */
$cfg  = "# HPE Management plugin configuration (written by settings page)\n";
$cfg .= 'STACK="'           . $stack        . "\"\n";
$cfg .= 'EXTRAS="'          . implode(' ', $extras) . "\"\n";
$cfg .= 'MCP_DIST="'        . $mcp_dist     . "\"\n";
$cfg .= 'MCP_VER="'         . $mcp_ver      . "\"\n";
$cfg .= 'SPP_LEGACY_VER="'  . $spp_ver      . "\"\n";
$cfg .= 'INSTALL_AMSD="'    . $install_amsd . "\"\n";
$cfg .= 'ENABLE_SNMP_REV="' . $snmp_rev     . "\"\n";
$cfg .= 'VERIFY_GPG="'      . $gpg          . "\"\n";

@mkdir(dirname($cfg_path), 0755, true);
file_put_contents($cfg_path, $cfg);

/* --- stream output straight to the iframe --- */
header('Content-Type: text/plain; charset=utf-8');
header('X-Accel-Buffering: no');
while (ob_get_level()) ob_end_flush();
ob_implicit_flush(true);

echo "== saved config to $cfg_path ==\n";
echo $cfg;
echo "\n";

if (isset($_POST['apply'])) {
    echo "== running install pipeline (this can take several minutes) ==\n";
    /* install.sh prints progress line-by-line.  passthru forwards both
     * stdout and stderr with no PHP buffering. */
    passthru("bash $plugdir/scripts/install.sh 2>&1");
} elseif (isset($_POST['restart'])) {
    echo "== restarting services ==\n";
    passthru("$rc restart 2>&1");
} elseif (isset($_POST['stop'])) {
    echo "== stopping services ==\n";
    passthru("$rc stop 2>&1");
} else {
    echo "(config saved — no action button selected)\n";
}

echo "\n== done ==\n";
