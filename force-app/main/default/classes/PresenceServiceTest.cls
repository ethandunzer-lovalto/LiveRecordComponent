@IsTest
private class PresenceServiceTest {
  // In-memory stand-in for the RecordPresence partition; unavailable means no capacity
  private class MemoryCache extends PresenceCache {
    private final Boolean available;
    private final Map<String, Object> values = new Map<String, Object>();

    MemoryCache(Boolean available) {
      this.available = available;
    }

    public override Boolean isAvailable() {
      return available;
    }

    public override Object get(String key) {
      return values.get(key);
    }

    public override void put(String key, Object value, Integer ttlSeconds) {
      if (available) {
        values.put(key, value);
      }
    }
  }

  // Canned settings, permission assignments and field history. Field history rows aren't created in Apex tests.
  private class StubSelector extends PresenceSelector {
    Record_Presence_Object__mdt config;
    Map<String, Set<Id>> usersByPermission = new Map<String, Set<Id>>();
    List<PresenceSelector.HistoryEntry> history = new List<PresenceSelector.HistoryEntry>();
    Set<String> trackedFields = new Set<String>();
    Boolean hasHistoryObject = true;
    Boolean failOnConfig = false;
    Set<String> lastFieldFilter;
    Integer permissionLookups = 0;

    public override Record_Presence_Object__mdt getObjectConfig(
      String objectApiName
    ) {
      if (failOnConfig) {
        throw new IllegalArgumentException('Settings unavailable');
      }
      return config;
    }

    public override Set<Id> getUserIdsWithPermission(String permissionName) {
      permissionLookups++;
      return usersByPermission.containsKey(permissionName)
        ? usersByPermission.get(permissionName)
        : new Set<Id>();
    }

    public override PresenceSelector.HistoryObject getHistoryObject(
      Schema.SObjectType objectType
    ) {
      return hasHistoryObject
        ? new PresenceSelector.HistoryObject(
            objectType + 'History',
            'ParentId',
            true
          )
        : null;
    }

    // Like the real query: rows after `after`, on the given fields (the SOQL filter is case-insensitive)
    public override List<PresenceSelector.HistoryEntry> getHistory(
      PresenceSelector.HistoryObject historyObject,
      Id recordId,
      Datetime after,
      Set<String> fieldNames
    ) {
      lastFieldFilter = fieldNames;
      List<PresenceSelector.HistoryEntry> rows = new List<PresenceSelector.HistoryEntry>();
      for (PresenceSelector.HistoryEntry row : history) {
        if (
          row.createdDate > after &&
          (fieldNames == null || fieldNames.contains(row.field.toLowerCase()))
        ) {
          rows.add(row);
        }
      }
      return rows;
    }

    public override Set<String> getHistoryTrackedFields(String objectApiName) {
      return trackedFields;
    }
  }

  @TestSetup
  static void setup() {
    User viewer = newUser('viewer', 'Standard User');
    User other = newUser('other', 'Standard User');
    User hidden = newUser('hidden', 'Standard User');
    System.runAs(new User(Id = UserInfo.getUserId())) {
      insert new List<User>{ viewer, other, hidden };
    }
    // Owned by the viewer, so they can see it whatever the org-wide default; last modified by the test user
    insert new Account(Name = 'Presence Test', OwnerId = viewer.Id);
  }

  // ---- Presence ----

  @IsTest
  static void recordsTheUserAndReturnsOtherViewersFromTheObject() {
    StubSelector selector = useStubs(false);
    Account acct = testAccount();
    User other = testUser('other');
    Long now = Datetime.now().getTime();
    seedPresence(acct.Id, other.Id, now - 5000);

    PresenceSnapshot snapshot = heartbeatAs(testUser('viewer'), acct.Id, null);

    Assert.areEqual(PresenceStore.MODE_OBJECT, snapshot.storageMode);
    Assert.areEqual(
      1,
      snapshot.viewers.size(),
      'Only the other user is listed, never the current user'
    );
    Assert.areEqual(other.Id, snapshot.viewers[0].userId);
    Assert.areEqual('Presence other', snapshot.viewers[0].name);
    Assert.isNotNull(snapshot.viewers[0].smallPhotoUrl);
    Assert.isTrue(snapshot.viewers[0].lastSeenMillis >= now - 6000);
    Assert.areEqual(
      2,
      presenceRows(acct.Id).size(),
      'The viewer was recorded too'
    );
    Assert.isTrue(snapshot.enabled);
    Assert.isNotNull(snapshot.serverTimeMillis);
  }

