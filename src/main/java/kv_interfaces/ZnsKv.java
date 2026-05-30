package kv_interfaces;

import java.nio.charset.StandardCharsets;
import java.util.Arrays;

import kvstore.exceptions.KvException;
import kvstore.exceptions.TxnException;
import site.ycsb.db.ZnsTxClient;
import main.Config;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

public class ZnsKv implements KvInterface {
    private static final Logger logger = LoggerFactory.getLogger(ZnsKv.class);

    // Harness-level tombstone: native putObj rejects empty payloads and has no
    // deleteObj, so we emulate delete by writing this sentinel and translating
    // it back to null on read.
    private static final byte[] TOMBSTONE =
        "__ZNS_TOMBSTONE__".getBytes(StandardCharsets.UTF_8);

    // We only want to initialize the native connection once per process
    private static ZnsKv instance = null;
    private static boolean isInitialized = false;
    
    public synchronized static ZnsKv getInstance() {
        if (instance == null) {
            instance = new ZnsKv();
        }
        return instance;
    }
    
    public ZnsKv() {
        if (!isInitialized) {
            // First time initialization
            int isolation = Config.get().ISOLATION_LEVEL;
            int durability = Config.get().DURABILITY_LEVEL;
            boolean enableRecovery = Config.get().ENABLE_RECOVERY;
            
            logger.info("Initializing ZnsKv with Isolation={}, Durability={}, Recovery={}", 
                        isolation, durability, enableRecovery);
                        
            int result = ZnsTxClient.nativeInitTx(isolation, durability, enableRecovery);
            if (result != 0) {
                throw new RuntimeException("ZnsTxClient.nativeInitTx failed with code: " + result);
            }
            
            isInitialized = true;
        }
    }
    
    public synchronized static void cleanupZns() {
        if (isInitialized) {
            logger.info("Cleaning up native ZNS TX manually due to SPDK JNI threading constraints...");
            try {
                ZnsTxClient.nativeCleanTx();
                logger.info("ZNS native cleanup successful.");
            } catch (Exception e) {
                logger.error("ZnsTxClient.nativeCleanTx failed", e);
            }
            isInitialized = false;
        }
    }

    @Override
    public Object begin() throws KvException, TxnException {
        long txId = ZnsTxClient.nativeBeginTx();
        return txId;
    }

    @Override
    public boolean commit(Object txn) throws KvException, TxnException {
        int result = ZnsTxClient.nativeEndTx();
        return result == 0;
    }

    @Override
    public boolean abort(Object txn) throws KvException, TxnException {
        int result = ZnsTxClient.nativeAbortTx();
        return result == 0;
    }

    @Override
    public boolean insert(Object txn, String key, String value) throws KvException, TxnException {
        byte[] data = value.isEmpty() ? TOMBSTONE : value.getBytes();
        int result = ZnsTxClient.nativePutObj(key, data);
        return result == 0;
    }

    @Override
    public boolean delete(Object txn, String key) throws KvException, TxnException {
        int result = ZnsTxClient.nativePutObj(key, TOMBSTONE);
        return result == 0;
    }

    @Override
    public String get(Object txn, String key) throws KvException, TxnException {
        byte[] data = ZnsTxClient.nativeGetObj(key, 65536);
        if (data == null || data.length == 0) return null;
        if (Arrays.equals(data, TOMBSTONE)) return null;
        return new String(data);
    }

    @Override
    public boolean set(Object txn, String key, String value) throws KvException, TxnException {
        return insert(txn, key, value);
    }

    @Override
    public boolean rollback(Object txn) {
        try {
            return abort(txn);
        } catch (Exception e) {
            return false;
        }
    }

    @Override
    public boolean isalive(Object txn) {
        return true; 
    }

    @Override
    public long getTxnId(Object txn) {
        return (Long) txn;
    }

    @Override
    public Object getTxn(long txnid) {
        return txnid;
    }

    @Override
    public boolean isInstrumented() {
        return false;
    }
}