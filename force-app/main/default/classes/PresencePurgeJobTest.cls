@IsTest
private class PresencePurgeJobTest {
  @IsTest
  static void hardDeletesRowsNotRefreshedForAnHour() {
    Datetime stale = Datetime.now()
      .addMinutes(-PresencePurgeJob.RETENTION_MINUTES - 5);
    Presence__c old = row('001000000000001AAA', stale);
    Presence__c fresh = row('001000000000002AAA', Datetime.now());
    Database.insert(
      new List<Presence__c>{ old, fresh },
      AccessLevel.SYSTEM_MODE
    );

    Test.startTest();
    Database.executeBatch(new PresencePurgeJob());
    Test.stopTest();

    List<Presence__c> remaining = [SELECT Id FROM Presence__c WITH SYSTEM_MODE];
    Assert.areEqual(1, remaining.size());
    Assert.areEqual(fresh.Id, remaining[0].Id);
    Assert.isFalse(
      Database.undelete(old.Id, false).isSuccess(),
      'Not left in the Recycle Bin'
    );
  }

  @IsTest
  static void schedulesHourly() {
    Test.startTest();
    Id jobId = PresencePurgeJob.scheduleHourly();
    Test.stopTest();

    CronTrigger cron = [
      SELECT CronExpression, CronJobDetail.Name
      FROM CronTrigger
      WHERE Id = :jobId
    ];
    Assert.areEqual('0 0 * * * ?', cron.CronExpression);
    Assert.areEqual(PresencePurgeJob.JOB_NAME, cron.CronJobDetail.Name);
  }

  @IsTest
  static void scheduledRunStartsThePurge() {
    Database.insert(
      row('001000000000001AAA', Datetime.now().addDays(-1)),
      AccessLevel.SYSTEM_MODE
    );

    Test.startTest();
    new PresencePurgeJob().execute((SchedulableContext) null);
    Test.stopTest();

    Assert.areEqual(0, [SELECT COUNT() FROM Presence__c WITH SYSTEM_MODE]);
  }

  private static Presence__c row(String recordId, Datetime lastSeen) {
    String key = recordId + ':' + UserInfo.getUserId();
    return new Presence__c(
      Name = key,
      Key__c = key,
      Record_Id__c = recordId,
      User__c = UserInfo.getUserId(),
      Last_Seen__c = lastSeen
    );
  }
}