  @IsTest
  static void usesTheCacheWhenItHasCapacity() {
    useStubs(true);
    Account acct = testAccount();
    User other = testUser('other');
    seedPresence(acct.Id, other.Id, Datetime.now().getTime() - 5000);

    PresenceSnapshot snapshot = heartbeatAs(testUser('viewer'), acct.Id, null);

    Assert.areEqual(PresenceStore.MODE_CACHE, snapshot.storageMode);
    Assert.areEqual(1, snapshot.viewers.size());
    Assert.areEqual(other.Id, snapshot.viewers[0].userId);
    Assert.areEqual(
      0,
      presenceRows(acct.Id).size(),
      'No Presence__c rows when the cache is used'
    );
    Map<Id, Long> cached = (Map<Id, Long>) PresenceService.cache.get(
      'p' + String.valueOf(acct.Id)
    );
    Assert.isTrue(cached.containsKey(testUser('viewer').Id));
  }

  @IsTest
  static void dropsUsersNotSeenWithinTheStalenessWindow() {
    useStubs(false);
    Account acct = testAccount();
    seedPresence(
      acct.Id,
      testUser('other').Id,
      Datetime.now().getTime() - 90000
    );

    Assert.areEqual(
      0,
      heartbeatAs(testUser('viewer'), acct.Id, null).viewers.size()
    );
  }

  @IsTest
  static void slowerHeartbeatsWidenTheStalenessWindow() {
    Assert.areEqual(60000L, PresenceService.staleWindowMillis(null));
    Assert.areEqual(60000L, PresenceService.staleWindowMillis(25));
    Assert.areEqual(
      60000L,
      PresenceService.staleWindowMillis(1),
      'Clamped to the 15 second minimum'
    );
    Assert.areEqual(144000L, PresenceService.staleWindowMillis(60));
    Assert.areEqual(
      288000L,
      PresenceService.staleWindowMillis(500),
      'Clamped to the 120 second maximum'
    );
  }

  @IsTest
  static void neverShowsHiddenUsers() {
    StubSelector selector = useStubs(false);
    Account acct = testAccount();
    User hidden = testUser('hidden');
    User other = testUser('other');
    selector.usersByPermission.put(
      PresenceService.HIDDEN_PERMISSION,
      new Set<Id>{ hidden.Id }
    );
    Long now = Datetime.now().getTime();
    seedPresence(acct.Id, hidden.Id, now - 1000);
    seedPresence(acct.Id, other.Id, now - 2000);

    PresenceSnapshot snapshot = heartbeatAs(testUser('viewer'), acct.Id, null);

    Assert.areEqual(1, snapshot.viewers.size());
    Assert.areEqual(other.Id, snapshot.viewers[0].userId);
  }

  @IsTest
  static void doesNotRecordUsersWithTheHiddenPermission() {
    useStubs(false);
    Account acct = testAccount();
    User viewer = testUser('viewer');
    assignPermissionSet(viewer.Id, 'Record_Presence_Integration_User');

    heartbeatAs(viewer, acct.Id, null);

    Assert.areEqual(0, presenceRows(acct.Id).size());
  }

  @IsTest
  static void listsViewersMostRecentFirst() {
    useStubs(false);
    Account acct = testAccount();
    Long now = Datetime.now().getTime();
    seedPresence(acct.Id, testUser('other').Id, now - 20000);
    seedPresence(acct.Id, testUser('hidden').Id, now - 1000);

    PresenceSnapshot snapshot = heartbeatAs(testUser('viewer'), acct.Id, null);

    Assert.areEqual(testUser('hidden').Id, snapshot.viewers[0].userId);
    Assert.areEqual(testUser('other').Id, snapshot.viewers[1].userId);
  }

