#!/system/bin/sh
MODDIR="${0%/*}"
MODPATH="$MODDIR"
cd "$MODDIR"

# --- Battery/thermal guard --------------------------------------------------
# Keep background helper daemons at a lower CPU scheduling priority. This does
# not stop the attestation engine; it only lets foreground Android work win CPU
# time when the helper is active.
renice_bg() {
    local p n
    for p in "$@"; do
        [ -n "$p" ] || continue
        for n in $(pidof "$p" 2>/dev/null); do
            toybox renice -n 10 -p "$n" >/dev/null 2>&1 || renice -n 10 -p "$n" >/dev/null 2>&1 || true
        done
    done
}

set +o standalone 2>/dev/null
unset ASH_STANDALONE

[ -f "$MODDIR/common_func.sh" ] && . "$MODDIR/common_func.sh"

# --- Play Integrity engine adapter ---
# Which prop file the zygisk reads, and what its spoof flags are called, is all
# that differs between the two builds. engine.sh owns it; everything below is
# identical in both.
CONFIG_DIR=/data/adb/tricky_store
if [ -f "$MODDIR/engine.sh" ]; then
    . "$MODDIR/engine.sh"
else
    log -t "AlwaysStrong" "engine.sh missing — no fingerprint handling this boot"
    engine_autopif()       { return 1; }
    engine_install_pif()   { return 1; }
    engine_enforce_spoof() { return 0; }
    ENGINE=none
fi

# --- Attestation engine adapter (TEESimulator-RS | TrickyStoreOSS) -----------
# build.sh overlays exactly one attest.sh; the daemon start/liveness below go
# through it. Fall back to the TEESimulator pattern if it is somehow missing.
if [ -f "$MODDIR/attest.sh" ]; then
    . "$MODDIR/attest.sh"
else
    attest_early() { return 1; }
    attest_start() { "$MODDIR/supervisor" "$MODDIR/daemon" "$MODDIR" & }
    attest_alive() { pidof TEESimulator >/dev/null 2>&1 || pidof daemon >/dev/null 2>&1; }
fi

# Engines that hijack keystore2 (TrickyStoreOSS) must start at the service stage,
# before sys.boot_completed — a late start misses the injection window and the
# daemon crash-loops with EBADF. Engines that don't (TEESimulator) return false
# here and are started after the boot-completed wait below.
#
# TrickyStoreOSS reads the verified-boot state when building the attestation
# rootOfTrust. The lock-state props are otherwise only asserted in the late
# block below (after boot_completed), so an early start could read the raw
# ORANGE/unlocked values. Pin the rootOfTrust-relevant props here first so the
# daemon reads green/locked; the late block re-asserts them for OEMs that reset
# them during boot.
if attest_early 2>/dev/null; then
    resetprop_if_diff ro.boot.verifiedbootstate green
    resetprop_if_diff vendor.boot.verifiedbootstate green
    resetprop_if_diff ro.boot.vbmeta.device_state locked
    resetprop_if_diff vendor.boot.vbmeta.device_state locked
    resetprop_if_diff ro.boot.flash.locked 1
    resetprop_if_diff ro.secureboot.lockstate locked
    resetprop_if_diff ro.boot.veritymode enforcing
    resetprop_if_diff vendor.boot.veritymode enforcing
    attest_start
fi

# --- Recovery mode guard ---
resetprop_if_match ro.boot.mode recovery unknown
resetprop_if_match ro.bootmode recovery unknown
resetprop_if_match ro.boot.bootmode recovery unknown
resetprop_if_match vendor.boot.mode recovery unknown
resetprop_if_match vendor.boot.bootmode recovery unknown

# --- SELinux enforcement ---
resetprop_if_diff ro.boot.selinux enforcing
if ! ${SKIPDELPROP:-false}; then
    delprop_if_exist ro.build.selinux 2>/dev/null || true
