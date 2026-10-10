// Hard-deletes Presence__c rows that haven't been refreshed for an hour. Rows are only written when the RecordPresence
// cache partition has no capacity, and heartbeats ignore rows older than a few minutes, so this keeps presence from
// piling up as a record of who viewed what. Schedule it hourly after install:
//     PresencePurgeJob.scheduleHourly();
// Runs without sharing: rows belong to the users who viewed the records, and the object is Private.
public without sharing class PresencePurgeJob implements Schedulable, Database.Batchable<SObject> {
  public static final String JOB_NAME = 'Record Presence purge';
  @TestVisible
  private static final Integer RETENTION_MINUTES = 60;

  // Schedules the job at the start of every hour and returns its CronTrigger ID
  public static Id scheduleHourly() {
    return System.schedule(JOB_NAME, '0 0 * * * ?', new PresencePurgeJob());
  }

  public void execute(SchedulableContext context) {
    Database.executeBatch(new PresencePurgeJob(), 2000);
  }

  public Database.QueryLocator start(Database.BatchableContext context) {
    Datetime cutoff = Datetime.now().addMinutes(-RETENTION_MINUTES);
    return Database.getQueryLocator(
      [SELECT Id FROM Presence__c WHERE Last_Seen__c < :cutoff WITH SYSTEM_MODE]
    );
  }

  public void execute(Database.BatchableContext context, List<SObject> rows) {
    PresenceStore.hardDelete((List<Presence__c>) rows);
  }

  public void finish(Database.BatchableContext context) {
    // Nothing to do; rows that failed to delete are picked up next hour
  }
}