  @IsTest
  static void leaveRemovesTheUserFromTheObject() {
    useStubs(false);
    Account acct = testAccount();
    User viewer = testUser('viewer');
    heartbeatAs(viewer, acct.Id, null);
    Id rowId = presenceRows(acct.Id)[0].Id;

    System.runAs(viewer) {
      PresenceService.leave(acct.Id);
      PresenceService.leave(null);
    }

    Assert.areEqual(0, presenceRows(acct.Id).size());
    Assert.isFalse(
      Database.undelete(rowId, false).isSuccess(),
      'Not left in the Recycle Bin'
    );
  }

  @IsTest
  static void leaveRemovesTheUserFromTheCache() {
    useStubs(true);
    Account acct = testAccount();
    User viewer = testUser('viewer');
    seedPresence(acct.Id, testUser('other').Id, Datetime.now().getTime());
    heartbeatAs(viewer, acct.Id, null);

    System.runAs(viewer) {
      PresenceService.leave(acct.Id);
    }

    Map<Id, Long> cached = (Map<Id, Long>) PresenceService.cache.get(
      'p' + String.valueOf(acct.Id)
    );
    Assert.isFalse(cached.containsKey(viewer.Id));
    Assert.isTrue(cached.containsKey(testUser('other').Id));
  }

  // ---- Access ----

  @IsTest
  static void returnsAnEmptySnapshotForARecordTheUserCantRead() {
    useStubs(false);
    Account acct = testAccount();
    seedPresence(acct.Id, testUser('other').Id, Datetime.now().getTime());
    // Standard users have no access to Presence__c, so its rows stand in for records they can't read
    Id unreadableId = presenceRows(acct.Id)[0].Id;
    seedPresence(unreadableId, testUser('other').Id, Datetime.now().getTime());

    PresenceSnapshot snapshot = heartbeatAs(
      testUser('viewer'),
      unreadableId,
      0L
    );

    assertEmpty(snapshot);
    Assert.areEqual(
      1,
      presenceRows(unreadableId).size(),
      'The viewer was not recorded'
    );
  }

  @IsTest
  static void returnsAnEmptySnapshotForADeletedRecord() {
    useStubs(false);
    Account acct = testAccount();
    delete acct;

    PresenceSnapshot snapshot = heartbeatAs(testUser('viewer'), acct.Id, 0L);

    assertEmpty(snapshot);
    Assert.areEqual(0, presenceRows(acct.Id).size());
  }

  @IsTest
  static void returnsAnEmptySnapshotWithoutARecordId() {
    useStubs(false);

    assertEmpty(PresenceService.heartbeat(null, null, null));
  }

  @IsTest
  static void turnsOffForDisabledObjects() {
    StubSelector selector = useStubs(false);
    selector.config = new Record_Presence_Object__mdt(
      Object_API_Name__c = 'Account',
      Enabled__c = false
    );
    Account acct = testAccount();

    PresenceSnapshot snapshot = heartbeatAs(testUser('viewer'), acct.Id, 0L);

    Assert.isFalse(snapshot.enabled);
    Assert.areEqual(0, presenceRows(acct.Id).size());
  }

  @IsTest
  static void reportsErrorsAsAuraHandledExceptions() {
    StubSelector selector = useStubs(false);
    selector.failOnConfig = true;
    Account acct = testAccount();

    try {
      PresenceService.heartbeat(acct.Id, null, null);
      Assert.fail('Expected an AuraHandledException');
    } catch (AuraHandledException e) {
      Assert.isTrue(
        e.getMessage().contains('Settings unavailable'),
        e.getMessage()
      );
    }
  }

  // ---- Change detection: no watched fields ----