fi
if [ "$(toybox cat /sys/fs/selinux/enforce 2>/dev/null)" = "0" ]; then
    chmod 640 /sys/fs/selinux/enforce
    chmod 440 /sys/fs/selinux/policy
fi

# --- Late properties (after boot_completed) — required for some OEMs ---
{
until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 1; done

# Verified-boot / bootloader-lock fingerprint
resetprop_if_diff ro.secureboot.lockstate locked
resetprop_if_diff ro.boot.flash.locked 1
resetprop_if_diff ro.boot.realme.lockstate 1
resetprop_if_diff ro.boot.vbmeta.device_state locked
resetprop_if_diff vendor.boot.verifiedbootstate green
resetprop_if_diff ro.boot.verifiedbootstate green
resetprop_if_diff ro.boot.veritymode enforcing
resetprop_if_diff vendor.boot.veritymode enforcing
resetprop_if_diff vendor.boot.vbmeta.device_state locked
resetprop_if_diff sys.oem_unlock_allowed 0
resetprop_if_diff ro.boot.warranty_bit 0
resetprop_if_diff ro.warranty_bit 0
resetprop_if_diff ro.secure 1
resetprop_if_diff ro.debuggable 0
resetprop_if_diff ro.adb.secure 1
resetprop_if_diff service.adb.root 0
resetprop_if_diff ro.boot.vbmeta.invalidate_on_error yes

# --- LineageOS prop scrub (hide derivative-ROM markers from PI checks) ---
LV=$(getprop ro.product.vendor.name 2>/dev/null)
case "$LV" in
    lineage_*) resetprop -n ro.product.vendor.name "${LV#lineage_}" ;;
esac
for LP in vendor.camera.aux.packagelist persist.vendor.camera.privapp.list; do
    LCV=$(getprop "$LP" 2>/dev/null)
    case "$LCV" in
        *org.lineageos.aperture*)
            LCV=$(echo "$LCV" | sed -e 's/,org\.lineageos\.aperture//g' \
                                    -e 's/org\.lineageos\.aperture,//g' \
                                    -e 's/^org\.lineageos\.aperture$//')
            resetprop -n "$LP" "$LCV"
            ;;
    esac
done
# Lineage Health HAL: the tell is the property NAME (it carries "lineage"), not
# the running service. Charging control reaches the HAL over binder
# (vendor.lineage.health.IChargingControl) and never reads init.svc.*, so
# dropping the prop hides the ROM marker while charge limiting keeps working.
# We used to `stop` the service too (inherited from specter) — that killed the
# feature for no gain. See issue #7.
resetprop --delete init.svc.vendor.lineage_health 2>/dev/null
}&

# --- Conflict re-scan on every boot ---
# A user can install a conflicting module AFTER they've installed AlwaysStrong
# (the install-time scan in customize.sh only fires once). Re-run the same
# disable-known-conflicts pass at every boot so a fresh install of e.g.
# playintegrityfix doesn't silently break our hooks.
if [ -x "$MODDIR/conflict_scan.sh" ]; then
    MODPATH="$MODDIR" sh "$MODDIR/conflict_scan.sh" >/dev/null 2>&1
    n=$?
    [ "$n" -gt 0 ] && log -t "AlwaysStrong" "disabled $n conflicting module(s) at boot"
fi

# --- Wait for boot, then start TEE simulator ---
while [ "$(getprop sys.boot_completed)" != "1" ]; do sleep 2; done

# Kill any stale TEE / aswatcher processes from a previous boot. TrickyStoreOSS is
# NOT in this list: when its engine is active it was already started early
# (above), so killing it here would nuke the live daemon.
for proc in TEESimulator supervisor daemon aswatcher; do
  for pid in $(pidof "$proc" 2>/dev/null); do
    kill -9 "$pid" 2>/dev/null
  done
done
pkill -9 -f TEESimulator 2>/dev/null || true

