package kv_interfaces;

/**
 * A backend that counts the operations it issued, for the run summary's NumOp line.
 *
 * This exists so that nothing in bench/ has to name a backend class. RocksDBKV is compiled
 * only under the `rocksdb` Maven profile -- its dependency is a locally built RocksDB+ZenFS
 * jar that a plain checkout cannot resolve -- and a direct reference from Planner or
 * Benchmark would break the default build. SqlKV already had both methods; RocksDBKV had
 * getNumOp and its counter was being reset through the public field.
 */
public interface OpCounting {
	int getNumOp();

	void clearNumOp();
}