  @IsTest
  static void anyChangeByAnotherUserIsMeaningful() {
    StubSelector selector = useStubs(false);
    Account acct = testAccount();
    Datetime changed = acct.LastModifiedDate;
    selector.history.add(
      entry(
        'Industry',
        null,
        'Agriculture',
        UserInfo.getUserId(),
        'Admin',
        changed
      )
    );

    PresenceSnapshot snapshot = heartbeatAs(
      testUser('viewer'),
      acct.Id,
      changed.getTime() - 1000
    );

    Assert.isTrue(snapshot.meaningfulChange);
    Assert.areEqual(changed.getTime(), snapshot.latestChangeMillis);
    Assert.areEqual(acct.LastModifiedBy.Name, snapshot.latestChangeByName);
    Assert.areEqual(UserInfo.getUserId(), snapshot.lastModifiedById);
    Assert.areEqual(acct.LastModifiedBy.Name, snapshot.lastModifiedByName);
    Assert.areEqual(changed.getTime(), snapshot.lastModifiedMillis);
    Assert.areEqual(
      1,
      snapshot.changes.size(),
      'History fills in what changed'
    );
    Assert.areEqual('Industry', snapshot.changes[0].fieldLabel);
    Assert.isNull(snapshot.changes[0].oldValue);
    Assert.areEqual('Agriculture', snapshot.changes[0].newValue);
    Assert.isNull(
      selector.lastFieldFilter,
      'All fields are shown when none are watched'
    );
  }

  @IsTest
  static void changesAreMeaningfulWithoutFieldHistory() {
    StubSelector selector = useStubs(false);
    selector.hasHistoryObject = false;
    Account acct = testAccount();

    PresenceSnapshot snapshot = heartbeatAs(
      testUser('viewer'),
      acct.Id,
      acct.LastModifiedDate.getTime() - 1000
    );

    Assert.isTrue(snapshot.meaningfulChange);
    Assert.areEqual(0, snapshot.changes.size());
  }

  @IsTest
  static void noChangeWhenTheBaselineIsCurrentOrUnknown() {
    useStubs(false);
    Account acct = testAccount();
    User viewer = testUser('viewer');

    Assert.isFalse(
      heartbeatAs(viewer, acct.Id, acct.LastModifiedDate.getTime())
        .meaningfulChange
    );
    Assert.isFalse(
      heartbeatAs(viewer, acct.Id, acct.LastModifiedDate.getTime() + 5000)
        .meaningfulChange
    );
    Assert.isFalse(heartbeatAs(viewer, acct.Id, null).meaningfulChange);
  }

  @IsTest
  static void ownChangesAreNotMeaningful() {
    useStubs(false);
    User viewer = testUser('viewer');
    Account acct = testAccount();
    Long baseline = acct.LastModifiedDate.getTime() - 1000;
    System.runAs(viewer) {
      update new Account(Id = acct.Id, Industry = 'Agriculture');
    }

    Assert.isFalse(heartbeatAs(viewer, acct.Id, baseline).meaningfulChange);
  }

  @IsTest
  static void changesByIgnoredUsersAreNotMeaningful() {
    StubSelector selector = useStubs(true);
    selector.usersByPermission.put(
      PresenceService.IGNORE_CHANGES_PERMISSION,
      new Set<Id>{ UserInfo.getUserId() }
    );
    Account acct = testAccount();
    User viewer = testUser('viewer');
    Long baseline = acct.LastModifiedDate.getTime() - 1000;

    Assert.isFalse(heartbeatAs(viewer, acct.Id, baseline).meaningfulChange);
    Assert.isFalse(heartbeatAs(viewer, acct.Id, baseline).meaningfulChange);
    Assert.areEqual(
      1,
      selector.permissionLookups,
      'The ignored users are cached between heartbeats'
    );
  }

  @IsTest
  static void ownAndIgnoredChangesAreLeftOutOfWhatChanged() {
    StubSelector selector = useStubs(false);
    User viewer = testUser('viewer');
    User other = testUser('other');
    selector.usersByPermission.put(
      PresenceService.IGNORE_CHANGES_PERMISSION,
      new Set<Id>{ other.Id }
    );
    Account acct = testAccount();
    Datetime changed = acct.LastModifiedDate;
    selector.history.add(
      entry(
        'Industry',
        null,
        'Agriculture',
        UserInfo.getUserId(),
        'Admin',
        changed
      )
    );
    selector.history.add(
      entry('Rating', null, 'Hot', viewer.Id, 'Viewer', changed)
    );
    selector.history.add(
      entry('Phone', null, '555-0100', other.Id, 'Integration', changed)
    );
    selector.history.add(
      entry('created', null, null, UserInfo.getUserId(), 'Admin', changed)
    );

    PresenceSnapshot snapshot = heartbeatAs(
      viewer,
      acct.Id,
      changed.getTime() - 1000
    );

    Assert.areEqual(1, snapshot.changes.size());
    Assert.areEqual('Industry', snapshot.changes[0].fieldLabel);
    Assert.areEqual(1, snapshot.totalChanges);
  }