# Start the attestation engine here only if it did NOT want the early start
# (TEESimulator). TrickyStoreOSS is already running from the early start above.
if ! attest_early 2>/dev/null; then
    attest_start
    # Give supervisor/TEE a lower scheduling priority once the forked children exist.
    ( sleep 2; renice_bg TEESimulator supervisor daemon ) &
fi

# --- aswatcher native daemon (inotify target.txt + Xposed + conflict) ---
case "$(uname -m)" in
    aarch64)       AS_ABI=arm64-v8a ;;
    armv7*|armv8l) AS_ABI=armeabi-v7a ;;
    x86_64)        AS_ABI=x86_64 ;;
    i?86)          AS_ABI=x86 ;;
    *)             AS_ABI="" ;;
esac
AS_BIN="$MODDIR/bin/$AS_ABI/aswatcher"
if [ -x "$AS_BIN" ]; then
    {
        sleep 5
        "$AS_BIN" &
        sleep 1
        renice_bg aswatcher
        log -t "AlwaysStrong" "aswatcher launched ($AS_ABI) (nice=10)"
    } &
fi

# --- Anti-detection hardening (each opt-out via a no_* flag) --------------
# Runs after the TEE/aswatcher daemons are up. All three degrade quietly if
# their prerequisites are missing (no pif yet, SELinux blocks /proc writes).
{
    CFG=/data/adb/tricky_store
    sleep 8   # let supervisor/daemon/aswatcher come up first

    # NOTE: prop_unify.sh (global resetprop of ro.product.*) ships but is
    # deliberately never invoked, on either engine. Both spoof Build/ro.product.*
    # where Play Integrity looks, so a global resetprop buys no integrity — and it
    # leaks the spoofed model to every process, so the device shows up as e.g.
    # "Pixel 10" in scrcpy/ADB. It stays in the tree for manual use only.

    # Suppress our log tags + scrub ANR/tombstone traces (self-daemonizes).
    # Periodic ANR/tombstone scrubbing costs I/O every 30 minutes. Keep it
    # opt-in for battery-friendly installs; create enable_logcat_cleanup to use it.
    if [ -f "$CFG/enable_logcat_cleanup" ] && [ -f "$MODDIR/logcat_cleanup.sh" ]; then
        MODPATH="$MODDIR" sh "$MODDIR/logcat_cleanup.sh" >/dev/null 2>&1 &
    fi
} &

# --- VBMeta digest (deferred, bounded) ---
# Reading the whole vbmeta partition during early boot can hang the boot
# animation on some Xiaomi devices. Skip if already set, only read 64KiB.
{
sleep 60
CURRENT_DIGEST=$(resetprop ro.boot.vbmeta.digest)
if [ -z "$CURRENT_DIGEST" ] || echo "$CURRENT_DIGEST" | grep -qE '^0+$'; then
    for p in /dev/block/by-name/vbmeta /dev/block/by-name/vbmeta_a /dev/block/bootdevice/by-name/vbmeta; do
        [ -e "$p" ] && VBMETA_BLK="$p" && break
    done
    if [ -n "$VBMETA_BLK" ]; then
        DIGEST=$(dd if="$VBMETA_BLK" bs=4096 count=16 2>/dev/null | sha256sum 2>/dev/null | cut -d' ' -f1)
        if [ -n "$DIGEST" ]; then
            resetprop -n ro.boot.vbmeta.digest "$DIGEST"
            log -t "AlwaysStrong" "VBMeta digest set: ${DIGEST:0:16}..."
        fi
    fi
fi
}&

# --- Housekeeping in background ---
{
    sleep 3
    # Hide TWRP-style recovery folders on /sdcard if empty
    for rdir in TWRP Fox OrangeFox PBRP PitchBlack Recovery; do
        target="/sdcard/$rdir"
        if [ -d "$target" ] && [ "$(ls -A "$target" 2>/dev/null)" ]; then
            mv "$target" "/data/adb/.recovery_backup_${rdir}" 2>/dev/null
        elif [ -d "$target" ]; then
            rmdir "$target" 2>/dev/null
        fi
    done
    rm -f /sdcard/.twrps 2>/dev/null
}&

