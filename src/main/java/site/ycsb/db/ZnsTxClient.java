package site.ycsb.db;

public class ZnsTxClient {
    static {
        System.loadLibrary("zns_tx_jni");
    }

    // Signature must match the JNI handler in jni/zns_tx_jni.cpp (9 args).
    // The previous 3-arg declaration was a silent mismatch: the JNI symbol reads
    // 6 extra slots off the stack regardless, so the extra args here were undefined
    // garbage that happened to land in valid ranges most of the time.
    public static native int nativeInitTx(int isolationLevel, int durabilityLevel, boolean enableRecovery,
        boolean enableNodeCheckpointing, boolean enablePeriodicGc, boolean enableEval,
        boolean enableBatchedNodeCheckpoint, boolean enableDebug, int driveCount);
    public static native void nativeCleanTx();
    public static native int nativeBeginTx();
    public static native int nativeEndTx();
    public static native int nativeAbortTx();
    public static native int nativeCreateObj(String objKey);
    public static native int nativeWriteObj(String objKey, long offset, byte[] data);
    public static native byte[] nativeReadObj(String objKey, long offset, int length);
    public static native int nativePutObj(String objKey, byte[] data);
    public static native byte[] nativeGetObj(String objKey, int maxLength);
}