  // ---- Change detection: watched fields ----

  @IsTest
  static void changesToFieldsThatArentWatchedAreNotMeaningful() {
    StubSelector selector = useStubs(false);
    selector.config = watch('Industry, Rating');
    Account acct = testAccount();
    selector.history.add(
      entry(
        'Phone',
        null,
        '555-0100',
        UserInfo.getUserId(),
        'Admin',
        acct.LastModifiedDate
      )
    );

    PresenceSnapshot snapshot = heartbeatAs(
      testUser('viewer'),
      acct.Id,
      acct.LastModifiedDate.getTime() - 1000
    );

    Assert.isFalse(snapshot.meaningfulChange);
    Assert.areEqual(
      new Set<String>{ 'industry', 'rating' },
      selector.lastFieldFilter
    );
  }

  @IsTest
  static void watchedFieldChangesAreMeaningful() {
    StubSelector selector = useStubs(false);
    selector.config = watch('Industry;Rating\nNumberOfEmployees');
    Account acct = testAccount();
    Datetime earlier = acct.LastModifiedDate;
    Datetime later = earlier.addSeconds(2);
    selector.history.add(
      entry('Rating', 'Warm', 'Hot', testUser('other').Id, 'Other User', later)
    );
    selector.history.add(
      entry(
        'Industry',
        'Banking',
        'Agriculture',
        UserInfo.getUserId(),
        'Admin',
        earlier
      )
    );
    selector.history.add(
      entry(
        'NumberOfEmployees',
        1200,
        1500,
        UserInfo.getUserId(),
        'Admin',
        earlier
      )
    );

    PresenceSnapshot snapshot = heartbeatAs(
      testUser('viewer'),
      acct.Id,
      earlier.getTime() - 1000
    );

    Assert.isTrue(snapshot.meaningfulChange);
    Assert.areEqual(
      later.getTime(),
      snapshot.latestChangeMillis,
      'The newest watched change'
    );
    Assert.areEqual('Other User', snapshot.latestChangeByName);
    Assert.areEqual(3, snapshot.changes.size());
    Assert.areEqual('Account Rating', snapshot.changes[0].fieldLabel);
    Assert.areEqual('Warm', snapshot.changes[0].oldValue);
    Assert.areEqual('Hot', snapshot.changes[0].newValue);
    Assert.areEqual('PICKLIST', snapshot.changes[0].fieldType);
    Assert.areEqual('1500', snapshot.changes[2].newValue);
  }

  @IsTest
  static void watchedLookupsShowNamesRatherThanIds() {
    StubSelector selector = useStubs(false);
    selector.config = watch('OwnerId');
    Account acct = testAccount();
    Datetime changed = acct.LastModifiedDate;
    Id oldOwner = testUser('other').Id;
    Id newOwner = testUser('viewer').Id;
    PresenceSelector.HistoryEntry ids = entry(
      'Owner',
      oldOwner,
      newOwner,
      UserInfo.getUserId(),
      'Admin',
      changed
    );
    ids.dataType = 'EntityId';
    PresenceSelector.HistoryEntry names = entry(
      'Owner',
      'Presence other',
      'Presence viewer',
      UserInfo.getUserId(),
      'Admin',
      changed
    );
    names.dataType = 'Text';
    selector.history.add(ids);
    selector.history.add(names);

    PresenceSnapshot snapshot = heartbeatAs(
      testUser('viewer'),
      acct.Id,
      changed.getTime() - 1000
    );

    Assert.isTrue(
      selector.lastFieldFilter.contains('owner'),
      'History records OwnerId changes as Owner'
    );
    Assert.areEqual(1, snapshot.changes.size());
    Assert.areEqual('Presence other', snapshot.changes[0].oldValue);
    Assert.areEqual('Presence viewer', snapshot.changes[0].newValue);
  }