# --- TEESimulator + aswatcher watchdog ---
{
    while true; do
        # A watchdog does not need to poll frequently; 10 minutes is enough to
        # recover a crashed helper while avoiding needless wakeups.
        sleep 600
        if ! attest_alive; then
            log -t "AlwaysStrong" "attestation daemon died, restarting..."
            attest_start
            ( sleep 2; renice_bg TEESimulator supervisor daemon ) &
        else
            renice_bg TEESimulator supervisor daemon
        fi
        if [ -x "$AS_BIN" ] && ! pidof aswatcher >/dev/null 2>&1; then
            log -t "AlwaysStrong" "aswatcher died, restarting..."
            "$AS_BIN" &
            sleep 1
            renice_bg aswatcher
        fi
    done
}&

# --- First-boot bootstrap (one-shot per module install) ------------------
# Marker file lives inside MODDIR — gets wiped when the module is
# uninstalled, so a reinstall re-bootstraps cleanly. On subsequent boots
# this whole block is a no-op; users press [Action] to refresh manually.
if [ ! -f "$MODDIR/.bootstrapped" ]; then
{
    sleep 20
    # network usually up well before this, but defer further for slow boots
    j=0
    until ping -c1 -W2 1.1.1.1 >/dev/null 2>&1; do
        j=$((j+1)); [ $j -gt 30 ] && break
        sleep 2
    done
    log -t "AlwaysStrong-boot" "first boot: starting bootstrap"

    # 1. keybox (skipped entirely in custom-keybox mode — user's own keybox).
    #    Retry with backoff: ping 1.1.1.1 only proves raw IP connectivity, not
    #    that DNS is up, and on ROMs where the resolver comes late (AOSP builds
    #    like ArrowOS) the first fetch resolves nothing and a single attempt
    #    would leave the device with no keybox until the hourly refresh. Stop as
    #    soon as one lands (rc 0 = updated, 2 = already current).
    if [ ! -f /data/adb/tricky_store/custom_keybox ] && [ -x "$MODDIR/keybox_fetch.sh" ]; then
        kb_try=0
        while :; do
            # to a file, not a pipe: in `cmd | log`, $? is log's exit code, so a
            # piped keybox_fetch.sh would always look like it succeeded.
            sh "$MODDIR/keybox_fetch.sh" >/data/adb/tricky_store/.kb_boot.log 2>&1
            kb_rc=$?
            cat /data/adb/tricky_store/.kb_boot.log 2>/dev/null | log -t "AlwaysStrong-boot"
            { [ "$kb_rc" = 0 ] || [ "$kb_rc" = 2 ]; } && break
            kb_try=$((kb_try+1)); [ $kb_try -ge 6 ] && break
            sleep $((kb_try * 10))   # 10s, 20s, 30s, 40s, 50s
        done
        rm -f /data/adb/tricky_store/.kb_boot.log
    fi

    # 2. fingerprint + security patch. Our native crawl is primary; upstream's
    #    fetcher, whose crawl hangs on some devices, is the fallback. Both end
    #    with the fingerprint in the file this build's zygisk reads.
    FP_DONE=0
    if [ -x "$MODDIR/pif_native_fetch.sh" ]; then
        sh "$MODDIR/pif_native_fetch.sh" >/data/adb/tricky_store/autopif.log 2>&1 && FP_DONE=1
        cat /data/adb/tricky_store/autopif.log 2>/dev/null | log -t "AlwaysStrong-boot"
    fi
    if [ "$FP_DONE" = 0 ]; then
        engine_autopif 2>&1 | log -t "AlwaysStrong-boot"
    fi

    # 2b. sync the attestation/system security patch to the fresh fingerprint
    [ -f "$MODDIR/sync_patch.sh" ] && sh "$MODDIR/sync_patch.sh" 2>&1 | log -t "AlwaysStrong-boot"

    # 3. enforce STRONG-friendly settings on every prop file the engine reads
    engine_enforce_spoof
    log -t "AlwaysStrong-boot" "STRONG enforced ($ENGINE)"

    # 4. restart PI consumers so they pick up the new state
    killall -9 com.google.android.gms.unstable 2>/dev/null
    killall -9 com.android.vending 2>/dev/null

    # NOTE: deliberately do NOT call status_fetch here. We don't want
    # the 🟢 status prefix to appear in module.prop's description before
    # the user has interacted with the module at all — the description
    # stays as the clean text from module.prop until the user presses
    # [Action] (or the hourly refresh fires, whichever happens first).

    # mark done regardless of individual step outcome — user can press
    # [Action] to retry if any step failed (e.g. no internet on first boot)
    touch "$MODDIR/.bootstrapped"
    log -t "AlwaysStrong-boot" "bootstrap done"
}&
fi

