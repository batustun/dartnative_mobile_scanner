# The JNI layer looks these up by name, so shrinking must not rename or remove
# them. Everything else in the plugin is free to be optimized away.
-keepclasseswithmembernames,includedescriptorclasses class com.dartnative.mobile_scanner.DNMobileScannerBridge {
    native <methods>;
    static void disposeAllFromNative();
}

# ML Kit ships its own consumer rules for the barcode model; nothing to add here.