  @IsTest
  static void lookupChangesRecordedOnlyAsIdsShowNoValues() {
    StubSelector selector = useStubs(false);
    Account acct = testAccount();
    // Without DataType, rows of IDs on a lookup are recognized by their values
    selector.history.add(
      entry(
        'Parent',
        null,
        String.valueOf(acct.Id),
        UserInfo.getUserId(),
        'Admin',
        acct.LastModifiedDate
      )
    );

    PresenceSnapshot snapshot = heartbeatAs(
      testUser('viewer'),
      acct.Id,
      acct.LastModifiedDate.getTime() - 1000
    );

    Assert.areEqual(1, snapshot.changes.size());
    Assert.areEqual(
      'Parent Account',
      snapshot.changes[0].fieldLabel,
      'Without the " ID" of the lookup\'s label'
    );
    Assert.isFalse(snapshot.changes[0].valuesRecorded);
    Assert.isNull(snapshot.changes[0].newValue);
  }

  @IsTest
  static void hidesChangesToFieldsTheUserCantRead() {
    StubSelector selector = useStubs(false);
    User limited = newUser('limited', 'Minimum Access - Salesforce');
    System.runAs(new User(Id = UserInfo.getUserId())) {
      insert limited;
      // Account access with Phone readable, Industry not
      PermissionSet permissionSet = new PermissionSet(
        Name = 'Presence_FLS_Test',
        Label = 'Presence FLS Test'
      );
      insert permissionSet;
      insert new ObjectPermissions(
        ParentId = permissionSet.Id,
        SobjectType = 'Account',
        PermissionsRead = true
      );
      insert new FieldPermissions(
        ParentId = permissionSet.Id,
        SobjectType = 'Account',
        Field = 'Account.Phone',
        PermissionsRead = true
      );
      insert new PermissionSetAssignment(
        AssigneeId = limited.Id,
        PermissionSetId = permissionSet.Id
      );
    }
    Account acct = new Account(Name = 'Limited', OwnerId = limited.Id);
    insert acct;
    acct = [SELECT LastModifiedDate FROM Account WHERE Id = :acct.Id];
    selector.config = watch('Industry');
    selector.history.add(
      entry(
        'Industry',
        null,
        'Agriculture',
        UserInfo.getUserId(),
        'Admin',
        acct.LastModifiedDate
      )
    );

    PresenceSnapshot watchedSnapshot = heartbeatAs(
      limited,
      acct.Id,
      acct.LastModifiedDate.getTime() - 1000
    );

    Assert.isFalse(
      watchedSnapshot.meaningfulChange,
      'A change the user can\'t read doesn\'t alert them'
    );

    selector.config = null;
    selector.history.add(
      entry(
        'Phone',
        null,
        '555-0100',
        UserInfo.getUserId(),
        'Admin',
        acct.LastModifiedDate
      )
    );
    PresenceSnapshot anySnapshot = heartbeatAs(
      limited,
      acct.Id,
      acct.LastModifiedDate.getTime() - 1000
    );

    Assert.isTrue(anySnapshot.meaningfulChange);
    Assert.areEqual(1, anySnapshot.changes.size());
    Assert.areEqual('Account Phone', anySnapshot.changes[0].fieldLabel);
  }

