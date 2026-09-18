#!/system/bin/sh
# Attestation-engine adapter — TEESimulator-RS (default, --engine tee).
#
# build.sh copies the selected attest/<engine>.sh into the module as attest.sh.
# customize.sh sources it and calls attest_install (with $ABI_DIR / $ARCH /
# $ZIPFILE / $MODPATH and install_file() + ui_print() in scope). service.sh
# sources it and calls attest_start / attest_alive (with $MODDIR in scope).
# engine.sh (the PIF adapter) keeps spoofProvider off for both engines: the
# attestation layer here is what supplies the hardware-attested keystore.

ATTEST=tee
ATTEST_NAME="TEESimulator-RS"

# Install the native TEE stack out of the flashed module zip.
attest_install() {
    install_file "lib/$ABI_DIR/libTEESimulator.so" "$MODPATH"
    install_file "lib/$ABI_DIR/libinject.so"       "$MODPATH"
    install_file "lib/$ABI_DIR/libsupervisor.so"   "$MODPATH"
    HAS_CERTGEN=0
    if unzip -l "$ZIPFILE" 2>/dev/null | grep -q "lib/$ABI_DIR/libcertgen.so"; then
        install_file "lib/$ABI_DIR/libcertgen.so" "$MODPATH"
        HAS_CERTGEN=1
    fi
    mv "$MODPATH/libinject.so"     "$MODPATH/inject"
    mv "$MODPATH/libsupervisor.so" "$MODPATH/supervisor"
    install_file "tee_classes.dex" "$MODPATH"
    chmod 755 "$MODPATH/inject" "$MODPATH/supervisor" 2>/dev/null
    if [ "$HAS_CERTGEN" -eq 1 ]; then
        ui_print "TEESim installed ($ABI_DIR, native certgen)"
    else
        ui_print "TEESim installed ($ABI_DIR)"
    fi
}

# TEESimulator is started after sys.boot_completed (it needs a fully-booted
# system), so it does NOT want the early start.
attest_early() { return 1; }

# Fork-based supervisor + daemon (TEESimulator-RS standard pattern).
attest_start() {
    # Lower the launcher priority; service.sh also re-applies it to forked
    # children after startup. This reduces contention without disabling TEE.
    if command -v nice >/dev/null 2>&1; then
        nice -n 10 "$MODDIR/supervisor" "$MODDIR/daemon" "$MODDIR" &
    else
        "$MODDIR/supervisor" "$MODDIR/daemon" "$MODDIR" &
    fi
}

# True while the TEE daemon is alive.
attest_alive() {
    pidof TEESimulator >/dev/null 2>&1 || pidof daemon >/dev/null 2>&1
}
