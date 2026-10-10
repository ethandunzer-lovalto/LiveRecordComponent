// Where presence lives: when each user was last seen on a record. Platform Cache when the RecordPresence partition has
// capacity, otherwise Presence__c rows. PresenceService only uses it after its user-mode check that the user can see the
// record.
public inherited sharing abstract class PresenceStore {
  public static final String MODE_CACHE = 'CACHE';
  public static final String MODE_OBJECT = 'OBJECT';
  // Cache entries older than this are dropped when the record's map is written. It's at least the longest staleness
  // window a client can ask for, so a client with a short window never drops users who heartbeat less often.
  @TestVisible
  private static final Long RETENTION_MILLIS = 300000;
  // Platform Cache's minimum time to live; every heartbeat renews it
  private static final Integer CACHE_TTL_SECONDS = 300;
  // A record with more viewers than this keeps the most recently seen ones, so its cache entry stays small
  @TestVisible
  private static final Integer MAX_ENTRIES = 500;

  // The cache when it has capacity, otherwise the object
  public static PresenceStore forRequest(PresenceCache cache) {
    if (cache.isAvailable()) {
      return new CacheStore(cache);
    }
    return new ObjectStore();
  }

  public abstract String mode();

  // Records userId as seen on the record at nowMillis (unless recordUser is false), and returns everyone seen on it at
  // or after sinceMillis as user ID => last seen millis, including userId.
  public abstract Map<Id, Long> touch(
    Id recordId,
    Id userId,
    Long nowMillis,
    Long sinceMillis,
    Boolean recordUser
  );

  // Forgets userId on the record.
  public abstract void remove(Id recordId, Id userId);

  // One cache entry per record: 'p' + record ID => (user ID => last seen millis). Concurrent heartbeats can overwrite
  // each other's update; the next heartbeat puts the user back, so there's no locking.
  public class CacheStore extends PresenceStore {
    private final PresenceCache cache;

    public CacheStore(PresenceCache cache) {
      this.cache = cache;
    }

    public override String mode() {
      return MODE_CACHE;
    }

    public override Map<Id, Long> touch(
      Id recordId,
      Id userId,
      Long nowMillis,
      Long sinceMillis,
      Boolean recordUser
    ) {
      Map<Id, Long> seen = read(recordId);
      Integer sizeBefore = seen.size();
      Long retainSince = nowMillis - RETENTION_MILLIS;
      for (Id seenUserId : new List<Id>(seen.keySet())) {
        if (seen.get(seenUserId) < retainSince) {
          seen.remove(seenUserId);
        }
      }
      if (recordUser) {
        seen.put(userId, nowMillis);
      }
      if (recordUser || seen.size() != sizeBefore) {
        cache.put(key(recordId), newest(seen, MAX_ENTRIES), CACHE_TTL_SECONDS);
      }
      return seenSince(seen, sinceMillis);
    }

    public override void remove(Id recordId, Id userId) {
      Map<Id, Long> seen = read(recordId);
      if (seen.remove(userId) != null) {
        cache.put(key(recordId), seen, CACHE_TTL_SECONDS);
      }
    }

    private Map<Id, Long> read(Id recordId) {
      Object value = cache.get(key(recordId));
      return value instanceof Map<Id, Long>
        ? (Map<Id, Long>) value
        : new Map<Id, Long>();
    }

    // Cache keys must be alphanumeric
    private String key(Id recordId) {
      return 'p' + String.valueOf(recordId);
    }
  }

  // One Presence__c row per user per record. Rows belong to whoever created them and the object is Private, so this
  // runs without sharing to see everyone's rows. Users get no access to Presence__c, so every query and DML here
  // says system mode explicitly rather than relying on the default.
  private without sharing class ObjectStore extends PresenceStore {
    public override String mode() {
      return MODE_OBJECT;
    }

    public override Map<Id, Long> touch(
      Id recordId,
      Id userId,
      Long nowMillis,
      Long sinceMillis,
      Boolean recordUser
    ) {
      String recordKey = String.valueOf(recordId);
      if (recordUser) {
        String rowKey = rowKey(recordId, userId);
        Presence__c row = new Presence__c(
          Name = rowKey,
          Key__c = rowKey,
          Record_Id__c = recordKey,
          User__c = userId,
          Last_Seen__c = Datetime.newInstance(nowMillis)
        );
        // Not all-or-none: two tabs creating the same row at once can fail with DUPLICATE_VALUE, and the other
        // tab's row is just as good
        Database.UpsertResult result = Database.upsert(
          row,
          Presence__c.Key__c,
          false,
          AccessLevel.SYSTEM_MODE
        );
        if (!result.isSuccess()) {
          System.debug(
            LoggingLevel.WARN,
            'Record Presence upsert failed: ' + result.getErrors()
          );
        }
      }
      // Queried with an explicit bind map: inline binds in this inner subclass fail at runtime ("Variable does not
      // exist: tmpVar3")
      List<Presence__c> rows = Database.queryWithBinds(
        'SELECT User__c, Last_Seen__c FROM Presence__c' +
          ' WHERE Record_Id__c = :recordKey AND Last_Seen__c >= :since AND User__c != NULL' +
          ' ORDER BY Last_Seen__c DESC LIMIT ' +
          MAX_ENTRIES,
        new Map<String, Object>{
          'recordKey' => recordKey,
          'since' => Datetime.newInstance(sinceMillis)
        },
        AccessLevel.SYSTEM_MODE
      );
      Map<Id, Long> seen = new Map<Id, Long>();
      for (Presence__c seenRow : rows) {
        seen.put(seenRow.User__c, seenRow.Last_Seen__c.getTime());
      }
      return seen;
    }

    public override void remove(Id recordId, Id userId) {
      hardDelete(
        Database.queryWithBinds(
          'SELECT Id FROM Presence__c WHERE Key__c = :rowKey',
          new Map<String, Object>{ 'rowKey' => rowKey(recordId, userId) },
          AccessLevel.SYSTEM_MODE
        )
      );
    }

    private String rowKey(Id recordId, Id userId) {
      return String.valueOf(recordId) + ':' + String.valueOf(userId);
    }
  }

  // Deletes the rows and empties them from the Recycle Bin, so presence isn't kept as a history of who viewed what.
  // Rows another transaction deleted first are skipped.
  public static void hardDelete(List<Presence__c> rows) {
    if (rows.isEmpty()) {
      return;
    }
    List<Id> deletedIds = new List<Id>();
    for (
      Database.DeleteResult result : Database.delete(
        rows,
        false,
        AccessLevel.SYSTEM_MODE
      )
    ) {
      if (result.isSuccess()) {
        deletedIds.add(result.getId());
      }
    }
    if (!deletedIds.isEmpty()) {
      Database.emptyRecycleBin(deletedIds);
    }
  }

  private static Map<Id, Long> seenSince(Map<Id, Long> seen, Long sinceMillis) {
    Map<Id, Long> recent = new Map<Id, Long>();
    for (Id seenUserId : seen.keySet()) {
      if (seen.get(seenUserId) >= sinceMillis) {
        recent.put(seenUserId, seen.get(seenUserId));
      }
    }
    return recent;
  }

  // The limit most recently seen users. Most records have a handful, so the sort rarely runs.
  @TestVisible
  private static Map<Id, Long> newest(Map<Id, Long> seen, Integer limitCount) {
    if (seen.size() <= limitCount) {
      return seen;
    }
    Map<Id, Long> kept = new Map<Id, Long>();
    for (Id seenUserId : newestFirst(seen)) {
      if (kept.size() == limitCount) {
        break;
      }
      kept.put(seenUserId, seen.get(seenUserId));
    }
    return kept;
  }

  // User IDs ordered by last seen, most recent first
  public static List<Id> newestFirst(Map<Id, Long> seen) {
    List<LastSeen> entries = new List<LastSeen>();
    for (Id seenUserId : seen.keySet()) {
      entries.add(new LastSeen(seenUserId, seen.get(seenUserId)));
    }
    entries.sort();
    List<Id> userIds = new List<Id>();
    for (LastSeen entry : entries) {
      userIds.add(entry.userId);
    }
    return userIds;
  }

  private class LastSeen implements Comparable {
    private final Id userId;
    private final Long millis;

    LastSeen(Id userId, Long millis) {
      this.userId = userId;
      this.millis = millis;
    }

    public Integer compareTo(Object other) {
      Long otherMillis = ((LastSeen) other).millis;
      return millis == otherMillis ? 0 : (millis > otherMillis ? -1 : 1);
    }
  }
}