  @IsTest
  static void formatsValuesForTheClient() {
    StubSelector selector = useStubs(false);
    User viewer = testUser('viewer');
    Opportunity opp = new Opportunity(
      Name = 'Presence Deal',
      StageName = 'Prospecting',
      CloseDate = Date.today(),
      OwnerId = viewer.Id
    );
    insert opp;
    opp = [SELECT LastModifiedDate FROM Opportunity WHERE Id = :opp.Id];
    Datetime changed = opp.LastModifiedDate;
    selector.history.add(
      entry(
        'CloseDate',
        Date.newInstance(2026, 3, 1),
        Date.newInstance(2026, 4, 15),
        UserInfo.getUserId(),
        'Admin',
        changed
      )
    );
    selector.history.add(
      entry('Amount', 40000.50, 52000, UserInfo.getUserId(), 'Admin', changed)
    );
    selector.history.add(
      entry('Description', null, null, UserInfo.getUserId(), 'Admin', changed)
    );
    selector.history.add(
      entry(
        'StageName',
        'Prospecting',
        'Closed Won',
        UserInfo.getUserId(),
        'Admin',
        changed
      )
    );

    PresenceSnapshot snapshot = heartbeatAs(
      viewer,
      opp.Id,
      changed.getTime() - 1000
    );

    Map<String, PresenceSnapshot.Change> byType = new Map<String, PresenceSnapshot.Change>();
    for (PresenceSnapshot.Change change : snapshot.changes) {
      byType.put(change.fieldType, change);
    }
    Assert.areEqual('2026-03-01', byType.get('DATE').oldValue);
    Assert.areEqual('2026-04-15', byType.get('DATE').newValue);
    Assert.areEqual('40000.50', byType.get('CURRENCY').oldValue);
    Assert.areEqual('52000', byType.get('CURRENCY').newValue);
    Assert.isFalse(
      byType.get('TEXTAREA').valuesRecorded,
      'Long text areas are recorded without values'
    );
    Assert.areEqual('Closed Won', byType.get('PICKLIST').newValue);
  }

  @IsTest
  static void formatsDateTimesAsEpochMillis() {
    StubSelector selector = useStubs(false);
    Account acct = testAccount();
    Datetime value = Datetime.newInstanceGmt(2026, 5, 1, 12, 0, 0);
    // History never records LastModifiedDate, but it's a date/time field on every object
    selector.history.add(
      entry(
        'LastModifiedDate',
        null,
        value,
        UserInfo.getUserId(),
        'Admin',
        acct.LastModifiedDate
      )
    );

    PresenceSnapshot snapshot = heartbeatAs(
      testUser('viewer'),
      acct.Id,
      acct.LastModifiedDate.getTime() - 1000
    );

    Assert.areEqual('DATETIME', snapshot.changes[0].fieldType);
    Assert.areEqual(
      String.valueOf(value.getTime()),
      snapshot.changes[0].newValue
    );
  }

  @IsTest
  static void capsTheChangesButCountsThemAll() {
    StubSelector selector = useStubs(false);
    Account acct = testAccount();
    for (Integer i = 0; i < PresenceService.MAX_CHANGES + 5; i++) {
      selector.history.add(
        entry(
          'Phone',
          null,
          '555-01' + i,
          UserInfo.getUserId(),
          'Admin',
          acct.LastModifiedDate
        )
      );
    }

    PresenceSnapshot snapshot = heartbeatAs(
      testUser('viewer'),
      acct.Id,
      acct.LastModifiedDate.getTime() - 1000
    );

    Assert.areEqual(PresenceService.MAX_CHANGES, snapshot.changes.size());
    Assert.areEqual(PresenceService.MAX_CHANGES + 5, snapshot.totalChanges);
  }

  // ---- Admin ----

  @IsTest
  static void givesAdminsTheConfigurationDetails() {
    StubSelector selector = useStubs(false);
    selector.config = watch('Industry, Rating, Bogus__c');
    selector.trackedFields = new Set<String>{ 'industry' };
    Account acct = testAccount();
    User viewer = testUser('viewer');
    assignPermissionSet(viewer.Id, 'Record_Presence_Admin');

    PresenceSnapshot snapshot = heartbeatAs(viewer, acct.Id, null);

    Assert.areEqual('Account', snapshot.adminInfo.objectApiName);
    Assert.areEqual('AccountHistory', snapshot.adminInfo.historyObject);
    Assert.areEqual(
      new Set<String>{ 'Industry', 'Rating' },
      new Set<String>(snapshot.adminInfo.watchedFields)
    );
    Assert.areEqual(
      new List<String>{ 'Rating' },
      snapshot.adminInfo.untrackedWatchedFields
    );
    Assert.areEqual(
      new List<String>{ 'Bogus__c' },
      snapshot.adminInfo.unknownWatchedFields
    );
  }

