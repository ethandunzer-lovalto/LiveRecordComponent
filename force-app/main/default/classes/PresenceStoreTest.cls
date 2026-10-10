@IsTest
private class PresenceStoreTest {
  private static final Id RECORD_ID = '001000000000001AAA';
  private static final Id USER_A = '005000000000001AAA';
  private static final Id USER_B = '005000000000002AAA';

  // In-memory stand-in for the RecordPresence partition
  private class MemoryCache extends PresenceCache {
    private final Map<String, Object> values = new Map<String, Object>();

    public override Boolean isAvailable() {
      return true;
    }

    public override Object get(String key) {
      return values.get(key);
    }

    public override void put(String key, Object value, Integer ttlSeconds) {
      values.put(key, value);
    }
  }

  @IsTest
  static void cacheStoreKeepsOneMapPerRecord() {
    MemoryCache cache = new MemoryCache();
    PresenceStore store = PresenceStore.forRequest(cache);
    Long now = Datetime.now().getTime();

    store.touch(RECORD_ID, USER_A, now - 10000, now - 60000, true);
    Map<Id, Long> seen = store.touch(RECORD_ID, USER_B, now, now - 60000, true);

    Assert.areEqual(PresenceStore.MODE_CACHE, store.mode());
    Assert.areEqual(
      new Map<Id, Long>{ USER_A => now - 10000, USER_B => now },
      seen
    );
    Assert.areEqual(seen, cache.get('p' + String.valueOf(RECORD_ID)));
  }

  @IsTest
  static void cacheStoreReturnsOnlyUsersSeenSinceTheWindowStart() {
    PresenceStore store = PresenceStore.forRequest(new MemoryCache());
    Long now = Datetime.now().getTime();
    store.touch(RECORD_ID, USER_A, now - 100000, now - 100000, true);

    Map<Id, Long> seen = store.touch(RECORD_ID, USER_B, now, now - 60000, true);

    Assert.areEqual(new Set<Id>{ USER_B }, seen.keySet());
  }

  @IsTest
  static void cacheStoreDropsEntriesPastRetention() {
    MemoryCache cache = new MemoryCache();
    PresenceStore store = PresenceStore.forRequest(cache);
    Long now = Datetime.now().getTime();
    cache.put(
      'p' + String.valueOf(RECORD_ID),
      new Map<Id, Long>{ USER_A => now - PresenceStore.RETENTION_MILLIS - 1 },
      300
    );

    // Reading without recording still writes back the pruned map
    store.touch(RECORD_ID, USER_B, now, now - 60000, false);

    Assert.areEqual(
      new Map<Id, Long>(),
      cache.get('p' + String.valueOf(RECORD_ID))
    );
  }

  @IsTest
  static void cacheStoreRemovesAUser() {
    MemoryCache cache = new MemoryCache();
    PresenceStore store = PresenceStore.forRequest(cache);
    Long now = Datetime.now().getTime();
    store.touch(RECORD_ID, USER_A, now, now, true);
    store.touch(RECORD_ID, USER_B, now, now, true);

    store.remove(RECORD_ID, USER_A);
    store.remove(RECORD_ID, '005000000000009AAA');

    Assert.areEqual(
      new Set<Id>{ USER_B },
      ((Map<Id, Long>) cache.get('p' + String.valueOf(RECORD_ID))).keySet()
    );
  }

  @IsTest
  static void keepsTheMostRecentlySeenUsers() {
    Map<Id, Long> seen = new Map<Id, Long>{
      USER_A => 100L,
      USER_B => 300L,
      '005000000000003AAA' => 200L
    };

    Assert.areEqual(
      new Map<Id, Long>{ USER_B => 300L, '005000000000003AAA' => 200L },
      PresenceStore.newest(seen, 2)
    );
    Assert.areEqual(seen, PresenceStore.newest(seen, 5));
    Assert.areEqual(
      new List<Id>{ USER_B, '005000000000003AAA', USER_A },
      PresenceStore.newestFirst(seen)
    );
  }

  @IsTest
  static void objectStoreKeepsOneRowPerUserPerRecord() {
    User viewer = newUser();
    Account acct = new Account(Name = 'Presence Store');
    insert acct;
    PresenceStore store = PresenceStore.forRequest(new UnavailableCache());
    Long now = Datetime.now().getTime();

    store.touch(acct.Id, viewer.Id, now - 30000, now - 60000, true);
    Map<Id, Long> seen = store.touch(
      acct.Id,
      viewer.Id,
      now,
      now - 60000,
      true
    );

    Assert.areEqual(PresenceStore.MODE_OBJECT, store.mode());
    Assert.areEqual(new Set<Id>{ viewer.Id }, seen.keySet());
    List<Presence__c> rows = [
      SELECT Key__c, Record_Id__c, User__c, Last_Seen__c
      FROM Presence__c
      WITH SYSTEM_MODE
    ];
    Assert.areEqual(1, rows.size());
    Assert.areEqual(
      String.valueOf(acct.Id) + ':' + String.valueOf(viewer.Id),
      rows[0].Key__c
    );
    Assert.areEqual(String.valueOf(acct.Id), rows[0].Record_Id__c);
    Assert.areEqual(viewer.Id, rows[0].User__c);
  }

  @IsTest
  static void objectStoreHardDeletesOnRemove() {
    User viewer = newUser();
    Account acct = new Account(Name = 'Presence Store');
    insert acct;
    PresenceStore store = PresenceStore.forRequest(new UnavailableCache());
    Long now = Datetime.now().getTime();
    store.touch(acct.Id, viewer.Id, now, now, true);
    Id rowId = [SELECT Id FROM Presence__c WITH SYSTEM_MODE].Id;

    store.remove(acct.Id, viewer.Id);
    store.remove(acct.Id, viewer.Id);

    Assert.areEqual(0, [SELECT COUNT() FROM Presence__c WITH SYSTEM_MODE]);
    // Hard-deleted rows still show in ALL ROWS queries for a while, but can't be restored
    Assert.isFalse(
      Database.undelete(rowId, false).isSuccess(),
      'Not left in the Recycle Bin'
    );
  }

  @IsTest
  static void realCacheWithoutCapacityIsUnavailable() {
    // Package build orgs and fresh installs have no capacity allocated. With capacity, the marker round-trips.
    PresenceCache cache = new PresenceCache();
    Boolean available = cache.isAvailable();
    cache.put('presenceTest', 1, 300);
    if (available) {
      Assert.areEqual(1, cache.get('presenceTest'));
    } else {
      Assert.isNull(cache.get('presenceTest'));
      Assert.areEqual(
        PresenceStore.MODE_OBJECT,
        PresenceStore.forRequest(cache).mode()
      );
    }
  }

  private class UnavailableCache extends PresenceCache {
    public override Boolean isAvailable() {
      return false;
    }
  }

  private static User newUser() {
    String unique =
      'store' + String.valueOf(Crypto.getRandomInteger()).remove('-');
    User viewer = new User(
      Alias = 'store',
      Email = unique + '@example.com',
      EmailEncodingKey = 'UTF-8',
      LastName = 'Presence Store',
      LanguageLocaleKey = 'en_US',
      LocaleSidKey = 'en_US',
      ProfileId = [SELECT Id FROM Profile WHERE Name = 'Standard User']
      .Id,
      TimeZoneSidKey = 'America/Los_Angeles',
      Username = unique + '@presence.test'
    );
    System.runAs(new User(Id = UserInfo.getUserId())) {
      insert viewer;
    }
    return viewer;
  }
}
