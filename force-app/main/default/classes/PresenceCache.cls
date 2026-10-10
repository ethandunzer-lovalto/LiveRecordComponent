// The RecordPresence Org cache partition, behind a small class so the rest of the code treats "no partition" and "no
// capacity" the same way (isAvailable() is false), and tests can swap in an in-memory map.
public inherited sharing virtual class PresenceCache {
  public static final String PARTITION_NAME = 'local.RecordPresence';
  // Marker written to check the partition can hold values
  @TestVisible
  private static final String PROBE_KEY = 'probe';
  private static final Integer PROBE_TTL_SECONDS = 86400;

  private Boolean available;
  private Cache.OrgPartition partition;

  // Whether the partition exists and can hold values. Checked once per transaction. The partition's isAvailable() is
  // true even with no capacity allocated (puts succeed, but nothing is stored), so this also checks that a marker
  // value can be read back. With capacity, the marker is usually there from an earlier request: a single get.
  public virtual Boolean isAvailable() {
    if (available == null) {
      available = false;
      try {
        partition = Cache.Org.getPartition(PARTITION_NAME);
        if (partition.isAvailable()) {
          if (partition.get(PROBE_KEY) == null) {
            partition.put(PROBE_KEY, true, PROBE_TTL_SECONDS);
          }
          available = partition.get(PROBE_KEY) != null;
        }
      } catch (Exception e) {
        // Cache.Org.OrgCacheException when the partition doesn't exist
        available = false;
      }
    }
    return available;
  }

  // The cached value, or null if there's none or the cache can't be read.
  public virtual Object get(String key) {
    if (!isAvailable()) {
      return null;
    }
    try {
      return partition.get(key);
    } catch (Exception e) {
      return null;
    }
  }

  // Best effort: when a put fails (item too large, partition full), the next request recomputes the value.
  public virtual void put(String key, Object value, Integer ttlSeconds) {
    if (!isAvailable()) {
      return;
    }
    try {
      partition.put(key, value, ttlSeconds);
    } catch (Exception e) {
      System.debug(
        LoggingLevel.WARN,
        'Record Presence cache put failed for ' + key + ': ' + e.getMessage()
      );
    }
  }
}
