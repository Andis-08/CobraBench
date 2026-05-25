package site.ycsb.db;

public class ZnsTxClient {
    static {
        System.loadLibrary("zns_tx_jni");
    }

    public static native int nativeInitTx(int isolationLevel, int durabilityLevel, boolean enableRecovery);
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