  @IsTest
  static void flagsEveryWatchedFieldWhenTheObjectHasNoHistory() {
    StubSelector selector = useStubs(false);
    selector.config = watch('Industry');
    selector.hasHistoryObject = false;
    Account acct = testAccount();
    User viewer = testUser('viewer');
    assignPermissionSet(viewer.Id, 'Record_Presence_Admin');

    PresenceSnapshot snapshot = heartbeatAs(viewer, acct.Id, null);

    Assert.isNull(snapshot.adminInfo.historyObject);
    Assert.areEqual(
      new List<String>{ 'Industry' },
      snapshot.adminInfo.untrackedWatchedFields
    );
  }

  @IsTest
  static void givesOtherUsersNoAdminDetails() {
    useStubs(false);

    Assert.isNull(
      heartbeatAs(testUser('viewer'), testAccount().Id, null).adminInfo
    );
  }

  // ---- Helpers ----

  private static StubSelector useStubs(Boolean cacheAvailable) {
    StubSelector selector = new StubSelector();
    PresenceService.selector = selector;
    PresenceService.cache = new MemoryCache(cacheAvailable);
    return selector;
  }

  private static PresenceSnapshot heartbeatAs(
    User runAs,
    Id recordId,
    Long baselineMillis
  ) {
    PresenceSnapshot snapshot;
    System.runAs(runAs) {
      snapshot = PresenceService.heartbeat(recordId, baselineMillis, 25);
    }
    return snapshot;
  }

  // Another user seen on the record at seenMillis, in whichever store the service is using
  private static void seedPresence(Id recordId, Id userId, Long seenMillis) {
    PresenceStore.forRequest(PresenceService.cache)
      .touch(recordId, userId, seenMillis, seenMillis, true);
  }

  private static List<Presence__c> presenceRows(Id recordId) {
    return [
      SELECT Id, User__c
      FROM Presence__c
      WHERE Record_Id__c = :recordId
      WITH SYSTEM_MODE
    ];
  }

  private static void assertEmpty(PresenceSnapshot snapshot) {
    Assert.areEqual(0, snapshot.viewers.size());
    Assert.isFalse(snapshot.meaningfulChange);
    Assert.isNull(snapshot.lastModifiedMillis);
    Assert.isNull(snapshot.storageMode);
    Assert.isNull(snapshot.adminInfo);
  }

  private static Record_Presence_Object__mdt watch(String watchedFields) {
    return new Record_Presence_Object__mdt(
      Object_API_Name__c = 'Account',
      Watched_Fields__c = watchedFields,
      Enabled__c = true
    );
  }

  private static PresenceSelector.HistoryEntry entry(
    String field,
    Object oldValue,
    Object newValue,
    Id createdById,
    String createdByName,
    Datetime createdDate
  ) {
    PresenceSelector.HistoryEntry row = new PresenceSelector.HistoryEntry();
    row.field = field;
    row.oldValue = oldValue;
    row.newValue = newValue;
    row.createdById = createdById;
    row.createdByName = createdByName;
    row.createdDate = createdDate;
    return row;
  }

  private static Account testAccount() {
    return [
      SELECT Id, LastModifiedDate, LastModifiedBy.Name
      FROM Account
      WHERE Name = 'Presence Test'
    ];
  }

  private static User testUser(String alias) {
    return [SELECT Id, Name FROM User WHERE LastName = :('Presence ' + alias)];
  }

  private static void assignPermissionSet(Id userId, String permissionSetName) {
    System.runAs(new User(Id = UserInfo.getUserId())) {
      insert new PermissionSetAssignment(
        AssigneeId = userId,
        PermissionSetId = [
          SELECT Id
          FROM PermissionSet
          WHERE Name = :permissionSetName
        ]
        .Id
      );
    }
  }

  private static User newUser(String alias, String profileName) {
    String unique =
      alias + String.valueOf(Crypto.getRandomInteger()).remove('-');
    return new User(
      Alias = alias.left(8),
      Email = unique + '@example.com',
      EmailEncodingKey = 'UTF-8',
      LastName = 'Presence ' + alias,
      LanguageLocaleKey = 'en_US',
      LocaleSidKey = 'en_US',
      ProfileId = [SELECT Id FROM Profile WHERE Name = :profileName]
      .Id,
      TimeZoneSidKey = 'America/Los_Angeles',
      Username = unique + '@presence.test'
    );
  }
}