# --- Hourly refresh (fingerprint + keybox, each toggle-able from WebUI) --
# WebUI writes flag files into /data/adb/tricky_store/ to opt OUT:
#   no_auto_fp      -> skip the fingerprint refresh
#   no_auto_keybox  -> skip the keybox fetch
# Keybox-only restarts PI when it actually changed (exit 0); fingerprint
# updates are picked up naturally on the next PI invocation, so we don't
# kick running banking apps for cosmetic refreshes.
{
    CFG=/data/adb/tricky_store
    export MODPATH="$MODDIR"
    while true; do
        # Interval is user-configurable from the WebUI. Default 6h, floor 15m
        # so a misconfigured value cannot create frequent network/CPU wakeups.
        INT=$(cat "$CFG/hourly_interval_sec" 2>/dev/null)
        case "$INT" in
            ''|*[!0-9]*) INT=21600 ;;
        esac
        [ "$INT" -lt 900 ] && INT=900
        sleep "$INT"
        if [ ! -f "$CFG/no_auto_fp" ]; then
            FP_DONE=0
            if [ -x "$MODDIR/pif_native_fetch.sh" ]; then
                sh "$MODDIR/pif_native_fetch.sh" >"$CFG/autopif.log" 2>&1 && FP_DONE=1
                cat "$CFG/autopif.log" 2>/dev/null | log -t "AlwaysStrong-hourly"
            fi
            if [ "$FP_DONE" = 0 ]; then
                engine_autopif 2>&1 | log -t "AlwaysStrong-hourly"
            fi
            [ -f "$MODDIR/sync_patch.sh" ] && sh "$MODDIR/sync_patch.sh" 2>&1 | log -t "AlwaysStrong-hourly"
            # upstream's fetcher resets these to a WEAK config (Fork's
            # migrate.sh writes spoofProvider=1 / spoofVendingFinger=0), which
            # would silently drop the verdict an hour after boot.
            engine_enforce_spoof
        fi
        if [ ! -f "$CFG/custom_keybox" ] && [ ! -f "$CFG/no_auto_keybox" ] && [ -x "$MODDIR/keybox_fetch.sh" ]; then
            kbout=$(sh "$MODDIR/keybox_fetch.sh" 2>&1)
            kbrc=$?
            [ -n "$kbout" ] && echo "$kbout" | log -t "AlwaysStrong-hourly"
            if [ "$kbrc" = "0" ]; then
                log -t "AlwaysStrong-hourly" "keybox updated, restarting PI"
                killall -9 com.google.android.gms.unstable 2>/dev/null
                killall -9 com.android.vending 2>/dev/null
            fi
        fi
        # Status — independent of toggles; cheap GET, idempotent module.prop write
        if [ -x "$MODDIR/status_fetch.sh" ]; then
            sh "$MODDIR/status_fetch.sh" 2>&1 | log -t "AlwaysStrong-hourly"
        fi
    done
}&
